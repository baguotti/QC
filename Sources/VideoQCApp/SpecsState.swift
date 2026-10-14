import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQCLib

@MainActor
public final class SpecsState: ObservableObject {
    @Published public var deliverableAssets: [DeliverableAsset] = [] {
        didSet {
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
        refreshSubtitleSidecars()
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
        
        audioAnalysisTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await DeliverablesInspector.analyzeBatchAudioLevels(assets: assetsToAnalyze) { [weak self] updatedAsset, completed, total in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let index = self.deliverableAssets.firstIndex(where: { $0.id == updatedAsset.id }) {
                        self.deliverableAssets[index] = updatedAsset
                    }
                    self.analyzedAudioCount = completed
                    self.totalAudioCount = total
                    self.audioAnalysisProgress = total > 0 ? Double(completed) / Double(total) : 1.0
                }
            }
            self.isAnalyzingAudioLevels = false
            self.audioAnalysisTask = nil
        }
    }
    
    public func cancelAudioAnalysis() {
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        isAnalyzingAudioLevels = false
    }
    
    public func inspectDeliverablesBatch(urls: [URL], append: Bool = false) {
        guard !urls.isEmpty else { return }
        cancelAudioAnalysis()
        isInspectingDeliverables = true
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            let assets = await DeliverablesInspector.inspectBatch(urls: urls)
            if append {
                var seen = Set(self.deliverableAssets.map { $0.fileURL.standardizedFileURL })
                let newAssets = assets.filter { seen.insert($0.fileURL.standardizedFileURL).inserted }
                if !newAssets.isEmpty {
                    self.deliverableAssets += newAssets
                }
            } else {
                self.deliverableAssets = assets
            }
            self.isInspectingDeliverables = false
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
