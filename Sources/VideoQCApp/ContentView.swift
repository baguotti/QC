import SwiftUI
import UniformTypeIdentifiers
import VideoQCLib

enum AppTab: Int, CaseIterable, Identifiable {
    case lineScanner = 0
    case deliverables = 1
    
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .lineScanner: return "01 // LINE SCANNER"
        case .deliverables: return "02 // DELIVERABLES MANIFEST"
        }
    }
}

struct ContentView: View {
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @State private var selectedTab: AppTab = .lineScanner
    
    // Shared Folder
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
    
    // MARK: - Tab 2: Deliverables Manifest State
    @State private var deliverableFiles: [URL] = []
    @State private var deliverableAssets: [DeliverableAsset] = []
    @State private var isInspectingDeliverables: Bool = false
    @State private var manifestCSVURL: URL? = nil
    @State private var manifestHTMLURL: URL? = nil
    
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
        VStack(spacing: 0) {
            // Header Masthead with Tab Switcher
            headerView
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            // Tab Content
            if selectedTab == .lineScanner {
                lineScannerTabView
            } else {
                deliverablesTabView
            }
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(bgMain)
        .foregroundColor(textMain)
    }
    
    // MARK: - Header & Tab Navigation
    
    private var headerView: some View {
        HStack(alignment: .center, spacing: 20) {
            // Brand Title
            VStack(alignment: .leading, spacing: 2) {
                Text("THE LINEFINDER 5000")
                    .font(.system(size: 16, weight: .black, design: .default))
                    .foregroundColor(textMain)
                    .tracking(1.5)
                Text("DELIVERY AUDIT & ASSET MANIFEST // APPLE SILICON")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .tracking(0.5)
            }
            
            Spacer()
            
            // Tab Selector
            HStack(spacing: 0) {
                ForEach(AppTab.allCases) { tab in
                    Button(action: {
                        selectedTab = tab
                        if tab == .deliverables && deliverableAssets.isEmpty && !videoFiles.isEmpty {
                            inspectDeliverablesBatch(urls: videoFiles)
                        }
                    }) {
                        Text(tab.title)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selectedTab == tab ? primaryBtnBg : bgSubtle)
                            .foregroundColor(selectedTab == tab ? primaryBtnFg : textSubtle)
                            .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            Spacer()
            
            // Right Controls
            HStack(spacing: 10) {
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
    
    // MARK: ==================== TAB 1: LINE SCANNER ====================
    
    private var lineScannerTabView: some View {
        HSplitView {
            // Left Panel: Configuration
            VStack(alignment: .leading, spacing: 18) {
                folderPickerSection
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
    
    private var folderPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "01", title: "DELIVERY FOLDER")
            
            VStack(alignment: .leading, spacing: 8) {
                Button(action: selectFolder) {
                    HStack {
                        Text(folderURL == nil ? "SELECT FOLDER..." : "CHANGE FOLDER...")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(textMain)
                            .tracking(0.5)
                        Spacer()
                        Text("[BROWSE]")
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
                
                if let folder = folderURL {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.lastPathComponent.uppercased())
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Text("\(videoFiles.count) VIDEO FILES DETECTED")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(videoFiles.isEmpty ? alertRed : textSubtle)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bgCardSubtle)
                    .border(borderLine, width: 1)
                } else {
                    Text("DRAG & DROP FOLDER HERE OR BROWSE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                        .background(bgCardSubtle)
                        .border(borderLine, width: 1)
                }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers)
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
                    Text("[ START QC AUDIT ]")
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
            
            Text("CHOOSE A DELIVERY FOLDER ON THE LEFT TO BEGIN FRAME-BY-FRAME ANALYSIS.\nDETECTS MATTE MISALIGNMENTS, LETTERBOX ARTIFACTS, AND COLORED EDGE LINES.")
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
    
    // MARK: ==================== TAB 2: DELIVERABLES MANIFEST ====================
    
    private var deliverablesTabView: some View {
        HSplitView {
            // Left Control Panel
            VStack(alignment: .leading, spacing: 18) {
                // Folder / Files Picker
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(num: "01", title: "DELIVERABLE ASSETS")
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: selectDeliverablesFolder) {
                            HStack {
                                Text("SELECT FOLDER...")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMain)
                                Spacer()
                                Text("[FOLDER]")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(textSubtle)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bgSubtle)
                            .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: selectIndividualFiles) {
                            HStack {
                                Text("SELECT FILE(S)...")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMain)
                                Spacer()
                                Text("[FILES]")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(textSubtle)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(bgSubtle)
                            .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                        
                        if !deliverableAssets.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(deliverableAssets.count) ASSETS LOADED")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(textMain)
                                
                                let totalBytes = deliverableAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
                                Text("TOTAL: \(DeliverablesInspector.formatFileSize(bytes: totalBytes))")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(textSubtle)
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
                    handleDeliverablesDrop(providers: providers)
                }
                
                // Actions
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(num: "02", title: "MANIFEST ACTIONS")
                    
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
                        Text("[ OPEN HTML MANIFEST ]")
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
            
            // Right Panel: Manifest Table / Stats
            VStack(alignment: .leading, spacing: 20) {
                if isInspectingDeliverables {
                    VStack(alignment: .center, spacing: 12) {
                        Spacer()
                        Text("INSPECTING DELIVERABLES METADATA...")
                            .font(.system(size: 18, weight: .heavy, design: .monospaced))
                        ProgressView()
                            .scaleEffect(1.2)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else if deliverableAssets.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Spacer()
                        Text("STATUS // READY TO INSPECT DELIVERABLES")
                            .font(.system(size: 32, weight: .black, design: .default))
                            .foregroundColor(textMain)
                            .tracking(1.0)
                        
                        Text("DROP A DELIVERY FOLDER OR VIDEO FILES TO INSTANTLY GENERATE AN ASSET MANIFEST.\nDISPLAYS EXACT TIMECODE LENGTHS, ASPECT RATIOS, RESOLUTIONS, FRAMERATES, AND SIZES.")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(textMuted)
                            .lineSpacing(4)
                        
                        Rectangle().fill(borderLine).frame(height: 1)
                        
                        HStack(spacing: 16) {
                            formatTag("16:9 • 9:16 • 4:5 • 1:1")
                            formatTag("SMPTE TIMECODES")
                            formatTag("FILE SIZES")
                            formatTag("CODEC PARSER")
                        }
                        Spacer()
                    }
                    .padding(40)
                } else {
                    // Quick Stats Strip
                    let totalBytes = deliverableAssets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
                    let totalSeconds = deliverableAssets.reduce(0.0) { $0 + $1.durationSeconds }
                    let uniqueRatios = Array(Set(deliverableAssets.map { $0.aspectRatioString })).sorted().joined(separator: ", ")
                    
                    HStack(spacing: 12) {
                        statBox(title: "TOTAL ASSETS", val: String(format: "%02d", deliverableAssets.count))
                        statBox(title: "TOTAL RUNTIME", val: TimecodeFormatter.format(frameIndex: Int(round(totalSeconds * 25.0)), fps: 25.0))
                        statBox(title: "ASPECT RATIOS", val: uniqueRatios.isEmpty ? "--" : uniqueRatios)
                        statBox(title: "TOTAL BATCH SIZE", val: DeliverablesInspector.formatFileSize(bytes: totalBytes))
                    }
                    
                    // Table
                    VStack(alignment: .leading, spacing: 0) {
                        // Table Header
                        HStack(spacing: 8) {
                            Text("#").frame(width: 25, alignment: .leading)
                            Text("FILE NAME").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                            Text("LENGTH / TC").frame(width: 140, alignment: .leading)
                            Text("RATIO & SIZE").frame(width: 140, alignment: .leading)
                            Text("FPS").frame(width: 75, alignment: .leading)
                            Text("FILE SIZE").frame(width: 80, alignment: .leading)
                            Text("CODEC").frame(width: 100, alignment: .leading)
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
                                    HStack(spacing: 8) {
                                        Text(String(format: "%02d", idx + 1))
                                            .frame(width: 25, alignment: .leading)
                                            .foregroundColor(textMuted)
                                        
                                        Text(asset.fileName.uppercased())
                                            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                                            .fontWeight(.bold)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(asset.fileName)
                                        
                                        Text("\(asset.timecode) (\(asset.formattedDuration))")
                                            .frame(width: 140, alignment: .leading)
                                            .foregroundColor(textSubtle)
                                        
                                        HStack(spacing: 4) {
                                            Text(asset.aspectRatioString)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 2)
                                                .background(bgSubtle)
                                                .border(borderLine, width: 1)
                                            Text(asset.resolutionString)
                                                .foregroundColor(textSubtle)
                                        }
                                        .frame(width: 140, alignment: .leading)
                                        
                                        Text(String(format: "%.2f", asset.fps))
                                            .frame(width: 75, alignment: .leading)
                                            .foregroundColor(textSubtle)
                                        
                                        Text(asset.formattedFileSize)
                                            .frame(width: 80, alignment: .leading)
                                            .fontWeight(.semibold)
                                        
                                        Text(asset.videoCodec)
                                            .frame(width: 100, alignment: .leading)
                                            .foregroundColor(textMuted)
                                            .lineLimit(1)
                                    }
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(idx % 2 == 0 ? bgPanel : bgCardSubtle)
                                    
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
            }
            .padding(28)
            .frame(minWidth: 540)
            .background(bgMain)
        }
    }
    
    // MARK: - Deliverables Handlers
    
    private func selectDeliverablesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Deliverables Folder"
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            let files = VideoScanner.findVideoFiles(in: selectedURL)
            inspectDeliverablesBatch(urls: files)
        }
    }
    
    private func selectIndividualFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType.quickTimeMovie, UTType.mpeg4Movie]
        panel.prompt = "Select Videos"
        
        if panel.runModal() == .OK {
            inspectDeliverablesBatch(urls: panel.urls)
        }
    }
    
    private func handleDeliverablesDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    let files = VideoScanner.findVideoFiles(in: url)
                    Task { @MainActor in
                        self.inspectDeliverablesBatch(urls: files)
                    }
                } else {
                    Task { @MainActor in
                        self.inspectDeliverablesBatch(urls: [url])
                    }
                }
            }
        }
        return true
    }
    
    private func inspectDeliverablesBatch(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isInspectingDeliverables = true
        
        Task {
            let assets = await DeliverablesInspector.inspectBatch(urls: urls)
            DispatchQueue.main.async {
                self.deliverableAssets = assets
                self.isInspectingDeliverables = false
            }
        }
    }
    
    private func exportDeliverablesManifest() {
        guard !deliverableAssets.isEmpty else { return }
        
        let csvString = DeliverablesInspector.generateManifestCSV(assets: deliverableAssets)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.commaSeparatedText]
        savePanel.nameFieldStringValue = "Deliverables_Manifest_\(Date().timeIntervalSince1970).csv"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? csvString.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    private func openManifestHTML() {
        guard !deliverableAssets.isEmpty else { return }
        
        let folderName = folderURL?.lastPathComponent ?? "Deliverables"
        let htmlString = DeliverablesInspector.generateManifestHTML(assets: deliverableAssets, folderName: folderName)
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Deliverables_Manifest_\(Int(Date().timeIntervalSince1970)).html")
        try? htmlString.write(to: tempURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(tempURL)
    }
    
    // MARK: - Helper UI Builders
    
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
    
    // MARK: - Logic Handlers
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Delivery Folder"
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            self.folderURL = selectedURL
            self.videoFiles = VideoScanner.findVideoFiles(in: selectedURL)
            self.scanResults = []
            self.generatedReportURL = nil
            self.generatedCSVURL = nil
            
            // Auto-populate deliverables tab with metadata
            inspectDeliverablesBatch(urls: self.videoFiles)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                Task { @MainActor in
                    self.folderURL = url
                    self.videoFiles = VideoScanner.findVideoFiles(in: url)
                    self.scanResults = []
                    self.generatedReportURL = nil
                    self.generatedCSVURL = nil
                    self.inspectDeliverablesBatch(urls: self.videoFiles)
                }
            }
        }
        return true
    }
    
    private func startScan() {
        guard let folder = folderURL, !videoFiles.isEmpty else { return }
        
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
}

// MARK: - Custom Minimalist Toggle Style
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
