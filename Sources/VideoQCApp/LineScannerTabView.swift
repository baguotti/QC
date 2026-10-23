import SwiftUI
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 3: GLITCH FINDER ====================
    
    var lineScannerTabView: some View {
        HSplitView {
            // Left Panel: Configuration
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    deliveryAssetsSection(forTab: .lineFinder)
                    lineCheckSection
                    frameCheckSection
                    fullCheckSection
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 440)
            .background(bgPanel)
            
            // Right Panel: Results / Live Progress / Empty State
            VStack(alignment: .leading, spacing: 0) {
                if scannerState.isFrameChecking {
                    frameCheckProgressView
                } else if scannerState.isScanning {
                    activeScanProgressView
                } else if hasLineResults || hasFrameCheckResults {
                    checkResultsView
                } else {
                    emptyStateView
                }
            }
            // Fill the rest: when the shown view is narrow (a progress view before its first update) the split view would
            // otherwise hand the space to the left panel, whose capped content then jumps to the middle.
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bgMain)
        }
    }
    
    // MARK: - Left Panel Building Blocks
    
    /// A group of settings rows separated by hairlines.
    func checkCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
    }
    
    func checkRow<Content: View>(_ label: String, divider: Bool = true, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if divider { Rectangle().fill(borderLine).frame(height: 1) }
            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundColor(textMuted)
                    .tracking(0.5)
                content()
            }
            .padding(.vertical, 11)
        }
    }
    
    func checkToggle(_ title: String, isOn: Binding<Bool>, disabled: Bool = false, help: String) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(StudioToggleStyle(isLight: isLightMode))
            .font(.ui(size: 10, weight: .semibold))
            .foregroundColor(textMain)
            .disabled(scannerState.isScanning || disabled)
            .explain(help)
    }
    
    /// Flat full-width run button (primary colours, no glow) shared by both checks.
    func runButton(_ title: String, icon: String, isReady: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundColor(isReady ? primaryBtnFg : textMuted)
            .background(RoundedRectangle(cornerRadius: 5).fill(isReady ? primaryBtnBg : bgSubtle.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isReady ? primaryBtnBg : borderLine.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isReady)
        .explain(help)
    }
    
    func stopButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(0.5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .foregroundColor(.white)
            .background(RoundedRectangle(cornerRadius: 5).fill(alertRed))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .explain(help)
    }
    
    // MARK: - 02 // LINE CHECK
    
    var lineCheckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "02", title: "LINE CHECK")
            
            checkCard {
                checkRow("TARGET COLOUR", divider: false) {
                    HStack(spacing: 8) {
                        Button(action: { scannerState.openColorPanel() }) {
                            RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                                .fill(scannerState.colorFromHex(scannerState.hexCode))
                                .frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).stroke(borderStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(scannerState.isScanning || scannerState.anyColor)
                        .explain("Click to pick any colour from the macOS colour wheel.")
                        
                        TextField("#HEX", text: $scannerState.hexCode)
                            .textFieldStyle(.plain)
                            .font(.ui(size: 12, weight: .semibold))
                            .foregroundColor(textMain)
                            .padding(.horizontal, 7)
                            .frame(width: 92, height: 26)
                            .studioBox(background: bgSubtle, border: borderLine)
                            .disabled(scannerState.isScanning || scannerState.anyColor)
                            .explain("Hex value of the line colour to look for.")
                        
                        Spacer()
                        if scannerState.anyColor {
                            Text("ANY COLOUR")
                                .font(.ui(size: 9, weight: .semibold))
                                .foregroundColor(accentBlue)
                        }
                    }
                    HStack(spacing: 5) {
                        ForEach(scannerState.colorPresets, id: \.1) { name, code in
                            let isOn = scannerState.hexCode.uppercased() == code
                            Button(action: { scannerState.hexCode = code }) {
                                HStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(scannerState.colorFromHex(code))
                                        .frame(width: 8, height: 8)
                                        .overlay(RoundedRectangle(cornerRadius: 1).stroke(borderLine, lineWidth: 0.5))
                                    Text(name)
                                }
                                .font(.ui(size: 9, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .foregroundColor(isOn ? primaryBtnFg : textMain)
                                .studioBox(background: isOn ? primaryBtnBg : bgSubtle, border: borderLine)
                            }
                            .buttonStyle(.plain)
                            .disabled(scannerState.isScanning || scannerState.anyColor)
                            .explain("Sets the target colour to \(name) (\(code)).")
                        }
                    }
                    .opacity(scannerState.anyColor ? 0.5 : 1)
                }
                
                checkRow("SENSITIVITY") {
                    HStack(spacing: 10) {
                        Slider(value: $scannerState.sensitivityPercentage, in: 0...100, step: 5)
                            .tint(primaryBtnBg)
                            .disabled(scannerState.isScanning || scannerState.anyColor)
                            .explain("How faint a line may be. Higher values also flag semi-transparent and blended lines; faint lines are only flagged when they hold for 6 frames.")
                        Text("\(Int(scannerState.sensitivityPercentage))%")
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(textMain)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                
                checkRow("DETECTION") {
                    checkToggle("ALSO FLAG OFF-COLOUR LINES", isOn: $scannerState.reportOffColorLines, disabled: scannerState.anyColor,
                                help: "Also report lines of another colour than the target (e.g. a grey edge column), when they persist for 6+ frames. Listed separately as OFF-COLOUR.")
                    checkToggle("ANY COLOUR (IGNORE TARGET)", isOn: $scannerState.anyColor,
                                help: "Flags solid lines of any colour that stand out from the picture next to them, instead of only the target colour.")
                    checkToggle("SPLIT-SCREEN SEAMS (FULL FRAME)", isOn: $scannerState.scanFullScreen,
                                help: "Also inspects the whole frame for split-screen seams and internal dividing lines.")
                    HStack {
                        Text("EDGE DEPTH")
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(textMain)
                        Spacer()
                        Text("\(scannerState.edgeDepth) PX")
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(textMain)
                        Stepper("", value: $scannerState.edgeDepth, in: 2...40)
                            .labelsHidden()
                            .controlSize(.small)
                            .disabled(scannerState.isScanning)
                    }
                    .explain("How far in from each frame edge to look for lines, in pixels.")
                }
                
                if scannerState.isTargetBlack && !scannerState.anyColor {
                    checkRow("DARK SCENES") {
                        checkToggle("SHADOW EXPANSION", isOn: $scannerState.enableExposureBoost,
                                    help: "Expands shadow levels so a render-black line stands apart from naturally dark picture.")
                        checkToggle("IGNORE FULL-FRAME BLACK", isOn: $scannerState.ignoreFullBlackFrames,
                                    help: "Skips solid black frames such as slates, countdowns and fades.")
                    }
                } else if scannerState.isTargetWhite && !scannerState.anyColor {
                    checkRow("BRIGHT SCENES") {
                        checkToggle("HIGHLIGHT EXPANSION", isOn: $scannerState.enableHighlightExpansion,
                                    help: "Expands highlight levels so white cove backdrops and studio lighting are not flagged.")
                        checkToggle("IGNORE FULL-FRAME WHITE", isOn: $scannerState.ignoreFullWhiteFrames,
                                    help: "Skips solid white logo cards, slates and white flashes.")
                    }
                }
                
                checkRow("RESULTS") {
                    checkToggle("MARK FLAGGED FILES IN FINDER", isOn: $scannerState.tagInFinder,
                                help: "Applies a red Finder tag to every file with line glitches.")
                }
            }
            
            if scannerState.isScanning {
                stopButton(scannerState.isCancelling ? "STOPPING..." : "STOP LINE CHECK", help: "Stops the line check in progress.", action: cancelScan)
            } else {
                runButton("RUN LINE CHECK", icon: "viewfinder",
                          isReady: !videoFiles.isEmpty && RGBColor(hex: scannerState.hexCode) != nil && !scannerState.isFrameChecking,
                          help: "Checks every frame of every video in the batch for edge lines and split-screen seams.", action: { startScan() })
            }
        }
    }
    
    var activeScanProgressView: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("SCANNING IN PROGRESS")
                    .font(.system(size: 28, weight: .heavy, design: .default))
                    .foregroundColor(textMain)
                    .tracking(1.0)
                Spacer()
                Text("PROCESSING")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(textMain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            
            if let p = scannerState.progressInfo {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CURRENT ASSET")
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(textMuted)
                        Text(p.currentFileName.uppercased())
                            .font(.system(size: 18, weight: .heavy, design: .monospaced))
                            .foregroundColor(textMain)
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 20) {
                        statItem(label: "BATCH PROGRESS", val: "FILE \(String(format: "%02d", p.currentFileIndex)) / \(String(format: "%02d", p.totalFiles))", width: 140)
                        statItem(label: "FRAME INDEX", val: "\(p.currentFrame) / \(p.totalFramesInFile)", width: 140)
                        statItem(label: "SPEED", val: "\(String(format: "%.0f", p.fps)) FPS", width: 110)
                        statItem(label: "FLAGGED", val: "\(p.flaggedVideosCount)", width: 80, isAlert: p.flaggedVideosCount > 0)
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
                .studioBox(background: bgPanel, border: borderLine)
            }
            Spacer()
        }
        .padding(28)
    }
    
    private var hasLineResults: Bool { !scannerState.scanResults.isEmpty }
    private var hasFrameCheckResults: Bool { !scannerState.frameCheckResults.isEmpty || scannerState.wasFrameCheckCancelled }
    
    /// One page: Line Check results, then Frame Check results (whichever were run).
    var checkResultsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if hasLineResults {
                    lineResultsSection
                }
                if hasLineResults && hasFrameCheckResults {
                    Rectangle()
                        .fill(borderStrong)
                        .frame(height: 2)
                        .padding(.vertical, 24)
                }
                if hasFrameCheckResults {
                    frameResultsSection
                }
            }
            .padding(28)
        }
    }
    
    private func resultsSectionTitle<Trailing: View>(_ title: String, status: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 28, weight: .black, design: .default))
                    .foregroundColor(textMain)
                    .tracking(1.0)
                Text(status)
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(textMuted)
            }
            Spacer()
            trailing()
        }
        .padding(.bottom, 4)
    }
    
    private func resultsStatus(count: Int, cancelled: Bool) -> String {
        "\(cancelled ? "STOPPED" : "COMPLETE") // \(count) VIDEOS ANALYZED\(cancelled ? " (PARTIAL)" : "")"
    }
    
    private var lineExportMenu: some View {
        Menu {
            Button(action: { openScanReportInGoogleSheets() }) {
                Label("Copy for Google Sheets", systemImage: "tablecells")
            }
            Divider()
            Button(action: { exportScanHTML() }) {
                Label("Save HTML Glitch Report...", systemImage: "safari")
            }
            Button(action: { exportScanCSV() }) {
                Label("Save CSV File...", systemImage: "doc.text")
            }
        } label: {
            HStack(spacing: 5) {
                Text("EXPORT")
                    .font(.ui(size: 11, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .foregroundColor(textMain)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .explain("Export the line report: copy for Google Sheets (paste with ⌘V), or save an HTML report or CSV file.")
    }
    
    @ViewBuilder
    private var lineResultsSection: some View {
        let flagged = scannerState.scanResults.filter { $0.isFlagged }
        let clean = scannerState.scanResults.count - flagged.count
        let totalSegments = flagged.reduce(0) { $0 + $1.glitchSegments.count }
        
        resultsSectionTitle("LINE CHECK", status: resultsStatus(count: scannerState.scanResults.count, cancelled: scannerState.wasScanCancelled)) {
            lineExportMenu
        }
        HStack(spacing: 12) {
            statBox(title: "TOTAL SCANNED", val: String(format: "%02d", scannerState.scanResults.count))
            statBox(title: "FLAGGED FILES", val: String(format: "%02d", flagged.count), isRed: !flagged.isEmpty)
            statBox(title: "PASSED FILES", val: String(format: "%02d", clean), isPositive: clean > 0)
            statBox(title: "GLITCH SEGMENTS", val: String(format: "%02d", totalSegments), isRed: totalSegments > 0)
        }
        if flagged.isEmpty {
            VStack(spacing: 8) {
                Text("STATUS // ALL DELIVERIES PASSED")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(accentPositive)
                Text("NO COLORED EDGE LINES OR MATTE ARTIFACTS DETECTED.")
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundColor(textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
            .studioBox(background: bgPanel, border: borderLine)
        } else {
            ForEach(flagged) { result in
                lineResultCard(result)
            }
        }
    }
    
    private func lineResultCard(_ result: VideoQCResult) -> some View {
        let segments = result.glitchSegments
        return VStack(alignment: .leading, spacing: 0) {
            flaggedResultHeader(result: result, segmentsCount: segments.count)
            
            Rectangle().fill(borderLine).frame(height: 1)
            
            HStack(spacing: 8) {
                Text("#").frame(width: 25, alignment: .leading)
                Text("FRAME").frame(width: 76, alignment: .leading)
                Text("LOCATION").frame(width: 140, alignment: .leading)
                Text("TIMECODE RANGE").frame(width: 155, alignment: .leading)
                Text("DURATION").frame(width: 130, alignment: .leading)
                Text("FRAMES").frame(width: 75, alignment: .leading)
                Spacer()
                Text("COLOR").frame(width: 75, alignment: .trailing)
                Text("PLAYER").frame(width: 75, alignment: .trailing)
            }
            .font(.ui(size: 9, weight: .semibold))
            .foregroundColor(textMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(bgCardSubtle)
            
            Rectangle().fill(borderLine).frame(height: 1)
            
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                glitchTableRow(result: result, seg: seg, idx: idx)
                if idx < segments.count - 1 {
                    Rectangle().fill(borderLine.opacity(0.6)).frame(height: 1)
                }
            }
        }
        .studioBox(background: bgPanel, border: borderLine)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                .stroke(alertRed, lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func glitchTableRow(result: VideoQCResult, seg: GlitchSegment, idx: Int) -> some View {
        Button(action: {
            jumpToGlitchInPlayer(fileURL: result.fileURL, frameIndex: seg.startFrame)
        }) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", idx + 1))
                    .frame(width: 25, alignment: .leading)
                    .foregroundColor(textMuted)
                
                GlitchThumbnailView(
                    fileURL: result.fileURL,
                    frameIndex: seg.startFrame,
                    fps: result.fps,
                    timecode: seg.startTimecode,
                    edge: seg.edge,
                    detectedColor: seg.detectedColor,
                    width: 72,
                    height: 40
                )
                .frame(width: 76, alignment: .leading)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX)")
                        .fontWeight(.bold)
                        .foregroundColor(textMain)
                    if let detail = seg.locationDetail {
                        Text(detail.uppercased())
                            .font(.ui(size: 8, weight: .semibold))
                            .foregroundColor(textMuted)
                    }
                    if seg.isOffColor {
                        Text("OFF-COLOUR")
                            .font(.ui(size: 8, weight: .semibold))
                            .foregroundColor(textMuted)
                            .help("A line of another colour than the target, flagged because it persists")
                    }
                }
                .frame(width: 140, alignment: .leading)
                
                Text(seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) -> \(seg.endTimecode)")
                    .frame(width: 155, alignment: .leading)
                    .fontWeight(.heavy)
                    .foregroundColor(textMain)
                
                Text(seg.frameCount == 1 ? "1 FRAME (0.04S)" : "\(seg.frameCount) FRAMES (\(String(format: "%.2f", seg.durationSeconds))S)")
                    .frame(width: 130, alignment: .leading)
                    .foregroundColor(textSubtle)
                
                Text("[\(seg.startFrame == seg.endFrame ? "\(seg.startFrame)" : "\(seg.startFrame)-\(seg.endFrame)")]")
                    .frame(width: 75, alignment: .leading)
                    .foregroundColor(textMuted)
                
                Spacer()
                
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(Color(red: Double(seg.detectedColor.r)/255, green: Double(seg.detectedColor.g)/255, blue: Double(seg.detectedColor.b)/255))
                        .frame(width: 10, height: 10)
                        .border(borderStrong, width: 1)
                    Text(seg.detectedColor.hexString.uppercased())
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(textMain)
                }
                .frame(width: 75, alignment: .trailing)
                
                // Jump to Player Inspect Action Button
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("INSPECT")
                        .font(.ui(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundColor(primaryBtnFg)
                .studioBox(background: primaryBtnBg, border: primaryBtnBg)
                .frame(width: 75, alignment: .trailing)
            }
            .font(.ui(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .explain("Click to jump immediately to \(seg.startTimecode) in the Player tab to inspect this glitch frame.")
    }
    
    private func flaggedResultHeader(result: VideoQCResult, segmentsCount: Int) -> some View {
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
                Text("[\(segmentsCount) OCCURRENCE(S) // \(result.errorFrames.count) FRAMES]")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(alertRed)
                if scannerState.lastScanTagInFinder {
                    Text("FINDER RED TAG APPLIED")
                        .font(.ui(size: 8, weight: .semibold))
                        .foregroundColor(textMuted)
                }
            }
        }
        .padding(14)
        .background(bgCardHeader)
        .contentShape(Rectangle())
        .explain(result.fileURL.path)
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.fileURL.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
            }
        }
    }
    
    var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            
            Text("STATUS // READY TO CHECK")
                .font(.system(size: 32, weight: .black, design: .default))
                .foregroundColor(textMain)
                .tracking(1.0)
            
            Text("CHOOSE A DELIVERY FOLDER OR VIDEO FILES ON THE LEFT, THEN RUN A CHECK.\nLINE CHECK: EDGE LINES AND SPLIT-SCREEN SEAMS. FRAME CHECK: FRAME-RATE MISMATCH, FLASH FRAMES AND MEDIA OFFLINE.")
                .font(.ui(size: 12, weight: .medium))
                .foregroundColor(textMuted)
                .lineSpacing(4)
            
            Spacer()
        }
        .padding(40)
    }
}

// MARK: - Frame Check

extension ContentView {
    
    private var frameCheckVideoCount: Int { videoFiles.filter { QCUtilities.mediaKind(of: $0) == .video }.count }
    
    var frameCheckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "03", title: "FRAME CHECK")
            
            checkCard {
                checkRow("WHAT IT FINDS", divider: false) {
                    Text("Frame-rate mismatch (e.g. 23.976 fps material exported at 25 fps), flash frames (stray black or solid frames mid-edit) and Media Offline frames. One fast pass per video.")
                        .font(.ui(size: 10))
                        .foregroundColor(textSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            if scannerState.isFrameChecking {
                stopButton(scannerState.wasFrameCheckCancelled ? "STOPPING..." : "STOP FRAME CHECK",
                           help: "Stops the frame check; files already checked keep their results.") {
                    scannerState.cancelFrameCheck()
                }
            } else {
                runButton("RUN FRAME CHECK", icon: "waveform.path.ecg",
                          isReady: frameCheckVideoCount > 0 && !scannerState.isScanning,
                          help: "Checks every video in the batch (fast, low resolution) for frame-rate mismatch, flash frames and Media Offline.") {
                    scannerState.startFrameCheck(videoFiles: videoFiles)
                }
            }
        }
    }
    
    var fullCheckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "04", title: "FULL CHECK")
            if scannerState.isFullCheck {
                stopButton("STOP FULL CHECK", help: "Stops the running check and skips the rest; finished files keep their results.",
                           action: cancelFullCheck)
            } else {
                runButton("RUN FULL CHECK", icon: "checklist",
                          isReady: frameCheckVideoCount > 0 && RGBColor(hex: scannerState.hexCode) != nil
                              && !scannerState.isScanning && !scannerState.isFrameChecking,
                          help: "Runs the Line Check, then the Frame Check, on every video with the settings above.",
                          action: startFullCheck)
            }
        }
    }
    
    var frameCheckProgressView: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("CHECKING FRAMES")
                .font(.system(size: 28, weight: .heavy))
                .foregroundColor(textMain)
                .tracking(1.0)
            if let p = scannerState.frameCheckProgress {
                VStack(alignment: .leading, spacing: 16) {
                    Text(p.fileName.uppercased())
                        .font(.system(size: 18, weight: .heavy, design: .monospaced))
                        .foregroundColor(textMain)
                        .lineLimit(1)
                    HStack(spacing: 20) {
                        statItem(label: "BATCH PROGRESS", val: "FILE \(String(format: "%02d", p.fileIndex)) / \(String(format: "%02d", p.totalFiles))", width: 140)
                        statItem(label: "FRAME", val: "\(p.frame) / \(p.totalFrames)", width: 140)
                        statItem(label: "SPEED", val: "\(String(format: "%.0f", p.speed)) FPS", width: 110)
                    }
                    GeometryReader { geo in
                        let ratio = (Double(p.fileIndex - 1) + Double(p.frame) / Double(max(1, p.totalFrames))) / Double(max(1, p.totalFiles))
                        ZStack(alignment: .leading) {
                            Rectangle().fill(borderLine).frame(height: 4)
                            Rectangle().fill(primaryBtnBg).frame(width: geo.size.width * CGFloat(min(1, max(0, ratio))), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(24)
                .studioBox(background: bgPanel, border: borderLine)
            }
            Spacer()
        }
        .padding(28)
    }
    
    @ViewBuilder
    private var frameResultsSection: some View {
        let results = scannerState.frameCheckResults
        let flagged = results.filter(\.isFlagged)
        
        resultsSectionTitle("FRAME CHECK", status: resultsStatus(count: results.count, cancelled: scannerState.wasFrameCheckCancelled)) {
            EmptyView()
        }
        HStack(spacing: 12) {
            statBox(title: "TOTAL SCANNED", val: String(format: "%02d", results.count))
            statBox(title: "FPS MISMATCH", val: String(format: "%02d", results.filter { $0.mismatch != nil }.count),
                    isRed: results.contains { $0.mismatch != nil })
            statBox(title: "FLASH / OFFLINE", val: String(format: "%02d", results.filter { !$0.flashFrames.isEmpty || !$0.offline.isEmpty }.count),
                    isRed: results.contains { !$0.flashFrames.isEmpty || !$0.offline.isEmpty })
            statBox(title: "CLEAN", val: String(format: "%02d", results.count - flagged.count), isPositive: results.count > flagged.count)
        }
        if flagged.isEmpty {
            VStack(spacing: 8) {
                Text("STATUS // ALL VIDEOS CLEAN")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundColor(accentPositive)
                Text("NO FRAME-RATE MISMATCH, FLASH FRAMES OR MEDIA OFFLINE DETECTED.")
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundColor(textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(40)
            .studioBox(background: bgPanel, border: borderLine)
        } else {
            ForEach(flagged) { result in
                frameCheckResultCard(result)
            }
        }
    }
    
    private struct FrameCheckRow: Identifiable {
        let id: String
        let kind: String
        let what: String
        let detail: String
        let frame: Int
    }
    
    private func frameCheckRows(_ result: FrameCheckResult) -> [FrameCheckRow] {
        var rows: [FrameCheckRow] = []
        if let m = result.mismatch {
            rows.append(FrameCheckRow(id: "mismatch", kind: "FPS MISMATCH", what: m.title, detail: m.pattern, frame: m.firstFrame))
        }
        for run in result.offline {
            let seconds = Double(run.count) / max(1, result.fps)
            rows.append(FrameCheckRow(id: "offline\(run.start)", kind: "MEDIA OFFLINE", what: run.timecode,
                                      detail: "\(run.count) frame\(run.count == 1 ? "" : "s") (\(String(format: "%.1f", seconds)) s)", frame: run.start))
        }
        for run in result.flashFrames {
            rows.append(FrameCheckRow(id: "flash\(run.start)", kind: "FLASH FRAME", what: run.timecode,
                                      detail: "\(run.detail), \(run.count) frame\(run.count == 1 ? "" : "s")", frame: run.start))
        }
        return rows
    }
    
    private func frameCheckResultCard(_ result: FrameCheckResult) -> some View {
        let rows = frameCheckRows(result)
        let shown = Array(rows.prefix(12))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.fileName.uppercased())
                        .font(.system(size: 14, weight: .heavy, design: .monospaced))
                        .foregroundColor(textMain)
                    Text("\(FrameCheckAnalyzer.rateLabel(result.fps).uppercased()) // \(result.totalFrames) FRAMES")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                Spacer()
                Text(result.verdict.uppercased())
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(alertRed)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 320, alignment: .trailing)
            }
            .padding(14)
            .background(bgCardHeader)
            .explain(result.fileURL.path)
            
            Rectangle().fill(borderLine).frame(height: 1)
            ForEach(Array(shown.enumerated()), id: \.element.id) { idx, row in
                Button(action: { jumpToGlitchInPlayer(fileURL: result.fileURL, frameIndex: row.frame) }) {
                    HStack(spacing: 8) {
                        Text(row.kind).frame(width: 120, alignment: .leading).fontWeight(.bold).foregroundColor(textMain)
                        Text(row.what).frame(width: 140, alignment: .leading).fontWeight(.heavy).foregroundColor(textMain)
                        Text(row.detail).lineLimit(1).foregroundColor(textSubtle)
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                            Text("INSPECT").font(.ui(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .foregroundColor(primaryBtnFg)
                        .studioBox(background: primaryBtnBg, border: primaryBtnBg)
                    }
                    .font(.ui(size: 11))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .explain(row.kind == "FPS MISMATCH"
                         ? "Open the first frame of the pattern in the Player (step with ← → to see it)."
                         : "Open \(row.what) in the Player.")
                if idx < shown.count - 1 { Rectangle().fill(borderLine.opacity(0.6)).frame(height: 1) }
            }
            if rows.count > shown.count {
                Text("+ \(rows.count - shown.count) MORE")
                    .font(.ui(size: 9, weight: .semibold))
                    .foregroundColor(textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .studioBox(background: bgPanel, border: borderLine)
        .overlay(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).stroke(alertRed, lineWidth: 1))
    }
}
