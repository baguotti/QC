import Foundation
import SwiftUI
import VideoQCLib

/// The linked Delivery Plan: rows read through the Sheets API as the signed-in Google user (every 10 s while a plan
/// panel is on screen, parsed only when the values changed), matched against the Inspect tab's measured files. QCpie's
/// own values live in the sheet's QCpie tab (`PlanQCTab`); every edit goes through the on-disk outbox (`PlanOutbox`). Observed only by the plan panels (drawer and window), never by `ContentView`,
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
        /// The QCpie tab's gid, once the sheet has one.
        var qcTab: String? = nil
        /// The Frame.io project or folder holding the plan's files (`FrameIORoot`).
        var frameioRoot: FrameIORoot? = nil

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
    /// Dropdown choices per tab (gid), keyed by header (lower case) or "#" + sheet column index.
    @Published private(set) var cellLists: [String: [String: [String]]] = [:]
    /// Every batch named in the plan (pending edits included), in natural order.
    @Published private(set) var batches: [String] = []
    /// Counts for the batch and Frame.io filters (rows), rebuilt with the states.
    struct PlanCounts: Equatable {
        var batches: [PlanBatchFilter.Item] = []
        var unbatched = 0
        var uploads = (none: 0, on: 0, stale: 0)
        /// Rows or files per mismatch, and how many rows / files have any.
        var mismatches: [PlanMismatch: Int] = [:]
        var mismatchTotal = 0
        /// Mismatches dismissed that would show now.
        var dismissed = 0
        static func == (a: PlanCounts, b: PlanCounts) -> Bool {
            a.batches == b.batches && a.unbatched == b.unbatched && a.uploads == b.uploads
                && a.mismatches == b.mismatches && a.mismatchTotal == b.mismatchTotal && a.dismissed == b.dismissed
        }
    }
    @Published private(set) var planCounts = PlanCounts()
    /// Whether rows can have a batch (the QCpie tab holds one for every code).
    var hasBatchColumn: Bool { hasQCTab || headers.values.contains { $0.columns[.batch] != nil } }
    var hasQCTab: Bool { config?.qcTab != nil }
    /// The last cell edit's outcome, for the status line.
    @Published private(set) var editState: EditState = .idle

    enum EditState: Equatable { case idle, saving(Int), saved, failed(String) }

    /// A cell by sheet row (1-based) and column (0-based).
    struct CellKey: Hashable, Sendable { let line: Int; let column: Int }
    /// Every edit not yet in a read of the sheet (on disk: `outbox.json`).
    private var outbox = PlanOutbox()
    /// Grids as last read from the sheet (`grids` = these + the outbox's edits).
    private var readGrids: [String: PlanGrid] = [:]
    /// Each tab's formatted layout (read every 5 minutes, or when rows or columns are added) and when it was read.
    private var layouts: [String: PlanGrid] = [:]
    private var layoutRead: [String: Date] = [:]
    private var layoutTask: Task<Void, Never>?
    /// `readLayouts` reading again what outgrew its layout meanwhile: at most twice, so a sheet edited non-stop can't
    /// keep it busy.
    private var rereadDepth = 0
    /// The last values read, by gid: the layout is filled with them.
    private var tables: [String: [[String]]] = [:]
    /// The last values reply as received: an identical one means nothing changed (no parse, no matching).
    private var lastValues: Data?
    /// The sheet's Drive version at the last values read; the 10 s check reads the values only when it moved
    /// (and every 3 minutes regardless). `versionCheck` false: not available (Drive API off, or signed in before the
    /// scope was added); tried again after `versionCheckRetry`.
    private var lastVersion: String?
    private var lastValuesRead = Date.distantPast
    /// The ranges of that read: other tabs on or off (or the QCpie tab added) need a read even if the sheet didn't change.
    private var lastRanges: [String] = []
    private var versionCheck: Bool?
    private var versionCheckRetry = Date.distantPast
    /// Grows ×2 (to ×12) while Google answers 429 (too many requests, e.g. many Macs on one plan), back to 1 on success.
    private var readBackoff: Double = 1
    private var lastMetadata = Date.distantPast
    private var reading = false
    /// The QCpie tab as last read (nil: none, or not read yet).
    private var qcTable: PlanQCTab.Table?
    /// Each tab's header (by gid): its line and the column of each field.
    private var headers: [String: (line: Int, columns: [PlanField: Int])] = [:]
    /// Bumped when matching or files change (cache key for per-row check summaries).
    private(set) var matchRevision = 0

    private var seen: [String: SeenRow] = [:]
    private var files: [PlanFile] = []
    private var visiblePanels = 0
    private var pollTask: Task<Void, Never>?
    private var matchTask: Task<Void, Never>?
    private var loadedFromDisk = false
    private let api = SheetsAPI.shared

    static let refreshInterval: Duration = .seconds(60)
    private static let configKey = "deliveryPlanConfig"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            self.config = config
            // Edits saved before quitting go out as soon as QCpie can reach the sheet.
            Task { await self.loadOutbox() }
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
            let meta = try await api.metadata(link.sheetID)
            let tabs = Self.planTabs(meta.tabs)
            guard !tabs.isEmpty else { phase = .failed("No tabs found in the sheet."); return }
            // One tab to start with (sheets often list the same files twice, e.g. by placement and by edit): the tab
            // the link points at, else the one with the most rows. Others are a click away in the ••• menu.
            let data = try await api.values(link.sheetID, ranges: tabs.map { SheetsAPI.quoted($0.name) })
            let counts = try await Task.detached(priority: .userInitiated) { () -> [String: Int] in
                let tables = try SheetsAPI.tables(data)
                var out: [String: Int] = [:]
                for (tab, table) in zip(tabs, tables) { out[tab.gid] = PlanParser.parse(table: table, tab: tab.name).rows.count }
                return out
            }.value
            let chosen = link.gid.flatMap { gid in tabs.contains { $0.gid == gid } ? gid : nil }
                ?? tabs.max { (counts[$0.gid] ?? 0) < (counts[$1.gid] ?? 0) }?.gid
            // Relinking the same sheet keeps the edits waiting to be sent.
            let kept = config?.link.sheetID == link.sheetID ? outbox : PlanOutbox()
            resetState()
            outbox = kept
            outboxLoaded = false   // the new sheet's saved outbox is read below
            tabCounts = counts
            var config = Config(link: link, title: meta.title.isEmpty ? "Delivery Plan" : meta.title, tabs: tabs)
            config.excluded = Set(tabs.map(\.gid).filter { $0 != chosen })
            config.qcTab = meta.tabs.first { $0.title == PlanQCTab.title }?.gid
            self.config = config
            saveConfig()
            lastMetadata = Date()
            // Edits saved for this sheet before (linked earlier, or before quitting) go out too.
            await loadOutbox()
            await refresh(adoptAsSeen: true)
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// The tabs a plan can show: visible ones, not the QCpie tab.
    nonisolated static func planTabs(_ tabs: [SheetsAPI.Tab]) -> [PlanTab] {
        tabs.filter { !$0.hidden && $0.title != PlanQCTab.title }.map { PlanTab(gid: $0.gid, name: $0.title) }
    }

    nonisolated static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Everything read or derived from a sheet (linking another one, unlinking).
    private func resetState() {
        seen = [:]; rows = []; grids = [:]; readGrids = [:]; layouts = [:]; layoutRead = [:]; layoutTask?.cancel(); layoutTask = nil
        tables = [:]; lastValues = nil; qcTable = nil; outbox = PlanOutbox(); states = [:]; fileIndex = [:]; headers = [:]
        cellLists = [:]; frameioFolders = [:]; frameioExtras = []; foldersSaveTask?.cancel(); dismissedMismatches = []
        localExtras = []; changes = [:]; removed = []; editState = .idle; loadedFromDisk = false
        statesRevision &+= 1   // the Summary mustn't show the old sheet's figures
        undoValues = []; undoTitle = nil
        lastVersion = nil; lastValuesRead = .distantPast; readBackoff = 1
        health = PlanHealth()
        linkSuggestions = [:]
        rootScanTask?.cancel(); rootScanTask = nil; rootFolders = []; lastRootScan = nil; rootScan = .idle
    }

    func unlink() {
        guard let config else { return }
        self.config = nil
        UserDefaults.standard.removeObject(forKey: Self.configKey)
        resetState()
        match = .empty
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

    /// Panels call these on appear / disappear: the sheet is only read while one is on screen.
    func panelAppeared() {
        visiblePanels += 1
        guard visiblePanels == 1 else { return }
        pollTask = Task { [weak self] in
            await self?.loadCachedIfNeeded()
            // Coming back to Inspect or the plan within a minute of the last read: no re-read.
            if let last = self?.lastUpdated, Date().timeIntervalSince(last) < 60 {} else { await self?.refresh() }
            self?.scanFrameIORootIfDue()
            while !Task.isCancelled {
                // Every 10 s while QCpie is in front, every minute behind other apps. One call returns every included
                // tab's values (a few hundred KB for a big plan, gzipped on the wire); an unchanged reply isn't parsed.
                try? await Task.sleep(for: .seconds((NSApp.isActive ? 10 : 60) * (self?.readBackoff ?? 1)))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
                self.scanFrameIORootIfDue()
            }
        }
    }

    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        if visiblePanels == 0 { pollTask?.cancel(); pollTask = nil }
    }

    /// Google sign-in finished: read the sheet and send what the outbox holds.
    func signedIn() {
        guard config != nil else { return }
        setHealth { $0.canWrite = nil; $0.writeError = nil }   // another account may have other rights
        versionCheck = nil; versionCheckRetry = .distantPast   // a new sign-in may carry the Drive scope
        Task { await refresh(full: true); scheduleFlush(after: 0) }
    }

    /// The tab list and title (tabs added, renamed or hidden in the sheet show up without relinking).
    private func readMetadata(_ config: Config) async throws -> Config {
        let meta = try await api.metadata(config.link.sheetID)
        // Applied to the config as it is now, not as it was when the call went out: a Frame.io folder set or a tab
        // turned off meanwhile mustn't be undone by this answer.
        guard var updated = self.config, updated.link == config.link else { return config }
        updated.tabs = Self.planTabs(meta.tabs)
        if !meta.title.isEmpty { updated.title = meta.title }
        updated.qcTab = meta.tabs.first { $0.title == PlanQCTab.title }?.gid
        lastMetadata = Date()
        if updated != self.config {
            self.config = updated
            saveConfig()
        }
        return updated
    }

    private func ranges(_ config: Config) -> [String] {
        config.included.map { SheetsAPI.quoted($0.name) } + (config.qcTab != nil ? [SheetsAPI.quoted(PlanQCTab.title)] : [])
    }

    /// Reads every included tab and the QCpie tab in one call. Parsing, matching and the grids run only when the reply
    /// differs from the last one. The tab list is read every 3 minutes, on `full`, and when a tab can't be found.
    /// `adoptAsSeen`: the first read of a new link isn't "changes".
    func refresh(adoptAsSeen: Bool = false, full: Bool = false) async {
        // A new link's first read waits for a read of the old one to finish (it'll be thrown away).
        if adoptAsSeen { while reading { try? await Task.sleep(for: .milliseconds(50)) } }
        guard var config, !reading else { return }
        reading = true
        defer { reading = false }
        if rows.isEmpty || adoptAsSeen { phase = .loading }
        let started = Date()
        do {
            if full || Date().timeIntervalSince(lastMetadata) > 180 { config = try await readMetadata(config) }
            // Cheap check first: nothing changed since the last read → no read (at most 3 minutes apart).
            var version: String?
            if versionCheck != false || Date() > versionCheckRetry {
                do {
                    version = try await api.version(config.link.sheetID)
                    versionCheck = true
                } catch SheetsAPI.Failure.noAccess(_) {
                    versionCheck = false
                    versionCheckRetry = Date().addingTimeInterval(1800)
                } catch SheetsAPI.Failure.notFound {
                    versionCheck = false
                    versionCheckRetry = Date().addingTimeInterval(1800)
                } catch {
                    // Anything else (offline, Google busy): the values read below says what's wrong, if anything.
                }
            }
            if !full, !adoptAsSeen, let version, version == lastVersion, lastValues != nil, ranges(config) == lastRanges,
               Date().timeIntervalSince(lastValuesRead) < 180 {
                if outbox.settle(readStart: started) { saveOutbox(); recomputeStates(); publishGrids() }
                readBackoff = 1
                if phase != .idle { phase = .idle }
                setHealth { $0.readError = nil }
                if lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true { lastUpdated = Date() }
                if !outbox.unsent.records.isEmpty || !outbox.unsent.cells.isEmpty { scheduleFlush(after: 0) }
                return
            }
            var data: Data
            do {
                // Every tab left out and no QCpie tab: nothing to read (Google refuses a read of no ranges).
                data = ranges(config).isEmpty ? Data(#"{"valueRanges":[]}"#.utf8) : try await api.values(config.link.sheetID, ranges: ranges(config))
            } catch SheetsAPI.Failure.http(400, _) {
                // A tab renamed or deleted since the last tab list.
                config = try await readMetadata(config)
                data = try await api.values(config.link.sheetID, ranges: ranges(config))
            }
            guard self.config?.link == config.link else { return }   // relinked meanwhile
            lastVersion = version
            lastValuesRead = Date()
            lastRanges = ranges(config)
            readBackoff = 1
            // Edits Google took before this read started are in it: they leave the overlay now, with the new values.
            let settled = outbox.settle(readStart: started)
            if settled { saveOutbox() }
            if data != lastValues || adoptAsSeen {
                lastValues = data
                let included = config.included
                let all = try await Task.detached(priority: .userInitiated) { try SheetsAPI.tables(data) }.value
                let planTables = Array(all.prefix(included.count))
                let qcValues = config.qcTab != nil && all.count > included.count ? all[included.count] : nil
                await apply(tabs: included, tables: planTables, qc: qcValues, adoptAsSeen: adoptAsSeen)
                await applyGrids(tabs: included, tables: planTables)
                let dir = Self.directory(config.link.sheetID)
                var cache = Dictionary(uniqueKeysWithValues: zip(included.map(\.gid), planTables))
                if let qcValues { cache["qc"] = qcValues }
                Task.detached(priority: .utility) { Self.writeCache(cache, to: dir) }
                lastUpdated = Date()
            } else {
                if settled { recomputeStates(); publishGrids() }
                // "Updated" moves on once a minute when nothing changed (each publish redraws the panels).
                if lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true { lastUpdated = Date() }
            }
            if phase != .idle { phase = .idle }
            setHealth { $0.readError = nil }
            // Tabs turned on or off while this read was out (its own refresh was skipped): read them now.
            if let now = self.config, now.link == config.link, now.included != config.included {
                Task { await self.refresh() }
            }
            if !outbox.unsent.records.isEmpty || !outbox.unsent.cells.isEmpty { scheduleFlush(after: 0) }
        } catch is CancellationError {
            if phase != .idle { phase = .idle }
        } catch {
            if case GoogleAuth.Failure.signedOut = error { GoogleAccount.shared.noteSignedOut() }
            if case SheetsAPI.Failure.http(429, _) = error {
                // Too many requests for the project (several Macs on the plan): read less often until Google answers.
                readBackoff = min(readBackoff * 2, 12)
                setHealth { $0.readError = "Google Sheets is busy: reading every \(Int(10 * self.readBackoff)) s for now." }
                return
            }
            phase = .failed(Self.describe(error))
            setHealth { $0.readError = Self.describe(error) }
        }
    }

    /// Bumped by each apply: a slower one that started earlier (the disk cache) mustn't overwrite a newer read.
    private var applyGeneration = 0

    private func apply(tabs: [PlanTab], tables: [[[String]]], qc: [[String]]?, adoptAsSeen: Bool) async {
        applyGeneration += 1
        let generation = applyGeneration
        let oldRows = rows
        let parsed = await Task.detached(priority: .userInitiated) { () -> ([PlanRow], [String], [String: (line: Int, columns: [PlanField: Int])], PlanQCTab.Table?, Bool, Bool) in
            var all: [PlanRow] = []
            var unread: [String] = []
            var headers: [String: (line: Int, columns: [PlanField: Int])] = [:]
            for (tab, table) in zip(tabs, tables) {
                let (rows, header) = PlanParser.parse(table: table, tab: tab.name)
                if let header {
                    headers[tab.gid] = (header.index + 1, header.columns)
                } else if rows.isEmpty {
                    unread.append(tab.name)
                }
                all += rows
            }
            // QCpie's own values come from its tab (the plan tabs' QC columns are lookups of it, or old copies).
            let qcTable = qc.flatMap(PlanQCTab.parse)
            if let qcTable { all = all.map { $0.withTracking(qcTable.values[($0.code ?? "").lowercased()] ?? [:]) } }
            PlanParser.flagDuplicates(&all)
            // Compared here, not on the main thread (~50 ms for 1,100 rows on efficiency cores).
            let rowsChanged = all != oldRows
            // Matching ignores QC columns: a status change doesn't re-run it.
            let matchChanged = rowsChanged && all.map(\.matchSignature) != oldRows.map(\.matchSignature)
            return (all, unread, headers, qcTable, rowsChanged, matchChanged)
        }.value
        guard generation == applyGeneration else { return }
        let (newRows, unread, newHeaders, newQC, rowsChanged, matchChanged) = parsed
        headers = newHeaders
        stampSheetsEdits(old: qcTable, new: newQC, adoptAsSeen: adoptAsSeen)
        qcTable = newQC
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
        if matchChanged { rematch() } else if rowsChanged { recomputeStates() }
    }

    /// A QC Status changed in Google Sheets (on the QCpie tab) without a new QC Updated: stamp it, so a file exported
    /// after it still sends the row back to To QC. Any Mac reading the change may stamp it; they agree to the second.
    private func stampSheetsEdits(old: PlanQCTab.Table?, new: PlanQCTab.Table?, adoptAsSeen: Bool) {
        guard let old, let new, !adoptAsSeen else { return }
        let stamp = PlanStatusResolver.stamp(Date(), by: "Sheets")
        var stamped = false
        defer { if stamped { saveOutbox(); scheduleFlush(after: 1) } }
        for (key, values) in new.values where outbox.records[key] == nil {
            let before = old.values[key] ?? [:]
            guard (values[.qcStatus] ?? "") != (before[.qcStatus] ?? ""), (values[.qcUpdated] ?? "") == (before[.qcUpdated] ?? ""),
                  !(values[.qcStatus] ?? "").isEmpty else { continue }
            outbox.set(code: key, name: "", [.qcUpdated: stamp], quiet: true)
            stamped = true
        }
    }

    /// Each tab's grid: its formatted layout filled with the latest values when the layout still fits them, else
    /// the values unformatted (or the last grid) until the layout has been read again. Layouts are read in the
    /// background every 5 minutes, and when rows or columns were added or removed.
    private func applyGrids(tabs: [PlanTab], tables newTables: [[[String]]]) async {
        let generation = applyGeneration
        let oldTables = tables
        for (tab, table) in zip(tabs, newTables) { tables[tab.gid] = table }
        let layouts = layouts
        let built = await Task.detached(priority: .userInitiated) { () -> ([String: PlanGrid], [String], [String: [ClosedRange<Int>]]) in
            var out: [String: PlanGrid] = [:]
            var stale: [String] = []
            var changed: [String: [ClosedRange<Int>]] = [:]
            for (tab, table) in zip(tabs, newTables) {
                guard let layout = layouts[tab.gid] else { out[tab.gid] = PlanGrid.fromTable(table); stale.append(tab.gid); continue }
                // A layout of another size still shows the values it has cells for, until it's read again.
                if !layout.fits(table) { stale.append(tab.gid) } else if let old = oldTables[tab.gid], old.count == table.count {
                    // Same size, some values changed: their rows' formats are read again (conditional colours).
                    let lines = PlanGrid.changedLines(old, table)
                    if lines.count > 40 { stale.append(tab.gid) } else if !lines.isEmpty { changed[tab.gid] = lines }
                }
                out[tab.gid] = layout.withTexts(table)
            }
            return (out, stale, changed)
        }.value
        guard generation == applyGeneration else { return }
        readGrids = built.0
        publishGrids()
        let due = tabs.filter { tab in built.1.contains(tab.gid) || layoutRead[tab.gid].map { Date().timeIntervalSince($0) > 300 } ?? true }
        if !due.isEmpty, layoutTask == nil { layoutTask = Task { await self.readLayouts(due); self.layoutTask = nil } }
        for tab in tabs where !due.contains(tab) {
            if let lines = built.2[tab.gid] { Task { await self.readRowFormats(tab, lines: lines) } }
        }
    }

    /// Re-reads the formats of rows whose values changed (a status set: Sheets' conditional formatting recolours the
    /// cell) and lays them into the tab's layout. A few KB per row range, only after a read that changed them.
    private func readRowFormats(_ tab: PlanTab, lines: [ClosedRange<Int>]) async {
        guard let config, let data = try? await api.rowFormats(config.link.sheetID, tab: tab.name, rows: lines),
              self.config?.link == config.link, let layout = layouts[tab.gid] else { return }
        let patched = await Task.detached(priority: .userInitiated) { layout.patchingFormats(data) }.value
        guard layouts[tab.gid] == layout else { return }   // re-read meanwhile: that one is newer
        layouts[tab.gid] = patched
        if let table = tables[tab.gid] { readGrids[tab.gid] = patched.withTexts(table) }
        publishGrids()
    }

    /// Reads tabs' formatting and dropdown choices (one tab at a time, off the main thread). ~1–3 MB per 1,000-row
    /// tab: only on link, every 5 minutes and when the sheet's size changed, never on the 10 s check.
    private func readLayouts(_ tabs: [PlanTab]) async {
        guard let config else { return }
        let id = config.link.sheetID
        for tab in tabs {
            guard let table = tables[tab.gid] else { continue }
            guard let data = try? await api.layout(id, tab: tab.name) else {
                layoutRead[tab.gid] = Date().addingTimeInterval(-240)   // try again in a minute, not every 10 s
                continue
            }
            let grid = await Task.detached(priority: .utility) { PlanGrid.fromSheets(layout: data, table: table) }.value
            guard self.config?.link == config.link else { return }
            layoutRead[tab.gid] = Date()
            if let grid {
                layouts[tab.gid] = grid
                // Values read while the layout was on its way win.
                readGrids[tab.gid] = tables[tab.gid].map { grid.withTexts($0) } ?? grid
            }
            if let header = headers[tab.gid] { await readLists(tab: tab, headerLine: header.line, table: table) }
        }
        publishGrids()
        // Rows or columns added while this read was out (or while another tab's was): read those once more, or new rows
        // would stay out of the Sheet view until the sheet changed again.
        let outgrown = tabs.filter { tab in
            guard let layout = layouts[tab.gid], let table = tables[tab.gid] else { return false }
            return !layout.fits(table)
        }
        let others = config.included.filter { tab in
            !tabs.contains(tab) && layouts[tab.gid].map { layout in tables[tab.gid].map { !layout.fits($0) } ?? false } ?? false
        }
        if !outgrown.isEmpty || !others.isEmpty, !Task.isCancelled, rereadDepth < 2 {
            rereadDepth += 1
            await readLayouts(outgrown + others)
            rereadDepth -= 1
        }
        let dir = Self.directory(id), cache = layouts
        Task.detached(priority: .utility) { Self.writeLayouts(cache, to: dir) }
    }

    /// Dropdown choices of the row under the header, keyed by header text (lower case), else "#" + sheet column.
    private func readLists(tab: PlanTab, headerLine: Int, table: [[String]]) async {
        guard let config, let data = try? await api.validations(config.link.sheetID, tab: tab.name, row: headerLine + 1) else { return }
        let (lists, ranges) = Self.parseValidations(data)
        var resolved = lists
        if !ranges.isEmpty, let values = try? await api.values(config.link.sheetID, ranges: ranges.map(\.range)),
           let read = try? SheetsAPI.tables(values) {
            for (item, cells) in zip(ranges, read) {
                let options = cells.flatMap { $0 }.map(PlanGrid.normalized).filter { !$0.isEmpty }
                if !options.isEmpty { resolved[item.column] = options }
            }
        }
        let names = headerLine - 1 < table.count ? table[headerLine - 1] : []
        var out: [String: [String]] = [:]
        for (column, options) in resolved {
            let name = column < names.count ? PlanGrid.normalized(names[column]).lowercased() : ""
            out[name.isEmpty ? "#\(column)" : name] = options
        }
        if cellLists[tab.gid] != (out.isEmpty ? nil : out) { cellLists[tab.gid] = out.isEmpty ? nil : out }
    }

    /// Lists (`ONE_OF_LIST`) and ranges to read (`ONE_OF_RANGE`) by sheet column, from a `validations` reply.
    nonisolated static func parseValidations(_ data: Data) -> (lists: [Int: [String]], ranges: [(column: Int, range: String)]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grid = ((json["sheets"] as? [[String: Any]])?.first?["data"] as? [[String: Any]])?.first,
              let values = (grid["rowData"] as? [[String: Any]])?.first?["values"] as? [[String: Any]] else { return ([:], []) }
        var lists: [Int: [String]] = [:]
        var ranges: [(Int, String)] = []
        for (column, cell) in values.enumerated() {
            guard let condition = (cell["dataValidation"] as? [String: Any])?["condition"] as? [String: Any],
                  let type = condition["type"] as? String else { continue }
            let entries = (condition["values"] as? [[String: Any]] ?? []).compactMap { $0["userEnteredValue"] as? String }
            if type == "ONE_OF_LIST" {
                let options = entries.map(PlanGrid.normalized).filter { !$0.isEmpty }
                if !options.isEmpty { lists[column] = options }
            } else if type == "ONE_OF_RANGE", let range = entries.first {
                ranges.append((column, range.hasPrefix("=") ? String(range.dropFirst()) : range))
            }
        }
        return (lists, ranges)
    }

    /// Read grids with the outbox's edits laid over (QCpie's columns by code, typed cells by position).
    private func publishGrids() {
        var out = readGrids
        if let config {
            let overlay = outbox.overlay
            for tab in config.included {
                guard var grid = out[tab.gid] else { continue }
                var edits = outbox.cellOverlay(gid: tab.gid)
                if !overlay.isEmpty, headers[tab.gid] != nil {
                    // QCpie's columns in this tab's view, found once per tab.
                    var columns: [PlanField: Int] = [:]
                    for field in PlanField.allCases where field.isTracking { columns[field] = gridColumn(field, gid: tab.gid) }
                    if !columns.isEmpty {
                        for row in rows where row.tab == tab.name {
                            guard let code = row.code, let values = overlay[code.lowercased()] else { continue }
                            for (field, value) in values {
                                if let column = columns[field] { edits[CellKey(line: row.line, column: column)] = value }
                            }
                        }
                    }
                }
                if !edits.isEmpty { grid = grid.applying(edits); out[tab.gid] = grid }
            }
        }
        if out != grids { grids = out }
    }

    // MARK: Editing

    /// Edits need Google sign-in (Google decides who may edit the sheet).
    var canEdit: Bool { GoogleAccount.shared.signedIn }

    /// A cell typed in the Sheet view. QCpie's columns go to the QCpie tab (by code); other cells are written where
    /// they are, unless the sheet changed them meanwhile. Shown at once either way.
    func editCell(gid: String, line: Int, column: Int, old: String, new: String) {
        guard let config, new != old, let tab = config.tabs.first(where: { $0.gid == gid }) else { return }
        let grid = readGrids[gid]
        let header = headers[gid].flatMap { h in grid?.text(line: h.line, column: column) }.map(PlanGrid.normalized)
        if let field = header.flatMap(PlanField.detect), field.isTracking, line > (headers[gid]?.line ?? 0) {
            guard let row = rows.first(where: { $0.tab == tab.name && $0.line == line }) else { return }
            queueQC([row]) { $0[field] = PlanGrid.normalized(new) }
            return
        }
        let sheetColumn = grid?.sheetColumns.flatMap { column < $0.count ? $0[column] : nil } ?? column
        let code = rows.first { $0.tab == tab.name && $0.line == line }?.code
        outbox.add(PlanOutbox.Cell(gid: gid, line: line, column: column, sheetColumn: sheetColumn, code: code,
                                   header: header.flatMap { $0.isEmpty ? nil : $0 }, value: new, expect: old, changed: Date()))
        saveOutbox()
        publishGrids()
        editState = .saving(outbox.unsent.records.count + outbox.unsent.cells.count)
        scheduleFlush()
    }

    private func loadCachedIfNeeded() async {
        guard !loadedFromDisk, let config else { return }
        loadedFromDisk = true
        let dir = Self.directory(config.link.sheetID)
        let (cache, seen, layoutCache, folders, dismissed, tree) = await Task.detached(priority: .userInitiated) { () -> ([String: [[String]]], [String: SeenRow], [String: PlanGrid], [String: [ListedFile]], [String], RootTree?) in
            func read<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
                (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
            }
            return (read("values.json", [String: [[String]]].self) ?? [:], read("seen.json", [String: SeenRow].self) ?? [:],
                    read("layouts.json", [String: PlanGrid].self) ?? [:], read("frameio-folders.json", [String: [ListedFile]].self) ?? [:],
                    read("dismissed-mismatches.json", [String].self) ?? [], read("frameio-tree.json", RootTree.self))
        }.value
        guard self.config?.link == config.link else { return }
        if !dismissed.isEmpty { dismissedMismatches.formUnion(dismissed); scheduleRecompute() }
        if let tree, tree.root == config.frameioRoot?.folder {
            rootFolders.formUnion(tree.folders)
            if lastRootScan == nil { lastRootScan = tree.scanned; rootScan = .done(tree.scanned) }
        }
        self.seen = seen
        // Listings that came in before this read are newer than the saved ones.
        frameioFolders = folders.merging(frameioFolders) { _, listed in listed }
        if layouts.isEmpty { layouts = layoutCache }
        let tabs = config.included.filter { cache[$0.gid] != nil }
        // Only before the first read of the sheet: the cache is older than any read.
        if !tabs.isEmpty, rows.isEmpty, lastValues == nil {
            let planTables = tabs.map { cache[$0.gid]! }
            await apply(tabs: tabs, tables: planTables, qc: cache["qc"], adoptAsSeen: false)
            if grids.isEmpty, lastValues == nil {
                for (tab, table) in zip(tabs, planTables) { tables[tab.gid] = table }
                readGrids = Dictionary(uniqueKeysWithValues: zip(tabs, planTables).map { tab, table in
                    (tab.gid, layouts[tab.gid]?.withTexts(table) ?? PlanGrid.fromTable(table))
                })
                publishGrids()
            }
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
    /// The connection at a glance (`PlanHealthBadge`); published only when it changes.
    @Published private(set) var health = PlanHealth()

    private func setHealth(_ change: (inout PlanHealth) -> Void) {
        var next = health
        change(&next)
        if next != health { health = next }
    }

    /// The outbox's counts in `health` (after every change to it).
    private func noteOutbox() {
        let unsent = outbox.unsent
        let written = outbox.records.values.filter { $0.written != nil }.count + outbox.cells.filter { $0.written != nil }.count
        setHealth {
            $0.waiting = unsent.records.count + unsent.cells.count
            $0.confirming = written
            if $0.waiting == 0 { $0.retrying = false }
        }
    }

    /// The health popover's Try Again.
    func retrySending() {
        retryDelay = 0
        scheduleFlush(after: 0)
    }

    /// Bumped by every recompute of the states (the Summary rebuilds its figures only then).
    private(set) var statesRevision = 0

    private func recomputeStates() {
        statesRevision &+= 1
        let dates = Dictionary(files.compactMap { f in f.modified.map { (f.url, $0) } }, uniquingKeysWith: { a, _ in a })
        var newStates: [String: PlanRowState] = [:]
        var index: [URL: PlanFileInfo] = [:]
        var batchNames = Set<String>()
        var perBatch: [String: (total: Int, done: Int, dropped: Int)] = [:]
        var uploads: [PlanUpload] = []
        uploads.reserveCapacity(rows.count)
        var mismatchCounts: [PlanMismatch: Int] = [:]
        var mismatchTotal = 0
        // Links first (pending writes win): the listed folders' extras and Frame.io's sizes depend on all of them.
        let overlay = outbox.overlay
        let links = rows.map { row in
            PlanGrid.normalized(row.code.flatMap { overlay[$0.lowercased()]?[.frameio] } ?? row.value(.frameio))
        }
        // Suggestions for rows linked since (by hand, an upload, another Mac through the sheet) leave: accepting one
        // would replace that link.
        if !linkSuggestions.isEmpty {
            var linkedCodes = Set<String>()
            for (row, link) in zip(rows, links) where !link.isEmpty { if let code = row.code?.lowercased() { linkedCodes.insert(code) } }
            let kept = linkSuggestions.filter { !linkedCodes.contains($0.key) }
            if kept.count != linkSuggestions.count { linkSuggestions = kept }
        }
        // By Frame.io id, not URL text: links pasted by hand can differ in form, and a row may link a stack's current
        // version while the folder lists the stack.
        let linked = Set(links.compactMap(Self.frameIOID))
        var listed: [String: ListedFile] = [:]
        var unlinked: [ListedFile] = []
        // Bound to a Frame.io folder: every folder of its tree (it was scanned whole). Otherwise only folders holding a
        // linked file (whatever happened to be browsed).
        let bound = config?.frameioRoot != nil
        for files in frameioFolders.values where bound || files.contains(where: { $0.isLinked(in: linked) }) {
            for file in files {
                for id in file.ids { listed[id] = file }
                if !file.isLinked(in: linked) { unlinked.append(file) }
            }
        }
        var linkedCodes: [String: Bool] = [:]
        if !unlinked.isEmpty {
            for (row, link) in zip(rows, links) {
                guard let code = row.code?.lowercased() else { continue }
                linkedCodes[code] = (linkedCodes[code] ?? true) && !link.isEmpty
            }
        }
        var dismissedNow = 0
        var extras = unlinked.filter { file in
            guard dismissedMismatches.contains("fx|" + (Self.frameIOID(file.url) ?? file.url)) else { return true }
            dismissedNow += 1
            return false
        }.map { PlanFrameIOExtra(name: $0.name, url: $0.url, note: extraNote($0.name, linkedCodes: linkedCodes)) }
        extras.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // "Done but not on Frame.io" only for plans that use Frame.io links at all.
        let tracksFrameIO = links.contains { !$0.isEmpty }
        for (row, link) in zip(rows, links) {
            let result = match.result(row)
            let pending = row.code.flatMap { overlay[$0.lowercased()] }
            var state = PlanStatusResolver.resolve(match: result.status, hasFiles: !result.files.isEmpty,
                                                   qc: pending?[.qcStatus] ?? row.value(.qcStatus),
                                                   updated: pending?[.qcUpdated] ?? row.value(.qcUpdated),
                                                   fileDates: result.files.compactMap { dates[$0] })
            var found: [(kind: PlanMismatch, flag: String)] = []
            if !link.isEmpty {
                state.upload = .uploaded
                // The local file changed after the upload (a minute's grace: the upload stamp has no seconds).
                let uploadedOn = pending?[.uploaded] ?? row.value(.uploaded)
                if let when = PlanUpload.date(uploadedOn), let newest = result.files.compactMap({ dates[$0] }).max(),
                   newest > when.addingTimeInterval(60) {
                    state.upload = .stale
                    found.append((.differs, "Changed after its upload to Frame.io (\(uploadedOn)): Frame.io has an older version."))
                } else if result.files.count == 1, let local = result.files.first, QCUtilities.mediaKind(of: local) != .image,
                          let remote = Self.frameIOID(link).flatMap({ listed[$0] }), remote.size > 0,
                          let bytes = filesByURL[local]?.bytes, bytes > 0, bytes != remote.size,
                          (remote.name as NSString).pathExtension.lowercased() == local.pathExtension.lowercased() {
                    // Same kind of file, another size: Frame.io holds another version (or another file).
                    state.upload = .stale
                    found.append((.differs, "Frame.io's file is \(Self.byteText(remote.size)), this one \(Self.byteText(bytes)): Frame.io has another version."))
                }
            } else if tracksFrameIO, state.state.isDone {
                found.append((.notUploaded, "\(state.state.title), but not on Frame.io."))
            }
            // Dismissed ones stay quiet until what they were about changes (another link, a newer local file).
            let newest = result.files.compactMap { dates[$0] }.max()
            for (kind, flag) in found {
                if !dismissedMismatches.isEmpty, dismissedMismatches.contains(Self.mismatchKey(row.id, kind, link: link, newest: newest)) {
                    dismissedNow += 1
                    continue
                }
                state.mismatches.append(kind)
                state.flags.append(flag)
            }
            for kind in state.mismatches { mismatchCounts[kind, default: 0] += 1 }
            if !state.mismatches.isEmpty { mismatchTotal += 1 }
            newStates[row.id] = state
            let rowBatch = PlanGrid.normalized(pending?[.batch] ?? row.value(.batch))
            if !rowBatch.isEmpty { batchNames.insert(rowBatch) }
            perBatch[rowBatch, default: (0, 0, 0)].total += 1
            if state.state.isDone { perBatch[rowBatch, default: (0, 0, 0)].done += 1 }
            if state.state == .dropped { perBatch[rowBatch, default: (0, 0, 0)].dropped += 1 }
            uploads.append(state.upload)
            for url in result.files where index[url] == nil {
                index[url] = PlanFileInfo(code: row.code ?? "", line: row.line, rowID: row.id, state: state.state,
                                          batch: rowBatch, frameio: link, upload: state.upload, mismatches: state.mismatches,
                                          channel: PlanGrid.normalized(row.value(.channel)), text: row.searchText)
            }
        }
        let sortedBatches = PlanBatch.sorted(batchNames)
        if sortedBatches != batches { batches = sortedBatches }
        // The filter menus' counts, once per recompute rather than on every redraw of the plan (each Inspect selection).
        var counts = PlanCounts(
            batches: sortedBatches.map { name in
                let c = perBatch[name] ?? (0, 0, 0)
                return PlanBatchFilter.Item(name: name, count: c.total, done: c.done, live: c.total - c.dropped)
            },
            unbatched: perBatch[""]?.total ?? 0,
            uploads: PlanUploadFilter.counts(uploads))
        if !extras.isEmpty { mismatchCounts[.frameioExtra] = extras.count }
        let local = match.extras.filter { !dismissedMismatches.contains("lx|" + $0.path) }
        dismissedNow += match.extras.count - local.count
        if !local.isEmpty { mismatchCounts[.localExtra] = local.count }
        counts.mismatches = mismatchCounts
        counts.mismatchTotal = mismatchTotal + extras.count + local.count
        counts.dismissed = dismissedNow
        if local != localExtras { localExtras = local }
        if counts != planCounts { planCounts = counts }
        if extras != frameioExtras { frameioExtras = extras }
        // Inspect's "Here, Not in the Plan" filter skips the dismissed ones too.
        let flagged = Set(local)
        for url in match.extras {
            index[url] = PlanFileInfo(code: "", line: 0, rowID: nil, state: nil, mismatches: flagged.contains(url) ? [.localExtra] : [])
        }
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
        queueQC(rows.filter { ids.contains($0.id) }) { item in item[.qcStatus] = status?.title ?? "" }
    }

    func setNote(_ note: String, rowID: String) {
        queueQC(rows.filter { $0.id == rowID }) { item in item[.qcNote] = note }
    }

    /// Sets ("" clears) the batch of rows. Shown at once, written with the statuses (by code, every tab).
    func setBatch(_ batch: String, rowIDs: [String]) {
        let ids = Set(rowIDs)
        let value = PlanGrid.normalized(batch)
        queueQC(rows.filter { ids.contains($0.id) }) { item in item[.batch] = value }
    }

    /// QC Updated as shown (a pending edit wins).
    func qcUpdated(_ row: PlanRow) -> String { shown(.qcUpdated, row) }
    func qcStatusText(_ row: PlanRow) -> String { shown(.qcStatus, row) }

    /// The batch as shown (a pending edit wins), normalised; "" when none.
    func batch(_ row: PlanRow) -> String {
        PlanGrid.normalized(shown(.batch, row))
    }

    /// A column QCpie writes, as shown: a pending edit wins over the last read.
    private func shown(_ field: PlanField, _ row: PlanRow) -> String {
        row.code.flatMap { outbox.records[$0.lowercased()]?.values[field.rawValue] } ?? row.value(field)
    }

    // MARK: Frame.io

    /// The row's Frame.io link as shown (a pending edit wins); "" when none.
    func frameioLink(_ row: PlanRow) -> String { PlanGrid.normalized(shown(.frameio, row)) }

    /// Whether rows can hold Frame.io links: the QCpie tab has a Frame.io column for every code.
    var hasFrameIOColumn: Bool { hasQCTab || headers.values.contains { $0.columns[.frameio] != nil } }

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

    nonisolated static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "2026-11-05 10:42 UTC": the Uploaded column.
    nonisolated static func uploadStamp(_ date: Date) -> String {
        PlanUpload.stampFormatter.string(from: date) + " UTC"
    }

    /// QCpie uploaded `file` (the Upload tab) as Frame.io file `fileID`: its row's Frame.io column gets the file's link
    /// and Uploaded the date. A newer upload replaces an older link. Files whose row isn't clear (none, or several codes
    /// in the name) are left for Link Frame.io File….
    func uploaded(_ file: URL, account: String, fileID: String) async {
        guard config != nil else { return }
        // Uploading before the plan was opened this session: its rows aren't loaded yet (the cache, else one read).
        if rows.isEmpty { await loadCachedIfNeeded() }
        if rows.isEmpty { await refresh() }
        var codes = Set<String>()
        // The queue and Inspect can spell the same path differently (symlinks, /private/var…).
        let info = fileIndex[file] ?? fileIndex[file.standardizedFileURL] ?? fileIndex[file.resolvingSymlinksInPath()]
        if let code = info?.code, !code.isEmpty {
            codes = [code.lowercased()]
        } else {
            // Not one of the plan's matched files: the code alone could be another campaign's, so the name must also
            // hold the row's name (as when linking while browsing).
            let fileTokens = PlanMatcher.tokens(file.deletingPathExtension().lastPathComponent)
            codes = self.codes(inFileNamed: file.lastPathComponent).filter { code in
                rows(withCode: code).contains { PlanMatcher.contains(fileTokens, PlanMatcher.tokens($0.name)) }
            }
        }
        guard codes.count == 1, let code = codes.first else { return }
        // The file's link: a few tries (a dropped request mustn't lose the link), then built from its project.
        var url: String?
        for attempt in 0..<3 where url == nil {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2 * attempt)) }
            if let item = try? await FrameIO.shared.item(account: account, kind: "files", id: fileID) {
                url = item.viewURL ?? item.projectID.map { "https://next.frame.io/project/\($0)/view/\(fileID)" }
            }
        }
        guard let url else { return }
        // Uploads finish one file at a time: one recompute for a burst, not one per file (main thread, maybe playback).
        queueQC(rows(withCode: code), quiet: true, refresh: false) { item in
            item[.frameio] = url
            item[.uploaded] = Self.uploadStamp(Date())
        }
        scheduleRecompute()
    }

    /// Files listed on Frame.io (the browser, the favourites crawl): a row without a link gets the file whose name holds
    /// its code, when exactly one such file was in the listing (stacks: the stack, so the link survives new versions).
    /// Only into a sheet that has a Frame.io column, and never over a link already there.
    func frameIOListed(_ items: [FrameIO.Item], folder: String?) {
        guard config != nil else { return }
        // Browsing before the plan was opened this session: load its cached rows once, then look again.
        if rows.isEmpty, !loadedFromDisk {
            Task { await self.loadCachedIfNeeded(); if !self.rows.isEmpty { self.frameIOListed(items, folder: folder) } }
            return
        }
        // Bound to a Frame.io folder: listings outside its tree aren't the plan's (no links, no extras from them).
        guard inPlanTree(folder) else { return }
        recordListing(items, folder: folder)
        // Found while browsing: only into a sheet with the QCpie tab (it's set up on purpose; links wait in the outbox
        // while this Mac is signed out).
        guard hasQCTab, !rows.isEmpty else { return }
        // Candidates per code: files whose name holds the code, plus files named exactly like a row without its code
        // ("…_20s" for "…_20s_KL0140") or exactly like the local file matched to the row: names without a code.
        let names = exactNameIndex()
        let listed = items.filter { !$0.isFolder && $0.viewURL != nil }
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let decisions = Self.linkDecisions(
            files: listed.map { (id: $0.id, name: Self.listedName($0)) },
            codesInName: { self.codes(inFileNamed: $0) }, localNames: names.local, bareNames: names.bare,
            rows: { self.rows(withCode: $0) }, isLinked: { !self.frameioLink($0).isEmpty },
            localFiles: { self.match.result($0).files.map(\.lastPathComponent) })
        var queued = false
        for decision in decisions {
            guard let item = byID[decision.fileID], let url = item.viewURL else { continue }
            let targets = rows(withCode: decision.code)
            let date = Self.listedDate(item)
            guard decision.certain else {
                suggest(LinkSuggestion(code: targets.first?.code ?? decision.code, rowName: targets.first?.name ?? "",
                                       fileName: Self.listedName(item), url: url, fileID: item.id.lowercased(), date: date,
                                       reason: decision.reason))
                continue
            }
            if linkSuggestions[decision.code] != nil { linkSuggestions[decision.code] = nil }   // a dictionary write publishes even when nothing changes
            queueQC(targets, quiet: true, refresh: false) { entry in
                entry[.frameio] = url
                if let date, targets.allSatisfy({ self.shown(.uploaded, $0).isEmpty }) { entry[.uploaded] = Self.uploadStamp(date) }
            }
            queued = true
        }
        // Rows already linked to a listed version stack: a version added since (on Frame.io, by anyone) moves Uploaded
        // on, so a local file exported before it isn't flagged as newer than Frame.io's.
        for item in items where item.isVersionStack {
            guard let url = item.viewURL, let updated = Self.listedDate(item) else { continue }
            let linked = rows.filter { $0.code != nil && frameioLink($0) == PlanGrid.normalized(url) }
            guard !linked.isEmpty else { continue }
            let recorded = linked.compactMap { PlanUpload.date(shown(.uploaded, $0)) }.max()
            guard recorded.map({ updated > $0.addingTimeInterval(60) }) ?? true else { continue }
            queueQC(linked, quiet: true, refresh: false) { entry in entry[.uploaded] = Self.uploadStamp(updated) }
            queued = true
        }
        // One recompute and redraw for the whole listing, not one per row.
        if queued { recomputeStates(); publishGrids() }
    }

    // MARK: Frame.io folder

    /// The Frame.io project or folder that holds the plan's files. Only its tree is read for the plan: links found while
    /// listing, "on Frame.io" and "on Frame.io, not in the plan" come from it alone, so they don't depend on what was
    /// browsed or favourited. Set once per plan (••• → Frame.io Folder…).
    struct FrameIORoot: Codable, Equatable, Sendable {
        let account: String
        /// The folder listed (a project: its root folder).
        let folder: String
        /// "Project › Folder", for display.
        let title: String
    }

    /// The tree's folders as of the last full scan (`frameio-tree.json`).
    struct RootTree: Codable, Sendable {
        let root: String
        let folders: [String]
        let scanned: Date
    }

    enum RootScan: Equatable { case idle, scanning(Int), done(Date), failed(String) }

    /// Published at the start and end of a scan and every 10 folders.
    @Published private(set) var rootScan: RootScan = .idle
    /// Folders known to be in the tree (filled as a scan goes; a full scan replaces it).
    private var rootFolders: Set<String> = []
    private var lastRootScan: Date?
    private var rootScanTask: Task<Void, Never>?
    private var rootScanToken: UUID?

    static let rootScanInterval: TimeInterval = 15 * 60
    static let rootScanFolderLimit = 1000

    /// Binds the plan to a Frame.io folder (nil: none). What was listed elsewhere is dropped and the tree is read.
    func setFrameIORoot(_ root: FrameIORoot?) {
        guard var config, config.frameioRoot != root else { return }
        config.frameioRoot = root
        self.config = config
        saveConfig()
        rootScanTask?.cancel(); rootScanTask = nil
        rootFolders = root.map { [$0.folder] } ?? []
        linkSuggestions = [:]   // found in the old folder
        lastRootScan = nil
        rootScan = .idle
        frameioFolders = [:]
        saveFrameIOFolders()
        saveRootTree(nil)
        scheduleRecompute()
        if root != nil { scanFrameIORoot() }
    }

    /// Whether a listing of `folder` is the plan's: anything without a bound folder, else only its tree.
    private func inPlanTree(_ folder: String?) -> Bool {
        guard let root = config?.frameioRoot else { return true }
        guard let folder else { return false }
        return folder == root.folder || rootFolders.contains(folder)
    }

    /// Every 15 minutes while a plan panel is on screen (and on opening one).
    private func scanFrameIORootIfDue() {
        guard config?.frameioRoot != nil, rootScanTask == nil else { return }
        if let last = lastRootScan, Date().timeIntervalSince(last) < Self.rootScanInterval { return }
        scanFrameIORoot()
    }

    func scanFrameIORoot() {
        guard let root = config?.frameioRoot, let link = config?.link, rootScanTask == nil else { return }
        let token = UUID()
        rootScanToken = token
        rootScanTask = Task { [weak self] in
            await self?.runRootScan(root, link: link)
            // A scan cancelled for a new folder mustn't clear the new scan's handle.
            if self?.rootScanToken == token { self?.rootScanTask = nil }
        }
    }

    /// Lists the tree breadth-first, one folder at a time (0.4 s apart: Frame.io's rate limits, and the browser shares
    /// them). Each listing goes through `FrameIOLinks.remember` like a browsed one (link index, plan links, extras).
    /// A complete scan replaces the tree, so folders moved out or deleted leave the plan.
    private func runRootScan(_ root: FrameIORoot, link: PlanSheetLink) async {
        guard await FrameIO.shared.isSignedIn else {
            let failure = RootScan.failed("Sign in to Frame.io (Upload tab) to read the plan's folder.")
            if rootScan != failure { rootScan = failure }
            lastRootScan = Date().addingTimeInterval(60 - Self.rootScanInterval)   // look again in a minute
            return
        }
        rootScan = .scanning(0)
        var queue = [root.folder]
        var tree: Set<String> = [root.folder]
        var listed = 0
        while !queue.isEmpty, listed < Self.rootScanFolderLimit {
            if Task.isCancelled { return }
            let folder = queue.removeFirst()
            let items: [FrameIO.Item]
            do {
                items = try await FrameIO.shared.children(account: root.account, folder: folder, thumbnails: false)
            } catch {
                guard config?.frameioRoot == root else { return }
                if folder == root.folder {
                    rootScan = .failed("Couldn't read the plan's Frame.io folder: \(UploadEngine.describe(error))")
                    lastRootScan = Date().addingTimeInterval(120 - Self.rootScanInterval)   // again in two minutes
                    return
                }
                continue   // one unreadable subfolder doesn't stop the scan (its old listing stays)
            }
            guard config?.frameioRoot == root, config?.link == link else { return }
            for item in items where item.isFolder && tree.insert(item.id).inserted {
                queue.append(item.id)
                rootFolders.insert(item.id)
            }
            await FrameIOLinks.shared.remember(items, account: root.account, folder: folder)
            listed += 1
            if listed % 10 == 0 { rootScan = .scanning(listed) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard !Task.isCancelled, config?.frameioRoot == root else { return }
        let complete = queue.isEmpty
        if complete {
            rootFolders = tree
            frameioFolders = frameioFolders.filter { tree.contains($0.key) }
            saveFrameIOFolders()
        }
        let now = Date()
        lastRootScan = now
        saveRootTree(RootTree(root: root.folder, folders: Array(rootFolders), scanned: now))
        rootScan = complete ? .done(now) : .failed("The plan's Frame.io folder has more than \(Self.rootScanFolderLimit) folders: only those were read. Pick a smaller folder.")
        scheduleRecompute()
    }

    private func saveRootTree(_ tree: RootTree?) {
        guard let config else { return }
        let file = Self.directory(config.link.sheetID).appendingPathComponent("frameio-tree.json")
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let tree, let data = try? JSONEncoder().encode(tree) { try? data.write(to: file, options: .atomic) }
            else { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// "Project › Folder" for a browser path.
    nonisolated static func rootTitle(_ path: [FrameIOBrowser.Crumb]) -> String {
        path.filter { $0.level == .project || $0.level == .folder }.map(\.title).joined(separator: " › ")
    }

    /// The folder a pasted Frame.io project or folder link points to (a file link: the folder holding it).
    func frameIORoot(fromLink text: String) async throws -> FrameIORoot {
        let link = try FrameIOLink.parse(await FrameIOLink.expand(text))
        let (path, _) = try await FrameIOLink.resolve(link, preferredAccount: FrameIOBrowser.shared.accountID)
        guard let account = path.first?.id, let folder = path.last(where: { $0.listedFolder != nil })?.listedFolder else {
            throw FrameIOLink.Failure.notFound
        }
        let folders = path.prefix { $0.listedFolder != nil || $0.level == .account || $0.level == .workspace }
        return FrameIORoot(account: account, folder: folder, title: Self.rootTitle(Array(folders)))
    }

    // MARK: Suggested links

    struct LinkDecision: Equatable, Sendable {
        /// Lower-cased code of the row(s).
        let code: String
        let fileID: String
        /// Linked by itself; otherwise suggested with `reason`.
        let certain: Bool
        let reason: String
    }

    /// Which rows a Frame.io listing's files belong to (pure: the fixture tests run real names through it). Candidates
    /// per code: files whose name holds the code, plus files without a code named exactly like the local file matched
    /// to a row (`localNames`) or a row's name without its code (`bareNames`), when that points to one row. Rows that
    /// already have a link are left alone. One file must fit the row (its name holds the row's name, is the row's name
    /// without the code, or is its local file's name); of several (a "_v2" beside the original), only one named
    /// exactly like the row. Certain = one file, a code in its name, and the row's name in it; anything else is a
    /// suggestion. Codes repeat across campaigns, so a code alone never links.
    nonisolated static func linkDecisions(files: [(id: String, name: String)], codesInName: (String) -> Set<String>,
                                          localNames: [String: Set<String>], bareNames: [String: Set<String>],
                                          rows: (String) -> [PlanRow], isLinked: (PlanRow) -> Bool,
                                          localFiles: (PlanRow) -> [String]) -> [LinkDecision] {
        var candidates: [String: [(id: String, name: String)]] = [:]
        var byNameOnly = Set<String>()
        for file in files {
            var codes = codesInName(file.name)
            if codes.isEmpty {
                byNameOnly.insert(file.id)
                let key = nameKey(file.name)
                if let local = localNames[key], local.count == 1 { codes = local }
                else if let bare = bareNames[key], bare.count == 1 { codes = bare }
            }
            for code in codes { candidates[code, default: []].append(file) }
        }
        var out: [LinkDecision] = []
        for (code, list) in candidates.sorted(by: { $0.key < $1.key }) {
            let targets = rows(code)
            guard !targets.isEmpty, !targets.contains(where: isLinked) else { continue }
            func fits(_ name: String, exactly: Bool) -> Bool {
                let key = nameKey(name)
                return targets.contains { row in
                    let rowKey = nameKey(row.name)
                    let local = localFiles(row).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                    if exactly { return key == rowKey || key == nameKey(strippingCode(row)) || local }
                    return PlanMatcher.contains(PlanMatcher.tokens(key), PlanMatcher.tokens(rowKey)) || key == nameKey(strippingCode(row)) || local
                }
            }
            let chosen: (id: String, name: String)?
            if list.count == 1 { chosen = fits(list[0].name, exactly: false) ? list[0] : nil } else {
                let exact = list.filter { fits($0.name, exactly: true) }
                chosen = exact.count == 1 ? exact[0] : nil
            }
            guard let file = chosen else { continue }
            let certain = list.count == 1 && !byNameOnly.contains(file.id) && targets.contains { row in
                PlanMatcher.contains(PlanMatcher.tokens(nameKey(file.name)), PlanMatcher.tokens(nameKey(row.name)))
            }
            let reason = certain ? "" : byNameOnly.contains(file.id) ? "Same name, no code in the file's name."
                : list.count > 1 ? "One of \(list.count) files with this code: the one named like the row."
                : "The file's name holds the code but not the row's name."
            out.append(LinkDecision(code: code, fileID: file.id, certain: certain, reason: reason))
        }
        return out
    }

    /// A Frame.io file that probably belongs to a row, waiting for a click (`PlanLinkSuggestionsSheet`).
    struct LinkSuggestion: Identifiable, Equatable, Sendable {
        let code: String
        let rowName: String
        let fileName: String
        let url: String
        let fileID: String
        let date: Date?
        let reason: String
        var id: String { code.lowercased() }
        var dismissKey: String { "sx|\(code.lowercased())|\(fileID)" }
    }

    /// One per code (the latest listing's), not dismissed, for rows still without a link.
    @Published private(set) var linkSuggestions: [String: LinkSuggestion] = [:]

    /// Rows that get a link any way (accepted, by hand, by an upload) leave the list in `queueQC`.
    var pendingSuggestions: [LinkSuggestion] {
        linkSuggestions.values.sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }
    }

    private func suggest(_ suggestion: LinkSuggestion) {
        guard !dismissedMismatches.contains(suggestion.dismissKey), linkSuggestions[suggestion.id] != suggestion else { return }
        linkSuggestions[suggestion.id] = suggestion
    }

    func acceptSuggestions(_ ids: [String]) {
        for id in ids {
            guard let s = linkSuggestions[id] else { continue }
            let targets = rows(withCode: id)
            linkSuggestions[id] = nil
            // Never over a link that came in meanwhile.
            guard !targets.isEmpty, targets.allSatisfy({ frameioLink($0).isEmpty }) else { continue }
            queueQC(targets, refresh: false) { entry in
                entry[.frameio] = s.url
                if let date = s.date, targets.allSatisfy({ self.shown(.uploaded, $0).isEmpty }) { entry[.uploaded] = Self.uploadStamp(date) }
            }
        }
        recomputeStates()
        publishGrids()
    }

    func dismissSuggestions(_ ids: [String]) {
        let keys = ids.compactMap { linkSuggestions[$0]?.dismissKey }
        for id in ids { linkSuggestions[id] = nil }
        dismiss(keys)
    }

    // MARK: Dismissed mismatches

    /// Mismatches set aside (per plan, saved beside its cache): rows by row, kind and what the flag was about; files on
    /// Frame.io ("fx|" + id) or here ("lx|" + path) not in the plan.
    @Published private(set) var dismissedMismatches: Set<String> = []
    /// Inspect files not in the plan, without the dismissed ones.
    @Published private(set) var localExtras: [URL] = []

    nonisolated static func mismatchKey(_ rowID: String, _ kind: PlanMismatch, link: String, newest: Date?) -> String {
        let id = frameIOID(link) ?? ""
        // "Another version" comes back when the local file changes again.
        let stamp = kind == .differs ? newest.map { String(Int($0.timeIntervalSince1970)) } ?? "" : ""
        return "\(rowID)|\(kind.rawValue)|\(id)|\(stamp)"
    }

    /// Dismisses the rows' current mismatches (`kind` nil: all of them).
    func dismissMismatches(_ kind: PlanMismatch? = nil, rowIDs: [String]) {
        let ids = Set(rowIDs)
        let dates = Dictionary(files.compactMap { f in f.modified.map { (f.url, $0) } }, uniquingKeysWith: { a, _ in a })
        var keys: [String] = []
        for row in rows where ids.contains(row.id) {
            let newest = match.result(row).files.compactMap { dates[$0] }.max()
            for found in state(row).mismatches where kind == nil || found == kind {
                keys.append(Self.mismatchKey(row.id, found, link: frameioLink(row), newest: newest))
            }
        }
        dismiss(keys)
    }

    func dismissFrameIOExtras(_ urls: [String]) { dismiss(urls.map { "fx|" + (Self.frameIOID($0) ?? $0) }) }
    func dismissLocalExtras(_ urls: [URL]) { dismiss(urls.map { "lx|" + $0.path }) }

    func restoreDismissedMismatches() {
        guard !dismissedMismatches.isEmpty else { return }
        dismissedMismatches = []
        saveDismissed()
        scheduleRecompute()
    }

    private func dismiss(_ keys: [String]) {
        let before = dismissedMismatches.count
        dismissedMismatches.formUnion(keys)
        guard dismissedMismatches.count != before else { return }
        saveDismissed()
        recomputeStates()
        publishGrids()
    }

    private var dismissedSaveTask: Task<Void, Never>?
    /// One write at a time, the latest set (separate detached writes could land out of order).
    private func saveDismissed() {
        guard let config else { return }
        let dir = Self.directory(config.link.sheetID)
        let previous = dismissedSaveTask
        let keys = dismissedMismatches.sorted()
        dismissedSaveTask = Task {
            await previous?.value
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(keys) { try? data.write(to: dir.appendingPathComponent("dismissed-mismatches.json"), options: .atomic) }
            }.value
        }
    }

    // MARK: Frame.io folders

    /// A file seen in a Frame.io folder listing (stacks: the stack's link with its current version's name and size).
    struct ListedFile: Codable, Equatable, Sendable {
        let name: String
        let url: String
        let size: Int64
        /// Stacks: the current version's id (a row may link the version rather than the stack).
        var head: String? = nil
        var ids: [String] { [DeliveryPlanStore.frameIOID(url), head].compactMap { $0 } }
        func isLinked(in linked: Set<String>) -> Bool { ids.contains(where: linked.contains) }
    }

    /// The Frame.io id a link ends with ("…/view/<id>?…"), nil for an empty link.
    nonisolated static func frameIOID(_ link: String) -> String? {
        let path = link.split(separator: "?").first.map(String.init) ?? link
        let id = path.split(separator: "/").last.map(String.init) ?? ""
        return id.isEmpty ? nil : id.lowercased()
    }
    /// The files of listed Frame.io folders that hold plan files (a plan code or a linked file), by folder id: what
    /// "On Frame.io, not in the plan" and Frame.io's file sizes come from. Replaced by each new listing of the folder,
    /// saved with the plan.
    private var frameioFolders: [String: [ListedFile]] = [:]
    /// Files in the plan's Frame.io folders that no row links to (folders holding at least one linked file).
    @Published private(set) var frameioExtras: [PlanFrameIOExtra] = []

    private func recordListing(_ items: [FrameIO.Item], folder: String?) {
        guard let folder = folder ?? items.first(where: { !$0.isFolder })?.parentID else { return }
        let files = items.filter { !$0.isFolder }.compactMap { item -> ListedFile? in
            guard let url = item.viewURL else { return nil }
            return ListedFile(name: Self.listedName(item), url: PlanGrid.normalized(url), size: item.displaySize ?? 0,
                              head: item.isVersionStack ? item.headVersion?.id.lowercased() : nil)
        }
        let next: [ListedFile]?
        if config?.frameioRoot != nil {
            next = files   // every folder of the plan's tree, plan files or not
        } else {
            let links = Set(rows.compactMap { Self.frameIOID(frameioLink($0)) })
            let holdsPlanFiles = files.contains { $0.isLinked(in: links) || !codes(inFileNamed: $0.name).isEmpty }
            next = holdsPlanFiles ? files : nil
        }
        guard frameioFolders[folder] != next else { return }
        frameioFolders[folder] = next
        saveFrameIOFolders()
        scheduleRecompute()
    }

    private var foldersSaveTask: Task<Void, Never>?
    private func saveFrameIOFolders() {
        guard let config else { return }
        let dir = Self.directory(config.link.sheetID)
        foldersSaveTask?.cancel()
        foldersSaveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let folders = frameioFolders
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(folders) { try? data.write(to: dir.appendingPathComponent("frameio-folders.json"), options: .atomic) }
            }.value
        }
    }

    /// Why a Frame.io file in a plan folder has no row: none has its code, its row links another file, or it's unlinked.
    /// `linkedCodes`: lower-case code → whether every row with it has a link.
    private func extraNote(_ name: String, linkedCodes: [String: Bool]) -> String {
        guard let code = codes(inFileNamed: name).sorted().first else { return "No row has this file's code." }
        return linkedCodes[code] == true
            ? "Another file for \(code.uppercased()): its row links a different one."
            : "Looks like \(code.uppercased())'s file: link it from the row."
    }

    /// When a listed item last reached Frame.io: a file's creation; a stack's last change (its newest version).
    nonisolated static func listedDate(_ item: FrameIO.Item) -> Date? {
        item.isVersionStack ? (item.updatedDate ?? item.createdDate) : item.createdDate
    }

    private var recomputeTask: Task<Void, Never>?
    /// States and grids once, 0.3 s after the last of a burst of automatic writes.
    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            recomputeStates()
            publishGrids()
        }
    }

    /// A listed file's name (stacks: their current version's).
    nonisolated static func listedName(_ item: FrameIO.Item) -> String {
        item.isVersionStack ? (item.headVersion?.name ?? item.title) : item.title
    }

    /// A name compared without extension, case or separators ("A_20s.mp4" = "a 20s").
    nonisolated static func nameKey(_ name: String) -> String {
        PlanMatcher.tokens((name as NSString).deletingPathExtension).joined(separator: " ")
    }

    /// The row's name without its code at the end ("…_20s_KL0140" → "…_20s").
    nonisolated static func strippingCode(_ row: PlanRow) -> String {
        guard let code = row.code, !code.isEmpty else { return row.name }
        let tokens = PlanMatcher.tokens(row.name), codeTokens = PlanMatcher.tokens(code)
        guard tokens.count > codeTokens.count, Array(tokens.suffix(codeTokens.count)) == codeTokens else { return row.name }
        return tokens.dropLast(codeTokens.count).joined(separator: " ")
    }

    /// Exact names that point at rows, by `nameKey`: the local files matched to them (`local`) and their names without
    /// the code (`bare`). Kept apart: a local match settles a name several rows share without their codes. Built once
    /// per set of rows and match.
    private var nameIndex: (rows: Int, match: Int, local: [String: Set<String>], bare: [String: Set<String>])?
    private func exactNameIndex() -> (local: [String: Set<String>], bare: [String: Set<String>]) {
        if let nameIndex, nameIndex.rows == rowsVersion, nameIndex.match == matchRevision { return (nameIndex.local, nameIndex.bare) }
        var local: [String: Set<String>] = [:], bare: [String: Set<String>] = [:]
        for row in rows {
            guard let code = row.code?.lowercased(), !code.isEmpty else { continue }
            bare[Self.nameKey(Self.strippingCode(row)), default: []].insert(code)
            for url in match.result(row).files { local[Self.nameKey(url.lastPathComponent), default: []].insert(code) }
        }
        nameIndex = (rowsVersion, matchRevision, local, bare)
        return (local, bare)
    }

    /// Find Frame.io Links (the plan's ••• menu): what it's doing or found, shown in the status line for a while.
    @Published private(set) var linkSearch: String?
    private var searchingLinks = false

    /// Scans the Frame.io favourites and the projects the plan's links already point to now, instead of waiting for the
    /// 30-minute background scan; rows without a link get one as listings come in (the same rules as browsing).
    func findFrameIOLinks() async {
        guard !searchingLinks else { return }
        guard hasQCTab else {
            showLinkSearch("Set up the QCpie tab first (Delivery Plan ••• menu).")
            return
        }
        if config?.frameioRoot != nil {
            let before = linkedCodes()
            linkSearch = "Reading the plan's Frame.io folder…"
            scanFrameIORoot()
            await rootScanTask?.value
            try? await Task.sleep(for: .milliseconds(500))   // the last listings reach the plan on the main actor
            if case .failed(let message) = rootScan { showLinkSearch(message); return }
            let found = linkedCodes().subtracting(before).count
            showLinkSearch(found == 0 ? "No new Frame.io links found." : "Found \(found) Frame.io link\(found == 1 ? "" : "s").")
            return
        }
        searchingLinks = true
        defer { searchingLinks = false }
        let before = linkedCodes()
        let link = config?.link
        linkSearch = "Looking on Frame.io…"
        let projects = Set(rows.compactMap { row -> String? in
            let link = frameioLink(row)
            return link.isEmpty ? nil : (try? FrameIOLink.parse(link))?.project
        })
        let ran = await FrameIOCommentSync.shared.scanNow(projects: projects)
        try? await Task.sleep(for: .milliseconds(500))   // the last listings reach the plan on the main actor
        guard config?.link == link else { linkSearch = nil; return }   // another sheet was linked meanwhile
        let found = linkedCodes().subtracting(before).count
        showLinkSearch(!ran ? "Sign in to Frame.io (Upload tab), or wait for the scan already running."
                       : found == 0 ? "No new Frame.io links found." : "Found \(found) Frame.io link\(found == 1 ? "" : "s").")
    }

    private func linkedCodes() -> Set<String> {
        Set(rows.compactMap { row in frameioLink(row).isEmpty ? nil : row.code?.lowercased() })
    }

    private var linkSearchClear: Task<Void, Never>?
    private func showLinkSearch(_ text: String) {
        linkSearch = text
        linkSearchClear?.cancel()
        linkSearchClear = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            linkSearch = nil
        }
    }

    /// A linked file answered 404 to a comment check: if Frame.io confirms it's gone (a second 404 for the file itself),
    /// rows linked to it lose the link. A file still processing, or a hiccup, keeps it.
    func frameIOFileMissing(account: String, fileID: String) async {
        guard rows.contains(where: { frameioLink($0).hasSuffix("/" + fileID) }) else { return }
        do {
            _ = try await FrameIO.shared.item(account: account, kind: "files", id: fileID)
        } catch FrameIO.Failure.http(404, _) {
            frameIOGone([fileID])
        } catch {}
    }

    /// Frame.io files or stacks deleted (in the browser, or found gone): rows linked to them lose the link.
    func frameIOGone(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        // Out of the listed folders too, or the file would show as "on Frame.io, not in the plan" until relisted.
        let goneIDs = Set(ids.map { $0.lowercased() })
        var dropped = false
        // By the item's own id: a stack's current version going doesn't take the stack with it.
        func gone(_ file: ListedFile) -> Bool { Self.frameIOID(file.url).map(goneIDs.contains) ?? false }
        for (folder, files) in frameioFolders where files.contains(where: gone) {
            frameioFolders[folder] = files.filter { !gone($0) }
            dropped = true
        }
        if dropped { saveFrameIOFolders(); scheduleRecompute() }
        let staleSuggestions = linkSuggestions.filter { goneIDs.contains($0.value.fileID) }.map(\.key)
        for key in staleSuggestions { linkSuggestions[key] = nil }
        let targets = rows.filter { row in
            let link = frameioLink(row)
            return !link.isEmpty && ids.contains { link.hasSuffix("/" + $0) || link.contains("/" + $0 + "?") }
        }
        guard !targets.isEmpty else { return }
        queueQC(targets, quiet: true) { item in item[.frameio] = ""; item[.uploaded] = "" }
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
            let date = Self.listedDate(item)
            queueQC(rows.filter { ids.contains($0.id) }) { entry in
                entry[.frameio] = url
                if let date { entry[.uploaded] = Self.uploadStamp(date) }
            }
            return nil
        }
        return FrameIOLink.Failure.notFound.errorDescription ?? "That file wasn't found in your Frame.io accounts."
    }

    func clearFrameIO(rowIDs: [String]) {
        let ids = Set(rowIDs)
        queueQC(rows.filter { ids.contains($0.id) }) { item in item[.frameio] = ""; item[.uploaded] = "" }
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

    /// Queues QCpie's columns for rows (by code) in the outbox: shown at once, written to the QCpie tab in one call
    /// 0.3 s after the last change. A status change is stamped (QC Updated) with time and reviewer.
    /// `quiet`: automatic writes (Frame.io links) say nothing when they can't be saved.
    /// `refresh: false` leaves the recompute and redraw to the caller (several rows queued in a row).
    // MARK: Undo

    /// The last edit made by hand (status, note, batch, Frame.io link), as each code's values before it: ⌘Z in Inspect,
    /// the plan window, or the status line's Undo puts them back. One level, like the Frame.io browser's Undo.
    private var undoValues: [(code: String, name: String, values: [PlanField: String])] = []
    /// What ⌘Z would undo ("Status", "Batch"…), nil when nothing.
    @Published private(set) var undoTitle: String?

    @discardableResult
    func undoLastEdit() -> Bool {
        guard undoTitle != nil, !undoValues.isEmpty else { return false }
        let entries = undoValues
        undoValues = []
        undoTitle = nil
        for entry in entries {
            guard let row = rows.first(where: { $0.code?.lowercased() == entry.code.lowercased() }) else { continue }   // row gone
            queueQC([row], refresh: false, undoable: false, stamp: false) { $0 = entry.values }
        }
        recomputeStates()
        publishGrids()
        return true
    }

    private static func undoTitle(_ fields: Set<PlanField>) -> String {
        if fields.contains(.qcStatus) { return "Status" }
        if fields.contains(.frameio) { return "Frame.io Link" }
        if fields.contains(.batch) { return "Batch" }
        if fields.contains(.qcNote) { return "Note" }
        return "Edit"
    }

    private func queueQC(_ targets: [PlanRow], quiet: Bool = false, refresh: Bool = true, undoable: Bool = true, stamp: Bool = true,
                         _ change: (inout [PlanField: String]) -> Void) {
        guard config != nil else { return }
        let coded = targets.filter { !($0.code ?? "").isEmpty }
        guard !coded.isEmpty else { if !quiet { editState = .failed("Statuses need a Code column in the sheet.") }; return }
        var values: [PlanField: String] = [:]
        change(&values)
        guard !values.isEmpty else { return }
        // Only a status change is stamped: QC Updated dates the review, and a note edited later must not hide a new
        // version that arrived before it.
        if stamp, values[.qcStatus] != nil {
            let reviewer = UserDefaults.standard.string(forKey: "reviewerName").flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
            values[.qcUpdated] = PlanStatusResolver.stamp(Date(), by: reviewer)
        }
        // A hand edit can be undone: each code's values before it (automatic writes don't replace the last undo).
        if !quiet, undoable {
            var seen = Set<String>()
            undoValues = coded.compactMap { row in
                guard seen.insert(row.code!.lowercased()).inserted else { return nil }
                return (row.code!, row.name, Dictionary(uniqueKeysWithValues: values.keys.map { ($0, shown($0, row)) }))
            }
            undoTitle = Self.undoTitle(Set(values.keys))
        }
        for row in coded { outbox.set(code: row.code!, name: row.name, values, quiet: quiet) }
        if let link = values[.frameio], !link.isEmpty {
            for row in coded where linkSuggestions[row.code!.lowercased()] != nil { linkSuggestions[row.code!.lowercased()] = nil }
        }
        saveOutbox()
        if refresh {
            recomputeStates()
            publishGrids()
        }
        if !quiet { editState = .saving(outbox.unsent.records.count + outbox.unsent.cells.count) }
        scheduleFlush()
    }

    // MARK: Outbox

    private var flushTask: Task<Void, Never>?
    private var flushing = false
    private var retryDelay: Double = 0

    private func scheduleFlush(after seconds: Double = 0.3) {
        flushTask?.cancel()
        flushTask = Task {
            // Gathers a burst of clicks / shortcuts / Frame.io listings into one call.
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    /// Sends what the outbox holds that Google doesn't have yet. QCpie's columns: the QCpie tab is read first (rows
    /// may have been sorted or added), then the values for codes it has are written and the others appended, as text.
    /// Cells: each tab is read, the cell found again by code and header, and written only if it still shows what
    /// QCpie showed. Offline or Google busy: kept and retried. No access: dropped with the reason.
    private func flush() async {
        guard !flushing, let config else { return }
        var (records, cells) = outbox.unsent
        guard !records.isEmpty || !cells.isEmpty else { return }
        let loud = records.contains { !$0.quiet } || !cells.isEmpty
        guard await GoogleAuth.shared.isSignedIn else {
            if loud { report(.failed("Saved on this Mac: sign in with Google (Delivery Plan ••• menu) to send it to the sheet.")) }
            return
        }
        if config.qcTab == nil {
            if records.contains(where: { !$0.quiet }) {
                report(.failed("Saved on this Mac: set up the QCpie tab (Delivery Plan ••• menu) to send statuses to the sheet."))
            }
            records = []
            guard !cells.isEmpty else { return }
        }
        flushing = true
        defer { flushing = false }
        let before = outbox
        let id = config.link.sheetID
        let sentAt = Date()
        var refused: [String] = []
        do {
            if !records.isEmpty {
                let data = try await api.values(id, ranges: [SheetsAPI.quoted(PlanQCTab.title)])
                let (table, hasValues) = try await Task.detached(priority: .userInitiated) { () -> (PlanQCTab.Table?, Bool) in
                    let values = try SheetsAPI.tables(data).first ?? []
                    return (PlanQCTab.parse(values), values.contains { $0.contains { !$0.isEmpty } })
                }.value
                var updates: [(range: String, values: [[String]])] = []
                let current: PlanQCTab.Table
                if table == nil, hasValues {
                    // Something else is in row 1 (a title added above the header?): writing there would overwrite it.
                    // Kept until the tab's first row is its header again.
                    if loud { report(.failed("Not saved yet: the QCpie tab's first row must be its header (Code, Deliverable, QC Status…).")) }
                    setHealth { $0.writeError = "The QCpie tab's first row must be its header (Code, Deliverable, QC Status…)."; $0.retrying = true }
                    return
                }
                if let table { current = table } else {
                    // The header row was cleared: put it back.
                    updates.append((PlanQCTab.cell(row: 1, column: 0), [PlanQCTab.header]))
                    var columns: [PlanField: Int] = [.id: 0, .name: 1]
                    for (i, field) in PlanQCTab.fields.enumerated() { columns[field] = i + 2 }
                    current = PlanQCTab.Table(columns: columns, lines: [:], values: [:], width: PlanQCTab.header.count)
                }
                let changes = records.map { PlanQCTab.Change(code: $0.code, name: $0.name, values: $0.fields) }
                let writes = PlanQCTab.writes(changes, into: current)
                try await api.update(id, updates + writes.updates, raw: true)
                try await api.append(id, range: "\(SheetsAPI.quoted(PlanQCTab.title))!A1", rows: writes.appends)
                outbox.written(codes: records.map(\.code), cells: [], sentAt: sentAt)
            }
            for gid in Set(cells.map(\.gid)) {
                guard let tab = config.tabs.first(where: { $0.gid == gid }) else {
                    outbox.drop(codes: [], cells: Set(cells.filter { $0.gid == gid }.map(\.id)), sentAt: sentAt)
                    refused.append("that tab is no longer in the sheet")
                    continue
                }
                let data = try await api.values(id, ranges: [SheetsAPI.quoted(tab.name)])
                let table = try SheetsAPI.tables(data).first ?? []
                var writes: [(range: String, values: [[String]])] = []
                var written = Set<UUID>(), conflicts = Set<UUID>()
                for cell in cells where cell.gid == gid {
                    switch Self.locate(cell, in: table) {
                    case .success(let (row, column)):
                        writes.append(("\(SheetsAPI.quoted(tab.name))!\(PlanGrid.columnName(column))\(row + 1)", [[cell.value]]))
                        written.insert(cell.id)
                    case .failure(let reason):
                        conflicts.insert(cell.id)
                        refused.append(reason.message)
                    }
                }
                try await api.update(id, writes, raw: false)
                outbox.written(codes: [], cells: written, sentAt: sentAt)
                outbox.drop(codes: [], cells: conflicts, sentAt: sentAt)
            }
            retryDelay = 0
            if loud { report(refused.isEmpty ? .saved : .failed("Not saved: \(refused[0]).")) }
            setHealth { $0.canWrite = true; $0.retrying = false; $0.writeError = refused.first.map { "Not saved: \($0)." } }
        } catch {
            switch error {
            case GoogleAuth.Failure.signedOut:
                GoogleAccount.shared.noteSignedOut()
                if loud { report(.failed("Saved on this Mac: sign in with Google (Delivery Plan ••• menu) to send it to the sheet.")) }
            case SheetsAPI.Failure.http(400, _):
                // Usually a tab renamed or deleted (the QCpie tab too): read the tab list and keep the edits; if the
                // QCpie tab is gone they wait for it to be set up again.
                _ = try? await readMetadata(config)
                retryDelay = min(max(5, retryDelay * 2), 120)
                setHealth { $0.writeError = Self.describe(error); $0.retrying = true }
                if loud { report(.failed("Not saved yet (\(Self.describe(error))): trying again in \(Int(retryDelay)) s.")) }
                scheduleFlush(after: retryDelay)
            case let failure as SheetsAPI.Failure where !failure.isTransient:
                // Google won't take these however often they're sent (no edit access, bad range): drop them.
                outbox.drop(codes: records.map(\.code), cells: Set(cells.map(\.id)), sentAt: sentAt)
                if loud { report(.failed("Not saved: \(Self.describe(error))")) }
                setHealth {
                    if case .noAccess = failure { $0.canWrite = false }
                    $0.writeError = Self.describe(error); $0.retrying = false
                }
            default:
                // Offline or Google busy: kept, tried again later (and on the next read).
                retryDelay = min(max(5, retryDelay * 2), 120)
                if loud { report(.failed("Not saved yet (\(Self.describe(error))): trying again in \(Int(retryDelay)) s.")) }
                setHealth { $0.writeError = Self.describe(error); $0.retrying = true }
                scheduleFlush(after: retryDelay)
            }
        }
        // Nothing sent or refused (offline, retrying): no save, recompute or read.
        guard outbox != before else { return }
        saveOutbox()
        recomputeStates()
        publishGrids()
        // Read again shortly, so the written edits come back from the sheet (and leave the outbox).
        refreshAfterEdit?.cancel()
        refreshAfterEdit = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await refresh()
            if !outbox.unsent.records.isEmpty || !outbox.unsent.cells.isEmpty { scheduleFlush(after: 0.3) }
        }
    }
    private var refreshAfterEdit: Task<Void, Never>?

    /// The outbox's messages, published only when they change: a send retried after every read (no QCpie tab yet,
    /// offline) would otherwise redraw the plan and toast in Inspect every 10 s.
    private func report(_ state: EditState) { if editState != state { editState = state } }

    struct CellRefusal: Error { let message: String }

    /// Where a typed cell is now (0-based row and sheet column): its row by code when the sheet was sorted, its
    /// column by header when columns moved. Refused when the row is gone or the cell no longer shows what QCpie did.
    nonisolated static func locate(_ cell: PlanOutbox.Cell, in table: [[String]]) -> Result<(Int, Int), CellRefusal> {
        func text(_ r: Int, _ c: Int) -> String { r < table.count && c < table[r].count ? table[r][c] : "" }
        var row = cell.line - 1
        var column = cell.sheetColumn
        if let header = PlanParser.header(table) {
            if let code = cell.code, let codeColumn = header.columns[.id],
               PlanGrid.normalized(text(row, codeColumn)).lowercased() != code.lowercased() {
                guard let moved = table.indices.first(where: { $0 > header.index && PlanGrid.normalized(text($0, codeColumn)).lowercased() == code.lowercased() }) else {
                    return .failure(CellRefusal(message: "the row \(code) is no longer in the sheet"))
                }
                row = moved
            }
            if let name = cell.header?.lowercased(),
               let found = table[header.index].firstIndex(where: { PlanGrid.normalized($0).lowercased() == name }) {
                column = found
            }
        }
        let current = text(row, column)
        guard PlanGrid.normalized(current) == PlanGrid.normalized(cell.expect) else {
            return .failure(CellRefusal(message: "the cell was changed in the sheet meanwhile (now “\(current)”)"))
        }
        return .success((row, column))
    }

    private var outboxSaveTask: Task<Void, Never>?

    /// Written in order, off the main thread (a newer save waits for the one before).
    /// False until the saved outbox has been read: a save before that would overwrite edits saved before quitting
    /// (the load merges, then saves).
    private var outboxLoaded = false

    private func saveOutbox() {
        noteOutbox()
        guard let config, outboxLoaded else { return }
        let file = Self.directory(config.link.sheetID).appendingPathComponent("outbox.json")
        let snapshot = outbox
        let previous = outboxSaveTask
        outboxSaveTask = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if snapshot.isEmpty { try? FileManager.default.removeItem(at: file) }
            else if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }

    private func loadOutbox() async {
        guard let config else { return }
        let file = Self.directory(config.link.sheetID).appendingPathComponent("outbox.json")
        let saved = await Task.detached(priority: .utility) {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(PlanOutbox.self, from: $0) }
        }.value
        guard self.config?.link == config.link else { return }
        outboxLoaded = true
        guard let saved else { if !outbox.isEmpty { saveOutbox() }; return }
        // Edits made since launch are newer than the saved ones.
        for (key, record) in saved.records where outbox.records[key] == nil { outbox.records[key] = record }
        outbox.cells = saved.cells.filter { old in !outbox.cells.contains { $0.id == old.id } } + outbox.cells
        saveOutbox()
        recomputeStates()
        publishGrids()
        scheduleFlush(after: 1)
    }

    // MARK: QCpie tab

    @Published private(set) var settingUpQCTab = false

    /// Adds the QCpie tab: one row per code with the values the plan tabs' QC columns hold today (plus edits waiting
    /// in the outbox), then turns those columns into lookups of it (cleared, one formula each, dropdowns removed, a
    /// warning when someone edits them in Sheets). The values are written before any column is cleared.
    /// Returns why it failed, nil when the tab is there.
    @discardableResult
    func setUpQCTab() async -> String? {
        guard var config, !settingUpQCTab else { return nil }
        settingUpQCTab = true
        defer { settingUpQCTab = false }
        let id = config.link.sheetID
        do {
            let meta = try await api.metadata(id)
            if meta.tabs.contains(where: { $0.title == PlanQCTab.title }) {
                config = try await readMetadata(config)
                await refresh(full: true)
                return nil
            }
            let tabs = meta.tabs.filter { $0.title != PlanQCTab.title }
            let data = try await api.values(id, ranges: tabs.map { SheetsAPI.quoted($0.title) })
            let pendingAt = Date()
            let pending = outbox.records.values.map { PlanQCTab.Change(code: $0.code, name: $0.name, values: $0.fields) }
            let plan = try await Task.detached(priority: .userInitiated) { try Self.qcTabPlan(tabs: tabs, tables: SheetsAPI.tables(data), pending: pending) }.value

            // One atomic batch: the tab with its values, header and dropdown, and the plan tabs' QC columns turned
            // into lookups (cleared, one formula, no dropdown, a warning when edited by hand). All or nothing, so a
            // failure can't leave columns cleared without the tab holding their values.
            let used = Set(meta.tabs.compactMap { Int($0.gid) })
            var gidNumber = Int.random(in: 1_000_000...2_000_000_000)
            while used.contains(gidNumber) { gidNumber = Int.random(in: 1_000_000...2_000_000_000) }
            let body = try JSONSerialization.data(withJSONObject: ["requests": Self.qcTabRequests(plan, sheetID: gidNumber)])
            _ = try await api.batchUpdate(id, body: body)
            // Waiting edits are in the tab now.
            outbox.written(codes: pending.map(\.code), cells: [], sentAt: pendingAt)
            saveOutbox()
            // Onto the config as it is now (settings changed during the set-up stay).
            if var current = self.config, current.link == config.link {
                current.qcTab = String(gidNumber)
                self.config = current
                saveConfig()
            }
            lastValues = nil
            editState = .saved
            await refresh(full: true)
            scheduleFlush(after: 0)
            return nil
        } catch {
            if case GoogleAuth.Failure.signedOut = error { GoogleAccount.shared.noteSignedOut() }
            let message = "Couldn't set up the QCpie tab: \(Self.describe(error))"
            editState = .failed(message)
            return message
        }
    }

    struct QCTabPlan: Sendable {
        struct Lookup: Sendable { let gid: String; let title: String; let field: PlanField; let column: Int; let codeColumn: Int; let firstRow: Int }
        /// The tab's rows under its header.
        let rows: [[String]]
        /// The plan tabs' QC columns that become lookups.
        let lookups: [Lookup]
    }

    /// The `batchUpdate` requests that add the QCpie tab (`sheetID`) and turn the plan tabs' QC columns into lookups.
    nonisolated static func qcTabRequests(_ plan: QCTabPlan, sheetID: Int) -> [[String: Any]] {
        func text(_ value: String) -> [String: Any] { value.isEmpty ? [:] : ["userEnteredValue": ["stringValue": value]] }
        let statusColumn = PlanQCTab.header.firstIndex(of: PlanField.qcStatus.title)!
        var requests: [[String: Any]] = [
            ["addSheet": ["properties": [
                "sheetId": sheetID, "title": PlanQCTab.title,
                // 26 columns: the lookups read A:Z (a range past the tab's last column is an error in Sheets).
                "gridProperties": ["rowCount": plan.rows.count + 200, "columnCount": 26, "frozenRowCount": 1],
            ]]],
            // Strings as given (stringValue): "2", "2026-11-05 10:42 UTC" stay text.
            ["updateCells": ["start": ["sheetId": sheetID, "rowIndex": 0, "columnIndex": 0],
                             "rows": ([PlanQCTab.header] + plan.rows).map { ["values": $0.map(text)] },
                             "fields": "userEnteredValue"]],
            ["repeatCell": ["range": ["sheetId": sheetID, "startRowIndex": 0, "endRowIndex": 1],
                            "cell": ["userEnteredFormat": ["textFormat": ["bold": true]]],
                            "fields": "userEnteredFormat.textFormat.bold"]],
            ["setDataValidation": ["range": ["sheetId": sheetID, "startRowIndex": 1, "startColumnIndex": statusColumn, "endColumnIndex": statusColumn + 1],
                                   "rule": ["condition": ["type": "ONE_OF_LIST", "values": PlanQCStatus.allCases.map { ["userEnteredValue": $0.title] }],
                                            "showCustomUi": true, "strict": false]]],
        ]
        for column in plan.lookups {
            let range: [String: Any] = ["sheetId": Int(column.gid) ?? 0, "startRowIndex": column.firstRow - 1,
                                        "startColumnIndex": column.column, "endColumnIndex": column.column + 1]
            // With a range, cells the rows don't cover are cleared too: the formula in the first, the rest emptied.
            requests.append(["updateCells": [
                "range": range,
                "rows": [["values": [["userEnteredValue": ["formulaValue": PlanQCTab.formula(column.field, codeColumn: column.codeColumn, firstRow: column.firstRow)]]]]],
                "fields": "userEnteredValue,dataValidation",
            ]])
            requests.append(["addProtectedRange": ["protectedRange": [
                "range": range, "warningOnly": true,
                "description": "Filled from the QCpie tab: set \(column.field.title) there or in QCpie.",
            ]]])
        }
        return requests
    }

    /// What setting up the QCpie tab writes, from every tab's values and the outbox (whose edits win).
    nonisolated static func qcTabPlan(tabs: [SheetsAPI.Tab], tables: [[[String]]], pending: [PlanQCTab.Change]) -> QCTabPlan {
        var rows: [PlanRow] = []
        var lookups: [QCTabPlan.Lookup] = []
        for (tab, table) in zip(tabs, tables) {
            let parsed = PlanParser.parse(table: table, tab: tab.title)
            rows += parsed.rows
            guard let header = parsed.header, let codeColumn = header.columns[.id] else { continue }
            for field in PlanQCTab.fields {
                if let column = header.columns[field] {
                    lookups.append(.init(gid: tab.gid, title: tab.title, field: field, column: column, codeColumn: codeColumn, firstRow: header.index + 2))
                }
            }
        }
        var changes = PlanQCTab.migrate(rows)
        for edit in pending {
            if let i = changes.firstIndex(where: { $0.code.lowercased() == edit.code.lowercased() }) {
                changes[i] = PlanQCTab.Change(code: changes[i].code, name: changes[i].name,
                                              values: changes[i].values.merging(edit.values) { _, new in new })
            } else {
                changes.append(edit)
            }
        }
        let header = PlanQCTab.header
        let out = changes.map { change -> [String] in
            [change.code, change.name] + PlanQCTab.fields.map { change.values[$0] ?? "" }
        }
        precondition(header.count == 2 + PlanQCTab.fields.count)
        return QCTabPlan(rows: out, lookups: lookups)
    }

    /// The tab's header line (1-based), once read.
    func headerLine(gid: String) -> Int? { headers[gid]?.line }

    /// Dropdown choices by the Sheet view's column (0-based), matched by header: the view leaves hidden columns
    /// out, so the sheet's column numbers can't be used.
    func listColumns(gid: String) -> [Int: [String]] {
        guard let lists = cellLists[gid], !lists.isEmpty, let grid = grids[gid] else { return [:] }
        let headerLine = headers[gid]?.line
        var out: [Int: [String]] = [:]
        for column in grid.columnWidths.indices {
            let name = headerLine.flatMap { grid.text(line: $0, column: column) }.map { PlanGrid.normalized($0).lowercased() } ?? ""
            let sheetColumn = grid.sheetColumns.flatMap { column < $0.count ? $0[column] : nil } ?? column
            if let list = (name.isEmpty ? nil : lists[name]) ?? lists["#\(sheetColumn)"] { out[column] = list }
        }
        return out
    }

    // MARK: Disk

    static func directory(_ sheetID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/DeliveryPlan/\(sheetID)", isDirectory: true)
    }

    nonisolated private static func writeCache(_ cache: [String: [[String]]], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: dir.appendingPathComponent("values.json"), options: .atomic) }
        // Files of the public-link reader, no longer used.
        for old in ["tabs.json", "grids.json"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
    }

    nonisolated private static func writeLayouts(_ layouts: [String: PlanGrid], to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(layouts) { try? data.write(to: dir.appendingPathComponent("layouts.json"), options: .atomic) }
    }
}
