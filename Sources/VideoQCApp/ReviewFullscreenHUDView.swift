import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VideoQCLib

typealias ReviewFullscreenHUDView = FullscreenPlayerView

// MARK: - Dedicated Studio Fullscreen Player View

struct FullscreenPlayerView: View {
    @ObservedObject var engine: PlayerEngine
    var scanResults: [VideoQCResult]
    var videoFiles: [URL] = []
    var isLightMode: Bool = false
    var onExit: () -> Void
    var onJumpNext: () -> Void
    var onJumpPrev: () -> Void
    var onAddNote: (() -> Void)? = nil
    var onExportScreenshot: ((ScreenshotPreset) -> Void)? = nil
    
    @State private var showControls: Bool = true
    @State private var isHoveringControls: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var accentPositive: Color { palette.accentPositive }
    private var accentSlotB: Color { palette.accentSlotB }
    private var alertRed: Color { palette.alertRed }
    private var accentBlue: Color { palette.accentBlue }
    
    var body: some View {
        ZStack {
            (isLightMode ? Color(white: 0.94) : Color.black)
                .ignoresSafeArea()
            
            // Fullscreen Video Viewport
            if engine.activeURL != nil {
                VideoViewportView(
                    engine: engine,
                    isLightMode: isLightMode,
                    allowScrollZoom: true,
                    onSingleClick: {
                        engine.togglePlayPause()
                        userDidInteract()
                    },
                    onDoubleClick: {
                        onExit()
                    }
                )
                .ignoresSafeArea()
            }
            
            // Floating Overlay Controls
            if showControls {
                VStack(spacing: 0) {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    
                    Spacer()
                    
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                userDidInteract()
            case .ended:
                break
            }
        }
        .onAppear {
            userDidInteract()
        }
        .onDisappear {
            hideTask?.cancel()
        }
    }
    
    private func userDidInteract() {
        if !showControls {
            withAnimation(.easeInOut(duration: 0.15)) {
                showControls = true
            }
        }
        
        hideTask?.cancel()
        if engine.isPlaying && !isHoveringControls {
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled && engine.isPlaying && !isHoveringControls {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showControls = false
                    }
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }
    
    // MARK: - Top Bar
    
    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            if engine.slotB.url != nil {
                Spacer()
                
                // Centered Comparison Controls Toolbar
                PlayerComparisonBar(
                    engine: engine,
                    isLightMode: isLightMode,
                    onInteraction: { userDidInteract() }
                )
                
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.activeFileName.isEmpty ? "NO ACTIVE ASSET" : engine.activeFileName.uppercased())
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(palette.textMain)
                        .lineLimit(1)
                    
                    if !engine.activeResolution.isEmpty {
                        Text("\(engine.activeResolution) // \(String(format: "%.1f", engine.activeFps)) FPS // \(engine.activeCodec)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMuted)
                    }
                }
                
                Spacer()
                
                // Compare B selector in Fullscreen
                Menu {
                    let candidateFiles = videoFiles.filter { $0 != engine.slotA.url }
                    if !candidateFiles.isEmpty {
                        Section("Queue Deliverables") {
                            ForEach(candidateFiles, id: \.self) { file in
                                Button(file.lastPathComponent) {
                                    engine.loadVideo(url: file, into: .slotB, autoplay: true)
                                    userDidInteract()
                                }
                            }
                        }
                        Divider()
                    }
                    Button("Open Compare File from Disk...") {
                        openCompareFileInFullscreen()
                    }
                } label: {
                    HStack(spacing: StudioTheme.scale(5)) {
                        Image(systemName: "square.split.2x1")
                            .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                        Text("[ + COMPARE (B) ]")
                            .font(.system(size: StudioTheme.scaleFont(11), weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, StudioTheme.scale(10))
                    .padding(.vertical, StudioTheme.scale(6))
                    .background(palette.bgPanel.opacity(0.85))
                    .foregroundColor(accentSlotB)
                    .border(accentSlotB.opacity(0.6), width: 1)
                }
                .buttonStyle(.plain)
                .help("Select a clip to compare side-by-side with current video in Slot B")
                
                Spacer()
            }
            
            Button(action: onExit) {
                HStack(spacing: StudioTheme.scale(6)) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                    Text("[ EXIT FULLSCREEN (ESC) ]")
                        .font(.system(size: StudioTheme.scaleFont(11), weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, StudioTheme.scale(14))
                .padding(.vertical, StudioTheme.scale(8))
                .background(palette.bgPanel.opacity(0.85))
                .foregroundColor(palette.textMain)
                .border(palette.borderLine, width: 1)
            }
            .buttonStyle(.plain)
            .help("Exit Fullscreen (ESC / F)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: isLightMode
                    ? [palette.bgMain.opacity(0.92), palette.bgMain.opacity(0.0)]
                    : [Color.black.opacity(0.85), Color.black.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onHover { isHovering in
            isHoveringControls = isHovering
            if isHovering { userDidInteract() }
        }
    }
    
    private func openCompareFileInFullscreen() {
        let panel = NSOpenPanel()
        panel.title = "Select Video to Compare (Slot B)"
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadVideo(url: url, into: .slotB)
            userDidInteract()
        }
    }
    
    // MARK: - Bottom Control Bar
    
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Timeline Scrubber
            TimelineScrubberView(engine: engine, isLightMode: isLightMode)
                .frame(height: 52)
            
            // Transport & Timecode Bar
            HStack(spacing: 12) {
                // Left: Timecode / Frame Count + Shuttle Speed (Fixed 280px width)
                HStack(spacing: 8) {
                    if engine.displayTimeAsFrames {
                        let maxNum = max(engine.totalFrames, engine.currentFrame, 999)
                        let digitCount = max(4, String(maxNum).count)
                        let frameColWidth = CGFloat(digitCount) * 8.8
                        
                        HStack(spacing: 4) {
                            Text("\(engine.currentFrame)")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundColor(accentBlue)
                                .frame(minWidth: frameColWidth, alignment: .trailing)
                            
                            Text("frames")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(accentBlue)
                        }
                        .frame(width: 130, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("\(engine.currentFrame)", forType: .string)
                            }) {
                                Label("Copy Frame (\(engine.currentFrame))", systemImage: "doc.on.doc")
                            }
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(engine.currentTimecode, forType: .string)
                            }) {
                                Label("Copy SMPTE (\(engine.currentTimecode))", systemImage: "clock")
                            }
                        }
                    } else {
                        Text(engine.currentTimecode)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(accentBlue)
                            .frame(width: 120, alignment: .leading)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(engine.currentTimecode, forType: .string)
                                }) {
                                    Label("Copy Timecode (\(engine.currentTimecode))", systemImage: "doc.on.doc")
                                }
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("\(engine.currentFrame)", forType: .string)
                                }) {
                                    Label("Copy Frame Number (\(engine.currentFrame))", systemImage: "number")
                                }
                            }
                    }
                    
                    if engine.shuttleStateText != "PAUSE" && (engine.isPlaying || engine.rate != 0) {
                        Text(engine.shuttleStateText)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .foregroundColor(accentBlue)
                            .tracking(0.5)
                    }
                }
                .frame(width: 280, alignment: .leading)
                
                Spacer()
                
                // Center: Transport Buttons
                PlayerTransportDeckView(
                    engine: engine,
                    scanResults: scanResults,
                    isLightMode: isLightMode,
                    hoverExplanation: nil,
                    hideGlitchNavWhenEmpty: true,
                    onJumpPrevGlitch: onJumpPrev,
                    onJumpNextGlitch: onJumpNext,
                    onAddNote: onAddNote,
                    onJumpPrevNote: { engine.jumpToPreviousNote() },
                    onJumpNextNote: { engine.jumpToNextNote() },
                    onExportScreenshot: onExportScreenshot,
                    showNotesAndGlitches: true
                )
                
                Spacer()
                
                // Right: Duration Timecode & Exit Fullscreen Button (Fixed 280px width)
                HStack(spacing: 12) {
                    Text(engine.displayTimeAsFrames ? "\(engine.totalFrames) frames" : engine.durationTimecode)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(palette.textMuted)
                        .frame(width: 120, alignment: .trailing)
                    
                    Button(action: onExit) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                            .frame(width: StudioTheme.scale(32), height: StudioTheme.scale(30))
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgPanel, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    .help("Exit Fullscreen (ESC / F)")
                }
                .frame(width: 280, alignment: .trailing)
            }
            .frame(height: StudioTheme.scale(32))
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 22)
        .background(
            LinearGradient(
                colors: isLightMode
                    ? [palette.bgMain.opacity(0.0), palette.bgMain.opacity(0.92)]
                    : [Color.black.opacity(0.0), Color.black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onHover { isHovering in
            isHoveringControls = isHovering
            if isHovering { userDidInteract() }
        }
    }
}

// MARK: - Pure Video Fullscreen View (Zero UI)

struct CleanVideoFullscreenView: View {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool = false
    var onExit: () -> Void
    
    @State private var hideCursorTask: Task<Void, Never>? = nil
    
    var body: some View {
        ZStack {
            (isLightMode ? Color(white: 0.94) : Color.black)
                .ignoresSafeArea()
            
            if engine.activeURL != nil {
                VideoViewportView(
                    engine: engine,
                    isLightMode: isLightMode,
                    allowScrollZoom: false,
                    onSingleClick: {
                        engine.togglePlayPause()
                    },
                    onDoubleClick: {
                        onExit()
                    }
                )
                .ignoresSafeArea()
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                resetCursorTimer()
            case .ended:
                break
            }
        }
        .onAppear {
            engine.setZoomFit()
            resetCursorTimer()
        }
        .onDisappear {
            hideCursorTask?.cancel()
        }
    }
    
    private func resetCursorTimer() {
        hideCursorTask?.cancel()
        if engine.isPlaying {
            hideCursorTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !Task.isCancelled && engine.isPlaying {
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
            }
        }
    }
}
