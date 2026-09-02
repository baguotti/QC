import SwiftUI
import Foundation
import UniformTypeIdentifiers
import VideoQCLib

struct ContentView: View {
    @AppStorage("isLightMode") var isLightMode: Bool = false
    @State var selectedTab: AppTab = .lineScanner
    @State var showUserGuide: Bool = false
    @State var hoverExplanation: String = ""
    
    // Shared Folder & Video Files
    @State var folderURL: URL? = nil
    @State var videoFiles: [URL] = []
    
    // MARK: - Tab 1: Line Scanner State
    @State var hexCode: String = "#FF00B4"
    @State var tolerancePercentage: Double = 15.0
    @State var edgeDepth: Int = 12
    @State var minSpanPercentage: Double = 70.0
    @State var checkTop: Bool = true
    @State var checkBottom: Bool = true
    @State var checkLeft: Bool = true
    @State var checkRight: Bool = true
    @State var enableExposureBoost: Bool = true
    @State var exposureMultiplier: Double = 10.0
    @State var ignoreFullBlackFrames: Bool = true
    
    @State var isScanning: Bool = false
    @State var progressInfo: VideoScanner.ScanProgress? = nil
    @State var scanResults: [VideoQCResult] = []
    @State var generatedReportURL: URL? = nil
    @State var generatedCSVURL: URL? = nil
    @State var scannerActor: VideoScanner? = nil
    
    // MARK: - Tab 2: Deliverables Specs State
    @State var deliverableAssets: [DeliverableAsset] = []
    @State var isInspectingDeliverables: Bool = false
    @State var manifestCSVURL: URL? = nil
    @State var manifestHTMLURL: URL? = nil
    
    // MARK: - Tab 3: Batch Renamer State
    @State var renameMode: RenameMode = .template
    @State var customNameText: String = ""
    @State var templateText: String = "{NAME}_{DUR}sec_{RATIO}_{TAG}"
    @State var findText: String = ""
    @State var replaceText: String = ""
    @State var prefixText: String = ""
    @State var suffixText: String = ""
    @State var customTag: String = "CLEAN"
    @State var textCase: TextCaseOption = .uppercase
    @State var indexStart: Int = 1
    @State var indexPadding: Int = 2
    @State var lastTransaction: RenameTransaction? = nil
    @State var selectedAssetIDs: Set<UUID> = []
    
    var renameItems: [RenameItem] {
        RenamerEngine.generateProposedItems(
            assets: deliverableAssets,
            mode: renameMode,
            customName: customNameText,
            templateString: templateText,
            findString: findText,
            replaceString: replaceText,
            prefixString: prefixText,
            suffixString: suffixText,
            customTag: customTag,
            caseOption: textCase,
            indexStart: indexStart,
            indexPadding: indexPadding,
            selectedAssetIDs: selectedAssetIDs
        )
    }
    
