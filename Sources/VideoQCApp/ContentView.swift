import SwiftUI
import UniformTypeIdentifiers
import VideoQCLib

enum AppTab: Int, CaseIterable, Identifiable {
    case lineScanner = 0
    case deliverables = 1
    case batchRenamer = 2
    
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .lineScanner: return "01 // LINE SCANNER"
        case .deliverables: return "02 // DELIVERABLES SPECS"
        case .batchRenamer: return "03 // BATCH RENAMER"
        }
    }
}

struct ContentView: View {
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @State private var selectedTab: AppTab = .lineScanner
    @State private var showUserGuide: Bool = false
    
    // Shared Folder & Video Files
    @State private var folderURL: URL? = nil
    @State private var videoFiles: [URL] = []
    
    // MARK: - Tab 1: Line Scanner State
    @State private var hexCode: String = "#FF00B4"
    @State private var tolerancePercentage: Double = 15.0
    @State private var edgeDepth: Int = 12
    @State private var minSpanPercentage: Double = 70.0
    @State private var checkTop: Bool = true
    @State private var checkBottom: Bool = true
    @State private var checkLeft: Bool = true
    @State private var checkRight: Bool = true
    @State private var enableExposureBoost: Bool = true
    @State private var exposureMultiplier: Double = 10.0
    @State private var ignoreFullBlackFrames: Bool = true
    
    @State private var isScanning: Bool = false
    @State private var progressInfo: VideoScanner.ScanProgress? = nil
    @State private var scanResults: [VideoQCResult] = []
    @State private var generatedReportURL: URL? = nil
    @State private var generatedCSVURL: URL? = nil
    @State private var scannerActor: VideoScanner? = nil
    
    // MARK: - Tab 2: Deliverables Specs State
    @State private var deliverableAssets: [DeliverableAsset] = []
    @State private var isInspectingDeliverables: Bool = false
    @State private var manifestCSVURL: URL? = nil
    @State private var manifestHTMLURL: URL? = nil
    
