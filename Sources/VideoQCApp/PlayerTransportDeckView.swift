import SwiftUI
import VideoQCLib

// MARK: - Reusable Unified Player Transport Deck

/// Encapsulates the 7 transport controls, playback utilities (Loop, Crosshair, Exposure),
/// and line glitch jump navigation into a single reusable component shared across windowed and fullscreen player views.
struct PlayerTransportDeckView: View {
    @ObservedObject var engine: PlayerEngine
    let scanResults: [VideoQCResult]
    var isLightMode: Bool
    var hoverExplanation: Binding<String>?
    var hideGlitchNavWhenEmpty: Bool
    let onJumpPrevGlitch: () -> Void
    let onJumpNextGlitch: () -> Void
    var onAddNote: (() -> Void)?
    var onToggleNotesDrawer: (() -> Void)?
    var isNotesDrawerOpen: Bool
    var onJumpPrevNote: (() -> Void)?
    var onJumpNextNote: (() -> Void)?
    var onExportScreenshot: (() -> Void)?
    var showNotesAndGlitches: Bool
    
    init(
        engine: PlayerEngine,
        scanResults: [VideoQCResult] = [],
        isLightMode: Bool = false,
        hoverExplanation: Binding<String>? = nil,
        hideGlitchNavWhenEmpty: Bool = false,
        onJumpPrevGlitch: @escaping () -> Void = {},
        onJumpNextGlitch: @escaping () -> Void = {},
        onAddNote: (() -> Void)? = nil,
        onToggleNotesDrawer: (() -> Void)? = nil,
        isNotesDrawerOpen: Bool = false,
        onJumpPrevNote: (() -> Void)? = nil,
        onJumpNextNote: (() -> Void)? = nil,
        onExportScreenshot: (() -> Void)? = nil,
        showNotesAndGlitches: Bool = false
    ) {
        self.engine = engine
        self.scanResults = scanResults
        self.isLightMode = isLightMode
        self.hoverExplanation = hoverExplanation
        self.hideGlitchNavWhenEmpty = hideGlitchNavWhenEmpty
        self.onJumpPrevGlitch = onJumpPrevGlitch
        self.onJumpNextGlitch = onJumpNextGlitch
        self.onAddNote = onAddNote
        self.onToggleNotesDrawer = onToggleNotesDrawer
        self.isNotesDrawerOpen = isNotesDrawerOpen
        self.onJumpPrevNote = onJumpPrevNote
        self.onJumpNextNote = onJumpNextNote
        self.onExportScreenshot = onExportScreenshot
        self.showNotesAndGlitches = showNotesAndGlitches
    }
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var textMain: Color { palette.textMain }
    private var textMuted: Color { palette.textMuted }
    private var accentBlue: Color { palette.accentBlue }
    private var alertRed: Color { palette.alertRed }
    private var dividerColor: Color {
        isLightMode ? palette.borderLine.opacity(0.45) : Color.white.opacity(0.2)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // 1. Unified Transport Deck (Tight & Proportional)
            HStack(spacing: 5) {
                // Slow Rev (Shift + J)
                transportBtn(icon: "backward", tooltip: "Slow Reverse (⇧J / Tap to accelerate)", size: 13, width: 26) {
                    engine.pressSlowJ()
                }
                
                // Step Back 1 Frame (Left Arrow)
                transportBtn(icon: "backward.frame.fill", tooltip: "Step Back 1 Frame (Left Arrow)", size: 13, width: 26) {
                    engine.stepFrame(forward: false)
                }
                
                // Shuttle Reverse (J)
                Button(action: { engine.pressJ() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 28, height: 28)
                        .foregroundColor(engine.rate < 0 ? accentBlue : textMain)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Shuttle Reverse (J: -1x, -2x, -4x, -8x)", binding: hoverExplanation)
                
                // Play / Pause (Space / K)
                Button(action: { engine.togglePlayPause() }) {
                    AnimatedPlayPauseIconView(
                        isPlaying: engine.isPlaying,
                        color: textMain,
                        size: 20
                    )
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Play / Pause (Spacebar / K)", binding: hoverExplanation)
                
                // Shuttle Forward (L)
                Button(action: { engine.pressL() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 28, height: 28)
                        .foregroundColor(engine.rate > 1.0 ? accentBlue : textMain)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TransportIconButtonStyle())
                .explain("Shuttle Forward (L: 1x, 2x, 4x, 8x)", binding: hoverExplanation)
                
                // Step Forward 1 Frame (Right Arrow)
                transportBtn(icon: "forward.frame.fill", tooltip: "Step Forward 1 Frame (Right Arrow)", size: 13, width: 26) {
                    engine.stepFrame(forward: true)
                }
                
                // Slow Forward (Shift + L)
                transportBtn(icon: "forward", tooltip: "Slow Forward (Shift + L / Tap to accelerate)", size: 13, width: 26) {
                    engine.pressSlowL()
                }
            }
            
            // Group Divider
            Rectangle()
                .fill(dividerColor)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)
            
            // 2. Playback Utilities: Loop, Title Safe, Crosshair & Exposure
            HStack(spacing: 4) {
                transportBtn(
                    icon: "repeat",
                    tooltip: engine.isLooping ? "Loop Playback: ON (⌘L)" : "Loop Playback: OFF (⌘L)",
                    isActive: engine.isLooping,
                    size: 11,
                    weight: .semibold,
                    width: 26
                ) {
                    engine.isLooping.toggle()
                }

                
                let safeAreaTooltip: String = {
                    switch engine.safeAreaMode {
                    case .off:
                        return engine.isNineBySixteen ? "Safe Area: OFF (Click for Title & Action)" : "Title & Action Safe: OFF"
                    case .standard:
                        return engine.isNineBySixteen ? "Safe Area: Title & Action (Click for TikTok)" : "Title & Action Safe: ON"
                    case .tikTok:
                        return "Safe Area: TikTok 9:16 (50% Opacity) (Click to turn OFF)"
                    }
                }()
                
                customTransportBtn(
                    tooltip: safeAreaTooltip,
                    isActive: engine.safeAreaMode != .off,
                    width: 26
                ) {
                    engine.cycleSafeAreaMode()
                } content: {
                    if engine.safeAreaMode == .tikTok {
                        ZStack {
                            RoundedRectangle(cornerRadius: 1.8)
                                .strokeBorder(lineWidth: 1.1)
                                .frame(width: 9.5, height: 15)
                            RoundedRectangle(cornerRadius: 0.8)
                                .strokeBorder(lineWidth: 0.8)
                                .frame(width: 6.5, height: 11)
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 1.5)
                                .strokeBorder(lineWidth: 1.1)
                                .frame(width: 16, height: 11.5)
                            RoundedRectangle(cornerRadius: 0.8)
                                .strokeBorder(lineWidth: 0.9)
                                .frame(width: 10.5, height: 7)
                        }
                    }
                }
                
                transportBtn(
                    icon: "scope",
                    tooltip: engine.showCenterCrosshair ? "Center Crosshair: ON" : "Center Crosshair: OFF",
                    isActive: engine.showCenterCrosshair,
                    size: 12,
                    weight: .semibold,
                    width: 26
                ) {
                    engine.showCenterCrosshair.toggle()
                }
                
                ExposureScrubberView(
                    engine: engine,
                    isLightMode: isLightMode,
                    hoverExplanation: hoverExplanation
                )
                
                // Screenshot / Screengrab Button (Camera next to EV)
                if let onExport = onExportScreenshot {
                    transportBtn(
                        icon: "camera.fill",
                        tooltip: "Export screenshot of current video frame as medium-quality JPG.",
                        size: 11,
                        weight: .bold,
                        width: 26
                    ) {
                        onExport()
                    }
                    .disabled(engine.activeURL == nil)
                }
            }
            
            // 3. Compact Review Notes Controls (Optional for decks that display notes inline, e.g. Fullscreen HUD)
            if showNotesAndGlitches && (onAddNote != nil || onToggleNotesDrawer != nil || onJumpPrevNote != nil || onJumpNextNote != nil) {
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                
                HStack(spacing: 2) {
                    if let onAdd = onAddNote {
                        Button(action: onAdd) {
                            HStack(spacing: 3) {
                                Image(systemName: "plus")
                                    .font(.system(size: 9, weight: .bold))
                                Text("NOTE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .frame(height: 28)
                            .padding(.horizontal, 5)
                            .foregroundColor(engine.activeURL == nil ? textMuted : textMain)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .disabled(engine.activeURL == nil)
                        .explain("Add review note at playhead (M).", binding: hoverExplanation)
                    }
                    
                    // Compact Note Navigator: < 💬 count >
                    let notesCount = engine.activeNotes.count
                    let hasNotes = notesCount > 0
                    
                    HStack(spacing: 1) {
                        Button(action: { onJumpPrevNote?() }) {
                            Image(systemName: "chevron.left.to.line")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 18, height: 28)
                                .foregroundColor(hasNotes ? textMain : textMuted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .disabled(!hasNotes || onJumpPrevNote == nil)
                        .explain(hasNotes ? "Jump to previous note" : "No notes logged", binding: hoverExplanation)
                        
                        if let onToggle = onToggleNotesDrawer {
                            Button(action: onToggle) {
                                HStack(spacing: 3) {
                                    Image(systemName: isNotesDrawerOpen ? "text.bubble.fill" : "text.bubble")
                                        .font(.system(size: 9, weight: .semibold))
                                    SlotText(
                                        hasNotes ? "\(notesCount)" : "NOTES",
                                        mode: hasNotes ? .character : .word,
                                        direction: .up,
                                        font: .system(size: 9, weight: .bold, design: .monospaced),
                                        foregroundColor: isNotesDrawerOpen ? accentBlue : (hasNotes ? textMain : textMuted)
                                    )
                                }
                                .frame(height: 28)
                                .padding(.horizontal, 4)
                                .foregroundColor(isNotesDrawerOpen ? accentBlue : (hasNotes ? textMain : textMuted))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(TransportIconButtonStyle())
                            .disabled(engine.activeURL == nil)
                            .explain(hasNotes ? "Toggle Review Notes drawer (\(notesCount) notes)." : "Toggle Review Notes drawer.", binding: hoverExplanation)
                        } else {
                            SlotText(
                                hasNotes ? "\(notesCount)" : "NOTE",
                                mode: hasNotes ? .character : .word,
                                direction: .up,
                                font: .system(size: 9, weight: .bold, design: .monospaced),
                                foregroundColor: hasNotes ? textMain : textMuted
                            )
                            .padding(.horizontal, 3)
                        }
                        
                        Button(action: { onJumpNextNote?() }) {
                            Image(systemName: "chevron.right.to.line")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 18, height: 28)
                                .foregroundColor(hasNotes ? textMain : textMuted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .disabled(!hasNotes || onJumpNextNote == nil)
                        .explain(hasNotes ? "Jump to next note" : "No notes logged", binding: hoverExplanation)
                    }
                }
            }
            
            // 4. Compact Line Finding Navigation (Optional for decks that display line nav inline, e.g. Fullscreen HUD)
            if showNotesAndGlitches {
                let hasGlitches = scanResults.contains(where: { $0.isFlagged && !$0.glitchSegments.isEmpty })
                if !hideGlitchNavWhenEmpty || hasGlitches {
                    Rectangle()
                        .fill(dividerColor)
                        .frame(width: 1, height: 14)
                        .padding(.horizontal, 2)
                    
                    HStack(spacing: 1) {
                        Button(action: onJumpPrevGlitch) {
                            Image(systemName: "chevron.left.to.line")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 18, height: 28)
                                .foregroundColor(hasGlitches ? alertRed : textMuted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .disabled(!hasGlitches)
                        .explain(
                            hasGlitches ? "Jump to previous line glitch (⇧N / cycles backwards through findings of Tab 3)." : "No line glitches found in Tab 3 to cycle through.",
                            binding: hoverExplanation
                        )
                        
                        Text("LINE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(hasGlitches ? alertRed : textMuted)
                            .padding(.horizontal, 3)
                        
                        Button(action: onJumpNextGlitch) {
                            Image(systemName: "chevron.right.to.line")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 18, height: 28)
                                .foregroundColor(hasGlitches ? alertRed : textMuted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .disabled(!hasGlitches)
                        .explain(
                            hasGlitches ? "Jump to next line glitch (N / cycles forwards through findings of Tab 3)." : "No line glitches found in Tab 3 to cycle through.",
                            binding: hoverExplanation
                        )
                    }
                }
            }
        }
    }
    
    private func transportBtn(
        icon: String,
        tooltip: String,
        isActive: Bool = false,
        activeColor: Color? = nil,
        size: CGFloat = 14,
        weight: Font.Weight = .bold,
        width: CGFloat = 30,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: weight))
                .frame(width: width, height: 28)
                .foregroundColor(isActive ? (activeColor ?? accentBlue) : textMain)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportIconButtonStyle())
        .explain(tooltip, binding: hoverExplanation)
    }
    
    private func customTransportBtn<Content: View>(
        tooltip: String,
        isActive: Bool = false,
        activeColor: Color? = nil,
        width: CGFloat = 26,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: width, height: 28)
                .foregroundColor(isActive ? (activeColor ?? accentBlue) : textMain)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportIconButtonStyle())
        .explain(tooltip, binding: hoverExplanation)
    }
}
