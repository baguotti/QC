import Foundation
import SwiftUI
import VideoQCLib

/// Where a plan's tabs and rows come from. Today: a sheet shared as "Anyone with the link" (`PublicSheetSource`).
/// Google sign-in (Sheets API, private and client sheets) will be a second implementation of the same two calls.
protocol PlanSheetSource: Sendable {
    /// Title and visible tabs of the spreadsheet.
    func describe(_ link: PlanSheetLink) async throws -> (title: String, tabs: [PlanTab])
    /// One tab as CSV.
    func csv(_ link: PlanSheetLink, tab: PlanTab) async throws -> String
}

enum PlanSourceError: LocalizedError {
    case notShared
    case http(Int)
    case noTabs

    var errorDescription: String? {
        switch self {
        case .notShared: return "The sheet isn't shared as “Anyone with the link”. Share it that way in Google Sheets, or wait for Google sign-in."
        case .http(let code): return "Google Sheets answered \(code)."
        case .noTabs: return "No tabs found in the sheet."
        }
    }
}

/// A link-shared sheet, read without signing in: `htmlview` lists the tabs, `export?format=csv&gid=` reads one.
/// (`gviz/tq` CSV was avoided: it types each column and blanks values that don't fit the column's majority type.)
struct PublicSheetSource: PlanSheetSource {
    let session: URLSession

    static let shared = PublicSheetSource(session: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }())

    private func get(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw PlanSourceError.http(0) }
        // Unshared sheets redirect to the Google sign-in page.
        if http.url?.host?.contains("accounts.google.com") == true || http.statusCode == 401 || http.statusCode == 403 {
            throw PlanSourceError.notShared
        }
        guard http.statusCode == 200 else { throw http.statusCode == 404 ? PlanSourceError.notShared : PlanSourceError.http(http.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }

    func describe(_ link: PlanSheetLink) async throws -> (title: String, tabs: [PlanTab]) {
        let html = try await get(URL(string: "https://docs.google.com/spreadsheets/d/\(link.sheetID)/htmlview")!)
        let (title, tabs) = Self.parseHTMLView(html)
        if tabs.isEmpty, let gid = link.gid { return (title, [PlanTab(gid: gid, name: "Sheet")]) }
        guard !tabs.isEmpty else { throw PlanSourceError.noTabs }
        return (title, tabs)
    }

    func csv(_ link: PlanSheetLink, tab: PlanTab) async throws -> String {
        let text = try await get(URL(string: "https://docs.google.com/spreadsheets/d/\(link.sheetID)/export?format=csv&gid=\(tab.gid)")!)
        if text.hasPrefix("<!DOCTYPE") || text.hasPrefix("<html") { throw PlanSourceError.notShared }
        return text
    }

    /// `{name: "Placement", pageUrl: "…", gid: "1810111647"}` entries and the `<title>`.
    static func parseHTMLView(_ html: String) -> (String, [PlanTab]) {
        var tabs: [PlanTab] = []
        let pattern = #"\{name: "((?:[^"\\]|\\.)*)", pageUrl: "[^"]*", gid: "(\d+)""#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = html as NSString
            for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let name = unescape(ns.substring(with: m.range(at: 1)))
                let gid = ns.substring(with: m.range(at: 2))
                if !tabs.contains(where: { $0.gid == gid }) { tabs.append(PlanTab(gid: gid, name: name)) }
            }
        }
        var title = ""
        if let start = html.range(of: "<title>"), let end = html.range(of: "</title>", range: start.upperBound..<html.endIndex) {
            title = String(html[start.upperBound..<end.lowerBound])
                .replacingOccurrences(of: " - Google Sheets", with: "")
                .replacingOccurrences(of: " - Google Drive", with: "")
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
                .trimmingCharacters(in: .whitespaces)
        }
        return (title, tabs)
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        let json = "\"" + text + "\""
        return (try? JSONDecoder().decode(String.self, from: Data(json.utf8))) ?? text
    }
}

/// The linked Delivery Plan: rows from the sheet, re-read every 60 s while a plan panel is on screen, matched against
/// the Inspect tab's measured files. Observed only by the plan panels (drawer and window), never by `ContentView`,
/// so refreshes and matching don't redraw the window. Fetching, parsing and matching run off the main thread.
@MainActor
final class DeliveryPlanStore: ObservableObject {
    static let shared = DeliveryPlanStore()

    struct Config: Codable, Equatable {
        var link: PlanSheetLink
        var title: String
        var tabs: [PlanTab]
        /// Tabs left out (by gid); new tabs are included.
        var excluded: Set<String> = []

        var included: [PlanTab] { tabs.filter { !excluded.contains($0.gid) } }
    }

    /// What a row looked like when changes were last marked seen.
    struct SeenRow: Codable, Equatable {
        var label: String
        var values: [String: String]
    }

    enum Change: Equatable {
        case added
        /// Field titles with old → new values.
        case changed([String])
    }

