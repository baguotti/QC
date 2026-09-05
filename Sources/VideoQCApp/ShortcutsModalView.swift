import SwiftUI
import AppKit

struct ShortcutsModalView: View {
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
    // Dynamic Studio Theme Palette
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    struct ShortcutItem: Identifiable {
        let id = UUID()
        let keys: [String]
        let icon: String
        let title: String
        let explanation: String
    }
    
    private let playbackShortcuts: [ShortcutItem] = [
        ShortcutItem(
            keys: ["SPACE"],
            icon: "playpause.fill",
            title: "PLAY / PAUSE",
            explanation: "Starts or pauses video playback seamlessly."
        ),
        ShortcutItem(
            keys: ["J"],
            icon: "backward.fill",
            title: "SHUTTLE REVERSE",
            explanation: "Shuttles backward at accelerating speeds (-1x, -2x, -4x, -8x, -16x)."
        ),
        ShortcutItem(
            keys: ["K"],
            icon: "pause.fill",
            title: "PAUSE / STOP SHUTTLE",
            explanation: "Stops playback or halts active high-speed shuttling immediately."
        ),
        ShortcutItem(
            keys: ["L"],
            icon: "forward.fill",
            title: "SHUTTLE FORWARD",
            explanation: "Shuttles forward at accelerating speeds (1x, 2x, 4x, 8x, 16x)."
        ),
        ShortcutItem(
            keys: ["⇧ + J", "⇧ + L"],
            icon: "backward",
            title: "SLOW-MOTION STEPPING",
            explanation: "Steps continuously in slow-motion (2, 4, 8, 15, 24, 30 FPS). Tap again to speed up."
        ),
        ShortcutItem(
            keys: ["←", "→"],
            icon: "backward.frame.fill",
            title: "STEP 1 FRAME",
            explanation: "Steps backward or forward by exactly one single video frame."
        ),
        ShortcutItem(
            keys: ["⇧ + ←", "⇧ + →"],
            icon: "gobackward",
            title: "STEP 5 FRAMES",
            explanation: "Skips backward or forward in the timeline by 5 video frames."
        ),
        ShortcutItem(
            keys: ["⌘ + L"],
            icon: "repeat",
            title: "SEAMLESS LOOP",
            explanation: "Toggles automatic end-to-start looping without interruption."
        )
    ]
    
    private let canvasShortcuts: [ShortcutItem] = [
        ShortcutItem(
            keys: ["F"],
            icon: "arrow.up.left.and.arrow.down.right",
            title: "CLEAN VIDEO FULLSCREEN",
            explanation: "Expands the viewport to full screen with zero UI. Press ESC to return."
        ),
        ShortcutItem(
            keys: ["⇧ + F"],
            icon: "aspectratio.fill",
            title: "REVIEW FULLSCREEN (HUD)",
            explanation: "Fullscreen mode with floating transport controls and timeline scrubber."
        ),
        ShortcutItem(
            keys: ["ESC"],
            icon: "xmark.circle",
            title: "EXIT / DISMISS",
            explanation: "Exits fullscreen playback or closes open popups and modals."
        ),
        ShortcutItem(
            keys: ["SCROLL", "PINCH"],
            icon: "plus.magnifyingglass",
            title: "CANVAS ZOOM",
            explanation: "Smoothly zooms the video canvas from 10% to 400% around cursor."
        ),
        ShortcutItem(
            keys: ["DRAG CANVAS"],
            icon: "hand.draw.fill",
            title: "PAN VIEWPORT",
            explanation: "Click and drag to pan across the zoomed video canvas."
        )
    ]
    
    private let navShortcuts: [ShortcutItem] = [
        ShortcutItem(
            keys: ["↑", "↓"],
            icon: "arrow.up.and.down",
            title: "PREVIOUS / NEXT DELIVERABLE",
            explanation: "Loads previous or next video file in the queue in tree display order."
        ),
        ShortcutItem(
            keys: ["HOME", "END"],
            icon: "backward.end.fill",
            title: "HEAD / TAIL JUMP",
            explanation: "Jumps directly to the very first or very last frame of the asset."
        ),
        ShortcutItem(
            keys: ["N", "⇧ + N"],
            icon: "sparkle.magnifyingglass",
            title: "NEXT / PREV GLITCH FINDING",
            explanation: "Jumps player playhead to the next or previous detected line glitch."
        )
    ]
    
    private let compareShortcuts: [ShortcutItem] = [
        ShortcutItem(
            keys: ["TAB"],
            icon: "eye.trianglebadge.exclamationmark.fill",
            title: "RAPID BLINK COMPARE",
            explanation: "Rapidly flickers between Slot A Master and Slot B Reference to spot differences."
        ),
        ShortcutItem(
            keys: ["X"],
            icon: "arrow.left.arrow.right",
            title: "SWAP A / B SLOTS",
            explanation: "Swaps active files between Slot A and Slot B."
        ),
        ShortcutItem(
            keys: ["W"],
            icon: "square.split.2x1",
            title: "SPLIT-SCREEN SLIDER",
            explanation: "Activates interactive wipe line slider compare mode."
        ),
        ShortcutItem(
            keys: ["D"],
            icon: "circle.lefthalf.filled",
            title: "DIFFERENCE MATTE",
            explanation: "Calculates mathematical per-pixel visual difference matte between A and B."
        )
    ]
    
    var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(0.65)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    isPresented = false
                }
            
            // Modal Card Container
            VStack(spacing: 0) {
                // Header Bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "command")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(palette.textMain)
                        Text("STUDIO KEYBOARD SHORTCUTS // QCpie")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(palette.textMain)
                    }
                    
                    Spacer()
                    
                    Button(action: { isPresented = false }) {
                        Text("CLOSE (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(palette.bgPanel)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Content Body
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        shortcutSection(title: "01 // PLAYBACK & TRANSPORT CONTROLS", items: playbackShortcuts)
                        shortcutSection(title: "02 // CANVAS & FULLSCREEN VIEWPORT", items: canvasShortcuts)
                        shortcutSection(title: "03 // QUEUE & GLITCH NAVIGATION", items: navShortcuts)
                        shortcutSection(title: "04 // DUAL-VIDEO (A/B) COMPARISON", items: compareShortcuts)
                    }
                    .padding(20)
                }
                .background(palette.bgMain)
            }
            .frame(width: 740, height: 560)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
        }
    }
    
    private func shortcutSection(title: String, items: [ShortcutItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .tracking(0.5)
            
            VStack(spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    HStack(spacing: 12) {
                        // Icon Box
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(palette.textMain)
                            .frame(width: 22, height: 22)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                        
                        // Key Badges
                        HStack(spacing: 4) {
                            ForEach(item.keys, id: \.self) { key in
                                Text(key)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(palette.textMain)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(palette.bgSubtle))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.borderLine, lineWidth: 1))
                            }
                        }
                        .frame(width: 140, alignment: .leading)
                        
                        // Title & Explanation
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(palette.textMain)
                            Text(item.explanation)
                                .font(.system(size: 10, weight: .regular))
                                .foregroundColor(palette.textSubtle)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(idx % 2 == 0 ? palette.bgPanel : palette.bgCardBody)
                }
            }
            .studioBox(background: palette.bgPanel, border: palette.borderLine)
        }
    }
}
