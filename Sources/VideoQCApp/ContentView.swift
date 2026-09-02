import SwiftUI
import UniformTypeIdentifiers
import VideoQCLib

struct ContentView: View {
    @State private var folderURL: URL? = nil
    @State private var videoFiles: [URL] = []
    
    // Configuration
    @State private var hexCode: String = "#FF00B4"
    @State private var tolerancePercentage: Double = 15.0
    @State private var edgeDepth: Int = 12
    @State private var minSpanPercentage: Double = 70.0
    @State private var checkTop: Bool = true
    @State private var checkBottom: Bool = true
    @State private var checkLeft: Bool = true
    @State private var checkRight: Bool = true
    
    // Enhanced Black Line Controls
    @State private var enableExposureBoost: Bool = true
    @State private var exposureMultiplier: Double = 10.0
    @State private var ignoreFullBlackFrames: Bool = true
    
    // Execution State
    @State private var isScanning: Bool = false
    @State private var progressInfo: VideoScanner.ScanProgress? = nil
    @State private var scanResults: [VideoQCResult] = []
    @State private var generatedReportURL: URL? = nil
    @State private var scannerActor: VideoScanner? = nil
    
    var isTargetBlack: Bool {
        guard let rgb = RGBColor(hex: hexCode) else { return false }
        return rgb.r <= 15 && rgb.g <= 15 && rgb.b <= 15
    }
    
    // Presets
    let colorPresets = [
        ("MAGENTA", "#FF00B4", 15.0),
        ("CYAN", "#00FFFF", 15.0),
        ("GREEN", "#00FF00", 15.0),
        ("RED", "#FF0000", 15.0),
        ("WHITE", "#FFFFFF", 15.0),
        ("BLACK (10X)", "#000000", 3.0)
    ]
    
    // Studio Palette
    let bgDark = Color(red: 0.04, green: 0.04, blue: 0.04)
    let panelDark = Color(red: 0.07, green: 0.07, blue: 0.07)
    let borderLine = Color(white: 0.16)
    let textMuted = Color(white: 0.45)
    let textSubtle = Color(white: 0.65)
    let alertRed = Color(red: 1.0, green: 0.22, blue: 0.22)
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Masthead
            headerView
            
            Rectangle()
                .fill(borderLine)
                .frame(height: 1)
            
