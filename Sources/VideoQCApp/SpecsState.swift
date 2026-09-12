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
    
    // Column Width & Resizing
    @Published public var specsFileNameColumnWidth: Double {
        didSet { UserDefaults.standard.set(specsFileNameColumnWidth, forKey: "specsFileNameColumnWidth") }
    }
    @Published public var liveFileNameColumnWidth: Double = 220.0
    @Published public var isDraggingFileNameColumn: Bool = false
    @Published public var dragStartFileNameWidth: Double? = nil
    
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
        isDraggingFileNameColumn ? liveFileNameColumnWidth : specsFileNameColumnWidth
    }
    
    public var isFileNameExpanded: Bool {
        effectiveFileNameColumnWidth > 240.0
    }
    
    public init() {
        let savedWidth = UserDefaults.standard.object(forKey: "specsFileNameColumnWidth") as? Double ?? 220.0
        self.specsFileNameColumnWidth = savedWidth
        self.liveFileNameColumnWidth = savedWidth
        self.specsSortColumnRaw = UserDefaults.standard.string(forKey: "specsSortColumn") ?? SpecsSortColumn.name.rawValue
        self.specsSortAscending = UserDefaults.standard.object(forKey: "specsSortAscending") as? Bool ?? true
    }
    
    public func onFileNameDragChanged(translationWidth: Double) {
        if dragStartFileNameWidth == nil {
            dragStartFileNameWidth = specsFileNameColumnWidth
            isDraggingFileNameColumn = true
        }
        let start = dragStartFileNameWidth ?? specsFileNameColumnWidth
        let newWidth = max(140.0, min(1200.0, start + translationWidth))
        liveFileNameColumnWidth = newWidth
    }
    
    public func onFileNameDragEnded(translationWidth: Double) {
        if let start = dragStartFileNameWidth {
            let finalWidth = max(140.0, min(1200.0, start + translationWidth))
            specsFileNameColumnWidth = finalWidth
            liveFileNameColumnWidth = finalWidth
        }
        dragStartFileNameWidth = nil
        isDraggingFileNameColumn = false
    }
    
    public func autoFitFileNameColumnWidth(filteredAssets: [DeliverableAsset]) {
        if isFileNameExpanded {
            specsFileNameColumnWidth = 220.0
            liveFileNameColumnWidth = 220.0
        } else {
            let longestName = filteredAssets.map { $0.fileName }.max(by: { $0.count < $1.count }) ?? ""
            let estWidth = Double(longestName.count) * 7.5 + 40.0
            let targetWidth = max(260.0, min(1000.0, estWidth))
            specsFileNameColumnWidth = targetWidth
            liveFileNameColumnWidth = targetWidth
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
