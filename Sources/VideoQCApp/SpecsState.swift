import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import VideoQCLib

@MainActor
public final class SpecsState: ObservableObject {
    /// Posted with a URL: the Inspect table scrolls that file into view (plan row clicks).
    public static let scrollToFile = Notification.Name("QCpieSpecsScrollToFile")

    @Published public var deliverableAssets: [DeliverableAsset] = [] {
        didSet {
            assetsVersion &+= 1
            if deliverableAssets.isEmpty {
                selectedDeliverableURLs = []
                selectionAnchorURL = nil
                subtitleCrossCheck = nil
            }
            // Only when files are added / removed: per-asset updates (audio levels) don't change subtitles.
            if oldValue.map(\.fileURL) != deliverableAssets.map(\.fileURL) {
                refreshSubtitleSidecars()
            }
        }
    }
    @Published public var specsFilterText: String = ""
    /// Primary (last clicked) row: Media Info, Reveal in Finder etc. act on it. Setting it to a row outside the
    /// multi-selection makes that row the whole selection.
    @Published public var selectedDeliverableURL: URL? = nil {
        didSet {
            guard let url = selectedDeliverableURL, !selectedDeliverableURLs.contains(url) else { return }
            selectedDeliverableURLs = [url]
            selectionAnchorURL = url
        }
    }
    /// Finder-style multi-selection: click, ⌘-click, ⇧-click.
    @Published public var selectedDeliverableURLs: Set<URL> = []
    public var selectionAnchorURL: URL? = nil
    /// Files in the order the table shows them; refreshed on each table render and read when a row is clicked
    /// (rows skip re-rendering when unchanged, so they must not capture the order).
    public var currentDisplayOrder: [URL] = []
    @Published public var isInspectingDeliverables: Bool = false
    @Published public var manifestCSVURL: URL? = nil
    @Published public var manifestHTMLURL: URL? = nil
    @Published public var deliverablesCollapsedFolderIDs: Set<String> = []
    @Published public var dismissedMismatchURLs: Set<URL> = []
    
    // Audio Level Analysis Tracking
    @Published public var isAnalyzingAudioLevels: Bool = false
    @Published public var audioAnalysisProgress: Double = 0.0
    @Published public var analyzedAudioCount: Int = 0
    @Published public var totalAudioCount: Int = 0
    private var audioAnalysisTask: Task<Void, Never>? = nil
    /// Identifies the current run: results of a cancelled run arriving late are dropped.
    private var audioAnalysisRun = 0
    
    // End-frame check (on demand)
    @Published public var isCheckingEndFrames: Bool = false
    @Published public var checkedEndFrameCount: Int = 0
    @Published public var totalEndFrameCount: Int = 0
    private var endFrameTask: Task<Void, Never>? = nil
    
    // MARK: - Multi-Selection
    
    public func isSelected(_ url: URL) -> Bool {
        selectedDeliverableURLs.contains(url)
    }
    