            // Main Content Layout
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
                .background(panelDark)
                
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
                .background(bgDark)
            }
        }
        .frame(minWidth: 940, minHeight: 680)
        .background(bgDark)
        .foregroundColor(.white)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("QC // VIDEO DELIVERY AUDIT")
                    .font(.system(size: 16, weight: .black, design: .default))
                    .tracking(1.5)
                Text("POST-PRODUCTION EDGE ARTIFACT AUDITOR // APPLE SILICON")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                    .tracking(0.5)
            }
            Spacer()
            
            HStack(spacing: 6) {
                Circle()
                    .fill(isScanning ? Color.orange : (scanResults.isEmpty ? Color(white: 0.3) : (scanResults.contains(where: \.isFlagged) ? alertRed : Color.white)))
                    .frame(width: 7, height: 7)
                Text(isScanning ? "SCANNING" : (scanResults.isEmpty ? "IDLE" : "COMPLETED"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textSubtle)
                    .tracking(1.0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(white: 0.1))
            .border(borderLine, width: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(panelDark)
    }
    
    // MARK: - Section 1: Folder Picker
    
    private var folderPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "01", title: "DELIVERY FOLDER")
            
            VStack(alignment: .leading, spacing: 8) {
                Button(action: selectFolder) {
                    HStack {
                        Text(folderURL == nil ? "SELECT FOLDER..." : "CHANGE FOLDER...")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                        Spacer()
                        Text("[BROWSE]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(textSubtle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(white: 0.12))
                    .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                .disabled(isScanning)
                
                if let folder = folderURL {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.lastPathComponent.uppercased())
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Text("\(videoFiles.count) VIDEO FILES DETECTED")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(videoFiles.isEmpty ? alertRed : Color.white)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.05))
                    .border(borderLine, width: 1)
                } else {
                    Text("DRAG & DROP FOLDER HERE OR BROWSE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.03))
                        .border(borderLine, width: 1)
                }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }
    
    // MARK: - Section 2: Color Target
    
    private var colorSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "02", title: "TARGET ERROR COLOR")
            
            HStack(spacing: 10) {
                // Color preview square
                if let rgb = RGBColor(hex: hexCode) {
                    Rectangle()
                        .fill(Color(red: Double(rgb.r)/255.0, green: Double(rgb.g)/255.0, blue: Double(rgb.b)/255.0))
                        .frame(width: 32, height: 32)
                        .border(Color(white: 0.3), width: 1)
                }
                
                TextField("#HEX", text: $hexCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .padding(7)
                    .background(Color(white: 0.12))
                    .border(borderLine, width: 1)
                    .frame(width: 110)
                    .disabled(isScanning)
                
                Spacer()
                
                Text("\(Int(tolerancePercentage))% TOL")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(textSubtle)
            }
            
            // Preset pills
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
                                .background(hexCode.uppercased() == code ? Color.white : Color(white: 0.1))
                                .foregroundColor(hexCode.uppercased() == code ? .black : .white)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(isScanning)
                    }
                }
            }
            
            // Tolerance Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("TOLERANCE THRESHOLD")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                    Spacer()
                    Text("\(Int(tolerancePercentage))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                Slider(value: $tolerancePercentage, in: isTargetBlack ? 1...15 : 5...35, step: 1)
                    .tint(.white)
                    .disabled(isScanning)
            }
        }
    }
    
    // MARK: - Black Line Mode Section
    
    private var blackLineModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DARK SCENE OPTIMIZATION")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(0.5)
                Spacer()
                Text("[ACTIVE]")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            
            Toggle("10X EXPOSURE BOOST MULTIPLIER", isOn: $enableExposureBoost)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .toggleStyle(StudioToggleStyle())
                .disabled(isScanning)
            
            Toggle("IGNORE FULL-FRAME BLACK SLATES", isOn: $ignoreFullBlackFrames)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .toggleStyle(StudioToggleStyle())
                .disabled(isScanning)
        }
        .padding(10)
        .background(Color(white: 0.05))
        .border(Color(white: 0.3), width: 1)
    }
    
    // MARK: - Section 3: Edge Bounds
    
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
                Stepper("", value: $edgeDepth, in: 2...40)
                    .labelsHidden()
                    .disabled(isScanning)
            }
            
            HStack(spacing: 12) {
                Toggle("TOP", isOn: $checkTop).toggleStyle(StudioToggleStyle()).disabled(isScanning)
                Toggle("BOT", isOn: $checkBottom).toggleStyle(StudioToggleStyle()).disabled(isScanning)
                Toggle("LFT", isOn: $checkLeft).toggleStyle(StudioToggleStyle()).disabled(isScanning)
                Toggle("RGT", isOn: $checkRight).toggleStyle(StudioToggleStyle()).disabled(isScanning)
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
        }
    }
    
    // MARK: - Section 4: Action Buttons
    
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
                        .foregroundColor(.black)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: startScan) {
                    Text("[ START QC AUDIT ]")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.0)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(videoFiles.isEmpty ? Color(white: 0.2) : Color.white)
                        .foregroundColor(videoFiles.isEmpty ? Color(white: 0.5) : Color.black)
                }
                .buttonStyle(.plain)
                .disabled(videoFiles.isEmpty || RGBColor(hex: hexCode) == nil)
            }
        }
    }
    
    // MARK: - Active Scan Progress View
    
    private var activeScanProgressView: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("SCANNING IN PROGRESS")
                    .font(.system(size: 28, weight: .black, design: .default))
                    .tracking(1.0)
                Spacer()
                Text("[PROCESSING]")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(6)
                    .border(borderLine, width: 1)
            }
            
            if let p = progressInfo {
                VStack(alignment: .leading, spacing: 16) {
                    // Current File
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CURRENT ASSET")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                        Text(p.currentFileName.uppercased())
                            .font(.system(size: 18, weight: .heavy, design: .monospaced))
                            .lineLimit(1)
                    }
                    
                    // Stats Grid
                    HStack(spacing: 20) {
                        statItem(label: "BATCH PROGRESS", val: "FILE \(String(format: "%02d", p.currentFileIndex)) / \(String(format: "%02d", p.totalFiles))")
                        statItem(label: "FRAME INDEX", val: "\(p.currentFrame) / \(p.totalFramesInFile)")
                        statItem(label: "SPEED", val: "\(String(format: "%.0f", p.fps)) FPS")
                        statItem(label: "FLAGGED", val: "\(p.flaggedVideosCount)", isAlert: p.flaggedVideosCount > 0)
                    }
                    
                    // Minimal Hairline Progress Bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color(white: 0.15))
                                .frame(height: 4)
                            
                            let ratio = (Double(p.currentFileIndex - 1) + (Double(p.currentFrame) / Double(max(1, p.totalFramesInFile)))) / Double(max(1, p.totalFiles))
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, ratio))), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(24)
                .background(panelDark)
                .border(borderLine, width: 1)
            }
            
            Spacer()
        }
        .padding(28)
    }
    
    // MARK: - Results Summary View
    
    private var resultsSummaryView: some View {
        let flagged = scanResults.filter { $0.isFlagged }
        let clean = scanResults.filter { !$0.isFlagged }
        let totalSegments = flagged.reduce(0) { $0 + $1.glitchSegments.count }
        
        return VStack(alignment: .leading, spacing: 20) {
            // Masthead
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUDIT COMPLETE")
                        .font(.system(size: 28, weight: .black, design: .default))
                        .tracking(1.0)
                    Text("\(scanResults.count) ASSETS ANALYZED")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                Spacer()
                
                if let reportURL = generatedReportURL {
                    HStack(spacing: 8) {
                        Button(action: { NSWorkspace.shared.open(reportURL) }) {
                            Text("[ OPEN HTML REPORT ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white)
                                .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([reportURL]) }) {
                            Text("[ FINDER ]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(white: 0.15))
                                .foregroundColor(.white)
                                .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // 4-Column Stats Strip
            HStack(spacing: 12) {
                statBox(title: "TOTAL SCANNED", val: String(format: "%02d", scanResults.count))
                statBox(title: "FLAGGED FILES", val: String(format: "%02d", flagged.count), isRed: !flagged.isEmpty)
                statBox(title: "PASSED FILES", val: String(format: "%02d", clean.count))
                statBox(title: "GLITCH SEGMENTS", val: String(format: "%02d", totalSegments), isRed: totalSegments > 0)
            }
            
            // List of Flagged Files & Glitch Segments
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if flagged.isEmpty {
                        VStack(spacing: 8) {
                            Text("STATUS // ALL DELIVERIES PASSED")
                                .font(.system(size: 16, weight: .black, design: .monospaced))
                            Text("NO COLORED EDGE LINES OR MATTE ARTIFACTS DETECTED.")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                        .background(panelDark)
                        .border(borderLine, width: 1)
                    } else {
                        ForEach(flagged) { result in
                            let segments = result.glitchSegments
                            VStack(alignment: .leading, spacing: 0) {
                                // Card Header
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.fileName.uppercased())
                                            .font(.system(size: 14, weight: .heavy, design: .monospaced))
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
                                .background(Color(white: 0.08))
                                
                                Rectangle().fill(borderLine).frame(height: 1)
                                
                                // Table Header
                                HStack(spacing: 8) {
                                    Text("#")
                                        .frame(width: 25, alignment: .leading)
                                    Text("LOCATION")
                                        .frame(width: 120, alignment: .leading)
                                    Text("TIMECODE RANGE")
                                        .frame(width: 170, alignment: .leading)
                                    Text("DURATION")
                                        .frame(width: 140, alignment: .leading)
                                    Text("FRAMES")
                                        .frame(width: 80, alignment: .leading)
                                    Spacer()
                                    Text("COLOR")
                                        .frame(width: 80, alignment: .trailing)
                                }
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(textMuted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(white: 0.05))
                                
                                Rectangle().fill(borderLine).frame(height: 1)
                                
                                // Table Rows
                                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                                    HStack(spacing: 8) {
                                        Text(String(format: "%02d", idx + 1))
                                            .frame(width: 25, alignment: .leading)
                                            .foregroundColor(textMuted)
                                        
                                        Text("\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX)")
                                            .frame(width: 120, alignment: .leading)
                                            .fontWeight(.bold)
                                        
                                        Text(seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) -> \(seg.endTimecode)")
                                            .frame(width: 170, alignment: .leading)
                                            .fontWeight(.heavy)
                                        
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
                                                .border(Color(white: 0.4), width: 1)
                                            Text(seg.detectedColor.hexString.uppercased())
                                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        }
                                        .frame(width: 80, alignment: .trailing)
                                    }
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    
                                    if idx < segments.count - 1 {
                                        Rectangle().fill(Color(white: 0.1)).frame(height: 1)
                                    }
                                }
                            }
                            .background(panelDark)
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
    
    // MARK: - Empty State View
    
    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("STATUS // READY TO AUDIT")
                .font(.system(size: 32, weight: .black, design: .default))
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
                .font(.system(size: 24, weight: .black, design: .monospaced))
                .foregroundColor(isRed ? alertRed : .white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelDark)
        .border(borderLine, width: 1)
    }
    
    private func statItem(label: String, val: String, isAlert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(textMuted)
            Text(val)
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .foregroundColor(isAlert ? alertRed : .white)
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
        
        let scanner = VideoScanner()
        self.scannerActor = scanner
        
        Task {
            let results = await scanner.scanBatch(videoURLs: videoFiles, config: config) { progress in
                DispatchQueue.main.async {
                    self.progressInfo = progress
                }
            }
            
            // Save report text & HTML files + tag flagged in Finder
            let reportURL = ReportWriter.saveReport(folderURL: folder, config: config, results: results)
            
            DispatchQueue.main.async {
                self.scanResults = results
                self.generatedReportURL = reportURL
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
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(configuration.isOn ? Color.white : Color.clear)
                    .frame(width: 8, height: 8)
                    .border(Color(white: 0.4), width: 1)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
