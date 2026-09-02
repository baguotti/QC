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
        ("Magenta", "#FF00B4", 15.0),
        ("Cyan", "#00FFFF", 15.0),
        ("Green", "#00FF00", 15.0),
        ("Red", "#FF0000", 15.0),
        ("White", "#FFFFFF", 15.0),
        ("Black (Auto 10x)", "#000000", 3.0)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Main content layout
            HSplitView {
                // Left Panel: Configuration & Folder Picker
                VStack(alignment: .leading, spacing: 16) {
                    folderPickerSection
                    colorSettingsSection
                    if isTargetBlack {
                        blackLineModeSection
                    }
                    edgeSettingsSection
                    actionSection
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(minWidth: 350, idealWidth: 390, maxWidth: 430)
                .background(Color(NSColor.controlBackgroundColor))
                
                // Right Panel: Progress & Results
                VStack(alignment: .leading, spacing: 16) {
                    if isScanning {
                        activeScanProgressView
                    } else if !scanResults.isEmpty {
                        resultsSummaryView
                    } else {
                        emptyStateView
                    }
                }
                .padding(20)
                .frame(minWidth: 460)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(minWidth: 840, minHeight: 620)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Image(systemName: "film.stack.fill")
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Video Edge QC")
                    .font(.headline)
                    .fontWeight(.bold)
                Text("Frame-by-frame batch colored line detection")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    // MARK: - Folder Picker Section
    
    private var folderPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("1. Video Delivery Folder", systemImage: "folder.badge.gearshape")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            HStack {
                Button(action: selectFolder) {
                    Label("Choose Folder...", systemImage: "folder")
                }
                .disabled(isScanning)
                
                if let folder = folderURL {
                    Text(folder.lastPathComponent)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                } else {
                    Text("No folder selected")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            
            if !videoFiles.isEmpty {
                Text("\(videoFiles.count) video files found")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }
    
    // MARK: - Color Settings Section
    
    private var colorSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("2. Target Error Color", systemImage: "eyedropper.halffull")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            HStack(spacing: 12) {
                // Color preview swatch
                if let rgb = RGBColor(hex: hexCode) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: Double(rgb.r)/255.0, green: Double(rgb.g)/255.0, blue: Double(rgb.b)/255.0))
                        .frame(width: 32, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
                }
                
                TextField("#HEX", text: $hexCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .font(.system(.body, design: .monospaced))
                    .disabled(isScanning)
            }
            
            // Preset pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(colorPresets, id: \.1) { name, code, defaultTol in
                        Button(action: {
                            hexCode = code
                            tolerancePercentage = defaultTol
                        }) {
                            Text(name)
                                .font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(isScanning)
                    }
                }
            }
            
            // Tolerance Slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Color Tolerance:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(tolerancePercentage))%")
                        .font(.caption)
                        .fontWeight(.bold)
                }
                Slider(value: $tolerancePercentage, in: isTargetBlack ? 1...15 : 5...35, step: 1)
                    .disabled(isScanning)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Black Line Mode Section
    
    private var blackLineModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Dark Scene Optimization", systemImage: "sparkles")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.yellow)
                Spacer()
                Text("Active")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.2))
                    .foregroundColor(.yellow)
                    .cornerRadius(4)
            }
            
            Toggle("Extreme Exposure Boost (\(Int(exposureMultiplier))x)", isOn: $enableExposureBoost)
                .font(.caption)
                .disabled(isScanning)
            
            Toggle("Ignore Full-Black Frames (Fades & Slates)", isOn: $ignoreFullBlackFrames)
                .font(.caption)
                .disabled(isScanning)
                
            Text("Separates genuine digital black render gaps from camera shadows/grain using extreme gain multiplier.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.08))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
    }
    
    // MARK: - Edge Settings Section
    
    private var edgeSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("3. Edge Margin & Scan Area", systemImage: "square.dashed")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            HStack {
                Text("Edge Depth:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(edgeDepth) px")
                    .font(.caption)
                    .fontWeight(.bold)
                Stepper("", value: $edgeDepth, in: 2...40)
                    .labelsHidden()
                    .disabled(isScanning)
            }
            
            HStack(spacing: 12) {
                Toggle("Top", isOn: $checkTop).disabled(isScanning)
                Toggle("Bottom", isOn: $checkBottom).disabled(isScanning)
                Toggle("Left", isOn: $checkLeft).disabled(isScanning)
                Toggle("Right", isOn: $checkRight).disabled(isScanning)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Action Section
    
    private var actionSection: some View {
        VStack(spacing: 8) {
            if isScanning {
                Button(role: .destructive, action: cancelScan) {
                    Label("Cancel QC Scan", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button(action: startScan) {
                    Label("Start QC Batch Scan", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(videoFiles.isEmpty || RGBColor(hex: hexCode) == nil)
            }
        }
    }
    
    // MARK: - Active Scan Progress View
    
    private var activeScanProgressView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("QC Scan in Progress...", systemImage: "hourglass")
                .font(.title3)
                .fontWeight(.bold)
            
            if let p = progressInfo {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Batch Progress:")
                            .font(.headline)
                        Spacer()
                        Text("File \(p.currentFileIndex) of \(p.totalFiles)")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    }
                    
                    ProgressView(value: Double(p.currentFileIndex - 1) + (Double(p.currentFrame) / Double(max(1, p.totalFramesInFile))), total: Double(p.totalFiles))
                        .progressViewStyle(.linear)
                    
                    Text("Scanning: \(p.currentFileName)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    HStack {
                        Text("Frame: \(p.currentFrame) / \(p.totalFramesInFile)")
                        Spacer()
                        Text(String(format: "Speed: %.0f FPS", p.fps))
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    if p.flaggedVideosCount > 0 {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("\(p.flaggedVideosCount) file(s) flagged with colored lines so far")
                                .font(.caption)
                                .foregroundColor(.red)
                                .fontWeight(.semibold)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(16)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(10)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Results Summary View
    
    private var resultsSummaryView: some View {
        let flagged = scanResults.filter { $0.isFlagged }
        let clean = scanResults.filter { !$0.isFlagged }
        
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("QC Scan Complete")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Scanned \(scanResults.count) video files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                if let reportURL = generatedReportURL {
                    Button(action: { NSWorkspace.shared.open(reportURL) }) {
                        Label("Open HTML Report", systemImage: "safari")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([reportURL]) }) {
                        Label("Finder", systemImage: "folder")
                    }
                    .controlSize(.small)
                }
            }
            
            // Summary Badges
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: flagged.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(flagged.isEmpty ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(flagged.count) Flagged")
                            .fontWeight(.bold)
                        if !flagged.isEmpty {
                            Text("Tagged RED in Finder")
                                .font(.system(size: 9))
                                .foregroundColor(.red.opacity(0.9))
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(flagged.isEmpty ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                .cornerRadius(8)
                
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                    Text("\(clean.count) Passed")
                        .fontWeight(.bold)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.15))
                .cornerRadius(8)
            }
            
            // List of Flagged Files & Glitch Segments
            Text("Glitch Occurrences & Durations:")
                .font(.subheadline)
                .fontWeight(.semibold)
            
            ScrollView {
                VStack(spacing: 10) {
                    if flagged.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.green)
                            Text("All files passed QC! No colored edge lines found.")
                                .font(.callout)
                        }
                        .padding(20)
                    } else {
                        ForEach(flagged) { result in
                            let segments = result.glitchSegments
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "xmark.octagon.fill")
                                        .foregroundColor(.red)
                                    Text(result.fileName)
                                        .font(.callout)
                                        .fontWeight(.bold)
                                    Spacer()
                                    Text("\(segments.count) occurrence(s) • \(result.errorFrames.count) frames")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.15))
                                        .cornerRadius(4)
                                }
                                
                                HStack {
                                    Text("\(result.resolution) • \(String(format: "%.2f", result.fps)) fps")
                                    Spacer()
                                    Label("Red Tagged in Finder", systemImage: "tag.fill")
                                        .foregroundColor(.red)
                                }
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                
                                Divider()
                                
                                // Clean list of continuous glitch segments
                                ForEach(segments.prefix(10)) { seg in
                                    HStack(spacing: 8) {
                                        Text(seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) → \(seg.endTimecode)")
                                            .font(.system(.caption, design: .monospaced))
                                            .fontWeight(.bold)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.15))
                                            .cornerRadius(4)
                                        
                                        Text(seg.frameCount == 1 ? "1 frame" : "\(seg.frameCount) frames (\(String(format: "%.2f", seg.durationSeconds))s)")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                        
                                        Spacer()
                                        
                                        Text("\(seg.edge.rawValue) edge (\(seg.avgThickness)px)")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                        
                                        HStack(spacing: 3) {
                                            Circle()
                                                .fill(Color(red: Double(seg.detectedColor.r)/255, green: Double(seg.detectedColor.g)/255, blue: Double(seg.detectedColor.b)/255))
                                                .frame(width: 8, height: 8)
                                            Text(seg.detectedColor.hexString)
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                
                                if segments.count > 10 {
                                    Text("+ \(segments.count - 10) more occurrences (see full HTML report)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.6))
            Text("Ready to Scan")
                .font(.title3)
                .fontWeight(.bold)
            Text("Select a delivery folder containing video files\nand configure your target hex color to begin QC.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Handlers
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        
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
            
            // Save report text file
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