    enum Phase: Equatable { case idle, loading, failed(String) }

    @Published private(set) var config: Config?
    @Published private(set) var rows: [PlanRow] = []
    @Published private(set) var match: PlanMatch = .empty
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var changes: [String: Change] = [:]
    @Published private(set) var removed: [SeenRow] = []
    /// Tabs whose header row wasn't found (shown so a renamed header doesn't silently drop a tab).
    @Published private(set) var unreadTabs: [String] = []
    /// Rows per tab (by gid) from the last read of each tab, for the tab picker.
    @Published private(set) var tabCounts: [String: Int] = [:]
    /// Inspect has files (matching is meaningful).
    @Published private(set) var hasFiles = false

    private var seen: [String: SeenRow] = [:]
    private var files: [PlanFile] = []
    private var visiblePanels = 0
    private var pollTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    private var loadedFromDisk = false
    private let source: PlanSheetSource = PublicSheetSource.shared

    static let refreshInterval: Duration = .seconds(60)
    private static let configKey = "deliveryPlanConfig"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            self.config = config
        }
    }

    // MARK: Linking

    func link(_ text: String) async {
        guard let link = PlanSheetLink.parse(text) else {
            phase = .failed("That isn't a Google Sheets link.")
            return
        }
        phase = .loading
        do {
            let (title, tabs) = try await source.describe(link)
            // One tab to start with (sheets often list the same files twice, e.g. by placement and by edit): the tab
            // the link points at, else the one with the most rows. Others are a click away in the ••• menu.
            let (chosen, counts) = try await Self.startingTab(link: link, tabs: tabs, source: source)
            tabCounts = counts
            var config = Config(link: link, title: title.isEmpty ? "Delivery Plan" : title, tabs: tabs)
            config.excluded = Set(tabs.map(\.gid).filter { $0 != chosen })
            self.config = config
            saveConfig()
            seen = [:]
            rows = []
            changes = [:]
            removed = []
            await refresh(adoptAsSeen: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated private static func startingTab(link: PlanSheetLink, tabs: [PlanTab], source: PlanSheetSource) async throws -> (String?, [String: Int]) {
        let counts = try await withThrowingTaskGroup(of: (String, Int).self) { group in
            for tab in tabs {
                group.addTask { (tab.gid, PlanParser.rows(csv: try await source.csv(link, tab: tab), tab: tab.name).count) }
            }
            var out: [String: Int] = [:]
            for try await (gid, count) in group { out[gid] = count }
            return out
        }
        if let gid = link.gid, tabs.contains(where: { $0.gid == gid }) { return (gid, counts) }
        return (tabs.max { (counts[$0.gid] ?? 0) < (counts[$1.gid] ?? 0) }?.gid, counts)
    }

    func unlink() {
        guard let config else { return }
        self.config = nil
        UserDefaults.standard.removeObject(forKey: Self.configKey)
        rows = []
        match = .empty
        changes = [:]
        removed = []
        unreadTabs = []
        tabCounts = [:]
        seen = [:]
        phase = .idle
        lastUpdated = nil
        let dir = Self.directory(config.link.sheetID)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: dir) }
    }

    func setIncluded(_ tab: PlanTab, _ included: Bool) {
        guard var config else { return }
        if included { config.excluded.remove(tab.gid) } else { config.excluded.insert(tab.gid) }
        self.config = config
        saveConfig()
        Task { await refresh() }
    }

    private func saveConfig() {
        if let config, let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.configKey) }
    }

    // MARK: Refreshing

    /// Panels call these on appear / disappear: the sheet is only polled while one is on screen.
    func panelAppeared() {
        visiblePanels += 1
        guard visiblePanels == 1 else { return }
        pollTask = Task { [weak self] in
            await self?.loadCachedIfNeeded()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        if visiblePanels == 0 { pollTask?.cancel(); pollTask = nil }
    }

    /// Re-reads the tab list and every included tab. `adoptAsSeen`: the first read of a new link isn't "changes".
    func refresh(adoptAsSeen: Bool = false) async {
        guard let config, phase != .loading || adoptAsSeen else { return }
        phase = .loading
        let source = source
        do {
            // The tab list too: tabs added or renamed in the sheet show up without relinking.
            let (title, tabs) = try await source.describe(config.link)
            var updated = config
            updated.tabs = tabs
            if !title.isEmpty { updated.title = title }
            if updated != self.config, self.config?.link == config.link {
                self.config = updated
                saveConfig()
            }
            let included = updated.included
            let csvs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for (index, tab) in included.enumerated() {
                    group.addTask { (index, try await source.csv(config.link, tab: tab)) }
                }
                var out = [String](repeating: "", count: included.count)
                for try await (index, text) in group { out[index] = text }
                return out
            }
            guard self.config?.link == config.link else { return }   // relinked meanwhile
            await apply(tabs: included, csvs: csvs, adoptAsSeen: adoptAsSeen)
            phase = .idle
            lastUpdated = Date()
            let dir = Self.directory(config.link.sheetID)
            let cache = Dictionary(uniqueKeysWithValues: zip(included.map(\.gid), csvs))
            Task.detached(priority: .utility) { Self.writeCache(cache, to: dir) }
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(tabs: [PlanTab], csvs: [String], adoptAsSeen: Bool) async {
        let parsed = await Task.detached(priority: .userInitiated) { () -> ([PlanRow], [String]) in
            var all: [PlanRow] = []
            var unread: [String] = []
            for (tab, text) in zip(tabs, csvs) {
                let rows = PlanParser.rows(csv: text, tab: tab.name)
                if rows.isEmpty, PlanParser.header(PlanParser.csv(text)) == nil { unread.append(tab.name) }
                all += rows
            }
            PlanParser.flagDuplicates(&all)
            return (all, unread)
        }.value
        let (newRows, unread) = parsed
        var counts = tabCounts
        for tab in tabs { counts[tab.gid] = newRows.filter { $0.tab == tab.name }.count }
        if counts != tabCounts { tabCounts = counts }
        if adoptAsSeen || (seen.isEmpty && rows.isEmpty) {
            seen = Self.snapshot(newRows)
            saveSeen()
        }
        let rowsChanged = newRows != rows
        if rowsChanged { rows = newRows }
        if unread != unreadTabs { unreadTabs = unread }
        recomputeChanges()
        if rowsChanged { rematch() }
    }

    private func loadCachedIfNeeded() async {
        guard !loadedFromDisk, let config else { return }
        loadedFromDisk = true
        let dir = Self.directory(config.link.sheetID)
        let (cache, seen) = await Task.detached(priority: .userInitiated) { () -> ([String: String], [String: SeenRow]) in
            let cache = (try? Data(contentsOf: dir.appendingPathComponent("tabs.json")))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            let seen = (try? Data(contentsOf: dir.appendingPathComponent("seen.json")))
                .flatMap { try? JSONDecoder().decode([String: SeenRow].self, from: $0) } ?? [:]
            return (cache, seen)
        }.value
        self.seen = seen
        let tabs = config.included.filter { cache[$0.gid] != nil }
        if !tabs.isEmpty, rows.isEmpty {
            await apply(tabs: tabs, csvs: tabs.map { cache[$0.gid]! }, adoptAsSeen: false)
        }
    }

    // MARK: Changes

    private static func label(_ row: PlanRow) -> String {
        [row.name, row.value(.resolution), row.value(.placement)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func snapshot(_ rows: [PlanRow]) -> [String: SeenRow] {
        Dictionary(rows.map { ($0.id, SeenRow(label: label($0), values: $0.content)) }, uniquingKeysWith: { a, _ in a })
    }

    private func recomputeChanges() {
        var result: [String: Change] = [:]
        for row in rows {
            guard let old = seen[row.id] else { result[row.id] = .added; continue }
            let now = row.content
            guard now != old.values else { continue }
            let fields = PlanField.allCases.compactMap { field -> String? in
                let a = old.values[field.rawValue] ?? "", b = now[field.rawValue] ?? ""
                return a == b ? nil : "\(field.title): \(a.isEmpty ? "—" : a) → \(b.isEmpty ? "—" : b)"
            }
            result[row.id] = .changed(fields)
        }
        let present = Set(rows.map(\.id))
        let gone = seen.filter { !present.contains($0.key) }.map(\.value).sorted { $0.label < $1.label }
        if result != changes { changes = result }
        if gone != removed { removed = gone }
    }

    /// Accepts the sheet as it is now: highlights and the Removed list clear.
    func markSeen() {
        seen = Self.snapshot(rows)
        saveSeen()
        recomputeChanges()
    }

    private func saveSeen() {
        guard let config else { return }
        let dir = Self.directory(config.link.sheetID)
        let seen = seen
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(seen) { try? data.write(to: dir.appendingPathComponent("seen.json"), options: .atomic) }
        }
    }

    // MARK: Files

    /// The Inspect tab's measured files (called when its list changes; cheap when nothing changed).
    func setAssets(_ assets: [DeliverableAsset]) {
        let newFiles = assets.filter { $0.width > 0 || $0.durationSeconds > 0 }.map(PlanFile.init)
        guard newFiles != files else { return }
        files = newFiles
        if hasFiles != !files.isEmpty { hasFiles = !files.isEmpty }
        rematch()
    }

    private func rematch() {
        let rows = rows, files = files
        matchTask?.cancel()
        matchTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { PlanMatcher.match(rows: rows, files: files) }.value
            guard !Task.isCancelled, let self, result != self.match else { return }
            self.match = result
        }
    }

    // MARK: Disk

    static func directory(_ sheetID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/DeliveryPlan/\(sheetID)", isDirectory: true)
    }

    nonisolated private static func writeCache(_ cache: [String: String], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: dir.appendingPathComponent("tabs.json"), options: .atomic) }
    }
}
