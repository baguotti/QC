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
    /// One tab as Sheets draws it (widths, colours, borders…), or nil when that can't be read: the CSV is enough.
    func grid(_ link: PlanSheetLink, tab: PlanTab) async -> PlanGrid?
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

    func grid(_ link: PlanSheetLink, tab: PlanTab) async -> PlanGrid? {
        let url = URL(string: "https://docs.google.com/spreadsheets/d/\(link.sheetID)/htmlview/sheet?headers=true&gid=\(tab.gid)")!
        guard let html = try? await get(url) else { return nil }
        // ~0.2 s (≥ 1 s on efficiency cores) for 1,100 rows, and only formatting: never ahead of playback.
        return await Task.detached(priority: .utility) { PlanGrid.parseHTML(html) }.value
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
        /// The Apps Script that writes cells (editing is off without it).
        var writer: PlanWriteLink? = nil

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
    @Published private(set) var rows: [PlanRow] = [] { didSet { rowsVersion &+= 1 } }
    private var rowsVersion = 0
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
    /// Each included tab as the sheet draws it, by gid (the Sheet view).
    @Published private(set) var grids: [String: PlanGrid] = [:]
    /// Files selected in Inspect: the rows holding them are highlighted.
    @Published private(set) var selectedFiles: Set<URL> = []
    /// Bumped when Inspect's selection changes there (not from a plan click): panels scroll to the row.
    @Published private(set) var scrollRequest = 0
    /// What a plan click asked Inspect to select, so its echo doesn't scroll the plan.
    private var revealedFromPlan: Set<URL>? = nil

    /// Inspect's selection changed (`ContentView` forwards it).
    func inspectSelectionChanged(_ urls: Set<URL>) {
        guard urls != selectedFiles else { revealedFromPlan = nil; return }
        selectedFiles = urls
        if urls != revealedFromPlan, !urls.isEmpty { scrollRequest += 1 }
        revealedFromPlan = nil
    }

    func noteRevealFromPlan(_ urls: [URL]) { revealedFromPlan = Set(urls) }

    /// Each row's state (by row id): its QC status when set, else what its files say.
    @Published private(set) var states: [String: PlanRowState] = [:]
    /// Inspect's view of the plan, by file: code, row and state; nil state = not in the plan. Rebuilt only when it
    /// changes, so `ContentView` (which mirrors it for the Inspect table) redraws once per change, never per poll.
    @Published private(set) var fileIndex: [URL: PlanFileInfo] = [:]
    /// The deployed script's version (nil until checked); statuses need version 2.
    @Published private(set) var scriptVersion: Int? = nil
    /// Dropdown choices per tab (gid), keyed by header (lower case) or "#" + sheet column index (script v4).
    @Published private(set) var cellLists: [String: [String: [String]]] = [:]
    /// Every batch named in the plan (pending edits included), in natural order.
    @Published private(set) var batches: [String] = []
    /// Whether any included tab has a Batch column.
    var hasBatchColumn: Bool { headers.values.contains { $0.columns[.batch] != nil } }
    /// The script's fingerprint of the dropdown choices at the last 10 s check.
    private var lastListsSig: String?
    var scriptOutdated: Bool { config?.writer != nil && (scriptVersion ?? AppsScriptWriter.scriptVersion) < AppsScriptWriter.scriptVersion }

    /// The last cell edit's outcome, for the status line.
    @Published private(set) var editState: EditState = .idle

    enum EditState: Equatable { case idle, saving(Int), saved, failed(String) }

    /// A cell by sheet row (1-based) and column (0-based).
    struct CellKey: Hashable, Sendable { let line: Int; let column: Int }
    private struct PendingEdit { let value: String; let since: Date }
    /// Edits sent but not yet seen in a read of the sheet: laid over every read so the cell doesn't flick back.
    private var pending: [String: [CellKey: PendingEdit]] = [:]
    /// Grids as last read from the sheet (`grids` = these + pending edits).
    private var readGrids: [String: PlanGrid] = [:]
    private var savingCount = 0
    private var refreshAfterEdit: Task<Void, Never>?

    /// QC columns sent but not yet seen in a read (by lower-cased code), laid over rows and grids.
    /// Columns QCpie wrote (QC columns, Batch, Frame.io, Uploaded) by field, until a read shows them.
    private struct PendingQC { var values: [PlanField: String] = [:]; var since: Date }
    private var pendingQC: [String: PendingQC] = [:]
    private var queuedQC: [String: PlanStatusItem] = [:]
    private var flushTask: Task<Void, Never>?
    /// Each tab's header (by gid): its line and the column of each field.
    private var headers: [String: (line: Int, columns: [PlanField: Int])] = [:]
    private var lastCounter: Int? = nil
    /// The script was asked to add the QC columns; reset by each read (which shows whether they're there).
    /// Columns asked of the script since the last read (each at most once per read).
    private var requestedColumns: Set<PlanField> = []
    /// Bumped when matching or files change (cache key for per-row check summaries).
    private(set) var matchRevision = 0

    /// The key a new script is made with, kept until editing is connected: reopening the set-up sheet after copying
    /// the script must not make a different one.
    var setupToken: String {
        if let token = UserDefaults.standard.string(forKey: "planSetupToken") { return token }
        let token = AppsScriptWriter.newToken()
        UserDefaults.standard.set(token, forKey: "planSetupToken")
        return token
    }

    private var seen: [String: SeenRow] = [:]
    private var files: [PlanFile] = []
    private var visiblePanels = 0
    private var pollTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    private var loadedFromDisk = false
    private var lastCachedCSVs: [String] = []
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
            grids = [:]; readGrids = [:]; pending = [:]; pendingQC = [:]; queuedQC = [:]; states = [:]; fileIndex = [:]; headers = [:]; scriptVersion = nil; lastCounter = nil; cellLists = [:]; lastListsSig = nil
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
        grids = [:]; readGrids = [:]; pending = [:]; pendingQC = [:]; queuedQC = [:]; states = [:]; fileIndex = [:]; headers = [:]; scriptVersion = nil; lastCounter = nil; cellLists = [:]; lastListsSig = nil
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
            await self?.checkScript()
            // Coming back to Inspect or the plan within a minute of the last read: no full re-read.
            if let last = self?.lastUpdated, Date().timeIntervalSince(last) < 60 {} else { await self?.refresh() }
            var lastFull = self?.lastUpdated ?? Date()
            while !Task.isCancelled {
                // With the script (v2): a few bytes every 10 s, the full read only when something changed (and every
                // 3 min regardless). Without: the full read every minute.
                if let writer = self?.config?.writer, (self?.scriptVersion ?? 0) >= 2 {
                    // Every 10 s while QCpie is in front, every minute behind other apps.
                    try? await Task.sleep(for: .seconds(NSApp.isActive ? 10 : 60))
                    guard !Task.isCancelled, let self else { return }
                    let changes = try? await AppsScriptWriter.changes(writer)
                    let counter = changes?.counter
                    // Dropdown choices edited in Sheets (not counted as edits): re-read them alone.
                    if let sig = changes?.listsSig {
                        if let last = lastListsSig, last != sig, let config {
                            await readLists(tabs: config.included, link: config.link)
                        }
                        lastListsSig = sig
                    }
                    // Each read records the counter it saw (`counterAtRead`), so our own saves, already read after
                    // saving, don't cause a second full read (~1 MB) here.
                    let moved = counter != nil && lastCounter != nil && counter != lastCounter
                    if counter != nil { lastCounter = counter }
                    if moved || Date().timeIntervalSince(lastFull) > 180 {
                        await refresh()
                        lastFull = Date()
                    }
                } else {
                    try? await Task.sleep(for: Self.refreshInterval)
                    guard !Task.isCancelled else { return }
                    await self?.refresh()
                    lastFull = Date()
                }
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
        // The change counter as of this read: edits already in it (our own saves included) are in what we read, so
        // the 10 s check only reads again for edits made after it.
        var counterAtRead: Int? = nil
        if let writer = config.writer, (scriptVersion ?? 0) >= 2 { counterAtRead = try? await AppsScriptWriter.changeCounter(writer) }
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
            // The formatted grid is read alongside: a failure there only costs the formatting.
            let fetched = try await withThrowingTaskGroup(of: (Int, String, PlanGrid?).self) { group in
                for (index, tab) in included.enumerated() {
                    group.addTask {
                        async let grid = source.grid(config.link, tab: tab)
                        let text = try await source.csv(config.link, tab: tab)
                        return (index, text, await grid)
                    }
                }
                var out = [(String, PlanGrid?)](repeating: ("", nil), count: included.count)
                for try await (index, text, grid) in group { out[index] = (text, grid) }
                return out
            }
            guard self.config?.link == config.link else { return }   // relinked meanwhile
            let csvs = fetched.map(\.0)
            await apply(tabs: included, csvs: csvs, adoptAsSeen: adoptAsSeen)
            let gridsChanged = await applyGrids(tabs: included, csvs: csvs, formatted: fetched.map(\.1))
            phase = .idle
            lastUpdated = Date()
            if let counterAtRead { lastCounter = counterAtRead }
            Task { await self.readLists(tabs: included, link: config.link) }
            guard gridsChanged || csvs != lastCachedCSVs else { return }   // nothing new to write
            lastCachedCSVs = csvs
            let dir = Self.directory(config.link.sheetID)
            let cache = Dictionary(uniqueKeysWithValues: zip(included.map(\.gid), csvs))
            let gridCache = readGrids
            Task.detached(priority: .utility) { Self.writeCache(cache, grids: gridCache, to: dir) }
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(tabs: [PlanTab], csvs: [String], adoptAsSeen: Bool) async {
        let oldRows = rows
        let parsed = await Task.detached(priority: .userInitiated) { () -> ([PlanRow], [String], [String: (line: Int, columns: [PlanField: Int])], Bool, Bool) in
            var all: [PlanRow] = []
            var unread: [String] = []
            var headers: [String: (line: Int, columns: [PlanField: Int])] = [:]
            for (tab, text) in zip(tabs, csvs) {
                let (rows, header) = PlanParser.parse(csv: text, tab: tab.name)   // one CSV parse for both
                if let header {
                    headers[tab.gid] = (header.index + 1, header.columns)
                } else if rows.isEmpty {
                    unread.append(tab.name)
                }
                all += rows
            }
            PlanParser.flagDuplicates(&all)
            // Compared here, not on the main thread (~50 ms for 1,100 rows on efficiency cores).
            let rowsChanged = all != oldRows
            // Matching ignores QC columns: a status change doesn't re-run it.
            let matchChanged = rowsChanged && all.map(\.matchSignature) != oldRows.map(\.matchSignature)
            return (all, unread, headers, rowsChanged, matchChanged)
        }.value
        let (newRows, unread, newHeaders, rowsChanged, matchChanged) = parsed
        headers = newHeaders
        requestedColumns = []
        var counts = tabCounts
        for tab in tabs { counts[tab.gid] = newRows.filter { $0.tab == tab.name }.count }
        if counts != tabCounts { tabCounts = counts }
        if adoptAsSeen || (seen.isEmpty && rows.isEmpty) {
            seen = Self.snapshot(newRows)
            saveSeen()
        }
        if rowsChanged { rows = newRows }
        if unread != unreadTabs { unreadTabs = unread }
        recomputeChanges()
        dropSettledQC()
        if matchChanged { rematch() } else if rowsChanged { recomputeStates() }
    }

    /// The formatted grid when it was read, else one rebuilt from the CSV. Publishes only what changed.
    @discardableResult
    private func applyGrids(tabs: [PlanTab], csvs: [String], formatted: [PlanGrid?]) async -> Bool {
        let current = readGrids
        let built = await Task.detached(priority: .userInitiated) { () -> [String: PlanGrid] in
            var out: [String: PlanGrid] = [:]
            for (index, tab) in tabs.enumerated() {
                if let grid = formatted[index] { out[tab.gid] = grid; continue }
                // Keep a formatted grid from an earlier read over an unformatted rebuild.
                let rebuilt = PlanGrid.fromCSV(csvs[index])
                if let old = current[tab.gid], old.formatted, old.rows.count == rebuilt.rows.count { out[tab.gid] = old } else { out[tab.gid] = rebuilt }
            }
            return out
        }.value
        let changed = built != readGrids
        readGrids = built
        publishGrids()
        return changed
    }

    /// Read grids with pending edits laid over. An edit leaves once the sheet shows it (or after 2 minutes).
    private func publishGrids() {
        var out = readGrids
        // Pending QC columns, by code → this tab's line for that code.
        if !pendingQC.isEmpty, let config {
            for tab in config.included {
                guard var grid = out[tab.gid], headers[tab.gid] != nil else { continue }
                // QCpie's columns in this tab's view, found once per tab.
                var columns: [PlanField: Int] = [:]
                for field in PlanField.allCases where field.isTracking { columns[field] = gridColumn(field, gid: tab.gid) }
                var edits: [CellKey: String] = [:]
                for row in rows where row.tab == tab.name {
                    guard let code = row.code, let p = pendingQC[code.lowercased()] else { continue }
                    for (field, value) in p.values {
                        if let column = columns[field] { edits[CellKey(line: row.line, column: column)] = value }
                    }
                }
                if !edits.isEmpty { grid = grid.applying(edits); out[tab.gid] = grid }
            }
        }
        for (gid, edits) in pending {
            guard let grid = readGrids[gid] else { continue }
            var keep: [CellKey: PendingEdit] = [:]
            for (key, edit) in edits where Date().timeIntervalSince(edit.since) < 120 {
                if PlanGrid.normalized(grid.text(line: key.line, column: key.column) ?? "") != PlanGrid.normalized(edit.value) {
                    keep[key] = edit
                }
            }
            pending[gid] = keep.isEmpty ? nil : keep
            if !keep.isEmpty { out[gid] = (out[gid] ?? grid).applying(keep.mapValues(\.value)) }
        }
        if out != grids { grids = out }
    }

    // MARK: Editing

    var canEdit: Bool { config?.writer != nil }

    /// Connects the script after checking it answers for this spreadsheet; nil turns editing off.
    func setWriter(_ link: PlanWriteLink?) async throws {
        guard var config else { return }
        if let link {
            scriptVersion = try await AppsScriptWriter.ping(link, sheetID: config.link.sheetID)
            UserDefaults.standard.removeObject(forKey: "planSetupToken")
        }
        guard self.config?.link == config.link else { return }
        config.writer = link
        self.config = config
        saveConfig()
        editState = .idle
    }

    /// Shows the new text at once and writes it; on failure or a conflicting change in the sheet the cell goes back.
    func editCell(gid: String, line: Int, column: Int, old: String, new: String) {
        guard let writer = config?.writer, new != old else { return }
        let key = CellKey(line: line, column: column)
        pending[gid, default: [:]][key] = PendingEdit(value: new, since: Date())
        publishGrids()
        savingCount += 1
        editState = .saving(savingCount)
        // The row's code and the column's header let the script find the cell again if rows were sorted or columns
        // inserted since QCpie read the sheet (by number alone, a same-looking cell on another row could be overwritten).
        let tabName = config?.tabs.first { $0.gid == gid }?.name
        let code = rows.first { $0.tab == tabName && $0.line == line }?.code
        let header = headers[gid].flatMap { readGrids[gid]?.text(line: $0.line, column: column) }
        let cell = PlanCellEdit(row: line, col: column + 1, code: code, header: header.flatMap { $0.isEmpty ? nil : $0 },
                                value: new, expect: old)
        Task {
            var failure: String? = nil
            do {
                let results = try await AppsScriptWriter.write(writer, gid: gid, cells: [cell])
                if let result = results.first, !result.ok {
                    failure = "Not saved: the cell was changed in the sheet meanwhile (now “\(result.current ?? "")”)."
                }
            } catch {
                failure = "Not saved: \(error.localizedDescription)"
            }
            savingCount -= 1
            if let failure {
                pending[gid]?[key] = nil
                publishGrids()
                editState = .failed(failure)
            } else if savingCount == 0 {
                editState = .saved
            }
            // Re-read shortly after the last save, so rows, matching and formatting follow the edit.
            refreshAfterEdit?.cancel()
            refreshAfterEdit = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, savingCount == 0 else { return }
                await refresh()
            }
        }
    }

    private func loadCachedIfNeeded() async {
        guard !loadedFromDisk, let config else { return }
        loadedFromDisk = true
        let dir = Self.directory(config.link.sheetID)
        let (cache, seen, gridCache) = await Task.detached(priority: .userInitiated) { () -> ([String: String], [String: SeenRow], [String: PlanGrid]) in
            let cache = (try? Data(contentsOf: dir.appendingPathComponent("tabs.json")))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            let seen = (try? Data(contentsOf: dir.appendingPathComponent("seen.json")))
                .flatMap { try? JSONDecoder().decode([String: SeenRow].self, from: $0) } ?? [:]
            let grids = (try? Data(contentsOf: dir.appendingPathComponent("grids.json")))
                .flatMap { try? JSONDecoder().decode([String: PlanGrid].self, from: $0) } ?? [:]
            return (cache, seen, grids)
        }.value
        self.seen = seen
        let tabs = config.included.filter { cache[$0.gid] != nil }
        if !tabs.isEmpty, rows.isEmpty {
            let csvs = tabs.map { cache[$0.gid]! }
            await apply(tabs: tabs, csvs: csvs, adoptAsSeen: false)
            if grids.isEmpty { await applyGrids(tabs: tabs, csvs: csvs, formatted: tabs.map { gridCache[$0.gid] }) }
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
            let fields = PlanField.allCases.filter { !$0.isTracking }.compactMap { field -> String? in
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
        let measured = assets.filter { $0.width > 0 || $0.durationSeconds > 0 }
        // Inspect updates its list once per file during loudness / end-frame checks (same files, new measurements):
        // dates already read for the same inspection of a file (`asset.id`) are kept, so only new or re-read files
        // are stat'ed (it was 1,000+ stats per finished file, maybe on a server).
        let known = Dictionary(measured.compactMap { asset in
            assetIDs[asset.fileURL] == asset.id ? filesByURL[asset.fileURL].map { (asset.fileURL, $0.modified) } : nil
        }, uniquingKeysWith: { a, _ in a })
        assetsTask?.cancel()
        assetsTask = Task {
            let newFiles = await Task.detached(priority: .utility) {
                measured.map { asset -> PlanFile in
                    var file = PlanFile(asset)
                    if let date = known[asset.fileURL] {
                        file.modified = date
                    } else {
                        file.modified = (try? FileManager.default.attributesOfItem(atPath: asset.fileURL.path))?[.modificationDate] as? Date
                    }
                    return file
                }
            }.value
            guard !Task.isCancelled else { return }
            assetIDs = Dictionary(measured.map { ($0.fileURL, $0.id) }, uniquingKeysWith: { a, _ in a })
            guard newFiles != files else { return }
            files = newFiles
            filesByURL = Dictionary(newFiles.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            if hasFiles != !files.isEmpty { hasFiles = !files.isEmpty }
            rematch()
        }
    }
    private var assetsTask: Task<Void, Never>?
    private var filesByURL: [URL: PlanFile] = [:]
    /// The inspection each file's date was read for (a re-inspection gets a new id and a new stat).
    private var assetIDs: [URL: UUID] = [:]

    /// A row's files with size and date (checks belong to a file version).
    func fileStamps(_ row: PlanRow) -> [(url: URL, size: Int64, modified: Date?)] {
        match.result(row).files.map { url in (url, filesByURL[url]?.bytes ?? 0, filesByURL[url]?.modified) }
    }

    private func rematch() {
        let rows = rows, files = files
        matchTask?.cancel()
        matchTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { PlanMatcher.match(rows: rows, files: files) }.value
            guard !Task.isCancelled, let self else { return }
            if result != self.match { self.match = result }
            self.matchRevision &+= 1
            self.recomputeStates()
        }
    }

    // MARK: States

    /// Row states and the per-file index for Inspect. ~1 ms for 1,100 rows; publishes only what changed.
    private func recomputeStates() {
        let dates = Dictionary(files.compactMap { f in f.modified.map { (f.url, $0) } }, uniquingKeysWith: { a, _ in a })
        var newStates: [String: PlanRowState] = [:]
        var index: [URL: PlanFileInfo] = [:]
        var batchNames = Set<String>()
        for row in rows {
            let result = match.result(row)
            let pending = row.code.flatMap { pendingQC[$0.lowercased()] }
            var state = PlanStatusResolver.resolve(match: result.status, hasFiles: !result.files.isEmpty,
                                                   qc: pending?.values[.qcStatus] ?? row.value(.qcStatus),
                                                   updated: pending?.values[.qcUpdated] ?? row.value(.qcUpdated),
                                                   fileDates: result.files.compactMap { dates[$0] })
            let link = frameioLink(row)
            if !link.isEmpty {
                state.upload = .uploaded
                // The local file changed after the upload (a minute's grace: the upload stamp has no seconds).
                let uploadedOn = shown(.uploaded, row)
                if let when = PlanUpload.date(uploadedOn), let newest = result.files.compactMap({ dates[$0] }).max(),
                   newest > when.addingTimeInterval(60) {
                    state.upload = .stale
                    state.flags.append("Changed after its upload to Frame.io (\(uploadedOn)): Frame.io has an older version.")
                }
                if !state.state.isDone, state.state != .dropped, state.state != .onHold {
                    state.flags.append("On Frame.io before passing QC.")
                }
            }
            newStates[row.id] = state
            let rowBatch = batch(row)
            if !rowBatch.isEmpty { batchNames.insert(rowBatch) }
            for url in result.files where index[url] == nil {
                index[url] = PlanFileInfo(code: row.code ?? "", line: row.line, rowID: row.id, state: state.state,
                                          batch: rowBatch, frameio: link, upload: state.upload, text: row.values.values.joined(separator: " ").lowercased())
            }
        }
        let sortedBatches = PlanBatch.sorted(batchNames)
        if sortedBatches != batches { batches = sortedBatches }
        for url in match.extras { index[url] = PlanFileInfo(code: "", line: 0, rowID: nil, state: nil) }
        if newStates != states { states = newStates }
        if index != fileIndex { fileIndex = index }
    }

    /// The tab's QC Status column (0-based), when it has one.
    func statusColumn(gid: String) -> Int? { gridColumn(.qcStatus, gid: gid) }

    /// A field's column in the Sheet view, found by header text: the view leaves hidden and collapsed columns out, so
    /// the sheet's column numbers (`headers`, from the CSV) can point at the wrong one. Nil when hidden in the view.
    func gridColumn(_ field: PlanField, gid: String) -> Int? {
        guard let header = headers[gid], let column = header.columns[field] else { return nil }
        guard let grid = readGrids[gid] else { return column }
        if PlanField.detect(grid.text(line: header.line, column: column) ?? "") == field { return column }
        return grid.columnWidths.indices.first { PlanField.detect(grid.text(line: header.line, column: $0) ?? "") == field }
    }

    func state(_ row: PlanRow) -> PlanRowState { states[row.id] ?? PlanRowState(state: .missing) }

    /// The QC note as shown (a pending edit wins).
    func note(_ row: PlanRow) -> String {
        shown(.qcNote, row)
    }

    // MARK: Statuses

    /// Sets (nil: clears) the QC status of rows, stamped with time and reviewer. Shown at once, written in one batch.
    func setStatus(_ status: PlanQCStatus?, rowIDs: [String]) {
        let ids = Set(rowIDs)
        queueQC(rows.filter { ids.contains($0.id) }) { item in item.status = status?.title ?? "" }
    }

    func setNote(_ note: String, rowID: String) {
        queueQC(rows.filter { $0.id == rowID }) { item in item.note = note }
    }

    /// Sets ("" clears) the batch of rows. Shown at once, written with the statuses (by code, every tab).
    func setBatch(_ batch: String, rowIDs: [String]) {
        let ids = Set(rowIDs)
        let value = PlanGrid.normalized(batch)
        queueQC(rows.filter { ids.contains($0.id) }) { item in item.batch = value }
    }

    /// The batch as shown (a pending edit wins), normalised; "" when none.
    func batch(_ row: PlanRow) -> String {
        PlanGrid.normalized(shown(.batch, row))
    }

    /// A column QCpie writes, as shown: a pending edit wins over the last read.
    private func shown(_ field: PlanField, _ row: PlanRow) -> String {
        row.code.flatMap { pendingQC[$0.lowercased()]?.values[field] } ?? row.value(field)
    }

    // MARK: Frame.io

    /// The row's Frame.io link as shown (a pending edit wins); "" when none.
    func frameioLink(_ row: PlanRow) -> String { PlanGrid.normalized(shown(.frameio, row)) }

    /// Whether any included tab has a Frame.io column (links found while browsing are only written then).
    var hasFrameIOColumn: Bool { headers.values.contains { $0.columns[.frameio] != nil } }

    /// Plan codes by their first token (built once per set of rows): a Frame.io listing is checked per file name token,
    /// not per row.
    private var codeIndex: (rows: Int, byToken: [String: [(code: String, tokens: [String])]])?

    /// Codes (lower case) whose rows are in the plan, found in a file name as whole tokens ("…_KL0001.mp4").
    private func codes(inFileNamed name: String) -> Set<String> {
        let tokens = PlanMatcher.tokens((name as NSString).deletingPathExtension)
        guard !tokens.isEmpty else { return [] }
        if codeIndex?.rows != rowsVersion {
            var byToken: [String: [(code: String, tokens: [String])]] = [:]
            var seen = Set<String>()
            for row in rows {
                guard let code = row.code?.lowercased(), !code.isEmpty, seen.insert(code).inserted else { continue }
                let codeTokens = PlanMatcher.tokens(code)
                if let first = codeTokens.first { byToken[first, default: []].append((code, codeTokens)) }
            }
            codeIndex = (rowsVersion, byToken)
        }
        var found = Set<String>()
        for token in Set(tokens) {
            for entry in codeIndex?.byToken[token] ?? [] where PlanMatcher.contains(tokens, entry.tokens) { found.insert(entry.code) }
        }
        return found
    }

    private func rows(withCode code: String) -> [PlanRow] { rows.filter { $0.code?.lowercased() == code } }

    /// "2026-11-05 10:42 UTC": the Uploaded column.
    nonisolated static func uploadStamp(_ date: Date) -> String {
        PlanUpload.stampFormatter.string(from: date) + " UTC"
    }

    /// QCpie uploaded `file` (the Upload tab) as Frame.io file `fileID`: its row's Frame.io column gets the file's link
    /// and Uploaded the date. A newer upload replaces an older link. Files whose row isn't clear (none, or several codes
    /// in the name) are left for Link Frame.io File….
    func uploaded(_ file: URL, account: String, fileID: String) async {
        guard config?.writer != nil else { return }
        var codes = Set<String>()
        if let code = fileIndex[file]?.code, !code.isEmpty { codes = [code.lowercased()] } else { codes = self.codes(inFileNamed: file.lastPathComponent) }
        guard codes.count == 1, let code = codes.first else { return }
        guard let item = try? await FrameIO.shared.item(account: account, kind: "files", id: fileID), let url = item.viewURL else { return }
        queueQC(rows(withCode: code), quiet: true) { item in
            item.frameio = url
            item.uploaded = Self.uploadStamp(Date())
        }
    }

    /// Files listed on Frame.io (the browser, the favourites crawl): a row without a link gets the file whose name holds
    /// its code, when exactly one such file was in the listing (stacks: the stack, so the link survives new versions).
    /// Only into a sheet that has a Frame.io column, and never over a link already there.
    func frameIOListed(_ items: [FrameIO.Item]) {
        guard config?.writer != nil, !scriptOutdated, hasFrameIOColumn, !rows.isEmpty else { return }
        var found: [String: (item: FrameIO.Item, count: Int)] = [:]
        for item in items where !item.isFolder && item.viewURL != nil {
            let name = item.isVersionStack ? (item.headVersion?.name ?? item.title) : item.title
            for code in codes(inFileNamed: name) { found[code] = (item, (found[code]?.count ?? 0) + 1) }
        }
        var queued = false
        for (code, entry) in found where entry.count == 1 {
            let targets = rows(withCode: code)
            guard !targets.isEmpty, targets.allSatisfy({ frameioLink($0).isEmpty }), let url = entry.item.viewURL else { continue }
            // The code alone could be another project's (codes repeat across campaigns): the file's name must also hold
            // the row's name (it ends with the code), or be the name of the local file matched to the row.
            let name = entry.item.isVersionStack ? (entry.item.headVersion?.name ?? entry.item.title) : entry.item.title
            let fileTokens = PlanMatcher.tokens((name as NSString).deletingPathExtension)
            let named = targets.contains { row in
                PlanMatcher.contains(fileTokens, PlanMatcher.tokens(row.name))
                    || match.result(row).files.contains { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
            }
            guard named else { continue }
            let date = entry.item.createdDate
            queueQC(targets, quiet: true, refresh: false) { item in
                item.frameio = url
                if let date, targets.allSatisfy({ self.shown(.uploaded, $0).isEmpty }) { item.uploaded = Self.uploadStamp(date) }
            }
            queued = true
        }
        // One recompute and redraw for the whole listing, not one per row.
        if queued { recomputeStates(); publishGrids() }
    }

    /// Frame.io files or stacks deleted (in the browser, or found gone): rows linked to them lose the link.
    func frameIOGone(_ ids: Set<String>) {
        guard config?.writer != nil, !ids.isEmpty else { return }
        let targets = rows.filter { row in
            let link = frameioLink(row)
            return !link.isEmpty && ids.contains { link.hasSuffix("/" + $0) || link.contains("/" + $0 + "?") }
        }
        guard !targets.isEmpty else { return }
        queueQC(targets, quiet: true) { item in item.frameio = ""; item.uploaded = "" }
    }

    /// Link Frame.io File…: a pasted Frame.io file or stack link goes into the rows' Frame.io column (a link set by hand
    /// is never replaced by one found while browsing). Failures show in the status line.
    func linkFrameIO(_ text: String, rowIDs: [String]) async {
        if let failure = await linkFrameIOFailure(text, rowIDs: rowIDs) { editState = .failed(failure) }
    }

    /// Nil when linked, else why not.
    private func linkFrameIOFailure(_ text: String, rowIDs: [String]) async -> String? {
        let link: FrameIOLink
        do {
            link = try FrameIOLink.parse(await FrameIOLink.expand(text))
        } catch {
            return (error as? FrameIOLink.Failure)?.errorDescription ?? error.localizedDescription
        }
        guard let asset = link.asset else { return "That's a folder or project link: paste the link of the file itself." }
        guard let accounts = try? await FrameIO.shared.accounts() else { return "Sign in to Frame.io (Upload tab) to check the link." }
        for account in accounts {
            var found = try? await FrameIO.shared.item(account: account.id, kind: "files", id: asset)
            if found == nil { found = try? await FrameIO.shared.item(account: account.id, kind: "version_stacks", id: asset) }
            guard let item = found, let url = item.viewURL else { continue }
            let ids = Set(rowIDs)
            let date = item.createdDate
            queueQC(rows.filter { ids.contains($0.id) }) { entry in
                entry.frameio = url
                if let date { entry.uploaded = Self.uploadStamp(date) }
            }
            return nil
        }
        return FrameIOLink.Failure.notFound.errorDescription ?? "That file wasn't found in your Frame.io accounts."
    }

    func clearFrameIO(rowIDs: [String]) {
        let ids = Set(rowIDs)
        queueQC(rows.filter { ids.contains($0.id) }) { item in item.frameio = ""; item.uploaded = "" }
    }

    // MARK: Linked filters

    /// The status filter and search shared by the plan and Inspect while `linkFilters` is on.
    /// `state`: -1 all, -2 not in the plan (Inspect only), else a `PlanState` raw value.
    /// `batch`: nil all, "" no batch, else a batch name.
    /// `upload`: nil all, else a `PlanUpload.passes` filter value.
    struct SharedFilter: Equatable { var state = -1; var search = ""; var batch: String? = nil; var upload: Int? = nil }

    @Published var linkFilters = UserDefaults.standard.bool(forKey: "planLinkFilters") {
        didSet { UserDefaults.standard.set(linkFilters, forKey: "planLinkFilters") }
    }
    @Published private(set) var sharedFilter = SharedFilter()

    /// A side's filter changed: the other side follows while linked.
    func publishFilter(_ filter: SharedFilter, fromPlan: Bool = false) {
        guard linkFilters, filter != sharedFilter else { return }
        // The plan has no "Not in Plan" chip: showing everything there mustn't undo Inspect's choice.
        if fromPlan, sharedFilter.state == -2, filter.state == -1 {
            // …but its search and batch still go across.
            let kept = SharedFilter(state: -2, search: filter.search, batch: filter.batch, upload: filter.upload)
            if kept != sharedFilter { sharedFilter = kept }
            return
        }
        sharedFilter = filter
    }

    /// The link button: on copies this side's filter to the other.
    func toggleLinkFilters(from filter: SharedFilter) {
        linkFilters.toggle()
        if linkFilters { sharedFilter = filter }
    }

    /// The row last clicked in the plan (shortcuts use it when Inspect has no selection, e.g. a Missing row).
    var focusedRowID: String?

    /// ⌥1–⌥6 / ⌥0: the rows of Inspect's selected files, else the plan's focused row. False when there's nothing.
    func setStatusForSelection(_ status: PlanQCStatus?) -> Bool {
        var ids = rowIDs(forFiles: Array(selectedFiles))
        if ids.isEmpty, let focused = focusedRowID, rows.contains(where: { $0.id == focused }) { ids = [focused] }
        guard !ids.isEmpty, config != nil else { return false }
        setStatus(status, rowIDs: ids)
        return true
    }

    /// Rows of the Inspect files given (setting a status from Inspect).
    func rowIDs(forFiles urls: [URL]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap { fileIndex[$0]?.rowID }.filter { seen.insert($0).inserted }
    }

    /// `quiet`: automatic writes (Frame.io links) say nothing when the sheet can't take them.
    /// `refresh: false` leaves the recompute and redraw to the caller (several rows queued in a row).
    private func queueQC(_ targets: [PlanRow], quiet: Bool = false, refresh: Bool = true, _ change: (inout PlanStatusItem) -> Void) {
        guard config?.writer != nil else { if !quiet { editState = .failed("Set up editing (••• menu) to set statuses.") }; return }
        guard !scriptOutdated else { if !quiet { editState = .failed("Update the script (••• → Update Script…) to set statuses.") }; return }
        let coded = targets.filter { !($0.code ?? "").isEmpty }
        guard !coded.isEmpty else { if !quiet { editState = .failed("Statuses need a Code column in the sheet.") }; return }
        let reviewer = UserDefaults.standard.string(forKey: "reviewerName").flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
        let stamp = PlanStatusResolver.stamp(Date(), by: reviewer)
        for row in coded {
            let key = row.code!.lowercased()
            var item = queuedQC[key] ?? PlanStatusItem(code: row.code!)
            change(&item)
            // Only a status change is stamped: QC Updated dates the review, and a note edited later must not hide a
            // new version that arrived before it.
            if item.status != nil { item.updated = stamp }
            queuedQC[key] = item
            var p = pendingQC[key] ?? PendingQC(since: Date())
            p.values.merge(item.fieldValues) { _, new in new }
            p.since = Date()
            pendingQC[key] = p
        }
        if refresh {
            recomputeStates()
            publishGrids()
        }
        editState = .saving(queuedQC.count)
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(300))   // gather a burst of clicks / shortcuts into one call
            guard !Task.isCancelled else { return }
            await flushQC()
        }
    }

    private func flushQC() async {
        guard let writer = config?.writer, !queuedQC.isEmpty else { return }
        let items = Array(queuedQC.values)
        queuedQC = [:]
        savingCount += 1
        do {
            // Columns being written that an included tab with codes lacks are added (asked once until a read shows
            // them). Setting any QC column adds all three.
            let included = config?.included.map(\.gid) ?? []
            var used = Set(items.flatMap { $0.fieldValues.keys })
            if used.contains(where: \.isQC) { used.formUnion([.qcStatus, .qcNote, .qcUpdated]) }
            let needed = [PlanField.qcStatus, .qcNote, .qcUpdated, .batch, .frameio, .uploaded].filter { field in
                used.contains(field) && !requestedColumns.contains(field) && included.contains { gid in
                    guard let columns = headers[gid]?.columns, columns[.id] != nil else { return false }
                    return columns[field] == nil
                }
            }
            if !needed.isEmpty {
                try await AppsScriptWriter.ensureColumns(writer, names: needed.map(\.title))
                requestedColumns.formUnion(needed)
            }
            let missing = try await AppsScriptWriter.setStatus(writer, items: items)
            savingCount -= 1
            editState = missing.isEmpty ? .saved : .failed("Not saved for \(missing.count) code\(missing.count == 1 ? "" : "s") no tab lists: \(missing.prefix(3).joined(separator: ", ")).")
        } catch {
            savingCount -= 1
            for item in items { pendingQC[item.code.lowercased()] = nil }
            recomputeStates()
            publishGrids()
            editState = .failed("Not saved: \(error.localizedDescription)")
        }
        refreshAfterEdit?.cancel()
        refreshAfterEdit = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, savingCount == 0, queuedQC.isEmpty else { return }
            await refresh()
        }
    }

    /// Pending QC edits leave once a read shows them (or after 2 minutes).
    private func dropSettledQC() {
        guard !pendingQC.isEmpty else { return }
        let byCode = Dictionary(rows.compactMap { r in r.code.map { ($0.lowercased(), r) } }, uniquingKeysWith: { a, _ in a })
        for (key, p) in pendingQC {
            let expired = Date().timeIntervalSince(p.since) > 120
            let row = byCode[key]
            let shows = row.map { r in
                p.values.allSatisfy { field, value in PlanGrid.normalized(value) == PlanGrid.normalized(r.value(field)) }
            } ?? false
            if expired || shows { pendingQC[key] = nil }
        }
    }

    /// Dropdown choices for the included tabs, after each full read and when the 10 s check's fingerprint moves
    /// (validation edits don't move the change counter).
    private func readLists(tabs: [PlanTab], link: PlanSheetLink) async {
        guard let writer = config?.writer, (scriptVersion ?? 0) >= 4 else {
            if !cellLists.isEmpty { cellLists = [:] }
            return
        }
        var lists: [String: [String: [String]]] = [:]
        for tab in tabs {
            guard let tabLists = try? await AppsScriptWriter.lists(writer, gid: tab.gid) else { return }   // keep the last
            if !tabLists.isEmpty { lists[tab.gid] = tabLists }
        }
        guard config?.link == link, lists != cellLists else { return }
        cellLists = lists
    }

    /// Dropdown choices by the Sheet view's column (0-based), matched by header: the view leaves hidden columns
    /// out, so the sheet's column numbers can't be used.
    func listColumns(gid: String) -> [Int: [String]] {
        guard let lists = cellLists[gid], !lists.isEmpty, let grid = grids[gid] else { return [:] }
        let headerLine = headers[gid]?.line
        var out: [Int: [String]] = [:]
        for column in grid.columnWidths.indices {
            let name = headerLine.flatMap { grid.text(line: $0, column: column) }.map { PlanGrid.normalized($0).lowercased() } ?? ""
            if let list = (name.isEmpty ? nil : lists[name]) ?? lists["#\(column)"] { out[column] = list }
        }
        return out
    }

    /// Asks the script its version (once per session, and after connecting).
    func checkScript() async {
        guard scriptVersion == nil || scriptOutdated, let writer = config?.writer, let sheetID = config?.link.sheetID else { return }
        if let version = try? await AppsScriptWriter.ping(writer, sheetID: sheetID), version != scriptVersion { scriptVersion = version }
    }

    // MARK: Disk

    static func directory(_ sheetID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/DeliveryPlan/\(sheetID)", isDirectory: true)
    }

    nonisolated private static func writeCache(_ cache: [String: String], grids: [String: PlanGrid], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: dir.appendingPathComponent("tabs.json"), options: .atomic) }
        if let data = try? JSONEncoder().encode(grids) { try? data.write(to: dir.appendingPathComponent("grids.json"), options: .atomic) }
    }
}

private extension PlanStatusItem {
    /// The columns this item writes, by field.
    var fieldValues: [PlanField: String] {
        var values: [PlanField: String] = [:]
        if let status { values[.qcStatus] = status }
        if let note { values[.qcNote] = note }
        if let updated { values[.qcUpdated] = updated }
        if let batch { values[.batch] = batch }
        if let frameio { values[.frameio] = frameio }
        if let uploaded { values[.uploaded] = uploaded }
        return values
    }
}
