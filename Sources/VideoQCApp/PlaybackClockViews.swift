import SwiftUI
import AppKit
import Combine

// Views that change on every video frame (timecode readouts, timeline playhead & fill) are drawn by AppKit /
// Core Animation and updated straight from `PlaybackClock`, so a frame tick never runs a SwiftUI transaction.
// Measured on playback: inside the window's view graph each tick cost a full layout + render pass (~4.7 ms);
// even an isolated NSHostingView per view cost ~0.6 ms per tick.

// MARK: - Live Playhead Text

/// Timecode or frame number that updates at frame rate. `template` is the widest string the field shows;
/// the hidden template Text reserves the exact layout size, so text changes never reach SwiftUI layout.
struct PlaybackClockText: View {
    enum Value {
        case timecode
        case frameNumber
    }

    let clock: PlaybackClock
    let value: Value
    let template: String
    let fontSize: CGFloat
    let color: Color
    var tracking: CGFloat = 0
    var alignment: Alignment = .leading
    /// Hover styling of the enclosing control, applied to the drawn text (nil = none).
    var hoverState: Bool? = nil

    var body: some View {
        Text(template)
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .tracking(tracking)
            .lineLimit(1)
            .hidden()
            .overlay {
                PlaybackClockTextRepresentable(
                    clock: clock,
                    value: value,
                    fontSize: fontSize,
                    color: NSColor(color),
                    kern: tracking,
                    alignment: alignment == .trailing ? .right : .left,
                    hoverState: hoverState
                )
            }
    }
}

private struct PlaybackClockTextRepresentable: NSViewRepresentable {
    let clock: PlaybackClock
    let value: PlaybackClockText.Value
    let fontSize: CGFloat
    let color: NSColor
    let kern: CGFloat
    let alignment: NSTextAlignment
    let hoverState: Bool?

    func makeNSView(context: Context) -> PlaybackClockTextNSView {
        PlaybackClockTextNSView()
    }

    func updateNSView(_ nsView: PlaybackClockTextNSView, context: Context) {
        nsView.configure(fontSize: fontSize, color: color, kern: kern, alignment: alignment, hoverState: hoverState)
        nsView.bind(to: clock, value: value)
    }
}

final class PlaybackClockTextNSView: NSView {
    private var subscription: AnyCancellable?
    private weak var boundClock: PlaybackClock?
    private var boundValue: PlaybackClockText.Value?
    private var text: String = ""
    private var attributes: [NSAttributedString.Key: Any] = [:]
    private var alignment: NSTextAlignment = .left
    private var hoverState: Bool?
    private var styleKey: String = ""

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func bind(to clock: PlaybackClock, value: PlaybackClockText.Value) {
        guard clock !== boundClock || value != boundValue else { return }
        boundClock = clock
        boundValue = value
        let texts: AnyPublisher<String, Never> = (value == .timecode)
            ? clock.$currentTimecode.eraseToAnyPublisher()
            : clock.$currentFrame.map { "\($0)" }.eraseToAnyPublisher()
        // @Published emits synchronously on the main actor (the clock is main-actor isolated).
        subscription = texts.removeDuplicates().sink { [weak self] newText in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.text = newText
                self.needsDisplay = true
            }
        }
    }

    func configure(fontSize: CGFloat, color: NSColor, kern: CGFloat, alignment: NSTextAlignment, hoverState: Bool?) {
        let key = "\(fontSize)|\(color)|\(kern)|\(alignment.rawValue)|\(String(describing: hoverState))"
        guard key != styleKey else { return }
        let previousHover = self.hoverState
        styleKey = key
        self.alignment = alignment
        self.hoverState = hoverState
        // Mirrors SwiftUI `.brightness(0.05)` on hover.
        let displayColor = (hoverState == true) ? Self.brightened(color, by: 0.05) : color
        attributes = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: displayColor,
            .kern: kern
        ]
        // Mirrors SwiftUI `.opacity(hovered ? 1.0 : 0.82)` with `.easeInOut(duration: 0.12)`.
        let targetAlpha: CGFloat = hoverState.map { $0 ? 1.0 : 0.82 } ?? 1.0
        if previousHover != nil && previousHover != hoverState {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = targetAlpha
            }
        } else {
            alphaValue = targetAlpha
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let x = (alignment == .right) ? bounds.width - size.width : 0
        string.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
    }

    private static func brightened(_ color: NSColor, by amount: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            srgbRed: min(1, rgb.redComponent + amount),
            green: min(1, rgb.greenComponent + amount),
            blue: min(1, rgb.blueComponent + amount),
            alpha: rgb.alphaComponent
        )
    }
}