    var isTargetBlack: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r <= 15 && rgb.g <= 15 && rgb.b <= 15
    }
    
    let colorPresets = [
        ("MAGENTA", "#FF00B4", 15.0),
        ("CYAN", "#00FFFF", 15.0),
        ("GREEN", "#00FF00", 15.0),
        ("RED", "#FF0000", 15.0),
        ("WHITE", "#FFFFFF", 15.0),
        ("BLACK (10X)", "#000000", 3.0)
    ]
    
    // Dynamic Studio Theme Palette
    var bgMain: Color { StudioTheme.bgMain(isLightMode) }
    var bgPanel: Color { StudioTheme.bgPanel(isLightMode) }
    var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    var bgCardHeader: Color { StudioTheme.bgCardHeader(isLightMode) }
    var bgCardSubtle: Color { StudioTheme.bgCardSubtle(isLightMode) }
    var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    var borderStrong: Color { StudioTheme.borderStrong(isLightMode) }
    var textMain: Color { StudioTheme.textMain(isLightMode) }
    var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    var textSubtle: Color { StudioTheme.textSubtle(isLightMode) }
    var alertRed: Color { StudioTheme.alertRed(isLightMode) }
    var primaryBtnBg: Color { StudioTheme.primaryBtnBg(isLightMode) }
    var primaryBtnFg: Color { StudioTheme.primaryBtnFg(isLightMode) }
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 1. Top Masthead
                headerView
                
                Rectangle()
                    .fill(borderLine)
                    .frame(height: 1)
                
                // 2. Dedicated Prominent Tab Navigation Bar
                tabBarStrip
                
                Rectangle()
                    .fill(borderLine)
                    .frame(height: 1)
                
                // 3. Main Tab Content
                if selectedTab == .lineScanner {
                    lineScannerTabView
                } else if selectedTab == .deliverables {
                    deliverablesTabView
                } else {
                    batchRenamerTabView
                }
                
                // 4. Bottom Contextual Explanation Bar
                Rectangle()
                    .fill(borderLine)
                    .frame(height: 1)
                
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 9))
                            .foregroundColor(hoverExplanation.isEmpty ? textMuted : alertRed)
                        Text("INFO //")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundColor(hoverExplanation.isEmpty ? textMuted : alertRed)
                    }
                    
                    Text(hoverExplanation.isEmpty ? "Hover over any button, field, or control for function details." : hoverExplanation)
                        .font(.system(size: 10, weight: hoverExplanation.isEmpty ? .regular : .semibold, design: .monospaced))
                        .foregroundColor(hoverExplanation.isEmpty ? textMuted : textMain)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text("v\(AppVersionInfo.version)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(bgPanel)
            }
            .frame(minWidth: 1000, minHeight: 720)
            .background(bgMain)
            .foregroundColor(textMain)
            
            // In-App Operation Guide Overlay Modal
            if showUserGuide {
                UserGuideView(isPresented: $showUserGuide)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showUserGuide)
    }
    
    // MARK: - Header & Navigation
    
    private var headerView: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(alertRed)
                    .frame(width: 4, height: 26)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("THE LINEFINDER 5000")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .tracking(1.5)
                        .foregroundColor(textMain)
                    
                    Text("STUDIO QC • FRAME AUDIT • ASSET SPECS • BATCH RENAMER")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                        .tracking(0.5)
                }
            }
            
            Spacer()
            
            HStack(spacing: 10) {
                // Version & GitHub Commit Link Badge
                Link(destination: AppVersionInfo.commitURL) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text("v\(AppVersionInfo.version)")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                        Text("//")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                        Text(AppVersionInfo.gitCommit)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(textSubtle)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 8))
                            .foregroundColor(textMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(bgSubtle)
                    .foregroundColor(textMain)
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .explain("Opens commit \(AppVersionInfo.gitCommit) on GitHub repository.", binding: $hoverExplanation)
                
                // Info / User Guide Modal Button
                Button(action: { showUserGuide.toggle() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 10))
                        Text("[ ℹ INFO / GUIDE ]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(bgSubtle)
                    .foregroundColor(textMain)
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .explain("Opens the user guide with descriptions of each tab.", binding: $hoverExplanation)
                
                // Theme Toggle
                Button(action: { isLightMode.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: isLightMode ? "sun.max.fill" : "moon.stars.fill")
                            .font(.system(size: 10))
                        Text(isLightMode ? "THEME: LIGHT" : "THEME: DARK")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(bgSubtle)
                    .foregroundColor(textMain)
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .explain("Switches between light and dark studio interface themes.", binding: $hoverExplanation)
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(isScanning || isInspectingDeliverables ? Color.orange : (scanResults.isEmpty && deliverableAssets.isEmpty ? textMuted : textMain))
                        .frame(width: 7, height: 7)
                    Text(isScanning || isInspectingDeliverables ? "BUSY" : "READY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(textSubtle)
                        .tracking(1.0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(bgSubtle)
                .border(borderLine, width: 1)
                .explain(isScanning || isInspectingDeliverables ? "Engine is currently processing video files." : "Engine is idle and ready for new jobs.", binding: $hoverExplanation)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(bgPanel)
    }
    
    private var tabBarStrip: some View {
        HStack(spacing: 12) {
            ForEach(AppTab.allCases) { tab in
                Button(action: {
                    selectedTab = tab
                    if (tab == .deliverables || tab == .batchRenamer) && deliverableAssets.isEmpty && !videoFiles.isEmpty {
                        inspectDeliverablesBatch(urls: videoFiles)
                    }
                }) {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(selectedTab == tab ? alertRed : textMuted)
                            .frame(width: 4, height: 16)
                        
                        Text(tab.title)
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1.0)
                        
                        if (tab == .deliverables || tab == .batchRenamer) && !deliverableAssets.isEmpty {
                            Text("[\(deliverableAssets.count)]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(selectedTab == tab ? primaryBtnFg : textSubtle)
                        } else if tab == .lineScanner && !scanResults.isEmpty {
                            let flaggedCount = scanResults.filter { $0.isFlagged }.count
                            Text(flaggedCount > 0 ? "[\(flaggedCount) FLAGGED]" : "[PASSED]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(flaggedCount > 0 ? alertRed : textSubtle)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(selectedTab == tab ? primaryBtnBg : bgSubtle)
                    .foregroundColor(selectedTab == tab ? primaryBtnFg : textSubtle)
                    .border(selectedTab == tab ? primaryBtnBg : borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .explain(
                    tab == .lineScanner ? "01 // LINE SCANNER: Scans video frames for edge line glitches and blanking errors." :
                    (tab == .deliverables ? "02 // DELIVERABLES SPECS: Reads container resolution, timecode, audio, and codecs." :
                     "03 // BATCH RENAMER: Renames files using inspected video metadata and custom templates."),
                    binding: $hoverExplanation
                )
            }
            
            Spacer()
            
            switch selectedTab {
            case .lineScanner:
                Text("MODE // FRAME-BY-FRAME EDGE ARTIFACT SCANNER")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .tracking(0.5)
            case .deliverables:
                Text("MODE // INSTANT ASSET SPECS & METADATA AUDITOR")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .tracking(0.5)
            case .batchRenamer:
                Text("MODE // GRANULAR DELIVERABLE BATCH RENAMING & TOKEN ENGINE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .tracking(0.5)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(bgCardHeader)
    }
    
    // MARK: - Reusable Unified Asset Selection Section
    
    func deliveryAssetsSection(forTab: AppTab) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "01", title: "DELIVERY ASSETS")
            
            VStack(alignment: .leading, spacing: 8) {
                Button(action: { selectAssets(forTab: forTab) }) {
                    HStack {
                        Text(folderURL == nil && videoFiles.isEmpty ? "SELECT FILES OR FOLDER..." : "CHANGE ASSETS...")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(textMain)
                            .tracking(0.5)
                        Spacer()
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(textSubtle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(bgSubtle)
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(isScanning)
                .explain("Opens file picker to select video files or a folder to inspect.", binding: $hoverExplanation)
                
                if let folder = folderURL {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.lastPathComponent.uppercased())
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                        Text("\(videoFiles.count) ASSET(S) FOUND IN DIRECTORY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgCardSubtle)
                    .border(borderLine, width: 1)
                    .explain("Active directory loaded: \(folder.path)", binding: $hoverExplanation)
                } else if !videoFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(videoFiles.count) INDIVIDUAL FILE(S)")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(textMain)
                        Text("BATCH LOADED DIRECTLY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgCardSubtle)
                    .border(borderLine, width: 1)
                    .explain("\(videoFiles.count) video files loaded into the working batch.", binding: $hoverExplanation)
                } else {
                    Text("DRAG & DROP FOLDER OR VIDEO FILES HERE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                        .background(bgCardSubtle)
                        .border(borderLine, width: 1)
                        .explain("Drag and drop video files or folders directly into the app.", binding: $hoverExplanation)
                }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers, forTab: forTab)
        }
    }
    
    // MARK: - Asset Selection & Drop Handlers
    
    func selectAssets(forTab: AppTab) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType.quickTimeMovie, UTType.mpeg4Movie, UTType.folder]
        panel.prompt = "Select"
        
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            var collectedVideos: [URL] = []
            var detectedFolder: URL? = nil
            
            for url in panel.urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        detectedFolder = url
                        let inFolder = VideoScanner.findVideoFiles(in: url)
                        collectedVideos.append(contentsOf: inFolder)
                    } else {
                        if detectedFolder == nil {
                            detectedFolder = url.deletingLastPathComponent()
                        }
                        let ext = url.pathExtension.lowercased()
                        if ["mp4", "mov", "m4v", "mkv", "avi", "prores"].contains(ext) {
                            collectedVideos.append(url)
                        }
                    }
                }
            }
            
            var uniqueVideos: [URL] = []
            var seen: Set<String> = []
            for v in collectedVideos {
                if !seen.contains(v.path) {
                    seen.insert(v.path)
                    uniqueVideos.append(v)
                }
            }
            
            guard !uniqueVideos.isEmpty else { return }
            
            self.folderURL = detectedFolder
            self.videoFiles = uniqueVideos
            self.scanResults = []
            self.generatedReportURL = nil
            self.generatedCSVURL = nil
            
            // Populate deliverables in background
            inspectDeliverablesBatch(urls: uniqueVideos)
        }
    }
    
    func handleDrop(providers: [NSItemProvider], forTab: AppTab) -> Bool {
        guard !providers.isEmpty else { return false }
        
        final class URLCollector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var urls: [URL] = []
            
            func append(_ url: URL) {
                lock.lock()
                defer { lock.unlock() }
                urls.append(url)
            }
        }
        
        let collector = URLCollector()
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    collector.append(url)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            let loadedURLs = collector.urls
            var collectedVideos: [URL] = []
            var detectedFolder: URL? = nil
            
            for url in loadedURLs {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                    if isDir.boolValue {
                        detectedFolder = url
                        let inFolder = VideoScanner.findVideoFiles(in: url)
                        collectedVideos.append(contentsOf: inFolder)
                    } else {
                        if detectedFolder == nil {
                            detectedFolder = url.deletingLastPathComponent()
                        }
                        let ext = url.pathExtension.lowercased()
                        if ["mp4", "mov", "m4v", "mkv", "avi", "prores"].contains(ext) {
                            collectedVideos.append(url)
                        }
                    }
                }
            }
            
            var uniqueVideos: [URL] = []
            var seen: Set<String> = []
            for v in collectedVideos {
                if !seen.contains(v.path) {
                    seen.insert(v.path)
                    uniqueVideos.append(v)
                }
            }
            
            guard !uniqueVideos.isEmpty else { return }
            
            self.folderURL = detectedFolder
            self.videoFiles = uniqueVideos
            self.scanResults = []
            self.generatedReportURL = nil
            self.generatedCSVURL = nil
            self.inspectDeliverablesBatch(urls: uniqueVideos)
        }
        return true
    }
    
    // MARK: - Line Scanner Execution
    
    func startScan() {
        guard !videoFiles.isEmpty else { return }
        let folder = folderURL ?? videoFiles.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())
        
        let config = QCConfig(
            targetHex: hexCode,
            tolerance: tolerancePercentage / 100.0,
            edgeDepth: edgeDepth,
            minSpanRatio: minSpanPercentage / 100.0,
            checkTop: checkTop,
            checkBottom: checkBottom,
            checkLeft: checkLeft,
            checkRight: checkRight,
            enableExposureBoost: enableExposureBoost,
            exposureMultiplier: exposureMultiplier,
            ignoreFullBlackFrames: ignoreFullBlackFrames
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
            
            let reports = ReportWriter.saveReport(folderURL: folder, config: config, results: results)
            
            DispatchQueue.main.async {
                self.scanResults = results
                self.generatedReportURL = reports.htmlURL
                self.generatedCSVURL = reports.csvURL
                self.isScanning = false
                self.scannerActor = nil
            }
        }
    }
    
    func cancelScan() {
        scannerActor?.cancel()
        self.isScanning = false
        self.scannerActor = nil
    }
    
    // MARK: - Deliverables Specs Execution
    
    func rescanDeliverables() {
        if let folder = folderURL {
            let updatedFiles = VideoScanner.findVideoFiles(in: folder)
            self.videoFiles = updatedFiles
            inspectDeliverablesBatch(urls: updatedFiles)
        } else if !videoFiles.isEmpty {
            inspectDeliverablesBatch(urls: videoFiles)
        }
    }
    
    func inspectDeliverablesBatch(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isInspectingDeliverables = true
        
        Task {
            let assets = await DeliverablesInspector.inspectBatch(urls: urls)
            DispatchQueue.main.async {
                self.deliverableAssets = assets
                self.selectedAssetIDs = Set(assets.map { $0.id })
                self.isInspectingDeliverables = false
            }
        }
    }
    
    func exportDeliverablesManifest() {
        guard !deliverableAssets.isEmpty else { return }
        
        let csvString = DeliverablesInspector.generateManifestCSV(assets: deliverableAssets)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        savePanel.nameFieldStringValue = "Deliverables_Specs_\(Date().timeIntervalSince1970).csv"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csvString.write(to: url, atomically: true, encoding: .utf8)
            self.manifestCSVURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    func openManifestHTML() {
        guard !deliverableAssets.isEmpty else { return }
        
        let folderName = (folderURL ?? deliverableAssets.first?.fileURL.deletingLastPathComponent())?.lastPathComponent ?? "DELIVERY_ASSETS"
        let htmlString = DeliverablesInspector.generateManifestHTML(assets: deliverableAssets, folderName: folderName)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Deliverables_Specs_\(UUID().uuidString).html")
        
        do {
            try htmlString.write(to: tempURL, atomically: true, encoding: .utf8)
            self.manifestHTMLURL = tempURL
            NSWorkspace.shared.open(tempURL)
        } catch {
            print("Failed to open Deliverables HTML: \(error)")
        }
    }
    
    // MARK: - Reusable UI Subviews & Helpers
    
    func sectionHeader(num: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(num)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(alertRed)
            Text("// \(title)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
                .tracking(1.0)
        }
    }
    
    func statBox(title: String, val: String, isRed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
            Text(val)
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundColor(isRed ? alertRed : textMain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(bgPanel)
        .border(borderLine, width: 1)
    }
    
    func statItem(label: String, val: String, isAlert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
            Text(val)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(isAlert ? alertRed : textMain)
        }
    }
    
    func formatTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bgSubtle)
            .foregroundColor(textSubtle)
            .border(borderLine, width: 1)
    }
}
