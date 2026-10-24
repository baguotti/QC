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
            
            // Label step: the smallest "nice" interval whose labels (measured) keep a clear gap at this width.
            let fpsSafe = max(1.0, fps)
            let sample = context.resolve(Text(TimecodeFormatter.format(frameIndex: 0, fps: fpsSafe))
                .font(.system(size: StudioTheme.scaleFont(8), weight: .semibold, design: .monospaced)))
            let labelWidth = sample.measure(in: CGSize(width: 400, height: 40)).width
            let pointsPerSecond = trackWidth / CGFloat(duration)
            let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
            let intervalSecs = steps.first { CGFloat($0) * pointsPerSecond >= labelWidth + 24 } ?? steps[steps.count - 1]
            
            // Minor ticks: subdivide the label step, keeping at least ~6 pt between ticks.
            let subdivisions: [Double] = [10, 6, 5, 4, 3, 2, 1]
            let minorDivisor = subdivisions.first { CGFloat(intervalSecs / $0) * pointsPerSecond >= 6 && (intervalSecs / $0) >= 1 } ?? 1
            let minorStep = intervalSecs / minorDivisor
            
            var tick = 0
            while Double(tick) * minorStep <= duration + 0.001 {
                let sec = Double(tick) * minorStep
                let x = trackInset + trackWidth * CGFloat(sec / duration)
                let isMajor = tick % Int(minorDivisor) == 0
                var tickPath = Path()
                let tickH: CGFloat = isMajor ? 5.5 : 3.0
                tickPath.move(to: CGPoint(x: x, y: size.height - tickH))
                tickPath.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tickPath, with: .color(isMajor ? majorTickColor : tickColor), lineWidth: 1)
                tick += 1
            }
            
            // Timecode labels, skipping any that would still touch the previous one (e.g. at the track ends).
            var lastLabelMaxX = -CGFloat.greatestFiniteMagnitude
            var labelIndex = 0
            while Double(labelIndex) * intervalSecs <= duration + 0.001 {
                let labelSec = Double(labelIndex) * intervalSecs
                labelIndex += 1
                let x = trackInset + trackWidth * CGFloat(labelSec / duration)
                let tc = TimecodeFormatter.format(frameIndex: Int(round(labelSec * fpsSafe)), fps: fpsSafe)
                let text = context.resolve(Text(tc)
                    .font(.system(size: StudioTheme.scaleFont(8), weight: .semibold, design: .monospaced))
                    .foregroundColor(textColor))
                let w = text.measure(in: CGSize(width: 400, height: 40)).width
                let anchor: UnitPoint
                let minX: CGFloat
                if x - w / 2 < 0 {
                    anchor = .topLeading
                    minX = x
                } else if x + w / 2 > width {
                    anchor = .topTrailing
                    minX = x - w
                } else {
                    anchor = .top
                    minX = x - w / 2
                }
                guard minX >= lastLabelMaxX + 8 else { continue }
                context.draw(text, at: CGPoint(x: x, y: 6), anchor: anchor)
                lastLabelMaxX = minX + w
            }
        }
        .frame(width: width, height: 22)
    }
}

// MARK: - Downward-Pointing Playhead Chevron Shape (CTI)

struct PlayheadChevronShape: Shape {
    var tipProportion: CGFloat = 0.38 // 38% of height tapers into a crisp downward chevron
    var cornerRadius: CGFloat = 1.0
    
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

// MARK: - Equatable Glitch & Note Marks
// Re-evaluated only when markers, notes or geometry change (not on hover, drag or playhead updates).

struct TimelineMarks: View, Equatable {
    struct NoteMark: Equatable {
        let frame: Int
        let colorTag: String
    }
    
    enum Style: Equatable {
        case rulerPips
        case trackBars
    }
    
    let style: Style
    let markerFrames: [Int]
    let notes: [NoteMark]
    let durSecs: Double
    let fps: Double
    let trackWidth: CGFloat
    let trackInset: CGFloat
    
    private static let markerColor = Color(red: 0.85, green: 0.38, blue: 0.38)
    
    private func ratio(for frame: Int) -> CGFloat {
        let secs = (Double(frame) + 0.5) / max(1.0, fps)
        return CGFloat(min(1.0, max(0.0, secs / durSecs)))
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            if durSecs > 0 {
                marks
            }
        }
    }
    
