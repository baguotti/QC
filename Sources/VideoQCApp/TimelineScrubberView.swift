import SwiftUI
import CoreMedia
import VideoQCLib

public struct TimelineScrubberView: View {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool
    
    // Theme colors
    private var trackBg: Color { isLightMode ? Color(white: 0.86) : Color(white: 0.10) }
    private var rulerBg: Color { isLightMode ? Color(white: 0.90) : Color(white: 0.13) }
    private var tickColor: Color { isLightMode ? Color(white: 0.65) : Color(white: 0.32) }
    private var majorTickColor: Color { isLightMode ? Color(white: 0.45) : Color(white: 0.55) }
    private var playheadColor: Color { Color(red: 0.11, green: 0.44, blue: 0.96) } // Premiere Pro Blue (#1D70F5)
    private var playedProgressColor: Color { isLightMode ? Color(white: 0.76) : Color(white: 0.18) }
    private var textColor: Color { isLightMode ? Color(white: 0.30) : Color(white: 0.68) }
    private var borderColor: Color { isLightMode ? Color(white: 0.78) : Color(white: 0.22) }
    
    public init(engine: PlayerEngine, isLightMode: Bool) {
        self.engine = engine
        self.isLightMode = isLightMode
    }
    
    public var body: some View {
        GeometryReader { geo in
            let width = max(10, geo.size.width)
            let playheadX = width * CGFloat(engine.currentProgress)
            
            VStack(spacing: 0) {
                // MARK: - Time Ruler (Top Strip)
                ZStack(alignment: .leading) {
                    rulerBg
                        .frame(height: 22)
                    
                    // Ruler Tick Marks & 5-Second Interval Timecodes
                    rulerTicksView(width: width)
                    
                    // Glitch Markers on Ruler (Red alert diamonds at line error timecodes)
                    ForEach(engine.activeMarkers) { marker in
                        let durSecs = CMTimeGetSeconds(engine.duration)
                        if durSecs > 0 {
                            let fps = max(1.0, engine.activeFps)
                            let markerSecs = Double(marker.frameIndex) / fps
                            let markerX = width * CGFloat(min(1.0, max(0.0, markerSecs / durSecs)))
                            glitchMarkerIcon(marker: marker)
                                .offset(x: markerX - 3.5, y: 13)
                        }
                    }
                    
                    // Needle line in ruler below head
                    Rectangle()
                        .fill(playheadColor)
                        .frame(width: 1, height: 10)
                        .offset(x: playheadX - 0.5, y: 6)
                    
                    // Current Playhead Marker (Small, sharp Premiere CTI)
                    playheadArrow
                        .offset(x: playheadX - 4.5, y: 1)
                }
                .border(borderColor, width: 1)
                
                // MARK: - Timeline Track (Scrubbing Track)
                ZStack(alignment: .leading) {
                    trackBg
                        .frame(height: 24)
                    
                    // Played Region Background Fill
                    Rectangle()
                        .fill(playedProgressColor)
                        .frame(width: playheadX, height: 24)
                    
                    // Glitch Markers across the track
                    ForEach(engine.activeMarkers) { marker in
                        let durSecs = CMTimeGetSeconds(engine.duration)
                        if durSecs > 0 {
                            let fps = max(1.0, engine.activeFps)
                            let markerSecs = Double(marker.frameIndex) / fps
                            let markerX = width * CGFloat(min(1.0, max(0.0, markerSecs / durSecs)))
                            Rectangle()
                                .fill(Color(red: 1.0, green: 0.25, blue: 0.25, opacity: 0.85))
                                .frame(width: 1.5, height: 24)
                                .offset(x: markerX - 0.75)
                        }
                    }
                    
                    // Playhead Needle across the track
                    Rectangle()
                        .fill(playheadColor)
                        .frame(width: 1, height: 24)
                        .offset(x: playheadX - 0.5)
                }
                .border(borderColor, width: 1)
            }
            .contentShape(Rectangle())
            // Mouse Drag Scrubbing
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if engine.isPlaying {
                            engine.pause()
                        }
                        engine.isScrubbing = true
                        let x = max(0, min(value.location.x, width))
                        let progress = Double(x / width)
                        engine.seek(toProgress: progress)
                    }
                    .onEnded { value in
                        let x = max(0, min(value.location.x, width))
                        let progress = Double(x / width)
                        engine.seek(toProgress: progress) {
                            engine.isScrubbing = false
                        }
                        // Safety release to guarantee scrubber never locks playhead
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            engine.isScrubbing = false
                        }
                    }
            )
        }
        .frame(height: 46)
    }
    
    // MARK: - Playhead Arrow Head
    
    private var playheadArrow: some View {
        Canvas { context, size in
            var path = Path()
            // Sleek, compact Premiere Pro CTI marker (9x10px)
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 9, y: 0))
            path.addLine(to: CGPoint(x: 9, y: 5))
            path.addLine(to: CGPoint(x: 4.5, y: 10))
            path.addLine(to: CGPoint(x: 0, y: 5))
            path.closeSubpath()
            
            context.fill(path, with: .color(playheadColor))
            
            // Subtle 0.5px hairline highlight on top edge
            var highlight = Path()
            highlight.move(to: CGPoint(x: 0, y: 0))
            highlight.addLine(to: CGPoint(x: 9, y: 0))
            context.stroke(highlight, with: .color(.white.opacity(0.35)), lineWidth: 0.75)
        }
        .frame(width: 9, height: 10)
    }
    
    // MARK: - Glitch Marker Icon (Alert Diamond)
    
    private func glitchMarkerIcon(marker: PlayerTimelineMarker) -> some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 3.5, y: 0))
            path.addLine(to: CGPoint(x: 7, y: 3.5))
            path.addLine(to: CGPoint(x: 3.5, y: 7))
            path.addLine(to: CGPoint(x: 0, y: 3.5))
            path.closeSubpath()
            
            context.fill(path, with: .color(Color(red: 1.0, green: 0.25, blue: 0.25)))
        }
        .frame(width: 7, height: 7)
    }
    
    // MARK: - Ruler Ticks (5-Second Intervals)
    
    private func rulerTicksView(width: CGFloat) -> some View {
        Canvas { context, size in
            let durSecs = CMTimeGetSeconds(engine.duration)
            guard durSecs > 0 else { return }
            
            // Interval: 5 seconds for deliverables (or adaptive for long files so marks never collide)
            let intervalSecs: Double
            if width / (durSecs / 5.0) >= 60 {
                intervalSecs = 5.0
            } else if width / (durSecs / 10.0) >= 60 {
                intervalSecs = 10.0
            } else if width / (durSecs / 15.0) >= 60 {
                intervalSecs = 15.0
            } else {
                intervalSecs = 30.0
            }
            
            // 1. Draw 1-second minor ticks
            let minorStep: Double = intervalSecs <= 5.0 ? 1.0 : (intervalSecs / 5.0)
            var sec = 0.0
            while sec <= durSecs + 0.001 {
                let x = width * CGFloat(sec / durSecs)
                let rem = sec.truncatingRemainder(dividingBy: intervalSecs)
                let isMajor = rem < 0.001 || abs(rem - intervalSecs) < 0.001
                
                var tickPath = Path()
                if isMajor {
                    // Major tick mark
                    tickPath.move(to: CGPoint(x: x, y: size.height - 8))
                    tickPath.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tickPath, with: .color(majorTickColor), lineWidth: 1)
                } else {
                    // Minor 1-second tick mark
                    tickPath.move(to: CGPoint(x: x, y: size.height - 4))
                    tickPath.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tickPath, with: .color(tickColor), lineWidth: 1)
                }
                sec += minorStep
            }
            
            // 2. Draw 5-second timecode labels
            var labelSec = 0.0
            while labelSec <= durSecs + 0.001 {
                let x = width * CGFloat(labelSec / durSecs)
                let frame = Int(round(labelSec * max(1.0, engine.activeFps)))
                let tc = TimecodeFormatter.format(frameIndex: frame, fps: engine.activeFps)
                
                let text = Text(tc)
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundColor(textColor)
                
                let anchor: UnitPoint
                if x < 35 {
                    anchor = .leading
                } else if x > width - 35 {
                    anchor = .trailing
                } else {
                    anchor = .center
                }
                
                context.draw(text, at: CGPoint(x: x, y: 5), anchor: anchor)
                labelSec += intervalSecs
            }
        }
        .frame(width: width, height: 22)
    }
}
