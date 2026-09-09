import SwiftUI
import VideoQCLib

extension ContentView {
    
    // MARK: ==================== TAB 3: LINE FINDER ====================
    
    var lineScannerTabView: some View {
        HSplitView {
            // Left Panel: Configuration
            VStack(alignment: .leading, spacing: 18) {
                deliveryAssetsSection(forTab: .lineFinder)
                colorSettingsSection
                if isTargetBlack {
                    blackLineModeSection
                } else if isTargetWhite {
                    whiteLineModeSection
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
    
    var colorSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(num: "02", title: "TARGET ERROR COLOR")
            
            HStack(spacing: 8) {
                // Interactive Color Swatch
                Button(action: openColorPanel) {
                    RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                        .fill(colorFromHex(hexCode))
                        .frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).stroke(borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isScanning)
                .explain("Interactive color swatch: click to open macOS color wheel.", binding: $hoverExplanation)
                
                TextField("#HEX", text: $hexCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(textMain)
                    .padding(6)
                    .foregroundColor(textMain)
                    .studioBox(background: bgSubtle, border: borderLine)
                    .frame(width: 95)
                    .disabled(isScanning)
                    .explain("Hex color value to search for on frame boundaries. Can be edited at all times.", binding: $hoverExplanation)
                
                // Custom Color Button
                Button(action: openColorPanel) {
                    HStack(spacing: 4) {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 9))
                        Text("CUSTOM")
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                    .foregroundColor(isCustomColor ? primaryBtnFg : textMain)
                    .studioBox(background: isCustomColor ? primaryBtnBg : bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                .disabled(isScanning)
                .explain("Opens macOS color wheel / palette to choose any custom color.", binding: $hoverExplanation)
                
                Spacer()
                
                Text("\(Int(tolerancePercentage))% TOL")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(textSubtle)
            }
            
            HStack(spacing: 5) {
                ForEach(colorPresets, id: \.1) { name, code, defaultTol in
                    Button(action: {
                        hexCode = code
                        tolerancePercentage = defaultTol
                    }) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(colorFromHex(code))
                                .frame(width: 8, height: 8)
                                .overlay(RoundedRectangle(cornerRadius: 1).stroke(borderLine, lineWidth: 0.5))
                            Text(name)
                        }
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundColor(hexCode.uppercased() == code ? primaryBtnFg : textMain)
                        .studioBox(background: hexCode.uppercased() == code ? primaryBtnBg : bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .disabled(isScanning)
                    .explain("Sets target color to \(name) (\(code)) with \(Int(defaultTol))% tolerance.", binding: $hoverExplanation)
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
                Slider(value: $tolerancePercentage, in: (isTargetBlack || isTargetWhite) ? 1...15 : 5...50, step: 1)
                    .tint(primaryBtnBg)
                    .disabled(isScanning)
                    .explain("Color match sensitivity. Lower values match strictly; higher values match broader shades.", binding: $hoverExplanation)
            }
        }
    }
    
    var blackLineModeSection: some View {
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
                .explain("Amplifies shadow levels 10X to avoid false flags on naturally dark scenes.", binding: $hoverExplanation)
            
            Toggle("IGNORE FULL-FRAME BLACK SLATES", isOn: $ignoreFullBlackFrames)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .toggleStyle(StudioToggleStyle(isLight: isLightMode))
                .disabled(isScanning)
                .explain("Skips solid black frames such as slates, head countdowns, and scene fades.", binding: $hoverExplanation)
        }
        .padding(10)
        .studioBox(background: bgCardSubtle, border: borderStrong)
    }
    
    var whiteLineModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HIGH-KEY / WHITE COVE OPTIMIZATION")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .foregroundColor(textMain)
                    .tracking(0.5)
                Spacer()
                Text("[ACTIVE]")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(textMain)
            }
            
            Toggle("HIGHLIGHT EXPANSION FILTER", isOn: $enableHighlightExpansion)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .toggleStyle(StudioToggleStyle(isLight: isLightMode))
                .disabled(isScanning)
                .explain("Amplifies highlight separation so natural white cove backdrops and studio lighting are not flagged.", binding: $hoverExplanation)
            
            Toggle("IGNORE FULL-FRAME WHITE SLATES", isOn: $ignoreFullWhiteFrames)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .toggleStyle(StudioToggleStyle(isLight: isLightMode))
                .disabled(isScanning)
                .explain("Skips solid white logo cards, slates, and white flash transitions.", binding: $hoverExplanation)
        }
        .padding(10)
        .studioBox(background: bgCardSubtle, border: borderStrong)
    }
    
    var edgeSettingsSection: some View {
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
                    .explain("Depth in pixels from outer frame boundaries to inspect for colored edge lines (all borders).", binding: $hoverExplanation)
            }
            
            Toggle("SCAN FULL SCREEN (SPLIT SCREENS)", isOn: $scanFullScreen)
                .toggleStyle(StudioToggleStyle(isLight: isLightMode))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(textMain)
                .disabled(isScanning)
                .explain("Inspects the entire frame for internal dividing line artifacts and split-screen seams.", binding: $hoverExplanation)
        }
    }
    
    var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(num: "04", title: "EXECUTION")
            
            if isScanning {
                Button(action: cancelScan) {
                    HStack(spacing: 7) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                        SlotText(
                            "CANCEL AUDIT",
                            mode: .character,
                            direction: .down,
                            font: .system(size: 11, weight: .heavy, design: .monospaced),
                            foregroundColor: .white,
                            tracking: 0.5,
                            stagger: 0.015,
                            rollDistance: 13
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .foregroundColor(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(alertRed)
                            .shadow(color: alertRed.opacity(0.35), radius: 8, x: 0, y: 0)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .explain("Aborts the active video scan in progress.", binding: $hoverExplanation)
            } else {
                let isReady = !videoFiles.isEmpty && RGBColor(hex: hexCode) != nil
                Button(action: startScan) {
                    HStack(spacing: 7) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 11, weight: .bold))
                            .scaleEffect(isAuditBtnHovered && isReady ? 1.08 : 1.0)
                        
                        SlotText(
                            "START LINE QC AUDIT",
                            mode: .character,
                            direction: .up,
                            font: .system(size: 11, weight: .heavy, design: .monospaced),
                            foregroundColor: !isReady ? textMuted : (isLightMode ? Color.white : Color(white: 0.08)),
                            tracking: 0.5,
                            stagger: 0.015,
                            rollDistance: 13,
                            trigger: isAuditBtnHovered
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .foregroundColor(!isReady ? textMuted : (isLightMode ? Color.white : Color(white: 0.08)))
                    .background(
                        Group {
                            if !isReady {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(bgSubtle.opacity(0.6))
                            } else if isLightMode {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(
                                        LinearGradient(
                                            colors: isAuditBtnHovered
                                                ? [Color(white: 0.20), Color(white: 0.12)]
                                                : [Color(white: 0.14), Color(white: 0.08)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .shadow(color: Color.black.opacity(isAuditBtnHovered ? 0.25 : 0.10), radius: isAuditBtnHovered ? 6 : 3, x: 0, y: 1)
                            } else {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(
                                        LinearGradient(
                                            colors: isAuditBtnHovered
                                                ? [Color.white, Color(white: 0.92)]
                                                : [Color(white: 0.95), Color(white: 0.88)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .shadow(color: isAuditBtnHovered ? Color.white.opacity(0.18) : Color.clear, radius: 8, x: 0, y: 0)
                            }
                        }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(
                                !isReady
                                    ? borderLine.opacity(0.5)
                                    : (isLightMode ? borderStrong.opacity(0.6) : Color.white.opacity(isAuditBtnHovered ? 0.9 : 0.5)),
                                lineWidth: 1
                            )
                    )
                    .animation(.spring(response: 0.24, dampingFraction: 0.8), value: isAuditBtnHovered)
                }
                .buttonStyle(.plain)
                .disabled(!isReady)
                .onHover { hovering in
                    isAuditBtnHovered = hovering
                }
                .explain("Starts frame-by-frame edge analysis across all files in the batch.", binding: $hoverExplanation)
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
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .studioBox(background: bgSubtle, border: borderLine)
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
    
    var resultsSummaryView: some View {
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
                    // Primary Action: Google Sheets
                    Button(action: { openScanReportInGoogleSheets() }) {
                        HStack(spacing: 5) {
                            Text("[ GOOGLE SHEETS ]")
                                .font(.system(size: 11, weight: .black, design: .monospaced))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(primaryBtnFg)
                        .studioBox(background: primaryBtnBg, border: primaryBtnBg)
                    }
                    .buttonStyle(.plain)
                    .explain("Copies glitch report as spreadsheet data and opens Google Sheets ready to paste (⌘V).", binding: $hoverExplanation)
                    
                    // Consolidated Export Dropdown
                    Menu {
                        Button(action: { exportScanHTML() }) {
                            Label("Save HTML Glitch Report...", systemImage: "safari")
                        }
                        Button(action: { exportScanCSV() }) {
                            Label("Save CSV File...", systemImage: "doc.text")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("EXPORT")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(isLightMode ? Color.black : Color.white)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(isLightMode ? Color.black : Color.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .foregroundColor(isLightMode ? Color.black : Color.white)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundColor(isLightMode ? Color.black : Color.white)
                    .fixedSize()
                    .explain("Export options: Save interactive HTML glitch report or CSV spreadsheet.", binding: $hoverExplanation)
                }
            }
            
            HStack(spacing: 12) {
                statBox(title: "TOTAL SCANNED", val: String(format: "%02d", scanResults.count))
                statBox(title: "FLAGGED FILES", val: String(format: "%02d", flagged.count), isRed: !flagged.isEmpty)
                statBox(title: "PASSED FILES", val: String(format: "%02d", clean.count), isPositive: !clean.isEmpty)
                statBox(title: "GLITCH SEGMENTS", val: String(format: "%02d", totalSegments), isRed: totalSegments > 0)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if flagged.isEmpty {
                        VStack(spacing: 8) {
                            Text("STATUS // ALL DELIVERIES PASSED")
                                .font(.system(size: 16, weight: .black, design: .monospaced))
                                .foregroundColor(accentPositive)
                            Text("NO COLORED EDGE LINES OR MATTE ARTIFACTS DETECTED.")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(40)
                        .studioBox(background: bgPanel, border: borderLine)
                    } else {
                        ForEach(flagged) { result in
                            let segments = result.glitchSegments
                            VStack(alignment: .leading, spacing: 0) {
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
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
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
                    }
                }
            }
        }
        .padding(28)
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
                
                Text("\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX)")
                    .frame(width: 140, alignment: .leading)
                    .fontWeight(.bold)
                    .foregroundColor(textMain)
                
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
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(textMain)
                }
                .frame(width: 75, alignment: .trailing)
                
                // Jump to Player Inspect Action Button
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                    Text("INSPECT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundColor(primaryBtnFg)
                .studioBox(background: primaryBtnBg, border: primaryBtnBg)
                .frame(width: 75, alignment: .trailing)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .explain("Click to jump immediately to \(seg.startTimecode) in the Player tab to inspect this glitch frame.", binding: $hoverExplanation)
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
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(alertRed)
                Text("FINDER RED TAG APPLIED")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
            }
        }
        .padding(14)
        .background(bgCardHeader)
        .contentShape(Rectangle())
        .explain(result.fileURL.path, binding: $hoverExplanation)
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
            
            Text("STATUS // READY TO AUDIT")
                .font(.system(size: 32, weight: .black, design: .default))
                .foregroundColor(textMain)
                .tracking(1.0)
            
            Text("CHOOSE A DELIVERY FOLDER OR VIDEO FILES ON THE LEFT TO BEGIN FRAME-BY-FRAME ANALYSIS.\nDETECTS COLORED EDGE LINES.")
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
}