    @ViewBuilder
    private var marks: some View {
        switch style {
        case .rulerPips:
            ForEach(Array(markerFrames.enumerated()), id: \.offset) { _, frame in
                Circle()
                    .fill(Self.markerColor)
                    .frame(width: 3.5, height: 3.5)
                    .shadow(color: Color.red.opacity(0.35), radius: 1)
                    .position(x: trackInset + trackWidth * ratio(for: frame), y: 20)
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Circle()
                    .fill(QCNoteTheme.color(for: note.colorTag))
                    .frame(width: 4.5, height: 4.5)
                    .shadow(color: QCNoteTheme.color(for: note.colorTag).opacity(0.35), radius: 1)
                    .position(x: trackInset + trackWidth * ratio(for: note.frame), y: 20)
            }
        case .trackBars:
            ForEach(Array(markerFrames.enumerated()), id: \.offset) { _, frame in
                Rectangle()
                    .fill(Self.markerColor)
                    .frame(width: 1.5, height: 10)
                    .position(x: trackWidth * ratio(for: frame), y: 5)
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                Rectangle()
                    .fill(QCNoteTheme.color(for: note.colorTag))
                    .frame(width: 1.5, height: 10)
                    .position(x: trackWidth * ratio(for: note.frame), y: 5)
            }
        }
    }
}

// MARK: - Audio Waveform (drawn once per file / size, never per frame)

struct TimelineWaveform: View, Equatable {
    let peaks: [Float]
    let color: Color
    
    nonisolated static func == (lhs: TimelineWaveform, rhs: TimelineWaveform) -> Bool {
        lhs.color == rhs.color && lhs.peaks == rhs.peaks
    }
    
    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, size.width > 0 else { return }
            // One bar per pixel column, each the loudest bin it covers, mirrored around the centre line.
            let columns = max(1, Int(size.width))
            let midY = size.height / 2
            var path = Path()
            for column in 0..<columns {
                let start = column * peaks.count / columns
                let end = max(start + 1, (column + 1) * peaks.count / columns)
                let peak = peaks[start..<min(end, peaks.count)].max() ?? 0
                let half = max(0.5, CGFloat(peak) * midY)
                path.addRect(CGRect(x: CGFloat(column), y: midY - half, width: 1, height: half * 2))
            }
            context.fill(path, with: .color(color))
        }
    }
}

// MARK: - Main Modern Minimal Timeline Scrubber View

public struct TimelineScrubberView: View {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool
    
    @State private var isDragging: Bool = false
    @State private var dragProgress: Double? = nil
    @State private var hoverX: CGFloat? = nil
    @State private var isHovering: Bool = false
    @State private var dragInitialProgress: Double = 0.0
    @State private var isGrabbingPlayhead: Bool = false
    /// Waveform lane under the scrub track; Shift + scroll over the timeline resizes it.
    @AppStorage("waveformLaneHeight") private var waveformLaneHeight: Double = 32
    private static let waveformLaneRange: ClosedRange<Double> = 20...200
    
    // Inset from outer container edges to float the track and protect playhead
    private let trackInset: CGFloat = 6.0
    
    // Theme colors
    private var containerBg: Color { isLightMode ? Color(white: 0.94) : Color(white: 0.125) }
    private var containerBorder: Color { isLightMode ? Color(white: 0.80) : Color(white: 0.15) }
    private var rulerDivider: Color { isLightMode ? Color(white: 0.86) : Color(white: 0.11) }
    
    private var trackGrooveBg: Color { isLightMode ? Color(white: 0.88) : Color(white: 0.09) }
    private var trackGrooveBorder: Color { isLightMode ? Color(white: 0.78) : Color(white: 0.10) }
    
    private var playheadAccent: Color { StudioTheme.accentBlue(isLightMode) }
    
    public init(engine: PlayerEngine, isLightMode: Bool) {
        self.engine = engine
        self.isLightMode = isLightMode
    }
    
