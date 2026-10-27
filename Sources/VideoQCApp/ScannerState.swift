import SwiftUI
import AppKit
import os
import VideoQCLib

@MainActor
public final class ScannerState: ObservableObject {
    @Published public var hexCode: String = UserPreferences.lineTargetHex
    @Published public var sensitivityPercentage: Double = UserPreferences.lineSensitivity
    @Published public var anyColor: Bool = UserPreferences.lineAnyColor
    @Published public var reportOffColorLines: Bool = UserPreferences.lineOffColor
    @Published public var edgeDepth: Int = UserPreferences.lineEdgeDepth
    @Published public var minSpanPercentage: Double = 25.0
    @Published public var scanFullScreen: Bool = UserPreferences.lineSplitSeams
    @Published public var enableExposureBoost: Bool = true
    @Published public var ignoreFullBlackFrames: Bool = true
    @Published public var enableHighlightExpansion: Bool = true
    @Published public var ignoreFullWhiteFrames: Bool = true
    
    @Published public var tagInFinder: Bool {
        didSet { UserDefaults.standard.set(tagInFinder, forKey: "tagInFinder") }
    }
    @Published public var lastScanTagInFinder: Bool = false
    @Published public var wasScanCancelled: Bool = false
    @Published public var isCancelling: Bool = false
    
    @Published public var isScanning: Bool = false
    @Published public var progressInfo: VideoScanner.ScanProgress? = nil
    @Published public var scanResults: [VideoQCResult] = []
    @Published public var lastScanConfig: QCConfig? = nil
    @Published public var generatedReportURL: URL? = nil
    @Published public var generatedCSVURL: URL? = nil
    @Published public var scannerActor: VideoScanner? = nil
    
    // Frame Check
    @Published public var isFrameChecking: Bool = false
    @Published public var frameCheckProgress: FrameCheckScanner.ScanProgress? = nil
    @Published public var frameCheckResults: [FrameCheckResult] = []
    @Published public var wasFrameCheckCancelled: Bool = false
    /// A Full Check is running: the Line Check, then the Frame Check on the same files.
    @Published public var isFullCheck: Bool = false
    private var frameCheckScanner: FrameCheckScanner? = nil
    
    /// A Line Check or Frame Check is running: the asset list must not change under it.
    public var isCheckRunning: Bool { isScanning || isFrameChecking }
    
    public init() {
        self.tagInFinder = UserDefaults.standard.bool(forKey: "tagInFinder")
    }
    
