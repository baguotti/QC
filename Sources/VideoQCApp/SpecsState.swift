import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQCLib

@MainActor
public final class SpecsState: ObservableObject {
    @Published public var deliverableAssets: [DeliverableAsset] = []
    @Published public var specsFilterText: String = ""
    @Published public var selectedDeliverableURL: URL? = nil
    @Published public var isInspectingDeliverables: Bool = false
    @Published public var manifestCSVURL: URL? = nil
    @Published public var manifestHTMLURL: URL? = nil
    @Published public var deliverablesCollapsedFolderIDs: Set<String> = []
    @Published public var dismissedMismatchURLs: Set<URL> = []
    
    public func isMismatchDismissed(for url: URL) -> Bool {
        dismissedMismatchURLs.contains(url.standardizedFileURL)
    }
    
    public func dismissMismatch(for url: URL) {
        dismissedMismatchURLs.insert(url.standardizedFileURL)
    }
    
    public func restoreMismatch(for url: URL) {
        dismissedMismatchURLs.remove(url.standardizedFileURL)
    }
    
    public func toggleDismissMismatch(for url: URL) {
        let key = url.standardizedFileURL
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
    public var liveFileNameColumnWidth: Double {
        get { liveDraggingColumn == .name ? liveDraggingWidth : specsFileNameColumnWidth }
        set { if liveDraggingColumn == .name { liveDraggingWidth = newValue } }
    }
    public var isDraggingFileNameColumn: Bool {
        liveDraggingColumn == .name
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
    public func onFileNameDragChanged(translationWidth: Double) {
        onColumnDragChanged(column: .name, translationWidth: translationWidth)
    }
    
    public func onFileNameDragEnded(translationWidth: Double) {
        onColumnDragEnded(column: .name, translationWidth: translationWidth)
    }
    
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
    
    public func inspectDeliverablesBatch(urls: [URL], append: Bool = false) {
        guard !urls.isEmpty else { return }
        isInspectingDeliverables = true
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            let assets = await DeliverablesInspector.inspectBatch(urls: urls)
            if append {
                var existingMap = Dictionary(uniqueKeysWithValues: self.deliverableAssets.map { ($0.fileURL.standardizedFileURL, $0) })
                for asset in assets {
                    let key = asset.fileURL.standardizedFileURL
                    if existingMap[key] == nil {
                        existingMap[key] = asset
                        self.deliverableAssets.append(asset)
                    }
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
