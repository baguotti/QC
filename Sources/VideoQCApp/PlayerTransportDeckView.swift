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
    
    init(
        engine: PlayerEngine,
        scanResults: [VideoQCResult],
        isLightMode: Bool = false,
        hoverExplanation: Binding<String>? = nil,
        hideGlitchNavWhenEmpty: Bool = false,
        onJumpPrevGlitch: @escaping () -> Void,
        onJumpNextGlitch: @escaping () -> Void
    ) {
        self.engine = engine
        self.scanResults = scanResults
        self.isLightMode = isLightMode
        self.hoverExplanation = hoverExplanation
        self.hideGlitchNavWhenEmpty = hideGlitchNavWhenEmpty
        self.onJumpPrevGlitch = onJumpPrevGlitch
        self.onJumpNextGlitch = onJumpNextGlitch
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
                
                transportBtn(
                    icon: engine.isAutoplayEnabled ? "play.circle.fill" : "play.circle",
                    tooltip: engine.isAutoplayEnabled ? "Autoplay on Select: ON (Plays from start on click or ↑/↓)" : "Autoplay on Select: OFF (Loads paused at frame 0)",
                    isActive: engine.isAutoplayEnabled,
                    size: 12,
                    weight: .semibold,
                    width: 26
                ) {
                    engine.isAutoplayEnabled.toggle()
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
            }
            
            // 3. Compact Borderless Line Finding Navigation
            let hasGlitches = scanResults.contains(where: { $0.isFlagged && !$0.glitchSegments.isEmpty })
            if !hideGlitchNavWhenEmpty || hasGlitches {
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                
                HStack(spacing: 3) {
                    Button(action: onJumpPrevGlitch) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left.to.line")
                                .font(.system(size: 9, weight: .bold))
                            Text("PREV LINE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                        .frame(height: 28)
                        .padding(.horizontal, 5)
                        .foregroundColor(hasGlitches ? alertRed : textMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(!hasGlitches)
                    .explain(
                        hasGlitches ? "Jump to previous detected line glitch (⇧N / cycles backwards through findings of Tab 3)." : "No line glitches found in Tab 3 to cycle through.",
                        binding: hoverExplanation
                    )
                    
                    Button(action: onJumpNextGlitch) {
                        HStack(spacing: 3) {
                            Text("NEXT LINE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                            Image(systemName: "chevron.right.to.line")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .frame(height: 28)
                        .padding(.horizontal, 5)
                        .foregroundColor(hasGlitches ? alertRed : textMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .disabled(!hasGlitches)
                    .explain(
                        hasGlitches ? "Jump to next detected line glitch (N / cycles forwards through findings of Tab 3)." : "No line glitches found in Tab 3 to cycle through.",
                        binding: hoverExplanation
                    )
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