// MARK: - Timeline Progress Fill

/// Played-progress fill of the timeline track (rounded 2 pt bar), moved by Core Animation from `PlaybackClock`.
struct TimelineProgressFill: NSViewRepresentable {
    let clock: PlaybackClock
    let dragProgress: Double?
    let color: Color

    func makeNSView(context: Context) -> TimelineProgressFillNSView {
        TimelineProgressFillNSView()
    }

    func updateNSView(_ nsView: TimelineProgressFillNSView, context: Context) {
        nsView.configure(color: NSColor(color).cgColor, dragProgress: dragProgress)
        nsView.bind(to: clock)
    }
}

final class TimelineProgressFillNSView: NSView {
    private let fillLayer = CALayer()
    private var subscription: AnyCancellable?
    private weak var boundClock: PlaybackClock?
    private var progress: Double = 0
    private var dragProgress: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fillLayer.cornerRadius = 2.0
        fillLayer.anchorPoint = .zero
        fillLayer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func bind(to clock: PlaybackClock) {
        guard clock !== boundClock else { return }
        boundClock = clock
        subscription = clock.$currentProgress.sink { [weak self] value in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.progress = value
                self.layoutFill()
            }
        }
    }

    func configure(color: CGColor, dragProgress: Double?) {
        self.dragProgress = dragProgress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = color
        CATransaction.commit()
        layoutFill()
    }

    override func layout() {
        super.layout()
        layoutFill()
    }

    private func layoutFill() {
        let fraction = CGFloat(min(1.0, max(0.0, dragProgress ?? progress)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width * fraction), height: bounds.height)
        CATransaction.commit()
    }
}

// MARK: - Timeline Playhead (CTI)

/// Needle + chevron head, positioned by Core Animation from `PlaybackClock` (or the live drag position).
/// Geometry matches the timeline's SwiftUI layout: needle at y 2 (43 pt tall), 11×13 chevron at y 1,
/// head scaled to 1.15 while dragging with `.spring(response: 0.2, dampingFraction: 0.7)`.
struct TimelinePlayhead: NSViewRepresentable {
    let clock: PlaybackClock
    let dragProgress: Double?
    let isDragging: Bool
    let trackInset: CGFloat
    let accent: Color
    let isLightMode: Bool

    func makeNSView(context: Context) -> TimelinePlayheadNSView {
        TimelinePlayheadNSView()
    }

    func updateNSView(_ nsView: TimelinePlayheadNSView, context: Context) {
        nsView.configure(
            accent: NSColor(accent).cgColor,
            strokeColor: (isLightMode ? NSColor.black.withAlphaComponent(0.20) : NSColor.white.withAlphaComponent(0.65)).cgColor,
            trackInset: trackInset,
            dragProgress: dragProgress,
            isDragging: isDragging
        )
        nsView.bind(to: clock)
    }
}

final class TimelinePlayheadNSView: NSView {
    private static let headSize = CGSize(width: 11, height: 13)

    private let needleLayer = CALayer()
    private let headLayer = CALayer()
    private let headFillLayer = CAShapeLayer()
    private let headStrokeLayer = CAShapeLayer()
    private let notchLayer = CALayer()

    private var subscription: AnyCancellable?
    private weak var boundClock: PlaybackClock?
    private var progress: Double = 0
    private var dragProgress: Double?
    private var isDragging: Bool = false
    private var trackInset: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let noActions: [String: CAAction] = [
            "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "transform": NSNull(),
            "backgroundColor": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "path": NSNull()
        ]

