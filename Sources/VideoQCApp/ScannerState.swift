import SwiftUI
import AppKit
import VideoQCLib

@MainActor
public final class ScannerState: ObservableObject {
    @Published public var hexCode: String = "#00FF00"
    @Published public var tolerancePercentage: Double = 25.0
    @Published public var edgeDepth: Int = 12
    @Published public var minSpanPercentage: Double = 70.0
    @Published public var scanFullScreen: Bool = false
    @Published public var enableExposureBoost: Bool = true
    @Published public var exposureMultiplier: Double = 10.0
    @Published public var ignoreFullBlackFrames: Bool = true
    @Published public var maxBlackVariance: Double = 2.0
    @Published public var enableHighlightExpansion: Bool = true
    @Published public var highlightMultiplier: Double = 8.0
    @Published public var ignoreFullWhiteFrames: Bool = true
    @Published public var maxWhiteVariance: Double = 2.0
    
    @Published public var isScanning: Bool = false
    @Published public var isAuditBtnHovered: Bool = false
    @Published public var progressInfo: VideoScanner.ScanProgress? = nil
    @Published public var scanResults: [VideoQCResult] = []
    @Published public var lastScanConfig: QCConfig? = nil
    @Published public var generatedReportURL: URL? = nil
    @Published public var generatedCSVURL: URL? = nil
    @Published public var scannerActor: VideoScanner? = nil
    
    public init() {}
    
    public var isTargetBlack: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r <= 15 && rgb.g <= 15 && rgb.b <= 15
    }
    
    public var isTargetWhite: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r >= 240 && rgb.g >= 240 && rgb.b >= 240
    }
    
    public let colorPresets = [
        ("GREEN", "#00FF00", 25.0),
        ("MAGENTA", "#FF00B4", 25.0),
        ("BLACK", "#000000", 3.0),
        ("WHITE", "#FFFFFF", 3.0)
    ]
    
    public var isCustomColor: Bool {
        !colorPresets.contains { $0.1.uppercased() == hexCode.uppercased() }
    }
    
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
        guard !videoFiles.isEmpty else { return }
        
        let config = QCConfig(
            targetHex: hexCode,
            tolerance: tolerancePercentage / 100.0,
            edgeDepth: edgeDepth,
            minSpanRatio: minSpanPercentage / 100.0,
            scanFullScreen: scanFullScreen,
            enableExposureBoost: enableExposureBoost,
            exposureMultiplier: exposureMultiplier,
            ignoreFullBlackFrames: ignoreFullBlackFrames,
            maxBlackVariance: maxBlackVariance,
            enableHighlightExpansion: enableHighlightExpansion,
            highlightMultiplier: highlightMultiplier,
            ignoreFullWhiteFrames: ignoreFullWhiteFrames,
            maxWhiteVariance: maxWhiteVariance
        )
        
        isScanning = true
        scanResults = []
        generatedReportURL = nil
        generatedCSVURL = nil
        
        let scanner = VideoScanner()
        self.scannerActor = scanner
        
        Task {
            let results = await scanner.scanBatch(videoURLs: videoFiles, config: config, maxConcurrentScanners: 2) { progress in
                DispatchQueue.main.async {
                    self.progressInfo = progress
                }
            }
            
            ReportWriter.tagFlaggedFilesInFinder(results: results)
            
            DispatchQueue.main.async {
                self.scanResults = results
                self.lastScanConfig = config
                self.isScanning = false
                self.scannerActor = nil
                onComplete(results, config)
            }
        }
    }
    
    public func cancelScan() {
        scannerActor?.cancel()
        self.isScanning = false
        self.scannerActor = nil
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
