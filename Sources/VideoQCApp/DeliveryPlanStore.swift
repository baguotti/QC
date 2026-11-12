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

    @Published var config: Config?
    @Published var rows: [PlanRow] = [] { didSet { rowsVersion &+= 1 } }
    var rowsVersion = 0
    @Published var match: PlanMatch = .empty
    @Published var phase: Phase = .idle
    @Published var lastUpdated: Date?
    @Published var changes: [String: Change] = [:]
    @Published var removed: [SeenRow] = []
    /// Tabs whose header row wasn't found (shown so a renamed header doesn't silently drop a tab).
    @Published var unreadTabs: [String] = []
    /// Tabs read without a Code column while the sheet has the QCpie tab: their rows can't show or take statuses.
    @Published var codelessTabs: [String] = []
    /// Rows per tab (by gid) from the last read of each tab, for the tab picker.
    @Published var tabCounts: [String: Int] = [:]
    /// Inspect has files (matching is meaningful).
    @Published var hasFiles = false
    /// Each included tab as the sheet draws it, by gid (the Sheet view).
    @Published var grids: [String: PlanGrid] = [:]
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
    @Published var states: [String: PlanRowState] = [:]
    /// Inspect's view of the plan, by file: code, row and state; nil state = not in the plan. Rebuilt only when it
    /// changes, so `ContentView` (which mirrors it for the Inspect table) redraws once per change, never per poll.
    @Published var fileIndex: [URL: PlanFileInfo] = [:]
    /// Dropdown choices per tab (gid), keyed by header (lower case) or "#" + sheet column index.
    @Published var cellLists: [String: [String: [String]]] = [:]
    /// Every batch named in the plan (pending edits included), in natural order.
    @Published var batches: [String] = []
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
    @Published var planCounts = PlanCounts()
    /// Whether rows can have a batch (the QCpie tab holds one for every code).
    var hasBatchColumn: Bool { hasQCTab || headers.values.contains { $0.columns[.batch] != nil } }
    var hasQCTab: Bool { config?.qcTab != nil }
    /// The last cell edit's outcome, for the status line.
    @Published var editState: EditState = .idle

    enum EditState: Equatable { case idle, saving(Int), saved, failed(String) }

    /// A cell by sheet row (1-based) and column (0-based).
    struct CellKey: Hashable, Sendable { let line: Int; let column: Int }
    /// Every edit not yet in a read of the sheet (on disk: `outbox.json`).
    var outbox = PlanOutbox()
    /// Grids as last read from the sheet (`grids` = these + the outbox's edits).
    var readGrids: [String: PlanGrid] = [:]
    /// Each tab's formatted layout (read every 5 minutes, or when rows or columns are added) and when it was read.
    var layouts: [String: PlanGrid] = [:]
    var layoutRead: [String: Date] = [:]
    var layoutTask: Task<Void, Never>?
    /// `readLayouts` reading again what outgrew its layout meanwhile: at most twice, so a sheet edited non-stop can't
    /// keep it busy.
    var rereadDepth = 0
    /// The last values read, by gid: the layout is filled with them.
    var tables: [String: [[String]]] = [:]
    /// The last values reply as received: an identical one means nothing changed (no parse, no matching).
    var lastValues: Data?
    /// The sheet's Drive version at the last values read; the 10 s check reads the values only when it moved
    /// (and every 3 minutes regardless). `versionCheck` false: not available (Drive API off, or signed in before the
    /// scope was added); tried again after `versionCheckRetry`.
    var lastVersion: String?
    var lastValuesRead = Date.distantPast
    /// The ranges of that read: other tabs on or off (or the QCpie tab added) need a read even if the sheet didn't change.
    var lastRanges: [String] = []
    var versionCheck: Bool?
    var versionCheckRetry = Date.distantPast
    /// Grows ×2 (to ×12) while Google answers 429 (too many requests, e.g. many Macs on one plan), back to 1 on success.
    var readBackoff: Double = 1
    var lastMetadata = Date.distantPast
    var reading = false
    /// The QCpie tab as last read (nil: none, or not read yet).
    var qcTable: PlanQCTab.Table?
    /// Each tab's header (by gid): its line and the column of each field.
    var headers: [String: (line: Int, columns: [PlanField: Int])] = [:]
    /// Bumped when matching or files change (cache key for per-row check summaries).
    var matchRevision = 0

    var seen: [String: SeenRow] = [:]
    var files: [PlanFile] = []
    var visiblePanels = 0
    var pollTask: Task<Void, Never>?
    var matchTask: Task<Void, Never>?
    var loadedFromDisk = false
    let api = SheetsAPI.shared

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
            // the link points at, else the one with the most coded rows, then the most rows (a tab without a Code
            // column can't take statuses or links, even when it lists more files). Others are in the ••• menu.
            let data = try await api.values(link.sheetID, ranges: tabs.map { SheetsAPI.quoted($0.name) })
            let (counts, coded) = try await Task.detached(priority: .userInitiated) { () -> ([String: Int], [String: Int]) in
                let tables = try SheetsAPI.tables(data)
                var counts: [String: Int] = [:], coded: [String: Int] = [:]
                for (tab, table) in zip(tabs, tables) {
                    let rows = PlanParser.parse(table: table, tab: tab.name).rows
                    counts[tab.gid] = rows.count
                    coded[tab.gid] = rows.count { !($0.code ?? "").isEmpty }
                }
                return (counts, coded)
            }.value
            let chosen = link.gid.flatMap { gid in tabs.contains { $0.gid == gid } ? gid : nil }
                ?? Self.startingTab(tabs.map(\.gid), counts: counts, coded: coded)
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
            Log.plan.error("Linking the sheet failed", error)
            phase = .failed(Self.describe(error))
        }
    }

    /// The tab a link without a gid starts on: most coded rows, then most rows.
    nonisolated static func startingTab(_ gids: [String], counts: [String: Int], coded: [String: Int]) -> String? {
        gids.max { (coded[$0] ?? 0, counts[$0] ?? 0) < (coded[$1] ?? 0, counts[$1] ?? 0) }
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
        codelessTabs = []
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

    func saveConfig() {
        if let config, let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.configKey) }
    }

    // Stored state of the sections below. Their code is in DeliveryPlanStore+Reading / +Matching / +FrameIOLinks /
    // +FrameIOFolders / +Editing: Swift keeps stored properties in the type's main declaration.

    // MARK: Refreshing
    /// Bumped by each apply: a slower one that started earlier (the disk cache) mustn't overwrite a newer read.
    var applyGeneration = 0
    // MARK: Files
    var assetsTask: Task<Void, Never>?
    var filesByURL: [URL: PlanFile] = [:]
    /// What Inspect's checks found in each file (subs, graphics, loudness), compared with its row (`PlanContentCheck`).
    var fileContent: [URL: PlanContent] = [:]
    /// The inspection each file's date was read for (a re-inspection gets a new id and a new stat).
    var assetIDs: [URL: UUID] = [:]
    // MARK: States
    /// Row states and the per-file index for Inspect. ~1 ms for 1,100 rows; publishes only what changed.
    /// The connection at a glance (`PlanHealthBadge`); published only when it changes.
    @Published var health = PlanHealth()
    /// Bumped by every recompute of the states (the Summary rebuilds its figures only then).
    var statesRevision = 0
    // MARK: Frame.io
    /// Plan codes by their first token (built once per set of rows): a Frame.io listing is checked per file name token,
    /// not per row.
    var codeIndex: (rows: Int, byToken: [String: [(code: String, tokens: [String])]])?
    /// Rows by lower-cased code, built once per set of rows: listings ask for every file's code (a filter over 1,100
    /// rows each time added up).
    var rowsByCode: (version: Int, map: [String: [PlanRow]])?
    // MARK: Frame.io folder
    /// Published at the start and end of a scan and every 10 folders.
    @Published var rootScan: RootScan = .idle
    /// Folders known to be in the tree (filled as a scan goes; a full scan replaces it).
    var rootFolders: Set<String> = []
    var lastRootScan: Date?
    var rootScanTask: Task<Void, Never>?
    var rootScanToken: UUID?
    // MARK: Suggested links
    /// One per code (the latest listing's), not dismissed, for rows still without a link.
    @Published var linkSuggestions: [String: LinkSuggestion] = [:]
    // MARK: Dismissed mismatches
    /// Mismatches set aside (per plan, saved beside its cache): rows by row, kind and what the flag was about; files on
    /// Frame.io ("fx|" + id) or here ("lx|" + path) not in the plan.
    @Published var dismissedMismatches: Set<String> = []
    /// Inspect files not in the plan, without the dismissed ones.
    @Published var localExtras: [URL] = []
    var dismissedSaveTask: Task<Void, Never>?
    // MARK: Frame.io folders
    /// The files of listed Frame.io folders that hold plan files (a plan code or a linked file), by folder id: what
    /// "On Frame.io, not in the plan" and Frame.io's file sizes come from. Replaced by each new listing of the folder,
    /// saved with the plan.
    var frameioFolders: [String: [ListedFile]] = [:]
    /// Files in the plan's Frame.io folders that no row links to (folders holding at least one linked file).
    @Published var frameioExtras: [PlanFrameIOExtra] = []
    var foldersSaveTask: Task<Void, Never>?
    var recomputeTask: Task<Void, Never>?
    /// Exact names that point at rows, by `nameKey`: the local files matched to them (`local`) and their names without
    /// the code (`bare`). Kept apart: a local match settles a name several rows share without their codes. Built once
    /// per set of rows and match.
    var nameIndex: (rows: Int, match: Int, local: [String: Set<String>], bare: [String: Set<String>])?
    /// Find Frame.io Links (the plan's ••• menu): what it's doing or found, shown in the status line for a while.
    @Published var linkSearch: String?
    var searchingLinks = false
    var linkSearchClear: Task<Void, Never>?
    // MARK: Linked filters
    @Published var linkFilters = UserDefaults.standard.bool(forKey: "planLinkFilters") {
        didSet { UserDefaults.standard.set(linkFilters, forKey: "planLinkFilters") }
    }
    @Published var sharedFilter = SharedFilter()
    /// The row last clicked in the plan (shortcuts use it when Inspect has no selection, e.g. a Missing row).
    var focusedRowID: String?
    // MARK: Undo
    /// The last edit made by hand (status, note, batch, Frame.io link), as each code's values before it: ⌘Z in Inspect,
    /// the plan window, or the status line's Undo puts them back. One level, like the Frame.io browser's Undo.
    var undoValues: [(code: String, name: String, values: [PlanField: String])] = []
    /// What ⌘Z would undo ("Status", "Batch"…), nil when nothing.
    @Published var undoTitle: String?
    // MARK: Outbox
    var flushTask: Task<Void, Never>?
    var flushing = false
    var retryDelay: Double = 0
    var refreshAfterEdit: Task<Void, Never>?
    var outboxSaveTask: Task<Void, Never>?
    /// Written in order, off the main thread (a newer save waits for the one before).
    /// False until the saved outbox has been read: a save before that would overwrite edits saved before quitting
    /// (the load merges, then saves).
    var outboxLoaded = false
    // MARK: QCpie tab
    @Published var settingUpQCTab = false
    // MARK: Disk

    static func directory(_ sheetID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/DeliveryPlan/\(sheetID)", isDirectory: true)
    }

    nonisolated static func writeCache(_ cache: [String: [[String]]], to dir: URL) {
        JSONFile.save(cache, to: dir.appendingPathComponent("values.json"), log: .plan)
        // Files of the public-link reader, no longer used.
        for old in ["tabs.json", "grids.json"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
    }

    nonisolated static func writeLayouts(_ layouts: [String: PlanGrid], to dir: URL) {
        JSONFile.save(layouts, to: dir.appendingPathComponent("layouts.json"), log: .plan)
    }
}