        needleLayer.actions = noActions

        // Chevron geometry uses SwiftUI's top-down path, flipped into this layer's bottom-up space.
        let headRect = CGRect(origin: .zero, size: Self.headSize)
        var flip = CGAffineTransform(translationX: 0, y: Self.headSize.height).scaledBy(x: 1, y: -1)
        let headPath = PlayheadChevronShape(tipProportion: 0.38, cornerRadius: 1.0).path(in: headRect).cgPath.copy(using: &flip)

        headLayer.bounds = headRect
        headLayer.actions = noActions

        headFillLayer.frame = headRect
        headFillLayer.path = headPath
        headFillLayer.shadowPath = headPath
        headFillLayer.shadowColor = NSColor.black.cgColor
        headFillLayer.shadowOpacity = 0.35
        headFillLayer.shadowRadius = 1.5
        headFillLayer.shadowOffset = CGSize(width: 0, height: -1)
        headFillLayer.actions = noActions

        headStrokeLayer.frame = headRect
        headStrokeLayer.path = headPath
        headStrokeLayer.fillColor = nil
        headStrokeLayer.lineWidth = 0.75
        headStrokeLayer.actions = noActions

        // Micro-notch center line: 1 × 4.5 pt, centered, raised 1.5 pt.
        notchLayer.backgroundColor = NSColor.white.withAlphaComponent(0.90).cgColor
        notchLayer.frame = CGRect(x: 5.0, y: 5.75, width: 1.0, height: 4.5)
        notchLayer.actions = noActions

        headLayer.addSublayer(headFillLayer)
        headLayer.addSublayer(headStrokeLayer)
        headLayer.addSublayer(notchLayer)
        layer?.addSublayer(needleLayer)
        layer?.addSublayer(headLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func bind(to clock: PlaybackClock) {
        guard clock !== boundClock else { return }
        boundClock = clock
        subscription = clock.$currentProgress.sink { [weak self] value in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.progress = value
                self.layoutPlayhead()
            }
        }
    }

    func configure(accent: CGColor, strokeColor: CGColor, trackInset: CGFloat, dragProgress: Double?, isDragging: Bool) {
        let dragStateChanged = (isDragging != self.isDragging)
        self.trackInset = trackInset
        self.dragProgress = dragProgress
        self.isDragging = isDragging
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        needleLayer.backgroundColor = accent
        headFillLayer.fillColor = accent
        headStrokeLayer.strokeColor = strokeColor
        CATransaction.commit()
        if dragStateChanged {
            animateHeadScale(to: isDragging ? 1.15 : 1.0)
        }
        layoutPlayhead()
    }

    override func layout() {
        super.layout()
        layoutPlayhead()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2.0
        headFillLayer.contentsScale = scale
        headStrokeLayer.contentsScale = scale
    }

    private func layoutPlayhead() {
        let fraction = CGFloat(min(1.0, max(0.0, dragProgress ?? progress)))
        let trackWidth = max(1.0, bounds.width - trackInset * 2)
        let playheadX = trackInset + trackWidth * fraction
        let needleWidth: CGFloat = isDragging ? 1.75 : 1.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Bottom-up layer space: SwiftUI y (from the top) → bounds.height - y - height.
        needleLayer.frame = CGRect(x: playheadX - needleWidth / 2, y: bounds.height - 2 - 43, width: needleWidth, height: 43)
        headLayer.position = CGPoint(x: playheadX, y: bounds.height - 1 - Self.headSize.height / 2)
        CATransaction.commit()
    }

    private func animateHeadScale(to scale: CGFloat) {
        let current = (headLayer.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? (scale == 1.0 ? 1.15 : 1.0)
        // SwiftUI .spring(response: 0.2, dampingFraction: 0.7) with unit mass.
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.2, 2)
        spring.damping = 4 * .pi * 0.7 / 0.2
        spring.fromValue = current
        spring.toValue = scale
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        headLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        headLayer.add(spring, forKey: "dragScale")
    }
}
