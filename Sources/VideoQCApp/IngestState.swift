import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQCLib
import AVFoundation

public enum IngestSortColumn: String, CaseIterable, Equatable, Sendable {
    case name = "name"
    case category = "category"
    case size = "size"
    case resolution = "resolution"
    case fps = "fps"
    case duration = "duration"
    case codec = "codec"
    case path = "path"
    
    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .category: return "Category"
        case .size: return "Size"
        case .resolution: return "Resolution"
        case .fps: return "FPS"
        case .duration: return "Duration"
        case .codec: return "Codec"
        case .path: return "Path"
        }
    }
}

@MainActor
public final class IngestState: ObservableObject {
    @Published public var manifest: IngestManifest = IngestManifest()
    @Published public var intakeFolderURL: URL? = nil
    
    // Status & Progress
    @Published public var isScanning: Bool = false
    @Published public var scanProgress: Double = 0.0
    @Published public var scanStatusMessage: String = ""
    
    // DIT Integration
    @Published public var ditRecords: [IngestDITRecord] = []
    @Published public var ditReportURL: URL? = nil
    @Published public var flags: [IngestFlag] = []
    @Published public var isFlagsExpanded: Bool = true
    
    // Search & Filter
    @Published public var filterText: String = ""
    @Published public var selectedCategoryFilter: IngestFileCategory? = nil
    @Published public var selectedItem: IngestItem? = nil
    
    // Sorting
    @Published public var sortColumn: IngestSortColumn = .name
    @Published public var sortAscending: Bool = true
    
    public init() {}
    
    // MARK: - Filtered & Sorted Items
    
    public var filteredItems: [IngestItem] {
        var result = manifest.items
        
        if let cat = selectedCategoryFilter {
            result = result.filter { $0.fileCategory == cat }
        }
        
        if !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = filterText.lowercased()
            result = result.filter { item in
                item.fileName.lowercased().contains(q) ||
                item.relativePath.lowercased().contains(q) ||
                (item.mediaMetadata?.videoCodec.lowercased().contains(q) ?? false) ||
                (item.mediaMetadata?.resolutionString.lowercased().contains(q) ?? false) ||
                item.fileCategory.rawValue.lowercased().contains(q)
            }
        }
        