    public var body: some View {
        GeometryReader { geo in
            let width = max(20, geo.size.width)
            let trackWidth = max(1.0, width - (trackInset * 2))
            let durSecs = CMTimeGetSeconds(engine.duration)
            let markerFrames = engine.activeMarkers.map(\.frameIndex)
            let noteMarks = engine.activeNotes.map { TimelineMarks.NoteMark(frame: $0.frameIndex, colorTag: $0.colorTag) }
            
            ZStack(alignment: .topLeading) {
                // Unified Studio Bezel Container (4px radius matching app design system)
                RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                    .fill(containerBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                            .stroke(containerBorder, lineWidth: 1)
                    )
                
                // Hairline Divider between Ruler and Scrubber Track
                Rectangle()
                    .fill(rulerDivider)
                    .frame(height: 0.75)
                    .offset(y: 22)
                
                // MARK: - Time Ruler (Top 22px)
                ZStack(alignment: .topLeading) {
                    RulerTicksCanvasView(
                        duration: durSecs,
                        fps: engine.activeFps,
                        width: width,
                        trackInset: trackInset,
                        isLightMode: isLightMode
                    )
                    .equatable()
                    
                    // Glitch & Review Note Pips on Ruler
                    TimelineMarks(
                        style: .rulerPips,
                        markerFrames: markerFrames,
                        notes: noteMarks,
                        durSecs: durSecs,
                        fps: engine.activeFps,
                        trackWidth: trackWidth,
                        trackInset: trackInset
                    )
                    .equatable()
                }
                .frame(height: 22)
                
                // MARK: - Precision Scrubber Track (Height: 10px, centered in lower 24px area at y=29)
                ZStack(alignment: .leading) {
                    // Recessed Precision Track Bed
                    RoundedRectangle(cornerRadius: 2.0)
                        .fill(trackGrooveBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2.0)
                                .stroke(trackGrooveBorder, lineWidth: 1.0)
                        )
                        .frame(width: trackWidth, height: 10)
                    
                    // Played Progress Fill (Solid theme accent; moved per frame by Core Animation, see PlaybackClockViews)
                    TimelineProgressFill(
                        clock: engine.clock,
                        dragProgress: dragProgress,
                        color: playheadAccent
                    )
                    .frame(width: trackWidth, height: 10)
                    
                    // Glitch & Review Note Markers Inside Track (Crisp 1.5px vertical bars)
                    TimelineMarks(
                        style: .trackBars,
                        markerFrames: markerFrames,
                        notes: noteMarks,
                        durSecs: durSecs,
                        fps: engine.activeFps,
                        trackWidth: trackWidth,
                        trackInset: trackInset
                    )
                    .equatable()
                }
                .frame(width: trackWidth, height: 10)
                .offset(x: trackInset, y: 29)
                
                if hasWaveform {
                    TimelineWaveform(peaks: engine.waveformPeaks, color: (isLightMode ? Color.black : Color.white).opacity(0.55))
                        .equatable()
                        .frame(width: trackWidth, height: waveformLaneHeight)
                        .background(RoundedRectangle(cornerRadius: 2.0).fill(trackGrooveBg))
                        .offset(x: trackInset, y: 46)
                        .allowsHitTesting(false)
                }
                
                // MARK: - Hover Ghost Needle
                if let hX = hoverX, isHovering && !isDragging && durSecs > 0 {
                    let clampedHX = max(trackInset, min(hX, width - trackInset))
                    
                    // Subtle Ghost Needle (hairline guide)
                    Rectangle()
                        .fill(isLightMode ? Color.black.opacity(0.18) : Color.white.opacity(0.18))
                        .frame(width: 1, height: 42 + (hasWaveform ? waveformLaneHeight + 4 : 0))
                        .offset(x: clampedHX - 0.5, y: 2)
                        .allowsHitTesting(false)
                }
                
                // MARK: - Modern Tactile Playhead (CTI; moved per frame by Core Animation, see PlaybackClockViews)
                TimelinePlayhead(
                    clock: engine.clock,
                    dragProgress: dragProgress,
                    isDragging: isDragging,
                    trackInset: trackInset,
                    accent: playheadAccent,
                    isLightMode: isLightMode
                )
                .allowsHitTesting(false)
                
                // Native AppKit Scroll Wheel & Trackpad Interceptor
                TimelineScrollTrackerView(laneTop: 46, onLaneScroll: hasWaveform ? { amount, isPrecise in
                    // Scrolling over the waveform lane makes it taller / shorter (like Premiere's track height).
                    let points = Double(amount) * (isPrecise ? 0.5 : 4)
                    waveformLaneHeight = min(Self.waveformLaneRange.upperBound, max(Self.waveformLaneRange.lowerBound, waveformLaneHeight + points))
                } : nil) { delta, phase, isPrecise in
                    let durSecs = CMTimeGetSeconds(engine.duration)
                    guard durSecs > 0, durSecs.isFinite, !durSecs.isNaN else { return }
                    let trackWidth = max(1.0, width - (trackInset * 2))
                    
                    if isPrecise {
                        let progressDelta = Double(delta / trackWidth)
                        let currentProg = dragProgress ?? engine.currentProgress
                        let newProg = min(1.0, max(0.0, currentProg + progressDelta))
                        
                        if phase.contains(.began) {
                            isDragging = true
                            dragProgress = newProg
                            engine.startScrubbing()
                            engine.scrubTo(progress: newProg)
                        } else if phase.contains(.changed) {
                            dragProgress = newProg
                            engine.scrubTo(progress: newProg)
                        } else if phase.contains(.ended) || phase.contains(.cancelled) {
                            isDragging = false
                            dragProgress = nil
                            engine.endScrubbing(at: newProg)
                        } else {
                            dragProgress = newProg
                            engine.scrubTo(progress: newProg)
                        }
                    } else {
                        let forward = delta > 0
                        engine.stepFrames(count: 1, forward: forward)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius))
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
                        let trackWidth = max(1.0, width - (trackInset * 2))
                        if !isDragging {
                            isDragging = true
                            dragInitialProgress = engine.currentProgress
                            let curPlayheadX = trackInset + trackWidth * CGFloat(min(1.0, max(0.0, engine.currentProgress)))
                            // If user touches on or within 14pt of the playhead chevron, grab without jumping
                            if abs(value.startLocation.x - curPlayheadX) <= 14 {
                                isGrabbingPlayhead = true
                            } else {
                                isGrabbingPlayhead = false
                            }
                            engine.startScrubbing()
                        }
                        
                        let progress: Double
                        if isGrabbingPlayhead {
                            let deltaX = value.location.x - value.startLocation.x
                            progress = min(1.0, max(0.0, dragInitialProgress + Double(deltaX / trackWidth)))
                        } else {
                            let x = max(trackInset, min(value.location.x, width - trackInset))
                            progress = Double((x - trackInset) / trackWidth)
                        }
                        dragProgress = progress
                        engine.scrubTo(progress: progress)
                    }
                    .onEnded { value in
                        isDragging = false
                        let trackWidth = max(1.0, width - (trackInset * 2))
                        let progress: Double
                        if isGrabbingPlayhead {
                            let deltaX = value.location.x - value.startLocation.x
                            progress = min(1.0, max(0.0, dragInitialProgress + Double(deltaX / trackWidth)))
                        } else {
                            let x = max(trackInset, min(value.location.x, width - trackInset))
                            progress = Double((x - trackInset) / trackWidth)
                        }
                        isGrabbingPlayhead = false
                        dragProgress = nil
                        engine.endScrubbing(at: progress)
                    }
            )
        }
        .frame(height: 46 + (hasWaveform ? waveformLaneHeight + 4 : 0))
        .padding(.vertical, 3)
    }
    
    private var hasWaveform: Bool { !engine.waveformPeaks.isEmpty }
}