    // MARK: - Tab 3: Batch Renamer State
    @State private var renameMode: RenameMode = .template
    @State private var customNameText: String = ""
    @State private var templateText: String = "{NAME}_{DUR}sec_{RATIO}_{TAG}"
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var prefixText: String = ""
    @State private var suffixText: String = ""
    @State private var customTag: String = "CLEAN"
    @State private var textCase: TextCaseOption = .uppercase
    @State private var indexStart: Int = 1
    @State private var indexPadding: Int = 2
    @State private var lastTransaction: RenameTransaction? = nil
    @State private var selectedAssetIDs: Set<UUID> = []
    
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
    var bgMain: Color { isLightMode ? Color(white: 0.96) : Color(red: 0.04, green: 0.04, blue: 0.04) }
    var bgPanel: Color { isLightMode ? Color.white : Color(red: 0.07, green: 0.07, blue: 0.07) }
    var bgSubtle: Color { isLightMode ? Color(white: 0.92) : Color(white: 0.12) }
    var bgCardHeader: Color { isLightMode ? Color(white: 0.94) : Color(white: 0.08) }
    var bgCardSubtle: Color { isLightMode ? Color(white: 0.97) : Color(white: 0.05) }
    var borderLine: Color { isLightMode ? Color(white: 0.82) : Color(white: 0.16) }
    var borderStrong: Color { isLightMode ? Color(white: 0.65) : Color(white: 0.35) }
    var textMain: Color { isLightMode ? Color(white: 0.06) : Color.white }
    var textMuted: Color { isLightMode ? Color(white: 0.45) : Color(white: 0.45) }
    var textSubtle: Color { isLightMode ? Color(white: 0.30) : Color(white: 0.65) }
    var alertRed: Color { isLightMode ? Color(red: 0.88, green: 0.12, blue: 0.12) : Color(red: 1.0, green: 0.22, blue: 0.22) }
    var primaryBtnBg: Color { isLightMode ? Color.black : Color.white }
    var primaryBtnFg: Color { isLightMode ? Color.white : Color.black }
    
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
            }
            .frame(minWidth: 1000, minHeight: 720)
            .background(bgMain)
            .foregroundColor(textMain)
            
            if showUserGuide {
                UserGuideView(isPresented: $showUserGuide)
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(alignment: .center) {
            // Brand Title
            VStack(alignment: .leading, spacing: 2) {
                Text("THE LINEFINDER 5000")
                    .font(.system(size: 16, weight: .black, design: .default))
                    .foregroundColor(textMain)
                    .tracking(1.5)
                Text("POST-PRODUCTION QC & DELIVERABLE SPECS AUDITOR")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .tracking(0.5)
            }
            
            Spacer()
            
            // Controls
            HStack(spacing: 10) {
                // Info / Manual Button
                Button(action: { showUserGuide = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(isLightMode ? Color.blue : Color.cyan)
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
                .help("Detailed operational guide and instructions for all tabs")
                
                Button(action: { isLightMode.toggle() }) {
                    Text(isLightMode ? "[THEME: LIGHT]" : "[THEME: DARK]")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(bgSubtle)
                        .foregroundColor(textMain)
                        .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                
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
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(bgPanel)
    }
    
    // MARK: - Dedicated Tab Bar Strip
    
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
    
    // MARK: - Reusable Unified Asset Selection Section (Used by Tabs 1, 2, and 3)
    
    private func deliveryAssetsSection(forTab: AppTab) -> some View {
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
                        Text("[OPEN]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(textSubtle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bgSubtle)
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(isScanning)
                
                if !videoFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if videoFiles.count == 1, let singleFile = videoFiles.first {
                            Text(singleFile.lastPathComponent.uppercased())
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("1 VIDEO FILE LOADED")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(textSubtle)
                        } else if let folder = folderURL {
                            Text(folder.lastPathComponent.uppercased())
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(videoFiles.count) VIDEO FILES DETECTED")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(textSubtle)
                        } else {
                            Text("\(videoFiles.count) VIDEO FILES LOADED")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgCardSubtle)
                    .border(borderLine, width: 1)
                } else {
                    Text("DRAG & DROP FOLDER OR VIDEO FILES HERE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                        .background(bgCardSubtle)
                        .border(borderLine, width: 1)
                }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers, forTab: forTab)
        }
    }
    
    // MARK: ==================== TAB 1: LINE SCANNER ====================
    
    private var lineScannerTabView: some View {
        HSplitView {
            // Left Panel: Configuration
            VStack(alignment: .leading, spacing: 18) {
                deliveryAssetsSection(forTab: .lineScanner)
                colorSettingsSection
                if isTargetBlack {
                    blackLineModeSection
                }
                edgeSettingsSection
                actionSection
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
            .background(bgPanel)
            
            // Right Panel: Results / Live Progress / Empty State
            VStack(alignment: .leading, spacing: 0) {
                if isScanning {
                    activeScanProgressView
                } else if !scanResults.isEmpty {
                    resultsSummaryView
                } else {
                    emptyStateView
                }
            }
            .frame(minWidth: 540)
            .background(bgMain)
        }
    }
    
    private var colorSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "02", title: "TARGET ERROR COLOR")
            
            HStack(spacing: 10) {
                if let rgb = RGBColor(hex: hexCode) {
                    Rectangle()
                        .fill(Color(red: Double(rgb.r)/255.0, green: Double(rgb.g)/255.0, blue: Double(rgb.b)/255.0))
                        .frame(width: 32, height: 32)
                        .border(borderStrong, width: 1)
                }
                
                TextField("#HEX", text: $hexCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(textMain)
                    .padding(7)
                    .background(bgSubtle)
                    .border(borderLine, width: 1)
                    .frame(width: 110)
                    .disabled(isScanning)
                
                Spacer()
                
                Text("\(Int(tolerancePercentage))% TOL")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(textSubtle)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(colorPresets, id: \.1) { name, code, defaultTol in
                        Button(action: {
                            hexCode = code
                            tolerancePercentage = defaultTol
                        }) {
                            Text(name)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(hexCode.uppercased() == code ? primaryBtnBg : bgSubtle)
                                .foregroundColor(hexCode.uppercased() == code ? primaryBtnFg : textMain)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(isScanning)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("TOLERANCE THRESHOLD")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                    Spacer()
                    Text("\(Int(tolerancePercentage))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(textMain)
                }
                Slider(value: $tolerancePercentage, in: isTargetBlack ? 1...15 : 5...35, step: 1)
                    .tint(primaryBtnBg)
                    .disabled(isScanning)
            }
        }
    }
    
    private var blackLineModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DARK SCENE OPTIMIZATION")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(textMain)
                    .tracking(0.5)
                Spacer()
                Text("[ACTIVE]")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMain)
            }
            
            Toggle("10X EXPOSURE BOOST MULTIPLIER", isOn: $enableExposureBoost)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .toggleStyle(StudioToggleStyle(isLight: isLightMode))
                .disabled(isScanning)
            
            Toggle("IGNORE FULL-FRAME BLACK SLATES", isOn: $ignoreFullBlackFrames)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .toggleStyle(StudioToggleStyle(isLight: isLightMode))
                .disabled(isScanning)
        }
        .padding(10)
        .background(bgCardSubtle)
        .border(borderStrong, width: 1)
    }
    
    private var edgeSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "03", title: "EDGE BOUNDS")
            
            HStack {
                Text("EDGE SCAN DEPTH:")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                Spacer()
                Text("\(edgeDepth) PX")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(textMain)
                Stepper("", value: $edgeDepth, in: 2...40)
                    .labelsHidden()
                    .disabled(isScanning)
            }
            
            HStack(spacing: 12) {
                Toggle("TOP", isOn: $checkTop).toggleStyle(StudioToggleStyle(isLight: isLightMode)).disabled(isScanning)
                Toggle("BOT", isOn: $checkBottom).toggleStyle(StudioToggleStyle(isLight: isLightMode)).disabled(isScanning)
                Toggle("LFT", isOn: $checkLeft).toggleStyle(StudioToggleStyle(isLight: isLightMode)).disabled(isScanning)
                Toggle("RGT", isOn: $checkRight).toggleStyle(StudioToggleStyle(isLight: isLightMode)).disabled(isScanning)
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(textMain)
        }
    }
    
    private var actionSection: some View {
        VStack(spacing: 8) {
            sectionHeader(num: "04", title: "EXECUTION")
            
            if isScanning {
                Button(action: cancelScan) {
                    Text("[ CANCEL AUDIT ]")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.0)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(alertRed)
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: startScan) {
                    Text("[ START LINE QC AUDIT ]")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.0)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(videoFiles.isEmpty ? bgSubtle : primaryBtnBg)
                        .foregroundColor(videoFiles.isEmpty ? textMuted : primaryBtnFg)
                }
                .buttonStyle(.plain)
                .disabled(videoFiles.isEmpty || RGBColor(hex: hexCode) == nil)
            }
        }
    }
    
    private var activeScanProgressView: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("SCANNING IN PROGRESS")
                    .font(.system(size: 28, weight: .black, design: .default))
                    .foregroundColor(textMain)
                    .tracking(1.0)
                Spacer()
                Text("[PROCESSING]")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(textMain)
                    .padding(6)
                    .border(borderLine, width: 1)
            }
            
            if let p = progressInfo {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CURRENT ASSET")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                        Text(p.currentFileName.uppercased())
                            .font(.system(size: 18, weight: .heavy, design: .monospaced))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 20) {
                        statItem(label: "BATCH PROGRESS", val: "FILE \(String(format: "%02d", p.currentFileIndex)) / \(String(format: "%02d", p.totalFiles))")
                        statItem(label: "FRAME INDEX", val: "\(p.currentFrame) / \(p.totalFramesInFile)")
                        statItem(label: "SPEED", val: "\(String(format: "%.0f", p.fps)) FPS")
                        statItem(label: "FLAGGED", val: "\(p.flaggedVideosCount)", isAlert: p.flaggedVideosCount > 0)
                    }
                    
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(borderLine)
                                .frame(height: 4)
                            
                            let ratio = (Double(p.currentFileIndex - 1) + (Double(p.currentFrame) / Double(max(1, p.totalFramesInFile)))) / Double(max(1, p.totalFiles))
                            Rectangle()
                                .fill(primaryBtnBg)
                                .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, ratio))), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(24)
                .background(bgPanel)
                .border(borderLine, width: 1)
            }
            Spacer()
        }
        .padding(28)
    }
    
    private var resultsSummaryView: some View {
        let flagged = scanResults.filter { $0.isFlagged }
        let clean = scanResults.filter { !$0.isFlagged }
        let totalSegments = flagged.reduce(0) { $0 + $1.glitchSegments.count }
        
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUDIT COMPLETE")
                        .font(.system(size: 28, weight: .black, design: .default))
                        .foregroundColor(textMain)
                        .tracking(1.0)
                    Text("\(scanResults.count) ASSETS ANALYZED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                Spacer()
                
                HStack(spacing: 8) {
                    if let reportURL = generatedReportURL {
                        Button(action: { NSWorkspace.shared.open(reportURL) }) {
                            Text("[ OPEN HTML REPORT ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(primaryBtnBg)
                                .foregroundColor(primaryBtnFg)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if let csvURL = generatedCSVURL {
                        Button(action: { NSWorkspace.shared.open(csvURL) }) {
                            Text("[ GOOGLE SHEETS / CSV ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(bgSubtle)
                                .foregroundColor(textMain)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if let reportURL = generatedReportURL {
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([reportURL]) }) {
                            Text("[ FINDER ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(bgSubtle)
                                .foregroundColor(textMain)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            HStack(spacing: 12) {
                statBox(title: "TOTAL SCANNED", val: String(format: "%02d", scanResults.count))
                statBox(title: "FLAGGED FILES", val: String(format: "%02d", flagged.count), isRed: !flagged.isEmpty)
                statBox(title: "PASSED FILES", val: String(format: "%02d", clean.count))
                statBox(title: "GLITCH SEGMENTS", val: String(format: "%02d", totalSegments), isRed: totalSegments > 0)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if flagged.isEmpty {
                        VStack(spacing: 8) {
                            Text("STATUS // ALL DELIVERIES PASSED")
                                .font(.system(size: 16, weight: .black, design: .monospaced))
                                .foregroundColor(textMain)
                            Text("NO COLORED EDGE LINES OR MATTE ARTIFACTS DETECTED.")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                        .background(bgPanel)
                        .border(borderLine, width: 1)
                    } else {
                        ForEach(flagged) { result in
                            let segments = result.glitchSegments
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.fileName.uppercased())
                                            .font(.system(size: 14, weight: .heavy, design: .monospaced))
                                            .foregroundColor(textMain)
                                        Text("\(result.resolution) // \(String(format: "%.2f", result.fps)) FPS // \(result.totalFrames) FRAMES")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundColor(textMuted)
                                    }
                                    Spacer()
                                    
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text("[\(segments.count) OCCURRENCE(S) // \(result.errorFrames.count) FRAMES]")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundColor(alertRed)
                                        Text("FINDER RED TAG APPLIED")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundColor(textMuted)
                                    }
                                }
                                .padding(14)
                                .background(bgCardHeader)
                                
                                Rectangle().fill(borderLine).frame(height: 1)
                                
                                HStack(spacing: 8) {
                                    Text("#").frame(width: 25, alignment: .leading)
                                    Text("LOCATION").frame(width: 120, alignment: .leading)
                                    Text("TIMECODE RANGE").frame(width: 170, alignment: .leading)
                                    Text("DURATION").frame(width: 140, alignment: .leading)
                                    Text("FRAMES").frame(width: 80, alignment: .leading)
                                    Spacer()
                                    Text("COLOR").frame(width: 80, alignment: .trailing)
                                }
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(bgCardSubtle)
                                
                                Rectangle().fill(borderLine).frame(height: 1)
                                
                                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                                    HStack(spacing: 8) {
                                        Text(String(format: "%02d", idx + 1))
                                            .frame(width: 25, alignment: .leading)
                                            .foregroundColor(textMuted)
                                        
                                        Text("\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX)")
                                            .frame(width: 120, alignment: .leading)
                                            .fontWeight(.bold)
                                            .foregroundColor(textMain)
                                        
                                        Text(seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) -> \(seg.endTimecode)")
                                            .frame(width: 170, alignment: .leading)
                                            .fontWeight(.heavy)
                                            .foregroundColor(textMain)
                                        
                                        Text(seg.frameCount == 1 ? "1 FRAME (0.04S)" : "\(seg.frameCount) FRAMES (\(String(format: "%.2f", seg.durationSeconds))S)")
                                            .frame(width: 140, alignment: .leading)
                                            .foregroundColor(textSubtle)
                                        
                                        Text("[\(seg.startFrame == seg.endFrame ? "\(seg.startFrame)" : "\(seg.startFrame)-\(seg.endFrame)")]")
                                            .frame(width: 80, alignment: .leading)
                                            .foregroundColor(textMuted)
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 5) {
                                            Rectangle()
                                                .fill(Color(red: Double(seg.detectedColor.r)/255, green: Double(seg.detectedColor.g)/255, blue: Double(seg.detectedColor.b)/255))
                                                .frame(width: 10, height: 10)
                                                .border(borderStrong, width: 1)
                                            Text(seg.detectedColor.hexString.uppercased())
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundColor(textMain)
                                        }
                                        .frame(width: 80, alignment: .trailing)
                                    }
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    
                                    if idx < segments.count - 1 {
                                        Rectangle().fill(borderLine.opacity(0.6)).frame(height: 1)
                                    }
                                }
                            }
                            .background(bgPanel)
                            .border(borderLine, width: 1)
                            .overlay(
                                Rectangle()
                                    .fill(alertRed)
                                    .frame(width: 3),
                                alignment: .leading
                            )
                        }
                    }
                }
            }
        }
        .padding(28)
    }
    
    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("STATUS // READY TO AUDIT")
                .font(.system(size: 32, weight: .black, design: .default))
                .foregroundColor(textMain)
                .tracking(1.0)
            
            Text("CHOOSE A DELIVERY FOLDER OR VIDEO FILES ON THE LEFT TO BEGIN FRAME-BY-FRAME ANALYSIS.\nDETECTS MATTE MISALIGNMENTS, LETTERBOX ARTIFACTS, AND COLORED EDGE LINES.")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(textMuted)
                .lineSpacing(4)
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            HStack(spacing: 16) {
                formatTag("PRORES 422/4444")
                formatTag("H.264")
                formatTag("H.265/HEVC")
                formatTag("QUICKTIME MOV")
                formatTag("MP4")
            }
            
            Spacer()
        }
        .padding(40)
    }
    
    // MARK: ==================== TAB 2: DELIVERABLES SPECS ====================
    
    private var deliverablesTabView: some View {
        HSplitView {
            // Left Control Panel
            VStack(alignment: .leading, spacing: 18) {
                // Unified Asset Picker (exact identical styling & font spacing)
                deliveryAssetsSection(forTab: .deliverables)
                
                // Actions
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(num: "02", title: "SPECS ACTIONS")
                    
                    Button(action: rescanDeliverables) {
                        HStack {
                            Text("[ RESCAN FOLDER / ASSETS ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                            Spacer()
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(bgSubtle)
                        .foregroundColor((videoFiles.isEmpty && folderURL == nil) ? textMuted : textMain)
                        .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    .disabled((videoFiles.isEmpty && folderURL == nil) || isInspectingDeliverables)
                    
                    Button(action: {
                        if !deliverableAssets.isEmpty {
                            exportDeliverablesManifest()
                        }
                    }) {
                        Text("[ EXPORT GOOGLE SHEETS / CSV ]")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(deliverableAssets.isEmpty ? bgSubtle : primaryBtnBg)
                            .foregroundColor(deliverableAssets.isEmpty ? textMuted : primaryBtnFg)
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    
                    Button(action: {
                        if !deliverableAssets.isEmpty {
                            openManifestHTML()
                        }
                    }) {
                        Text("[ OPEN HTML SPECS ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(bgSubtle)
                            .foregroundColor(deliverableAssets.isEmpty ? textMuted : textMain)
                            .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(deliverableAssets.isEmpty)
                    
                    if let firstURL = deliverableAssets.first?.fileURL {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([firstURL])
                        }) {
                            Text("[ REVEAL IN FINDER ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(bgSubtle)
                                .foregroundColor(textMain)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if !deliverableAssets.isEmpty {
                        Button(action: {
                            deliverableAssets = []
                        }) {
                            Text("[ CLEAR LIST ]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
            .background(bgPanel)
            
            // Right Panel: Specs Table / Stats
            VStack(alignment: .leading, spacing: 0) {
                if isInspectingDeliverables {
                    VStack(alignment: .center, spacing: 12) {
                        Spacer()
                        Text("INSPECTING DELIVERABLES SPECS...")
                            .font(.system(size: 18, weight: .heavy, design: .monospaced))
                        ProgressView()
                            .scaleEffect(1.2)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                } else if deliverableAssets.isEmpty {
                    emptyDeliverablesStateView
                } else {
                    deliverablesResultsView
                }
            }
            .frame(minWidth: 540)
            .background(bgMain)
        }
    }
    
    private var emptyDeliverablesStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("STATUS // READY TO INSPECT DELIVERABLES")
                .font(.system(size: 32, weight: .black, design: .default))
                .foregroundColor(textMain)
                .tracking(1.0)
            
            Text("CHOOSE A DELIVERY FOLDER OR VIDEO FILES ON THE LEFT TO INSTANTLY GENERATE A DELIVERABLE SPECS AUDIT.\nDISPLAYS EXACT TIMECODE LENGTHS, ASPECT RATIOS, RESOLUTIONS, FRAMERATES, AND SIZES.")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(textMuted)
                .lineSpacing(4)
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            HStack(spacing: 16) {
                formatTag("16:9 • 9:16 • 4:5 • 1:1")
                formatTag("SMPTE TIMECODES")
                formatTag("FILE SIZES")
                formatTag("CODEC & BITRATES")
            }
            
            Spacer()
        }
        .padding(40)
    }
    
    private var deliverablesResultsView: some View {
        let totalBytes = deliverableAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let totalSeconds = deliverableAssets.reduce(0.0) { $0 + $1.durationSeconds }
        let mismatchCount = deliverableAssets.filter { $0.validation.hasAnyMismatch }.count
        
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUDIT COMPLETE")
                        .font(.system(size: 28, weight: .black, design: .default))
                        .foregroundColor(textMain)
                        .tracking(1.0)
                    Text("\(deliverableAssets.count) ASSETS ANALYZED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: rescanDeliverables) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .bold))
                            Text("[ RESCAN ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bgSubtle)
                        .foregroundColor(textMain)
                        .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isInspectingDeliverables)
                    
                    Button(action: exportDeliverablesManifest) {
                        Text("[ EXPORT GOOGLE SHEETS / CSV ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(primaryBtnBg)
                            .foregroundColor(primaryBtnFg)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: openManifestHTML) {
                        Text("[ OPEN HTML SPECS ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    
                    if let firstURL = deliverableAssets.first?.fileURL {
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([firstURL]) }) {
                            Text("[ FINDER ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(bgSubtle)
                                .foregroundColor(textMain)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Quick Stats Strip
            HStack(spacing: 12) {
                statBox(title: "TOTAL ASSETS", val: String(format: "%02d", deliverableAssets.count))
                statBox(title: "NAME MISMATCHES", val: String(format: "%02d", mismatchCount), isRed: mismatchCount > 0)
                statBox(title: "TOTAL RUNTIME", val: TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0))
                statBox(title: "TOTAL BATCH SIZE", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
            }
            
            // Table
            VStack(alignment: .leading, spacing: 0) {
                // Table Header
                HStack(spacing: 8) {
                    Text("#").frame(width: 25, alignment: .leading)
                    Text("FILE NAME").frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    Text("STATUS").frame(width: 75, alignment: .leading)
                    Text("TIMECODE (TC)").frame(width: 140, alignment: .leading)
                    Text("RATIO & SIZE").frame(width: 140, alignment: .leading)
                    Text("FPS").frame(width: 65, alignment: .leading)
                    Text("FILE SIZE").frame(width: 75, alignment: .leading)
                    Text("VIDEO").frame(width: 85, alignment: .leading)
                    Text("AUDIO SPEC & BITRATE").frame(width: 150, alignment: .leading)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(bgCardHeader)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Table Rows
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(deliverableAssets.enumerated()), id: \.element.id) { idx, asset in
                            let hasMismatch = asset.validation.hasAnyMismatch
                            
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", idx + 1))
                                    .frame(width: 25, alignment: .leading)
                                    .foregroundColor(textMuted)
                                
                                Text(asset.fileName.uppercased())
                                    .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                                    .fontWeight(.bold)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(asset.fileName)
                                
                                // Validation Status Badge
                                if hasMismatch {
                                    Text("MISMATCH")
                                        .font(.system(size: 8, weight: .black, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(alertRed)
                                        .foregroundColor(.white)
                                        .frame(width: 75, alignment: .leading)
                                        .help(asset.validation.summaryString)
                                } else {
                                    Text("OK")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                        .frame(width: 75, alignment: .leading)
                                }
                                
                                // Timecode Cell with Warning
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.timecode)
                                        .foregroundColor(asset.validation.isDurationMismatch ? alertRed : textSubtle)
                                        .fontWeight(asset.validation.isDurationMismatch ? .bold : .regular)
                                    
                                    if let detail = asset.validation.durationMismatchDetail {
                                        Text(detail)
                                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                            .foregroundColor(alertRed)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 140, alignment: .leading)
                                
                                // Ratio Cell with Warning
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(asset.aspectRatioString)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(asset.validation.isRatioMismatch ? alertRed : bgSubtle)
                                            .foregroundColor(asset.validation.isRatioMismatch ? .white : textMain)
                                            .border(asset.validation.isRatioMismatch ? alertRed : borderLine, width: 1)
                                        
                                        Text(asset.resolutionString)
                                            .foregroundColor(textSubtle)
                                    }
                                    
                                    if let detail = asset.validation.ratioMismatchDetail {
                                        Text(detail)
                                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                            .foregroundColor(alertRed)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 140, alignment: .leading)
                                
                                Text(String(format: "%.2f", asset.fps))
                                    .frame(width: 65, alignment: .leading)
                                    .foregroundColor(textSubtle)
                                
                                Text(asset.formattedFileSize)
                                    .frame(width: 75, alignment: .leading)
                                    .fontWeight(.semibold)
                                
                                Text(asset.videoCodec)
                                    .frame(width: 85, alignment: .leading)
                                    .foregroundColor(textMuted)
                                    .lineLimit(1)
                                
                                // Audio Column
                                if !asset.hasAudio {
                                    Text("NONE")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                        .frame(width: 150, alignment: .leading)
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(asset.audioCodec)
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                .foregroundColor(textMain)
                                            if asset.audioBitrate != "--" {
                                                Text(asset.audioBitrate)
                                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(bgSubtle)
                                                    .border(borderLine, width: 1)
                                                    .foregroundColor(textSubtle)
                                            }
                                        }
                                        if !asset.audioFormatDetail.isEmpty {
                                            Text(asset.audioFormatDetail)
                                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                                .foregroundColor(textMuted)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(width: 150, alignment: .leading)
                                    .help(asset.audioConfig)
                                }
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(hasMismatch ? (isLightMode ? Color.red.opacity(0.08) : Color.red.opacity(0.12)) : (idx % 2 == 0 ? bgPanel : bgCardSubtle))
                            .overlay(
                                hasMismatch ? Rectangle().fill(alertRed).frame(width: 3) : nil,
                                alignment: .leading
                            )
                            
                            if idx < deliverableAssets.count - 1 {
                                Rectangle().fill(borderLine.opacity(0.4)).frame(height: 1)
                            }
                        }
                    }
                }
            }
            .background(bgPanel)
            .border(borderLine, width: 1)
        }
        .padding(28)
    }
    
    // MARK: ==================== TAB 3: BATCH RENAMER ====================
    
    private var batchRenamerTabView: some View {
        HSplitView {
            // Left Control Panel
            VStack(alignment: .leading, spacing: 16) {
                // 01 // Assets
                deliveryAssetsSection(forTab: .batchRenamer)
                
                // 02 // Rename Mode
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(num: "02", title: "RENAME MODE")
                    
                    HStack(spacing: 6) {
                        ForEach(RenameMode.allCases) { mode in
                            Button(action: { renameMode = mode }) {
                                Text(mode.rawValue)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(renameMode == mode ? primaryBtnBg : bgSubtle)
                                    .foregroundColor(renameMode == mode ? primaryBtnFg : textMain)
                                    .border(borderLine, width: 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                // 03 // Pattern & Rules Builder
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(num: "03", title: "PATTERN & RULES")
                    
                    if renameMode == .template {
                        VStack(alignment: .leading, spacing: 8) {
                            // 1. Custom Name Field for {NAME}
                            VStack(alignment: .leading, spacing: 4) {
                                Text("PROJECT / ASSET NAME {NAME}:")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMuted)
                                TextField("e.g. NIKE_AIR (leave blank for original)", text: $customNameText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMain)
                                    .padding(7)
                                    .background(bgSubtle)
                                    .border(borderStrong, width: 1)
                            }
                            
                            // 2. Template Structure
                            VStack(alignment: .leading, spacing: 4) {
                                Text("TEMPLATE STRUCTURE:")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMuted)
                                
                                TextField("e.g. {NAME}_{DUR}sec_{RATIO}_{TAG}", text: $templateText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMain)
                                    .padding(7)
                                    .background(bgSubtle)
                                    .border(borderStrong, width: 1)
                            }
                            
                            Text("CLICK TO INSERT TOKEN:")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            
                            // Token Chips ScrollView
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 5) {
                                    ForEach(RenamerEngine.availableTokens, id: \.token) { item in
                                        Button(action: {
                                            insertToken(item.token)
                                        }) {
                                            Text(item.token)
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(bgSubtle)
                                                .foregroundColor(textMain)
                                                .border(borderLine, width: 1)
                                        }
                                        .buttonStyle(.plain)
                                        .help("\(item.label) (e.g. \(item.example))")
                                    }
                                }
                            }
                            
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("CUSTOM TAG {TAG}:")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    TextField("TAG", text: $customTag)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMain)
                                        .padding(6)
                                        .background(bgSubtle)
                                        .border(borderLine, width: 1)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("INDEX START:")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(textMuted)
                                    Stepper("\(indexStart) (PAD: \(indexPadding))", value: $indexStart, in: 1...999)
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                }
                            }
                        }
                    } else if renameMode == .findReplace {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("FIND TEXT:")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("Find text in filename...", text: $findText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .background(bgSubtle)
                                .border(borderLine, width: 1)
                            
                            Text("REPLACE WITH:")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("Replace with...", text: $replaceText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .background(bgSubtle)
                                .border(borderLine, width: 1)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PREFIX (ADD TO START):")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("Prefix_", text: $prefixText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .background(bgSubtle)
                                .border(borderLine, width: 1)
                            
                            Text("SUFFIX (ADD TO END):")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                            TextField("_Suffix", text: $suffixText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(textMain)
                                .padding(8)
                                .background(bgSubtle)
                                .border(borderLine, width: 1)
                        }
                    }
                    
                    // Case Formatting
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TEXT CASING:")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                        
                        HStack(spacing: 5) {
                            ForEach(TextCaseOption.allCases) { opt in
                                Button(action: { textCase = opt }) {
                                    Text(opt.rawValue)
                                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(textCase == opt ? primaryBtnBg : bgSubtle)
                                        .foregroundColor(textCase == opt ? primaryBtnFg : textSubtle)
                                        .border(borderLine, width: 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // 04 // Execution
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(num: "04", title: "EXECUTION")
                    
                    let items = renameItems
                    let activeSelectedCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status == .pending }.count
                    let hasCollisions = items.contains { selectedAssetIDs.contains($0.asset.id) && $0.status.isErrorOrCollision }
                    
                    Button(action: executeRename) {
                        Text(hasCollisions ? "[ RESOLVE COLLISIONS FIRST ]" : (activeSelectedCount > 0 ? "[ RENAME \(activeSelectedCount) SELECTED FILE(S) ]" : "[ NO CHANGES TO APPLY ]"))
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(hasCollisions ? alertRed : (activeSelectedCount > 0 ? primaryBtnBg : bgSubtle))
                            .foregroundColor(hasCollisions ? .white : (activeSelectedCount > 0 ? primaryBtnFg : textMuted))
                    }
                    .buttonStyle(.plain)
                    .disabled(activeSelectedCount == 0 || hasCollisions)
                    
                    if let trans = lastTransaction {
                        Button(action: undoLastRename) {
                            HStack {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 9, weight: .bold))
                                Text("[ UNDO / REVERT (\(trans.entries.count) FILES) ]")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
            .background(bgPanel)
            
            // Right Panel
            VStack(alignment: .leading, spacing: 0) {
                if deliverableAssets.isEmpty {
                    emptyRenamerStateView
                } else {
                    renamerResultsView
                }
            }
            .frame(minWidth: 540)
            .background(bgMain)
        }
    }
    
    private var emptyRenamerStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("STATUS // READY TO BATCH RENAME")
                .font(.system(size: 32, weight: .black, design: .default))
                .foregroundColor(textMain)
                .tracking(1.0)
            
            Text("CHOOSE A DELIVERY FOLDER OR VIDEO FILES ON THE LEFT TO AUTOMATICALLY RENAME ASSETS ACCORDING TO SPECS.\nSUPPORTS SMART DURATION TOKENS, ASPECT RATIOS, RESOLUTIONS, AUDIO, CODEC, AND CUSTOM TAGS.")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(textMuted)
                .lineSpacing(4)
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            HStack(spacing: 16) {
                formatTag("{NAME}")
                formatTag("{XXsec}")
                formatTag("{RATIO}")
                formatTag("{TAG}")
                formatTag("{RES}")
                formatTag("{FPS}")
            }
            
            Spacer()
        }
        .padding(40)
    }
    
    private var renamerResultsView: some View {
        let items = renameItems
        let totalCount = items.count
        let selectedCount = selectedAssetIDs.count
        let readyCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status == .pending }.count
        let collisionCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status.isErrorOrCollision }.count
        let unchangedCount = items.filter { selectedAssetIDs.contains($0.asset.id) && $0.status == .unchanged }.count
        let excludedCount = items.filter { !selectedAssetIDs.contains($0.asset.id) }.count
        
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LIVE BATCH PREVIEW")
                        .font(.system(size: 28, weight: .black, design: .default))
                        .foregroundColor(textMain)
                        .tracking(1.0)
                    Text("\(selectedCount) OF \(totalCount) ASSETS SELECTED // SELECT INDIVIDUAL FILES BELOW")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: toggleSelectAll) {
                        Text(selectedAssetIDs.count == deliverableAssets.count ? "[ DESELECT ALL ]" : "[ SELECT ALL ]")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    
                    if let firstURL = deliverableAssets.first?.fileURL {
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([firstURL]) }) {
                            Text("[ FINDER ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(bgSubtle)
                                .foregroundColor(textMain)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Quick Stats Strip
            HStack(spacing: 12) {
                statBox(title: "TOTAL ASSETS", val: String(format: "%02d", totalCount))
                statBox(title: "TO BE RENAMED", val: String(format: "%02d", readyCount))
                statBox(title: "COLLISIONS", val: String(format: "%02d", collisionCount), isRed: collisionCount > 0)
                statBox(title: "EXCLUDED / UNCHANGED", val: String(format: "%02d", excludedCount + unchangedCount))
            }
            
            // Table
            VStack(alignment: .leading, spacing: 0) {
                // Table Header
                HStack(spacing: 8) {
                    // Select All Toggle Column
                    Button(action: toggleSelectAll) {
                        HStack(spacing: 6) {
                            Image(systemName: selectedAssetIDs.count == deliverableAssets.count && !deliverableAssets.isEmpty ? "checkmark.square.fill" : (selectedAssetIDs.isEmpty ? "square" : "minus.square.fill"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(textMain)
                            Text("#")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 55, alignment: .leading)
                    
                    Text("CURRENT FILE NAME").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                    Text("➔").frame(width: 20, alignment: .center)
                    Text("PROPOSED NEW NAME").frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                    Text("SPECS APPLIED").frame(width: 140, alignment: .leading)
                    Text("STATUS").frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(bgCardHeader)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Table Rows
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            let isSelected = selectedAssetIDs.contains(item.asset.id)
                            let isCollision = isSelected && item.status.isErrorOrCollision
                            let isUnchanged = isSelected && item.status == .unchanged
                            
                            HStack(spacing: 8) {
                                // Large Checkbox + Index Number
                                HStack(spacing: 6) {
                                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(isSelected ? primaryBtnBg : textMuted)
                                    
                                    Text(String(format: "%02d", idx + 1))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(isSelected ? textMain : textMuted)
                                }
                                .frame(width: 55, alignment: .leading)
                                
                                Text(item.originalName + (item.originalExtension.isEmpty ? "" : ".\(item.originalExtension)"))
                                    .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                                    .foregroundColor(isSelected ? textMuted : textMuted.opacity(0.35))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Text("➔")
                                    .frame(width: 20, alignment: .center)
                                    .foregroundColor(isSelected ? textSubtle : textMuted.opacity(0.25))
                                    .font(.system(size: 10, weight: .bold))
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(isSelected ? item.proposedFullName : "\(item.originalName).\(item.originalExtension)")
                                        .fontWeight(.bold)
                                        .foregroundColor(!isSelected ? textMuted.opacity(0.35) : (isCollision ? alertRed : (isUnchanged ? textMuted : textMain)))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    
                                    if isSelected, let col = item.collisionDetail {
                                        Text(col)
                                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                            .foregroundColor(alertRed)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                                
                                Text("\(item.asset.aspectRatioString) • \(Int(round(item.asset.durationSeconds)))s • \(item.asset.videoCodec)")
                                    .frame(width: 140, alignment: .leading)
                                    .foregroundColor(isSelected ? textSubtle : textMuted.opacity(0.35))
                                    .lineLimit(1)
                                
                                // Status Badge
                                Text(isSelected ? item.status.badgeText : "EXCLUDED")
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(!isSelected ? bgSubtle.opacity(0.5) : (isCollision ? alertRed : (isUnchanged ? bgSubtle : primaryBtnBg)))
                                    .foregroundColor(!isSelected ? textMuted.opacity(0.6) : (isCollision ? .white : (isUnchanged ? textMuted : primaryBtnFg)))
                                    .border(isCollision ? alertRed : borderLine, width: 1)
                                    .frame(width: 110, alignment: .trailing)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                isCollision ? (isLightMode ? Color.red.opacity(0.08) : Color.red.opacity(0.12)) :
                                (isSelected ? (idx % 2 == 0 ? bgPanel : bgCardSubtle) : (isLightMode ? Color(white: 0.94) : Color(white: 0.04)))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelected {
                                    selectedAssetIDs.remove(item.asset.id)
                                } else {
                                    selectedAssetIDs.insert(item.asset.id)
                                }
                            }
                            .overlay(
                                isCollision ? Rectangle().fill(alertRed).frame(width: 3) : nil,
                                alignment: .leading
                            )
                            
                            if idx < items.count - 1 {
                                Rectangle().fill(borderLine.opacity(0.4)).frame(height: 1)
                            }
                        }
                    }
                }
            }
            .background(bgPanel)
            .border(borderLine, width: 1)
        }
        .padding(28)
    }
    
    // MARK: - Handlers & Unified Scanning Logic
    
    private func toggleSelectAll() {
        if selectedAssetIDs.count == deliverableAssets.count {
            selectedAssetIDs.removeAll()
        } else {
            selectedAssetIDs = Set(deliverableAssets.map { $0.id })
        }
    }
    
    private func insertToken(_ token: String) {
        if templateText.isEmpty {
            templateText = token
        } else {
            templateText += "_\(token)"
        }
    }
    
    private func executeRename() {
        let items = renameItems
        let result = RenamerEngine.executeBatchRename(items: items, selectedIDs: selectedAssetIDs)
        if let transaction = result.transaction {
            self.lastTransaction = transaction
        }
        
        // Refresh deliverable assets
        if let folder = folderURL {
            let updatedFiles = VideoScanner.findVideoFiles(in: folder)
            self.videoFiles = updatedFiles
            inspectDeliverablesBatch(urls: updatedFiles)
        } else if !videoFiles.isEmpty {
            if let transaction = result.transaction {
                let urlMap = Dictionary(uniqueKeysWithValues: transaction.entries.map { ($0.oldURL, $0.newURL) })
                let updated = self.videoFiles.map { urlMap[$0] ?? $0 }
                self.videoFiles = updated
                inspectDeliverablesBatch(urls: updated)
            }
        }
    }
    
    private func undoLastRename() {
        guard let trans = lastTransaction else { return }
        _ = RenamerEngine.undoRenameTransaction(trans)
        self.lastTransaction = nil
        
        // Refresh deliverable assets
        if let folder = folderURL {
            let updatedFiles = VideoScanner.findVideoFiles(in: folder)
            self.videoFiles = updatedFiles
            inspectDeliverablesBatch(urls: updatedFiles)
        } else if !videoFiles.isEmpty {
            let urlMap = Dictionary(uniqueKeysWithValues: trans.entries.map { ($0.newURL, $0.oldURL) })
            let updated = self.videoFiles.map { urlMap[$0] ?? $0 }
            self.videoFiles = updated
            inspectDeliverablesBatch(urls: updated)
        }
    }
    
    private func selectAssets(forTab: AppTab) {
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
    
    private func handleDrop(providers: [NSItemProvider], forTab: AppTab) -> Bool {
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
    
    // Line Scanner Execution
    private func startScan() {
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
            let results = await scanner.scanBatch(videoURLs: videoFiles, config: config) { progress in
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
    
    private func cancelScan() {
        Task {
            await scannerActor?.cancel()
            DispatchQueue.main.async {
                self.isScanning = false
                self.scannerActor = nil
            }
        }
    }
    
    // Deliverables Specs Handlers
    private func rescanDeliverables() {
        if let folder = folderURL {
            let updatedFiles = VideoScanner.findVideoFiles(in: folder)
            self.videoFiles = updatedFiles
            inspectDeliverablesBatch(urls: updatedFiles)
        } else if !videoFiles.isEmpty {
            inspectDeliverablesBatch(urls: videoFiles)
        }
    }
    
    private func inspectDeliverablesBatch(urls: [URL]) {
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
    
    private func exportDeliverablesManifest() {
        guard !deliverableAssets.isEmpty else { return }
        
        let csvString = DeliverablesInspector.generateManifestCSV(assets: deliverableAssets)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        savePanel.nameFieldStringValue = "Deliverables_Specs_\(Date().timeIntervalSince1970).csv"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csvString.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    private func openManifestHTML() {
        guard !deliverableAssets.isEmpty else { return }
        
        let folderName = folderURL?.lastPathComponent ?? "Deliverables"
        let htmlString = DeliverablesInspector.generateManifestHTML(assets: deliverableAssets, folderName: folderName)
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Deliverables_Specs_\(Int(Date().timeIntervalSince1970)).html")
        try? htmlString.write(to: tempURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(tempURL)
    }
    
    // UI Helpers
    private func sectionHeader(num: String, title: String) -> some View {
        HStack(spacing: 6) {
            Text(num)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
            Text("//")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
            Text(title)
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(textMain)
                .tracking(1.0)
        }
    }
    
    private func statBox(title: String, val: String, isRed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
                .tracking(0.5)
            Text(val)
                .font(.system(size: 20, weight: .black, design: .monospaced))
                .foregroundColor(isRed ? alertRed : textMain)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgPanel)
        .border(borderLine, width: 1)
    }
    
    private func statItem(label: String, val: String, isAlert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
            Text(val)
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .foregroundColor(isAlert ? alertRed : textMain)
        }
    }
    
    private func formatTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .border(borderLine, width: 1)
    }
}

// Minimalist Toggle Style
struct StudioToggleStyle: ToggleStyle {
    var isLight: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(configuration.isOn ? (isLight ? Color.black : Color.white) : Color.clear)
                    .frame(width: 8, height: 8)
                    .border(isLight ? Color(white: 0.6) : Color(white: 0.4), width: 1)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
