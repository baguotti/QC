import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VideoQCLib

// The Player's timecode menu and readout, and the zoom menu.
struct PlayerTimecodeMenuView: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    @ObservedObject var playerEngine: PlayerEngine
    var accentBlue: Color
    @State private var isHovered: Bool = false
    
    var body: some View {
        // Click switches timecode ↔ frames; right-click copies the value as currently shown.
        Button(action: { playerEngine.displayTimeAsFrames.toggle() }) {
            PlayerTimecodeReadout(
                clock: playerEngine.clock,
                displayTimeAsFrames: playerEngine.displayTimeAsFrames,
                totalFrames: playerEngine.totalFrames,
                accentBlue: accentBlue,
                isHovered: isHovered
            )
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .explain(playerEngine.displayTimeAsFrames
                 ? "Frame count. Click to show timecode · Right-click to copy the frame number."
                 : "Timecode. Click to show frame count · Right-click to copy the timecode.")
        .contextMenu {
            // Static title: the value is read at click time so the menu is not rebuilt every frame.
            Button(action: {
                let text = playerEngine.displayTimeAsFrames ? "\(playerEngine.currentFrame)" : playerEngine.currentTimecode
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }) {
                Label(playerEngine.displayTimeAsFrames ? "Copy Frame Number" : "Copy Timecode", systemImage: "doc.on.doc")
            }
        }
    }
}

/// Timecode menu readout; the live value is drawn outside SwiftUI's update cycle (see `PlaybackClockText`).
struct PlayerTimecodeReadout: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    let clock: PlaybackClock
    let displayTimeAsFrames: Bool
    let totalFrames: Int
    let accentBlue: Color
    let isHovered: Bool
    
    private static let font = Font.ui(size: 13, weight: .semibold)
    
    var body: some View {
        if displayTimeAsFrames {
            let digitCount = max(4, String(max(totalFrames, 999)).count)
            let frameColWidth = CGFloat(digitCount) * 8.2
            
            HStack(spacing: 4) {
                PlaybackClockText(
                    clock: clock,
                    value: .frameNumber,
                    template: String(repeating: "0", count: digitCount),
                    fontSize: 13,
                    color: accentBlue,
                    alignment: .trailing,
                    hoverState: isHovered
                )
                .frame(minWidth: frameColWidth, alignment: .trailing)
                
                Text("frames")
                    .font(Self.font)
                    .foregroundColor(accentBlue)
                    .opacity(isHovered ? 1.0 : 0.82)
                    .brightness(isHovered ? 0.05 : 0.0)
                    .animation(Motion.hover, value: isHovered)
            }
        } else {
            PlaybackClockText(
                clock: clock,
                value: .timecode,
                template: "00:00:00:00",
                fontSize: 13,
                color: accentBlue,
                tracking: 0.5,
                hoverState: isHovered
            )
        }
    }
}

struct PlayerZoomMenuView: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    @ObservedObject var playerEngine: PlayerEngine
    var bgSubtle: Color
    var borderLine: Color
    var textMain: Color
    var textMuted: Color
    @State private var isHovered: Bool = false
    
    var body: some View {
        Menu {
            Button("Fit") { playerEngine.setZoomFit() }
            Divider()
            Button("10%") { playerEngine.setZoomLevel(0.10) }
            Button("25%") { playerEngine.setZoomLevel(0.25) }
            Button("50%") { playerEngine.setZoomLevel(0.50) }
            Button("75%") { playerEngine.setZoomLevel(0.75) }
            Button("100%") { playerEngine.setZoomLevel(1.0) }
            Button("150%") { playerEngine.setZoomLevel(1.50) }
            Button("200%") { playerEngine.setZoomLevel(2.0) }
            Button("400%") { playerEngine.setZoomLevel(4.0) }
        } label: {
            HStack(spacing: 4) {
                Text(playerEngine.isFitZoom ? "Fit" : "\(Int(round(playerEngine.zoomScale * 100)))%")
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundColor(textMain)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                    .foregroundColor(textMuted)
            }
            .padding(.horizontal, 6)
            .frame(width: 62, height: 22)
            .studioBox(background: bgSubtle, border: isHovered ? borderLine.opacity(0.8) : borderLine)
            .opacity(isHovered ? 1.0 : 0.82)
            .brightness(isHovered ? 0.05 : 0.0)
            .animation(Motion.hover, value: isHovered)
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 62)
    }
}