// MARK: - Native AppKit Scroll Wheel & Trackpad Gesture View

struct TimelineScrollTrackerView: NSViewRepresentable {
    /// Distance from the top where the waveform lane starts; vertical scrolling below it goes to `onLaneScroll`.
    var laneTop: CGFloat = 0
    var onLaneScroll: ((CGFloat, Bool) -> Void)? = nil
    var onScroll: (CGFloat, NSEvent.Phase, Bool) -> Void
    
    func makeNSView(context: Context) -> TimelineScrollNSView {
        let view = TimelineScrollNSView()
        updateNSView(view, context: context)
        return view
    }
    
    func updateNSView(_ nsView: TimelineScrollNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onLaneScroll = onLaneScroll
        nsView.laneTop = laneTop
    }
}

final class TimelineScrollNSView: NSView {
    var onScroll: ((CGFloat, NSEvent.Phase, Bool) -> Void)?
    var onLaneScroll: ((CGFloat, Bool) -> Void)?
    var laneTop: CGFloat = 0
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Intercept scroll wheel events so trackpad two-finger swipes and mouse wheel are handled here,
        // but return nil for mouse clicks so SwiftUI's DragGesture continues to handle clicking and dragging.
        if let currentEvent = NSApp.currentEvent, currentEvent.type == .scrollWheel {
            return self
        }
        return nil
    }
    
    override func scrollWheel(with event: NSEvent) {
        if let onLaneScroll, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            let point = convert(event.locationInWindow, from: nil)
            let fromTop = isFlipped ? point.y : bounds.height - point.y
            if fromTop >= laneTop {
                onLaneScroll(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                return
            }
        }
        let delta: CGFloat
        let isPrecise = event.hasPreciseScrollingDeltas
        
        if abs(event.scrollingDeltaX) > 0.001 {
            delta = event.scrollingDeltaX
        } else if abs(event.scrollingDeltaY) > 0.001 {
            // Invert Y: scrolling up or right advances forward; scrolling down or left goes backward
            delta = -event.scrollingDeltaY
        } else {
            super.scrollWheel(with: event)
            return
        }
        
        let phase = event.phase.isEmpty ? event.momentumPhase : event.phase
        onScroll?(delta, phase, isPrecise)
    }
}
