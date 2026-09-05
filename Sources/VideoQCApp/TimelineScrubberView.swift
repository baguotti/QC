import SwiftUI
import CoreMedia
import VideoQCLib

// MARK: - Equatable Memoized Ruler Ticks
// Isolates the heavy CoreGraphics/Canvas tick marks & timecodes so they are
// NEVER re-drawn during playhead scrubbing or playback.

public struct RulerTicksCanvasView: View, Equatable {
    let duration: Double
    let fps: Double
    let width: CGFloat
    let trackInset: CGFloat
    let isLightMode: Bool
    
    private var tickColor: Color { isLightMode ? Color(white: 0.70) : Color(white: 0.28) }
    private var majorTickColor: Color { isLightMode ? Color(white: 0.48) : Color(white: 0.46) }
    private var textColor: Color { isLightMode ? Color(white: 0.38) : Color(white: 0.60) }
    
    public static nonisolated func == (lhs: RulerTicksCanvasView, rhs: RulerTicksCanvasView) -> Bool {
        abs(lhs.duration - rhs.duration) < 0.001 &&
        abs(lhs.fps - rhs.fps) < 0.001 &&
        abs(lhs.width - rhs.width) < 0.5 &&
        lhs.trackInset == rhs.trackInset &&
        lhs.isLightMode == rhs.isLightMode
    }
    
    public var body: some View {
        Canvas { context, size in
            guard duration > 0 else { return }
            let trackWidth = max(1.0, width - (trackInset * 2))
            
            // Adaptive interval for long master files so marks never overlap
            let intervalSecs: Double
            if trackWidth / (duration / 5.0) >= 60 {
                intervalSecs = 5.0
            } else if trackWidth / (duration / 10.0) >= 60 {
                intervalSecs = 10.0
            } else if trackWidth / (duration / 15.0) >= 60 {
                intervalSecs = 15.0
            } else {
                intervalSecs = 30.0
            }
            
            // 1. Draw 1-second minor & major ticks
            let minorStep: Double = intervalSecs <= 5.0 ? 1.0 : (intervalSecs / 5.0)
            var sec = 0.0
            while sec <= duration + 0.001 {
                let x = trackInset + trackWidth * CGFloat(sec / duration)
                let rem = sec.truncatingRemainder(dividingBy: intervalSecs)
                let isMajor = rem < 0.001 || abs(rem - intervalSecs) < 0.001
                
                var tickPath = Path()
                let tickH: CGFloat = isMajor ? 5.5 : 3.0
                tickPath.move(to: CGPoint(x: x, y: size.height - tickH))
                tickPath.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tickPath, with: .color(isMajor ? majorTickColor : tickColor), lineWidth: 1)
                sec += minorStep
            }
            
            // 2. Draw 5-second interval timecode labels
            var labelSec = 0.0
            while labelSec <= duration + 0.001 {
                let x = trackInset + trackWidth * CGFloat(labelSec / duration)
                let frame = Int(round(labelSec * max(1.0, fps)))
                let tc = TimecodeFormatter.format(frameIndex: frame, fps: fps)
                
                let text = Text(tc)
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor)
                
                let anchor: UnitPoint
                if x < 40 {
                    anchor = .leading
                } else if x > width - 40 {
                    anchor = .trailing
                } else {
                    anchor = .center
                }
                
                context.draw(text, at: CGPoint(x: x, y: 4), anchor: anchor)
                labelSec += intervalSecs
            }
        }
        .frame(width: width, height: 18)
    }
}

// MARK: - Downward-Pointing Playhead Chevron Shape (CTI)

struct PlayheadChevronShape: Shape {
    var tipProportion: CGFloat = 0.40 // 40% of height tapers into a crisp downward chevron
    var cornerRadius: CGFloat = 1.5
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let bodyH = h * (1.0 - tipProportion)
        let r = min(cornerRadius, min(w / 4, bodyH / 4))
        let midX = rect.midX
        
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: bodyH))
        path.addLine(to: CGPoint(x: midX, y: h))
        path.addLine(to: CGPoint(x: 0, y: bodyH))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        return path
    }
}

// MARK: - Main Modern Minimal Timeline Scrubber View

public struct TimelineScrubberView: View {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool
    
    @State private var isDragging: Bool = false
    @State private var hoverX: CGFloat? = nil
    @State private var isHovering: Bool = false
    
    // Inset from outer container edges to float the pill track and protect playhead
    private let trackInset: CGFloat = 6.0
    
    // Theme colors
    private var containerBg: Color { isLightMode ? Color(white: 0.94) : Color(red: 0.055, green: 0.055, blue: 0.06) }
    private var containerBorder: Color { isLightMode ? Color(white: 0.80) : Color(white: 0.15) }
    private var rulerDivider: Color { isLightMode ? Color(white: 0.86) : Color(white: 0.11) }
    
    private var trackGrooveBg: Color { isLightMode ? Color(white: 0.88) : Color(white: 0.035) }
    private var trackGrooveBorder: Color { isLightMode ? Color(white: 0.78) : Color(white: 0.10) }
    
    private var playheadAccent: Color { StudioTheme.accentBlue(isLightMode) }
    