        return sortItems(result)
    }
    
    public func toggleSort(_ column: IngestSortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = (column != .size && column != .duration)
        }
    }
    
    private func sortItems(_ list: [IngestItem]) -> [IngestItem] {
        list.sorted { a, b in
            let order: ComparisonResult
            switch sortColumn {
            case .name:
                order = a.fileName.localizedStandardCompare(b.fileName)
            case .category:
                order = a.fileCategory.rawValue.localizedStandardCompare(b.fileCategory.rawValue)
            case .size:
                if a.fileSizeBytes == b.fileSizeBytes {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = a.fileSizeBytes < b.fileSizeBytes ? .orderedAscending : .orderedDescending
                }
            case .resolution:
                let aRes = a.mediaMetadata != nil ? (a.mediaMetadata!.width * a.mediaMetadata!.height) : 0
                let bRes = b.mediaMetadata != nil ? (b.mediaMetadata!.width * b.mediaMetadata!.height) : 0
                if aRes == bRes {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = aRes < bRes ? .orderedAscending : .orderedDescending
                }
            case .fps:
                let aFPS = a.mediaMetadata?.fps ?? 0
                let bFPS = b.mediaMetadata?.fps ?? 0
                if aFPS == bFPS {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = aFPS < bFPS ? .orderedAscending : .orderedDescending
                }
            case .duration:
                let aDur = a.mediaMetadata?.durationSeconds ?? 0
                let bDur = b.mediaMetadata?.durationSeconds ?? 0
                if aDur == bDur {
                    order = a.fileName.localizedStandardCompare(b.fileName)
                } else {
                    order = aDur < bDur ? .orderedAscending : .orderedDescending
                }
            case .codec:
                let aCodec = a.mediaMetadata?.videoCodec ?? ""
                let bCodec = b.mediaMetadata?.videoCodec ?? ""
                order = aCodec.localizedStandardCompare(bCodec)
            case .path:
                order = a.relativePath.localizedStandardCompare(b.relativePath)
            }
            return sortAscending ? (order == .orderedAscending) : (order == .orderedDescending)
        }
    }
    
    // MARK: - Intake Scanning Engine
    
    public func scanIntake(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isScanning = true
        scanProgress = 0.0
        scanStatusMessage = "Enumerating files..."
        
        Task { [weak self] in
            guard let self else { return }
            
            // Determine root intake directory
            let rootURL: URL
            var isDir: ObjCBool = false
            if urls.count == 1 && FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir) && isDir.boolValue {
                rootURL = urls[0]
            } else {
                rootURL = urls[0].deletingLastPathComponent()
            }
            
            self.intakeFolderURL = rootURL
            
            // Enumerate files recursively
            var allFileURLs: [URL] = []
            let fileManager = FileManager.default
            
            for url in urls {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        let enumerator = fileManager.enumerator(
                            at: url,
                            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .creationDateKey, .contentModificationDateKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        )
                        while let file = enumerator?.nextObject() as? URL {
                            var dirVal: AnyObject?
                            try? (file as NSURL).getResourceValue(&dirVal, forKey: .isDirectoryKey)
                            if (dirVal as? Bool) != true {
                                allFileURLs.append(file)
                            }
                        }
                    } else {
                        allFileURLs.append(url)
                    }
                }
            }
            
            // Deduplicate
            var seen = Set<String>()
            var uniqueFiles: [URL] = []
            for f in allFileURLs {
                let p = f.standardizedFileURL.path
                if !seen.contains(p) {
                    seen.insert(p)
                    uniqueFiles.append(f)
                }
            }
            
            self.scanStatusMessage = "Found \(uniqueFiles.count) files. Classifying & inspecting metadata..."
            
            // Classify and inspect files
            let items = await Self.classifyAndInspectFiles(
                files: uniqueFiles,
                rootURL: rootURL,
                onProgress: { [weak self] current, total in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.scanProgress = total > 0 ? Double(current) / Double(total) : 0.0
                        self.scanStatusMessage = "Inspecting media (\(current)/\(total))..."
                    }
                }
            )
            
            // Update Manifest
            self.manifest.items = items
            
            // Auto-check elements received
            self.manifest.hasRawFootage = items.contains { $0.fileCategory == .rawFootage }
            self.manifest.hasTranscodes = items.contains { $0.fileCategory == .transcode }
            self.manifest.hasCameraReports = items.contains { $0.fileCategory == .cameraReport }
            self.manifest.hasLocationAudio = items.contains { $0.fileCategory == .locationAudio }
            self.manifest.hasShootingLUTs = items.contains { $0.fileCategory == .lut }
            
            // Aggregate technical details
            self.aggregateFootageDetails(items: items)
            
            // Run DIT cross-reference if DIT records exist
            if !self.ditRecords.isEmpty {
                self.flags = IngestDITParser.crossReference(items: items, ditRecords: self.ditRecords)
            }
            
            self.isScanning = false
            self.scanStatusMessage = ""
        }
    }
    
    // MARK: - File Classification & Parallel Inspection
    
    private static func classifyAndInspectFiles(
        files: [URL],
        rootURL: URL,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> [IngestItem] {
        let rootPath = rootURL.standardizedFileURL.path
        let videoExts: Set<String> = [
            "mov", "mp4", "m4v", "mkv", "avi", "prores", "mxf", "r3d", "ari", "arx", "braw", "dpx", "crm"
        ]
        let audioExts: Set<String> = [
            "wav", "aif", "aiff", "mp3", "m4a", "flac", "bwf"
        ]
        let lutExts: Set<String> = [
            "cube", "3dl", "look", "lut"
        ]
        let reportExts: Set<String> = [
            "pdf", "csv", "tsv", "txt", "html", "ale", "xml"
        ]
        
        return await withTaskGroup(of: IngestItem.self) { group in
            var items: [IngestItem] = []
            items.reserveCapacity(files.count)
            
            let total = files.count
            var inspectedCount = 0
            
            for file in files {
                group.addTask {
                    let ext = file.pathExtension.lowercased()
                    let fullPath = file.standardizedFileURL.path
                    let pathComponents = file.pathComponents.map { $0.uppercased() }
                    let fileName = file.lastPathComponent
                    let upperFileName = fileName.uppercased()
                    
                    // Relative Path
                    let relativePath: String
                    if fullPath.hasPrefix(rootPath) {
                        let sub = String(fullPath.dropFirst(rootPath.count))
                        relativePath = sub.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    } else {
                        relativePath = fileName
                    }
                    
                    // File Size
                    let resValues = try? file.resourceValues(forKeys: [.fileSizeKey])
                    let sizeBytes = Int64(resValues?.fileSize ?? 0)
                    let formattedSize = DeliverablesInspector.formatFileSize(bytes: sizeBytes)
                    
                    // Classification: Check directory and name for TRANSCODES or PROXY
                    let isTranscodeDir = pathComponents.contains("TRANSCODES") ||
                                         pathComponents.contains("TRANSCODE") ||
                                         pathComponents.contains("PROXY") ||
                                         pathComponents.contains("PROXIES")
                    let isTranscodeName = upperFileName.contains("_PROXY") ||
                                          upperFileName.contains("_TRANSCODE") ||
                                          upperFileName.contains("_TC")
                    
                    let category: IngestFileCategory
                    if videoExts.contains(ext) {
                        category = (isTranscodeDir || isTranscodeName) ? .transcode : .rawFootage
                    } else if audioExts.contains(ext) {
                        category = .locationAudio
                    } else if lutExts.contains(ext) {
                        category = .lut
                    } else if reportExts.contains(ext) {
                        let isReportContext = pathComponents.contains("REPORT") ||
                                              pathComponents.contains("REPORTS") ||
                                              pathComponents.contains("DIT") ||
                                              pathComponents.contains("ALE") ||
                                              upperFileName.contains("REPORT") ||
                                              upperFileName.contains("ALE") ||
                                              upperFileName.contains("DIT") ||
                                              ext == "pdf" || ext == "ale"
                        category = isReportContext ? .cameraReport : .other
                    } else {
                        category = .other
                    }
                    
                    // Inspect video metadata if video
                    var mediaMeta: IngestMediaMetadata? = nil
                    if videoExts.contains(ext) {
                        let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                        if let deliverable = await DeliverablesInspector.inspectFile(url: file) {
                            let camera = await DeliverablesInspector.extractCameraMakeModel(asset: asset)
                            mediaMeta = IngestMediaMetadata(
                                width: deliverable.width,
                                height: deliverable.height,
                                resolutionString: deliverable.resolutionString,
                                aspectRatioString: deliverable.aspectRatioString,
                                fps: deliverable.fps,
                                durationSeconds: deliverable.durationSeconds,
                                formattedDuration: deliverable.formattedDuration,
                                totalFrames: deliverable.totalFrames,
                                timecode: deliverable.timecode,
                                videoCodec: deliverable.videoCodec,
                                audioCodec: deliverable.audioCodec,
                                audioConfig: deliverable.audioConfig,
                                cameraMakeModel: camera,
                                container: deliverable.container,
                                creationDate: deliverable.creationDate,
                                formattedCreationDate: deliverable.formattedCreationDate
                            )
                        }
                    }
                    
                    return IngestItem(
                        fileURL: file,
                        relativePath: relativePath,
                        fileName: fileName,
                        fileSizeBytes: sizeBytes,
                        formattedFileSize: formattedSize,
                        fileCategory: category,
                        mediaMetadata: mediaMeta
                    )
                }
            }
            
            for await item in group {
                items.append(item)
                inspectedCount += 1
                onProgress(inspectedCount, total)
            }
            
            return items
        }
    }
    
    // MARK: - Technical Details Aggregation
    
    private func aggregateFootageDetails(items: [IngestItem]) {
        let rawItems = items.filter { $0.fileCategory == .rawFootage && $0.mediaMetadata != nil }
        let transcodeItems = items.filter { $0.fileCategory == .transcode && $0.mediaMetadata != nil }
        let allVideoItems = items.compactMap { $0.mediaMetadata }
        
        // 1. Raw Media Codec
        if !rawItems.isEmpty {
            let counts = rawItems.compactMap { $0.mediaMetadata?.videoCodec }.reduce(into: [:]) { counts, codec in
                counts[codec, default: 0] += 1
            }
            if let topCodec = counts.max(by: { $0.value < $1.value })?.key {
                self.manifest.rawMediaCodec = topCodec
            }
        }
        
        // 2. Transcode Codec
        if !transcodeItems.isEmpty {
            let counts = transcodeItems.compactMap { $0.mediaMetadata?.videoCodec }.reduce(into: [:]) { counts, codec in
                counts[codec, default: 0] += 1
            }
            if let topCodec = counts.max(by: { $0.value < $1.value })?.key {
                self.manifest.transcodeCodec = topCodec
            }
        }
        
        // 3. Shooting Resolution
        if !rawItems.isEmpty {
            let counts = rawItems.compactMap { $0.mediaMetadata?.resolutionString }.reduce(into: [:]) { counts, res in
                counts[res, default: 0] += 1
            }
            if let topRes = counts.max(by: { $0.value < $1.value })?.key {
                self.manifest.shootingResolution = topRes
            }
        } else if !allVideoItems.isEmpty {
            let counts = allVideoItems.map { $0.resolutionString }.reduce(into: [:]) { counts, res in
                counts[res, default: 0] += 1
            }
            if let topRes = counts.max(by: { $0.value < $1.value })?.key {
                self.manifest.shootingResolution = topRes
            }
        }
        
        // 4. Main FPS / Project Timebase
        if !allVideoItems.isEmpty {
            let counts = allVideoItems.map { String(format: "%.2f", $0.fps) }.reduce(into: [:]) { counts, fps in
                counts[fps, default: 0] += 1
            }
            if let topFPS = counts.max(by: { $0.value < $1.value })?.key {
                self.manifest.mainFPS = "\(topFPS) fps"
            }
        }
        
        // 5. Camera Used (if discovered in metadata)
        let cameras = allVideoItems.compactMap { $0.cameraMakeModel }.filter { !$0.isEmpty }
        if !cameras.isEmpty {
            let counts = cameras.reduce(into: [:]) { counts, cam in
                counts[cam, default: 0] += 1
            }
            if let topCam = counts.max(by: { $0.value < $1.value })?.key {
                self.manifest.cameraUsed = topCam
            }
        }
    }
    
    // MARK: - DIT Report Import & Audit
    
    public func promptImportDITReport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType.commaSeparatedText,
            UTType.tabSeparatedText,
            UTType.plainText,
            UTType(filenameExtension: "csv") ?? .plainText,
            UTType(filenameExtension: "tsv") ?? .plainText,
            UTType(filenameExtension: "ale") ?? .plainText
        ]
        panel.prompt = "Import DIT Report"
        panel.message = "Select a CSV, TSV, or ALE report provided by the DIT"
        
        if panel.runModal() == .OK, let url = panel.url {
            importDITReport(url: url)
        }
    }
    
    public func importDITReport(url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let records = IngestDITParser.parse(content: content)
            self.ditRecords = records
            self.ditReportURL = url
            
            // Re-run cross-referencing immediately
            self.flags = IngestDITParser.crossReference(items: manifest.items, ditRecords: records)
            self.isFlagsExpanded = !self.flags.isEmpty
        } catch {
            print("Failed to read DIT report: \(error)")
        }
    }
    
    public func clearDITReport() {
        ditRecords = []
        ditReportURL = nil
        flags = []
    }
    
    // MARK: - Exporting Reports
    
    public func exportManifestCSV() {
        let csv = IngestDITParser.generateManifestCSV(manifest: manifest, flags: flags)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        let job = manifest.jobName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        savePanel.nameFieldStringValue = "Ingest_Report_\(job.isEmpty ? "Footage" : job)_\(Int(Date().timeIntervalSince1970)).csv"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    public func openManifestHTML() {
        let html = IngestDITParser.generateManifestHTML(manifest: manifest, flags: flags)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Ingest_Report_\(UUID().uuidString).html")
        
        do {
            try html.write(to: tempURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(tempURL)
        } catch {
            print("Failed to open Ingest HTML: \(error)")
        }
    }
    
    public func copyManifestSummaryToClipboard() {
        var text = "=== INGEST INTAKE SUMMARY ===\n"
        text += "Job: \(manifest.jobName.isEmpty ? "--" : manifest.jobName)\n"
        text += "Ingested By: \(manifest.ingestedBy.isEmpty ? "--" : manifest.ingestedBy)\n"
        text += "Received Via: \(manifest.receivedVia)\n"
        text += "Added to Client Drives: \(manifest.addedToClientDrives ? "YES" : "NO")\n"
        text += "Camera: \(manifest.cameraUsed.isEmpty ? "--" : manifest.cameraUsed)\n"
        text += "Raw Codec: \(manifest.rawMediaCodec.isEmpty ? "--" : manifest.rawMediaCodec)\n"
        text += "Transcode Codec: \(manifest.transcodeCodec.isEmpty ? "--" : manifest.transcodeCodec)\n"
        text += "Resolution: \(manifest.shootingResolution.isEmpty ? "--" : manifest.shootingResolution)\n"
        text += "FPS: \(manifest.mainFPS.isEmpty ? "--" : manifest.mainFPS)\n"
        text += "Total Files: \(manifest.items.count)\n"
        if !flags.isEmpty {
            text += "\n=== DISCREPANCIES (\(flags.count)) ===\n"
            for f in flags {
                text += "[\(f.severity.rawValue)] \(f.fileName): \(f.title) - \(f.detail)\n"
            }
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