    public var isTargetBlack: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r <= 15 && rgb.g <= 15 && rgb.b <= 15
    }
    
    public var isTargetWhite: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r >= 240 && rgb.g >= 240 && rgb.b >= 240
    }
    
    public let colorPresets = [
        ("GREEN", "#00FF00"),
        ("MAGENTA", "#FF00B4"),
        ("BLACK", "#000000"),
        ("WHITE", "#FFFFFF")
    ]
    
    public func openColorPanel() {
        NSColorPanel.setPickerMask(.wheelModeMask)
        NSColorPanel.setPickerMode(.wheel)
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let rgb = RGBColor(hex: hexCode) {
            panel.color = NSColor(srgbRed: CGFloat(rgb.r) / 255.0, green: CGFloat(rgb.g) / 255.0, blue: CGFloat(rgb.b) / 255.0, alpha: 1.0)
        }
        panel.isContinuous = true
        panel.orderFront(nil)
    }
    
    public func colorFromHex(_ hex: String) -> Color {
        guard let rgb = RGBColor(hex: hex) else { return Color.clear }
        return Color(red: Double(rgb.r) / 255.0, green: Double(rgb.g) / 255.0, blue: Double(rgb.b) / 255.0)
    }
    
    public func startScan(
        videoFiles: [URL],
        onComplete: @escaping @MainActor ([VideoQCResult], QCConfig) -> Void
    ) {
        guard !videoFiles.isEmpty else {
            isFullCheck = false
            return
        }
        
        let config = QCConfig(
            targetHex: hexCode,
            tolerance: (isTargetBlack || isTargetWhite) ? 0.03 : 0.25,
            edgeDepth: edgeDepth,
            minSpanRatio: minSpanPercentage / 100.0,
            scanFullScreen: scanFullScreen,
            sensitivity: sensitivityPercentage / 100.0,
            anyColor: anyColor,
            reportOffColorLines: reportOffColorLines,
            enableExposureBoost: enableExposureBoost,
            ignoreFullBlackFrames: ignoreFullBlackFrames,
            enableHighlightExpansion: enableHighlightExpansion,
            ignoreFullWhiteFrames: ignoreFullWhiteFrames
        )
        
        isScanning = true
        isCancelling = false
        wasScanCancelled = false
        if !isFullCheck {   // a single check replaces the whole report
            frameCheckResults = []
            wasFrameCheckCancelled = false
        }
        scanResults = []
        lastScanTagInFinder = tagInFinder
        generatedReportURL = nil
        generatedCSVURL = nil
        
        let scanner = VideoScanner()
        self.scannerActor = scanner
        
        // Display-only progress: every ScannerState change re-renders ContentView, so cap it at 5 Hz.
        let lastProgressPublish = OSAllocatedUnfairLock(initialState: 0.0)
        
        // Utility priority: batch scans yield to playback decode and UI work.
        Task(priority: .utility) {
            let results = await scanner.scanBatch(
                videoURLs: videoFiles,
                config: config,
                maxConcurrentScanners: 2,
                progressHandler: { progress in
                    let now = CFAbsoluteTimeGetCurrent()
                    let shouldPublish = lastProgressPublish.withLock { last -> Bool in
                        guard now - last >= 0.2 else { return false }
                        last = now
                        return true
                    }
                    guard shouldPublish else { return }
                    DispatchQueue.main.async {
                        self.progressInfo = progress
                    }
                },
                onFileCompleted: { result in
                    DispatchQueue.main.async {
                        if !self.scanResults.contains(where: { $0.fileURL == result.fileURL }) {
                            self.scanResults.append(result)
                        }
                    }
                }
            )
            
            if self.tagInFinder {
                await Task.detached(priority: .utility) {
                    ReportWriter.tagFlaggedFilesInFinder(results: results)
                }.value
            }
            
            DispatchQueue.main.async {
                self.scanResults = results
                self.lastScanConfig = config
                self.isScanning = false
                self.isCancelling = false
                self.scannerActor = nil
                onComplete(results, config)
            }
        }
    }
    
    /// One pass per video: frame-rate mismatch (stutter), flash frames, Media Offline frames and legal range.
    public func startFrameCheck(videoFiles: [URL]) {
        let videos = videoFiles.filter { QCUtilities.mediaKind(of: $0) == .video }
        guard !videos.isEmpty, !isFrameChecking, !isScanning else {
            isFullCheck = false
            return
        }
        isFrameChecking = true
        wasFrameCheckCancelled = false
        frameCheckResults = []
        frameCheckProgress = nil
        if !isFullCheck {
            scanResults = []
            wasScanCancelled = false
        }
        let scanner = FrameCheckScanner()
        frameCheckScanner = scanner
        Task(priority: .utility) {
            let results = await scanner.scanBatch(videos, legalSpec: .current) { progress in
                DispatchQueue.main.async { self.frameCheckProgress = progress }
            }
            await MainActor.run {
                self.frameCheckResults = results
                self.isFrameChecking = false
                self.isFullCheck = false
                self.frameCheckScanner = nil
            }
        }
    }
    
    public func cancelFrameCheck() {
        guard isFrameChecking else { return }
        wasFrameCheckCancelled = true
        frameCheckScanner?.cancel()
    }
    
    public func cancelScan() {
        guard isScanning else { return }
        wasScanCancelled = true
        isCancelling = true
        scannerActor?.cancel()
    }
    
    public func exportScanHTML(folderURL: URL?, videoFiles: [URL]) {
        guard !scanResults.isEmpty, let config = lastScanConfig else { return }
        let folder = folderURL ?? videoFiles.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        
        let csvFileName = "QC_Report.csv"
        let htmlString = ReportWriter.generateHTMLReport(folderURL: folder, config: config, results: scanResults, csvFileName: csvFileName)
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.nameFieldStringValue = "QC_Report_\(folder.lastPathComponent).html"
        savePanel.directoryURL = folder
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? htmlString.write(to: url, atomically: true, encoding: .utf8)
            self.generatedReportURL = url
            NSWorkspace.shared.open(url)
        }
    }
    
    public func exportScanCSV(folderURL: URL?, videoFiles: [URL]) {
        guard !scanResults.isEmpty else { return }
        let folder = folderURL ?? videoFiles.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        
        let csvString = ReportWriter.generateCSVReport(results: scanResults)
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "QC_Report_\(folder.lastPathComponent).csv"
        savePanel.directoryURL = folder
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csvString.write(to: url, atomically: true, encoding: .utf8)
            self.generatedCSVURL = url
            NSWorkspace.shared.open(url)
        }
    }
    
    public func generateTSVReport() -> String? {
        guard !scanResults.isEmpty else { return nil }
        return ReportWriter.generateTSVReport(results: scanResults)
    }
}
