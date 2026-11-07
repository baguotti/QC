import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VideoQCLib

// The Player's exposure scrubber and volume slider.
// MARK: - Exposure Scrubber Control (After Effects Style)

struct ExposureScrubberView: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool = false
    
    @State private var isDragging: Bool = false
    @State private var dragStartEV: Double = 0.0
    @State private var isHoveringNumber: Bool = false
    
    private var formattedEV: String {
        let val = abs(engine.exposureEV) < 0.05 ? 0.0 : engine.exposureEV
        return String(format: "%+.1f", val)
    }
    
    private var isNonZero: Bool {
        abs(engine.exposureEV) >= 0.05
    }
    
    // AE blue accent for the scrubbable number
    private var scrubberBlue: Color {
        StudioTheme.accentBlue(isLightMode)
    }
    
    private var iconColor: Color {
        if isNonZero {
            return scrubberBlue
        } else {
            return isLightMode ? Color(white: 0.12) : Color.white
        }
    }
    
    var body: some View {
        HStack(spacing: 2) {
            // Aperture Reset Button
            Button(action: {
                withAnimation(Motion.hover) {
                    engine.resetExposure()
                }
            }) {
                // The iris turns and opens slightly with EV (−5…+5 → −30°…+30°, 92%…108%), like a lens aperture.
                Image(systemName: "camera.aperture")
                    .font(.system(size: StudioTheme.scaleFont(12), weight: .semibold))
                    .foregroundColor(iconColor)
                    .rotationEffect(.degrees(engine.exposureEV * 6))
                    .scaleEffect(1 + engine.exposureEV * 0.016)
                    .animation(Motion.list, value: engine.exposureEV)
                    .frame(width: StudioTheme.scale(22), height: StudioTheme.scale(26))
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .explain("Reset Exposure to +0.0 EV")
            
            // Drag-Scrub Number
            // Fixed width (widest value reserved underneath) so dragging doesn't shift the transport row.
            ZStack(alignment: .leading) {
                Text("+8.8").hidden()
                Text(formattedEV)
            }
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(scrubberBlue)
                .fixedSize()
                .frame(height: StudioTheme.scale(26))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartEV = engine.exposureEV
                            }
                            // 35 pt horizontal drag = 1.0 EV
                            let delta = Double(value.translation.width) / 35.0
                            let target = min(5.0, max(-5.0, dragStartEV + delta))
                            let stepped = (target * 10.0).rounded() / 10.0
                            if abs(engine.exposureEV - stepped) > 0.001 {
                                engine.exposureEV = stepped
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(Motion.hover) {
                        engine.resetExposure()
                    }
                }
                .onHover { hovering in
                    if hovering != isHoveringNumber {
                        isHoveringNumber = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .onDisappear {
                    if isHoveringNumber {
                        isHoveringNumber = false
                        NSCursor.pop()
                    }
                }
                .explain("Change Exposure (EV): Drag left/right to adjust, click aperture to reset (Current: \(formattedEV))")
    }
}
}

// MARK: - Subtle Studio Volume Slider

struct StudioVolumeSlider: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    @Binding var volume: Float
    @Binding var isMuted: Bool
    var accentColor: Color
    var textMuted: Color
    var isLightMode: Bool
    
    @State private var isDragging: Bool = false
    @State private var isHovered: Bool = false
    
    private var sliderWidth: CGFloat { StudioTheme.scale(70) }
    private var trackHeight: CGFloat { StudioTheme.scale(3) }
    private var thumbDiameter: CGFloat { StudioTheme.scale(8) }
    
    private var currentThumbDiameter: CGFloat {
        (isHovered || isDragging) ? StudioTheme.scale(9) : thumbDiameter
    }
    
    private var thumbColor: Color {
        if isMuted {
            return textMuted.opacity(0.6)
        }
        return isLightMode ? Color(white: 0.22) : Color.white
    }
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usableWidth = max(1, width - thumbDiameter)
            let clampedVal = CGFloat(max(0, min(1, volume)))
            let thumbCenter = (thumbDiameter / 2) + clampedVal * usableWidth
            let fillWidth = (clampedVal <= 0.001) ? 0 : min(width, thumbCenter + (thumbDiameter / 2) * clampedVal)
            
            ZStack(alignment: .leading) {
                // Background Track & Active Fill, clipped to capsule shape
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(isLightMode ? Color.black.opacity(0.12) : Color.white.opacity(0.16))
                        .frame(width: width, height: trackHeight)
                    
                    if fillWidth > 0 {
                        Rectangle()
                            .fill(isMuted ? textMuted.opacity(0.4) : accentColor)
                            .frame(width: fillWidth, height: trackHeight)
                    }
                }
                .clipShape(Capsule())
                .frame(width: width, height: trackHeight)
                .position(x: width / 2, y: geo.size.height / 2)
                
                // Subtle Knob / Ball
                Circle()
                    .fill(thumbColor)
                    .frame(width: currentThumbDiameter, height: currentThumbDiameter)
                    .overlay(
                        Circle()
                            .strokeBorder(isLightMode ? Color.black.opacity(0.15) : Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(isLightMode ? 0.2 : 0.4), radius: 1, x: 0, y: 0.5)
                    .position(x: thumbCenter, y: geo.size.height / 2)
                    .animation(Motion.hover, value: isHovered)
                    .animation(Motion.hover, value: isDragging)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        updateVolume(location: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        updateVolume(location: gesture.location.x, width: width)
                        isDragging = false
                    }
            )
        }
        .frame(width: sliderWidth, height: StudioTheme.scale(18))
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func updateVolume(location: CGFloat, width: CGFloat) {
        let usableWidth = max(1, width - thumbDiameter)
        let localX = location - (thumbDiameter / 2)
        let fraction = max(0, min(1, localX / usableWidth))
        volume = Float(fraction)
        if isMuted && volume > 0 {
            isMuted = false
        }
    }
}