    /// Click handling like Finder. `displayOrder` is the list as shown (for ⇧-click ranges).
    public func handleClick(on url: URL, modifiers: NSEvent.ModifierFlags, displayOrder: [URL]) {
        let key = url
        if modifiers.contains(.command) {
            if selectedDeliverableURLs.contains(key) {
                selectedDeliverableURLs.remove(key)
                if selectedDeliverableURL == key {
                    selectedDeliverableURL = displayOrder.first { selectedDeliverableURLs.contains($0) }
                }
            } else {
                selectedDeliverableURLs.insert(key)
                selectedDeliverableURL = url
            }
            selectionAnchorURL = url
        } else if modifiers.contains(.shift), let anchor = selectionAnchorURL {
            let order = displayOrder
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: key) {
                selectedDeliverableURLs.formUnion(order[min(a, b)...max(a, b)])
            } else {
                selectedDeliverableURLs.insert(key)
            }
            selectedDeliverableURL = url
        } else {
            selectedDeliverableURLs = [key]
            selectedDeliverableURL = url
            selectionAnchorURL = url
        }
    }
    
    /// Keyboard selection: `index` in `order` (clamped). Extending selects the range from the anchor to it (going back
    /// shrinks it), as in Finder. Returns the newly focused file.
    @discardableResult
    public func moveSelection(to index: Int, extend: Bool, order: [URL]) -> URL? {
        guard !order.isEmpty else { return nil }
        let i = min(max(0, index), order.count - 1)
        let url = order[i]
        if extend, let anchor = selectionAnchorURL, let a = order.firstIndex(of: anchor) {
            selectedDeliverableURLs = Set(order[min(a, i)...max(a, i)])
            selectedDeliverableURL = url
        } else {
            selectedDeliverableURLs = [url]
            selectedDeliverableURL = url
            selectionAnchorURL = url
        }
        return url
    }

    /// The focused file's position in `order` (the last one moved to or clicked).
    public func focusIndex(in order: [URL]) -> Int? {
        selectedDeliverableURL.flatMap { order.firstIndex(of: $0) }
    }

    /// The rows an action on `url` applies to: the whole selection if `url` is part of it, else just `url`.
    public func actionTargets(for url: URL, displayOrder: [URL]) -> [URL] {
        guard isSelected(url), selectedDeliverableURLs.count > 1 else { return [url] }
        return displayOrder.filter { selectedDeliverableURLs.contains($0) }
    }
    
    // MARK: - Subtitles (.srt per deliverable) & Cross-Check
    
    /// Resolved .srt per video: attached by hand, or same-name sidecar.
    @Published public private(set) var subtitleURLs: [URL: URL] = [:]
    /// Videos whose .srt was attached by hand (cached so table rows never read UserDefaults).
    @Published public private(set) var manuallyAttachedSubtitleVideos: Set<URL> = []
    @Published public var subtitleCrossCheck: SubtitleCrossCheckReport? = nil
    @Published public var showSubtitleCrossCheck: Bool = false
    @Published public private(set) var isCrossCheckingSubtitles: Bool = false
    private var sidecarTask: Task<Void, Never>? = nil
    private var attachmentObserver: AnyCancellable?
    
    public func subtitleURL(for video: URL) -> URL? {
        subtitleURLs[video]
    }
    
    public func hasSubtitleMismatch(_ video: URL) -> Bool {
        subtitleCrossCheck?.mismatchedVideos.contains(video) ?? false
    }
    
    public func refreshSubtitleSidecars() {
        let videos = deliverableAssets.map(\.fileURL)
        sidecarTask?.cancel()
        sidecarTask = Task { @MainActor [weak self] in
            let (resolved, manual): ([URL: URL], Set<URL>) = await Task.detached(priority: .utility) {
                var map: [URL: URL] = [:]
                var manual: Set<URL> = []
                for video in videos {
                    if let srt = SubtitleAttachments.resolve(for: video) { map[video] = srt }
                    if SubtitleAttachments.manual(for: video) != nil { manual.insert(video) }
                }
                return (map, manual)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.subtitleURLs = resolved
            self.manuallyAttachedSubtitleVideos = manual
        }
    }
    
    /// Attaches (nil: detaches) an .srt to a video; remembered across launches and used by the player too.
    public func attachSubtitles(_ srt: URL?, to video: URL) {
        SubtitleAttachments.setManual(srt, for: video)
    }
    
    /// Compares the .srt of each video (in list order; the first is the reference) and opens the results.
    public func runSubtitleCrossCheck(videos: [URL], fpsByVideo: [URL: Double], options: SubtitleCrossCheck.Options = SubtitleCrossCheck.Options()) {
        let pairs = videos.compactMap { video in subtitleURL(for: video).map { (video, $0) } }
        guard pairs.count >= 2 else { return }
        isCrossCheckingSubtitles = true
        Task { @MainActor [weak self] in
            let loaded: [SubtitleCrossCheckReport.File] = await Task.detached(priority: .userInitiated) {
                pairs.map { video, srt in
                    let cues = (try? SubtitleParser.load(from: srt)) ?? []
                    return SubtitleCrossCheckReport.File(videoURL: video, srtURL: srt, cues: cues,
                                                         fps: fpsByVideo[video].flatMap { $0 > 0 ? $0 : nil } ?? 25)
                }
            }.value
            guard let self else { return }
            var report = SubtitleCrossCheckReport(files: loaded, referenceVideo: loaded[0].videoURL, options: options)
            report.recompute()
            self.subtitleCrossCheck = report
            self.isCrossCheckingSubtitles = false
            self.showSubtitleCrossCheck = true
        }
    }
    
    public func isMismatchDismissed(for url: URL) -> Bool {
        dismissedMismatchURLs.contains(url)
    }
    
    public func toggleDismissMismatch(for url: URL) {
        let key = url
        if dismissedMismatchURLs.contains(key) {
            dismissedMismatchURLs.remove(key)
        } else {
            dismissedMismatchURLs.insert(key)
        }
    }
    
    // Universal Column Width & Resizing
    @Published public var columnWidths: [SpecsSortColumn: Double] = [:]
    @Published public var liveDraggingColumn: SpecsSortColumn? = nil
    @Published public var liveDraggingWidth: Double = 0.0
    private var dragStartWidth: Double? = nil
    
    // Backwards-compatible legacy properties for fileName column
    public var specsFileNameColumnWidth: Double {
        get { columnWidths[.name] ?? SpecsSortColumn.name.defaultWidth }
        set { setColumnWidth(newValue, for: .name) }
    }
    
    // Sorting
    @Published public var specsSortColumnRaw: String {
        didSet { UserDefaults.standard.set(specsSortColumnRaw, forKey: "specsSortColumn") }
    }
    @Published public var specsSortAscending: Bool {
        didSet { UserDefaults.standard.set(specsSortAscending, forKey: "specsSortAscending") }
    }
    
    public var specsSortColumn: SpecsSortColumn {
        get { SpecsSortColumn(rawValue: specsSortColumnRaw) ?? .name }
        set { specsSortColumnRaw = newValue.rawValue }
    }
    
    public var effectiveFileNameColumnWidth: Double {
        columnWidth(for: .name)
    }
    
    public var isFileNameExpanded: Bool {
        effectiveFileNameColumnWidth > 240.0
    }
    
    public init() {
        var widths: [SpecsSortColumn: Double] = [:]
        for col in SpecsSortColumn.allCases {
            let key = col == .name ? "specsFileNameColumnWidth" : "specsColumnWidth_\(col.rawValue)"
            if let saved = UserDefaults.standard.object(forKey: key) as? Double {
                widths[col] = max(col.minWidth, min(col.maxWidth, saved))
            } else {
                widths[col] = col.defaultWidth
            }
        }
        self.columnWidths = widths
        self.specsSortColumnRaw = UserDefaults.standard.string(forKey: "specsSortColumn") ?? SpecsSortColumn.name.rawValue
        self.specsSortAscending = UserDefaults.standard.object(forKey: "specsSortAscending") as? Bool ?? true
        attachmentObserver = NotificationCenter.default.publisher(for: SubtitleAttachments.didChange)
            .sink { [weak self] _ in self?.refreshSubtitleSidecars() }
    }
    
    /// Columns the user hid (File Name can't be). Remembered.
    @Published public var hiddenColumns: Set<SpecsSortColumn> = Set(
        (UserDefaults.standard.array(forKey: "specsHiddenColumns") as? [String] ?? []).compactMap(SpecsSortColumn.init(rawValue:))
    ) {
        didSet { UserDefaults.standard.set(hiddenColumns.map(\.rawValue), forKey: "specsHiddenColumns") }
    }

    // MARK: Column templates

    /// A saved column layout: which columns show and their widths.
    public struct ColumnTemplate: Codable, Equatable, Identifiable {
        public var name: String
        public var hidden: [String]
        public var widths: [String: Double]
        public var id: String { name }
    }

    /// Built in, always offered: everything, the columns delivery QC needs, and a narrow one.
    public static let builtInTemplates: [ColumnTemplate] = [
        ColumnTemplate(name: "All Columns", hidden: [], widths: [:]),
        ColumnTemplate(name: "Delivery QC", hidden: [SpecsSortColumn.date, .endFrame, .path].map(\.rawValue), widths: [:]),
        ColumnTemplate(name: "Compact", hidden: [SpecsSortColumn.date, .endFrame, .path, .fps, .videoCodec, .audioCodec].map(\.rawValue), widths: [:]),
    ]

    @Published public private(set) var columnTemplates: [ColumnTemplate] =
        (UserDefaults.standard.data(forKey: "specsColumnTemplates")).flatMap { try? JSONDecoder().decode([ColumnTemplate].self, from: $0) } ?? []

    /// Saves the current layout under a name (replacing one with the same name).
    public func saveColumnTemplate(named name: String) {
        let widths = Dictionary(uniqueKeysWithValues: SpecsSortColumn.allCases.map { ($0.rawValue, columnWidth(for: $0)) })
        let template = ColumnTemplate(name: name, hidden: hiddenColumns.map(\.rawValue).sorted(), widths: widths)
        columnTemplates.removeAll { $0.name == name }
        columnTemplates.append(template)
        persistTemplates()
    }

    public func deleteColumnTemplate(named name: String) {
        columnTemplates.removeAll { $0.name == name }
        persistTemplates()
    }

    /// Shows the template's columns; widths it saved are applied, others stay as they are.
    public func applyColumnTemplate(_ template: ColumnTemplate) {
        hiddenColumns = Set(template.hidden.compactMap(SpecsSortColumn.init(rawValue:)))
        for (key, width) in template.widths {
            if let column = SpecsSortColumn(rawValue: key) { setColumnWidth(width, for: column) }
        }
    }

    private func persistTemplates() {
        if let data = try? JSONEncoder().encode(columnTemplates) { UserDefaults.standard.set(data, forKey: "specsColumnTemplates") }
    }

    public func isColumnVisible(_ column: SpecsSortColumn) -> Bool { column == .name || !hiddenColumns.contains(column) }

    public func setColumnVisible(_ column: SpecsSortColumn, _ visible: Bool) {
        guard column != .name else { return }
        if visible { hiddenColumns.remove(column) } else { hiddenColumns.insert(column) }
    }

    public func columnWidth(for column: SpecsSortColumn) -> Double {
        if liveDraggingColumn == column {
            return liveDraggingWidth
        }
        return columnWidths[column] ?? column.defaultWidth
    }
    
    public func isDragging(column: SpecsSortColumn) -> Bool {
        liveDraggingColumn == column
    }
    
    public func setColumnWidth(_ width: Double, for column: SpecsSortColumn) {
        let clamped = max(column.minWidth, min(column.maxWidth, width))
        columnWidths[column] = clamped
        let key = column == .name ? "specsFileNameColumnWidth" : "specsColumnWidth_\(column.rawValue)"
        UserDefaults.standard.set(clamped, forKey: key)
    }
    
    public func resetColumnWidth(for column: SpecsSortColumn) {
        setColumnWidth(column.defaultWidth, for: column)
    }
    
    public func onColumnDragChanged(column: SpecsSortColumn, translationWidth: Double) {
        if dragStartWidth == nil || liveDraggingColumn != column {
            dragStartWidth = columnWidth(for: column)
            liveDraggingColumn = column
        }
        let start = dragStartWidth ?? columnWidth(for: column)
        let newWidth = max(column.minWidth, min(column.maxWidth, start + translationWidth))
        liveDraggingWidth = newWidth
    }
    
    public func onColumnDragEnded(column: SpecsSortColumn, translationWidth: Double) {
        if let start = dragStartWidth {
            let finalWidth = max(column.minWidth, min(column.maxWidth, start + translationWidth))
            setColumnWidth(finalWidth, for: column)
        }
        dragStartWidth = nil
        liveDraggingColumn = nil
    }
    
    // Legacy fileName helpers routed to universal implementation
    
    public func autoFitFileNameColumnWidth(filteredAssets: [DeliverableAsset]) {
        if isFileNameExpanded {
            setColumnWidth(SpecsSortColumn.name.defaultWidth, for: .name)
        } else {
            let longestName = filteredAssets.map { $0.fileName }.max(by: { $0.count < $1.count }) ?? ""
            let estWidth = Double(longestName.count) * 7.5 + 40.0
            let targetWidth = max(260.0, min(1000.0, estWidth))
            setColumnWidth(targetWidth, for: .name)
        }
    }
    
    public func toggleSpecsSort(_ column: SpecsSortColumn) {
        if specsSortColumn == column {
            specsSortAscending.toggle()
        } else {
            specsSortColumn = column
            if column == .date || column == .size {
                specsSortAscending = false
            } else {
                specsSortAscending = true
            }
        }
    }
    
    /// Bumped on every change to `deliverableAssets` (cheap key for `displayedAssets`).
    private(set) var assetsVersion = 0
    private struct DisplayKey: Equatable {
        let version: Int, filter: String, mask: Int, column: String, ascending: Bool, plan: String
    }
    private var displayCache: (key: DisplayKey, assets: [DeliverableAsset])?

    /// The Specs table's rows: filtered by name / path and media kind, then sorted. Memoized: the table reads it several
    /// times per render, and audio analysis re-renders once per finished file (re-sorting 500 rows each time).
    /// `planKey` changes with the Delivery Plan filter and index; `planAllows` / `planText` are only called on a cache
    /// miss. The search also finds files by their plan row (every word in the file name, path or row's values).
    public func displayedAssets(filter: String, mask: Int, planKey: String = "", planAllows: ((URL) -> Bool)? = nil,
                                planText: ((URL) -> String?)? = nil, planSort: ((URL) -> Int)? = nil) -> [DeliverableAsset] {
        let key = DisplayKey(version: assetsVersion, filter: filter, mask: mask, column: specsSortColumnRaw, ascending: specsSortAscending, plan: planKey)
        if let cache = displayCache, cache.key == key { return cache.assets }
        let base: [DeliverableAsset]
        let words = filter.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if filter.isEmpty && mask == MediaKindFilter.all && planAllows == nil {
            base = deliverableAssets
        } else {
            base = deliverableAssets.filter {
                MediaKindFilter.allows($0.fileURL, mask: mask) && (planAllows?($0.fileURL) ?? true) &&
                (filter.isEmpty || $0.fileName.localizedCaseInsensitiveContains(filter) || $0.fileURL.path.localizedCaseInsensitiveContains(filter)
                    || Self.allWords(words, in: $0.fileName.lowercased() + " " + (planText?($0.fileURL) ?? "")))
            }
        }
        var assets = sortDeliverableAssets(base)
        if let planSort {
            // Plan order / status, stable: the column sort breaks ties.
            let keys = Dictionary(assets.map { ($0.fileURL, planSort($0.fileURL)) }, uniquingKeysWith: { a, _ in a })
            let order = Dictionary(assets.enumerated().map { ($0.element.fileURL, $0.offset) }, uniquingKeysWith: { a, _ in a })
            assets.sort { a, b in
                let ka = keys[a.fileURL] ?? .max, kb = keys[b.fileURL] ?? .max
                return ka != kb ? (specsSortAscending ? ka < kb : ka > kb) : order[a.fileURL]! < order[b.fileURL]!
            }
        }
        displayCache = (key, assets)
        return assets
    }

    private static func allWords(_ words: [String], in text: String) -> Bool {
        !words.isEmpty && words.allSatisfy { text.contains($0) }
    }

    public func sortDeliverableAssets(_ assets: [DeliverableAsset]) -> [DeliverableAsset] {
        assets.sorted { a, b in
            let order: ComparisonResult
            switch specsSortColumn {
            case .name:
                order = a.fileName.localizedStandardCompare(b.fileName)
            case .timecode:
                if a.durationSeconds == b.durationSeconds {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.durationSeconds < b.durationSeconds ? .orderedAscending : .orderedDescending
                }
            case .ratio:
                let aPixels = a.width * a.height
                let bPixels = b.width * b.height
                if aPixels == bPixels {
                    order = a.aspectRatioString.compare(b.aspectRatioString)
                } else {
                    order = aPixels < bPixels ? .orderedAscending : .orderedDescending
                }
            case .fps:
                if a.fps == b.fps {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.fps < b.fps ? .orderedAscending : .orderedDescending
                }
            case .size:
                if a.fileSizeBytes == b.fileSizeBytes {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.fileSizeBytes < b.fileSizeBytes ? .orderedAscending : .orderedDescending
                }
            case .date:
                let aDate = a.creationDate ?? .distantPast
                let bDate = b.creationDate ?? .distantPast
                if aDate == bDate {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = aDate < bDate ? .orderedAscending : .orderedDescending
                }
            case .videoCodec:
                if a.videoCodec == b.videoCodec {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.videoCodec.localizedStandardCompare(b.videoCodec)
                }
            case .endFrame:
                // Black first, then not black, unavailable, unchecked.
                func rank(_ asset: DeliverableAsset) -> Int {
                    switch asset.endFrame?.verdict {
                    case .black: return 0
                    case .notBlack: return 1
                    case .unreadable: return 2
                    case .unavailable: return 3
                    case nil: return 4
                    }
                }
                order = rank(a) == rank(b) ? .orderedSame : (rank(a) < rank(b) ? .orderedAscending : .orderedDescending)
            case .audioCodec:
                let aAudio = "\(a.audioCodec) \(a.audioBitrate)"
                let bAudio = "\(b.audioCodec) \(b.audioBitrate)"
                if aAudio == bAudio {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = aAudio.localizedStandardCompare(bAudio)
                }
            case .path:
                order = a.fileURL.path.localizedStandardCompare(b.fileURL.path)
            }
            
            return specsSortAscending ? (order == .orderedAscending) : (order == .orderedDescending)
        }
    }
    
    public func analyzeAudioLevels() {
        guard !deliverableAssets.isEmpty else { return }
        cancelAudioAnalysis()
        
        let assetsToAnalyze = deliverableAssets
        totalAudioCount = assetsToAnalyze.count
        analyzedAudioCount = 0
        audioAnalysisProgress = 0.0
        isAnalyzingAudioLevels = true
        audioAnalysisRun += 1
        let run = audioAnalysisRun
        
        audioAnalysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await DeliverablesInspector.analyzeBatchAudioLevels(assets: assetsToAnalyze) { [weak self] updatedAsset, completed, total in
                Task { @MainActor [weak self] in
                    guard let self, self.audioAnalysisRun == run else { return }
                    if let index = self.deliverableAssets.firstIndex(where: { $0.id == updatedAsset.id }) {
                        self.deliverableAssets[index] = updatedAsset
                    }
                    self.analyzedAudioCount = completed
                    self.totalAudioCount = total
                    self.audioAnalysisProgress = total > 0 ? Double(completed) / Double(total) : 1.0
                }
            }
            guard self.audioAnalysisRun == run else { return }
            self.isAnalyzingAudioLevels = false
            self.audioAnalysisTask = nil
        }
    }
    
    /// Classifies the last frame of every listed deliverable (BLACK / NEAR BLACK / NOT BLACK).
    public func checkEndFrames() {
        guard !deliverableAssets.isEmpty else { return }
        cancelEndFrameCheck()
        let urls = deliverableAssets.map(\.fileURL)
        totalEndFrameCount = urls.count
        checkedEndFrameCount = 0
        isCheckingEndFrames = true
        endFrameTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let owner = self else { return }
            await DeliverablesInspector.checkBatchEndFrames(urls: urls) { [weak owner] url, result, completed, _ in
                Task { @MainActor [weak owner] in
                    guard let owner else { return }
                    if let index = owner.deliverableAssets.firstIndex(where: { $0.fileURL == url }) {
                        owner.deliverableAssets[index].endFrame = result
                    }
                    owner.checkedEndFrameCount = completed
                }
            }
            owner.isCheckingEndFrames = false
            owner.endFrameTask = nil
        }
    }
    
    public func cancelEndFrameCheck() {
        endFrameTask?.cancel()
        endFrameTask = nil
        isCheckingEndFrames = false
    }
    
    public func cancelAudioAnalysis() {
        audioAnalysisRun += 1
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        isAnalyzingAudioLevels = false
    }
    
    /// Bumped when the queue is replaced: batches of an earlier queue (still inspecting a big folder) are dropped
    /// instead of landing over the new one.
    private var inspectGeneration = 0
    private var inspectionsRunning = 0
    /// Files added (append batches) since the queue was replaced: kept when the replacing batch lands after them.
    private var appendedSinceReplace: Set<URL> = []

    /// Empties the list; inspections still running for the old queue are dropped when they finish.
    public func clearDeliverables() {
        cancelAudioAnalysis()
        inspectGeneration += 1
        inspectionsRunning = 0
        appendedSinceReplace = []
        isInspectingDeliverables = false
        deliverableAssets = []
    }

    public func inspectDeliverablesBatch(urls: [URL], append: Bool = false) {
        guard !urls.isEmpty else { return }
        cancelAudioAnalysis()
        if !append {
            inspectGeneration += 1
            inspectionsRunning = 0
            appendedSinceReplace = []
        }
        let generation = inspectGeneration
        inspectionsRunning += 1
        isInspectingDeliverables = true
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            let assets = await DeliverablesInspector.inspectBatch(urls: urls)
            guard generation == self.inspectGeneration else { return }
            self.inspectionsRunning -= 1
            if append {
                var seen = Set(self.deliverableAssets.map { $0.fileURL.standardizedFileURL })
                let newAssets = assets.filter { seen.insert($0.fileURL.standardizedFileURL).inserted }
                self.appendedSinceReplace.formUnion(newAssets.map { $0.fileURL.standardizedFileURL })
                if !newAssets.isEmpty {
                    self.deliverableAssets += newAssets
                }
            } else {
                // Files added while this batch was inspecting landed first: keep them.
                let landed = Set(assets.map { $0.fileURL.standardizedFileURL })
                self.deliverableAssets = assets + self.deliverableAssets.filter {
                    let url = $0.fileURL.standardizedFileURL
                    return self.appendedSinceReplace.contains(url) && !landed.contains(url)
                }
            }
            if self.inspectionsRunning <= 0 { self.isInspectingDeliverables = false }
        }
    }
    
    public func exportDeliverablesManifest(rootFolderURL: URL?) {
        guard !deliverableAssets.isEmpty else { return }
        
        let csvString = DeliverablesInspector.generateManifestCSV(assets: deliverableAssets, rootFolderURL: rootFolderURL)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        savePanel.nameFieldStringValue = "Deliverables_Specs_\(Date().timeIntervalSince1970).csv"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csvString.write(to: url, atomically: true, encoding: .utf8)
            self.manifestCSVURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    public func openManifestHTML(rootFolderURL: URL?) {
        guard !deliverableAssets.isEmpty else { return }
        
        let folderName = (rootFolderURL ?? deliverableAssets.first?.fileURL.deletingLastPathComponent())?.lastPathComponent ?? "DELIVERY_ASSETS"
        let htmlString = DeliverablesInspector.generateManifestHTML(assets: deliverableAssets, folderName: folderName, rootFolderURL: rootFolderURL)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Deliverables_Specs_\(UUID().uuidString).html")
        
        do {
            try htmlString.write(to: tempURL, atomically: true, encoding: .utf8)
            self.manifestHTMLURL = tempURL
            NSWorkspace.shared.open(tempURL)
        } catch {
            print("Failed to open Deliverables HTML: \(error)")
        }
    }
    
    public func generateManifestTSV(rootFolderURL: URL?) -> String? {
        guard !deliverableAssets.isEmpty else { return nil }
        return DeliverablesInspector.generateManifestTSV(assets: deliverableAssets, rootFolderURL: rootFolderURL)
    }
}


/// Result of comparing several deliverables' subtitles against one reference file.
public struct SubtitleCrossCheckReport: Sendable {
    public struct File: Sendable, Identifiable {
        public var id: URL { videoURL }
        public let videoURL: URL
        public let srtURL: URL
        public let cues: [SubtitleCue]
        public let fps: Double
        public var differences: [SubtitleCrossCheck.Difference] = []
    }
    
    public var files: [File]
    public var referenceVideo: URL
    public var options: SubtitleCrossCheck.Options
    
    public var reference: File? { files.first { $0.videoURL == referenceVideo } }
    public var mismatchedVideos: Set<URL> { Set(files.filter { !$0.differences.isEmpty }.map(\.videoURL)) }
    public var totalDifferences: Int { files.reduce(0) { $0 + $1.differences.count } }
    
    public mutating func recompute() {
        guard let reference = reference else { return }
        for index in files.indices {
            files[index].differences = files[index].videoURL == referenceVideo ? [] :
                SubtitleCrossCheck.compare(reference: reference.cues, other: files[index].cues, options: options)
        }
    }
}