    private var progressGradient: LinearGradient {
        LinearGradient(
            colors: isLightMode ? [
                StudioTheme.accentBlue(true).opacity(0.85),
                StudioTheme.accentBlue(true)
            ] : [
                StudioTheme.accentBlue(false).opacity(0.80),
                StudioTheme.accentBlue(false)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    
    public init(engine: PlayerEngine, isLightMode: Bool) {
        self.engine = engine
        self.isLightMode = isLightMode
    }
    
    public var body: some View {
        GeometryReader { geo in
            let width = max(20, geo.size.width)
            let trackWidth = max(1.0, width - (trackInset * 2))
            let playheadX = trackInset + trackWidth * CGFloat(engine.currentProgress)
            let durSecs = CMTimeGetSeconds(engine.duration)
            
            ZStack(alignment: .topLeading) {
                // Unified Modern Rounded Bezel Container
                RoundedRectangle(cornerRadius: 8)
                    .fill(containerBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(containerBorder, lineWidth: 1)
                    )
                
                // Hairline Divider between Ruler and Scrubber Track
                Rectangle()
                    .fill(rulerDivider)
                    .frame(height: 0.75)
                    .offset(y: 19)
                
                // MARK: - Time Ruler (Top 19px)
                ZStack(alignment: .topLeading) {
                    RulerTicksCanvasView(
                        duration: durSecs,
                        fps: engine.activeFps,
                        width: width,
                        trackInset: trackInset,
                        isLightMode: isLightMode
                    )
                    .equatable()
                    
                    // Glitch Markers on Ruler (Subtle, crisp neon pips)
                    ForEach(engine.activeMarkers) { marker in
                        if durSecs > 0 {
                            let fps = max(1.0, engine.activeFps)
                            let markerSecs = Double(marker.frameIndex) / fps
                            let markerX = trackInset + trackWidth * CGFloat(min(1.0, max(0.0, markerSecs / durSecs)))
                            Circle()
                                .fill(Color(red: 1.0, green: 0.28, blue: 0.30))
                                .frame(width: 3.5, height: 3.5)
                                .shadow(color: Color.red.opacity(0.6), radius: 1.5)
                                .position(x: markerX, y: 17)
                        }
                    }
                }
                .frame(height: 19)
                
                // MARK: - Modern Floating Scrubber Track (Bottom, Height: 12px, centered in 26px area)
                ZStack(alignment: .leading) {
                    // Recessed Pill Track Bed
                    Capsule()
                        .fill(trackGrooveBg)
                        .overlay(
                            Capsule()
                                .stroke(trackGrooveBorder, lineWidth: 0.75)
                        )
                        .frame(width: trackWidth, height: 12)
                    
                    // Played Progress Fill with Smooth Capsule Mask
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(progressGradient)
                            .frame(width: max(0, playheadX - trackInset), height: 12)
                        
                        // Subtle Glass Specular Top Highlight
                        Rectangle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: max(0, playheadX - trackInset), height: 1)
                            .offset(y: -5.5)
                    }
                    .frame(width: trackWidth, height: 12, alignment: .leading)
                    .clipShape(Capsule())
                    
                    // Glitch Markers Inside Track (Radiant Coral Neon Bars)
                    ForEach(engine.activeMarkers) { marker in
                        if durSecs > 0 {
                            let fps = max(1.0, engine.activeFps)
                            let markerSecs = Double(marker.frameIndex) / fps
                            let markerX = trackWidth * CGFloat(min(1.0, max(0.0, markerSecs / durSecs)))
                            Capsule()
                                .fill(Color(red: 1.0, green: 0.28, blue: 0.30))
                                .frame(width: 2, height: 10)
                                .shadow(color: Color.red.opacity(0.6), radius: 2)
                                .position(x: markerX, y: 6)
                        }
                    }
                }
                .frame(width: trackWidth, height: 12)
                .offset(x: trackInset, y: 26)
                
                // MARK: - Hover Ghost Needle
                if let hX = hoverX, isHovering && !isDragging && durSecs > 0 {
                    let clampedHX = max(trackInset, min(hX, width - trackInset))
                    
                    // Subtle Ghost Needle (hairline guide)
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: 36)
                        .offset(x: clampedHX - 0.5, y: 5)
                        .allowsHitTesting(false)
                }
                
                // MARK: - Modern Tactile Playhead (CTI)
                // 1. Full-Height Precision Needle (Clean, no glow)
                Capsule()
                    .fill(playheadAccent)
                    .frame(width: isDragging ? 2.0 : 1.5, height: 38)
                    .offset(x: playheadX - (isDragging ? 1.0 : 0.75), y: 4)
                    .allowsHitTesting(false)
                
                // 2. Chevron-Style Tactile Head Badge (Clean, no glow)
                ZStack {
                    PlayheadChevronShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.25, green: 0.62, blue: 1.0),
                                    Color(red: 0.12, green: 0.46, blue: 0.95)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 11, height: 13)
                        .shadow(color: Color.black.opacity(0.4), radius: 1.5, x: 0, y: 1)
                    
                    PlayheadChevronShape()
                        .stroke(Color.white.opacity(0.65), lineWidth: 0.75)
                        .frame(width: 11, height: 13)
                    
                    // Micro-notch center line
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 1.2, height: 5.0)
                        .offset(y: -1.5)
                }
                .scaleEffect(isDragging ? 1.15 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
                .offset(x: playheadX - 5.5, y: 2)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            // Smooth Hover Tracking
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverX = location.x
                    isHovering = true
                case .ended:
                    hoverX = nil
                    isHovering = false
                }
            }
            // Instantaneous 120 FPS Drag Scrubbing
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                        }
                        if engine.isPlaying || engine.rate != 0 {
                            engine.pause()
                        }
                        let x = max(trackInset, min(value.location.x, width - trackInset))
                        let progress = Double((x - trackInset) / trackWidth)
                        engine.scrubTo(progress: progress)
                    }
                    .onEnded { value in
                        isDragging = false
                        let x = max(trackInset, min(value.location.x, width - trackInset))
                        let progress = Double((x - trackInset) / trackWidth)
                        engine.endScrubbing(at: progress)
                    }
            )
        }
        .frame(height: 46)
    }
}
