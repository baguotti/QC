import SwiftUI

/// Direction for the text roll animation.
public enum SlotRollDirection: Sendable {
    case down // Incoming enters from top, outgoing exits to bottom
    case up   // Incoming enters from bottom, outgoing exits to top
}

/// Granularity of the roll transition.
public enum SlotRollMode: Sendable {
    case character // Rolls glyph-by-glyph with subtle mechanical stagger
    case word      // Rolls the entire phrase / word as one unit
}

private struct SlotItem: Identifiable, Equatable {
    let id: Int
    var segment: String
}

/// Tactile, dependency-free text roll animation component inspired by slot-text / textmotion.
/// Subtle mechanical vertical slide with spring easing, intrinsic sizing, and vertical clipping.
public struct SlotText: View {
    public let text: String
    public var mode: SlotRollMode
    public var direction: SlotRollDirection
    public var font: Font
    public var foregroundColor: Color
    public var tracking: CGFloat
    public var stagger: Double
    public var rollDistance: CGFloat
    public var animateOnAppear: Bool
    
    public var trigger: AnyHashable?
    public var rollOnHover: Bool
    
    @State private var items: [SlotItem] = []
    @State private var isInitialMount: Bool = true
    @State private var hoverTriggerId = UUID()
    
    public init(
        _ text: String,
        mode: SlotRollMode = .character,
        direction: SlotRollDirection = .down,
        font: Font = .system(size: 10, weight: .bold, design: .monospaced),
        foregroundColor: Color = .primary,
        tracking: CGFloat = 0.5,
        stagger: Double = 0.025,
        rollDistance: CGFloat = 14,
        animateOnAppear: Bool = false,
        trigger: AnyHashable? = nil,
        rollOnHover: Bool = false
    ) {
        self.text = text
        self.mode = mode
        self.direction = direction
        self.font = font
        self.foregroundColor = foregroundColor
        self.tracking = tracking
        self.stagger = stagger
        self.rollDistance = rollDistance
        self.animateOnAppear = animateOnAppear
        self.trigger = trigger
        self.rollOnHover = rollOnHover
        
        let initial = Self.makeItems(from: text, mode: mode)
        _items = State(initialValue: initial)
    }
    
    private static func makeItems(from string: String, mode: SlotRollMode) -> [SlotItem] {
        switch mode {
        case .character:
            return string.enumerated().map { SlotItem(id: $0.offset, segment: String($0.element)) }
        case .word:
            return [SlotItem(id: 0, segment: string)]
        }
    }
    
    private var activeTrigger: AnyHashable {
        AnyHashable([trigger, rollOnHover ? AnyHashable(hoverTriggerId) : nil])
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                SlotSegmentCell(
                    segment: item.segment,
                    index: item.id,
                    direction: direction,
                    font: font,
                    foregroundColor: foregroundColor,
                    tracking: tracking,
                    stagger: stagger,
                    rollDistance: rollDistance,
                    animateOnAppear: animateOnAppear || !isInitialMount,
                    trigger: activeTrigger
                )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if rollOnHover && hovering {
                hoverTriggerId = UUID()
            }
        }
        .onAppear {
            sync(to: text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isInitialMount = false
            }
        }
        .onChange(of: text) { _, newText in
            sync(to: newText)
        }
    }
    
    private func sync(to newText: String) {
        switch mode {
        case .word:
            if items.isEmpty {
                items = [SlotItem(id: 0, segment: newText)]
            } else {
                items[0].segment = newText
            }
        case .character:
            let newChars = Array(newText).map { String($0) }
            let maxCount = max(items.count, newChars.count)
            var updated: [SlotItem] = []
            for i in 0..<maxCount {
                let ch = i < newChars.count ? newChars[i] : ""
                updated.append(SlotItem(id: i, segment: ch))
            }
            items = updated
            
            // If target is shorter, prune collapsed trailing slots after animation finishes
            if newChars.count < items.count {
                let pruneDelay = Double(maxCount) * stagger + 0.35
                DispatchQueue.main.asyncAfter(deadline: .now() + pruneDelay) {
                    if self.items.count > newChars.count {
                        self.items = Array(self.items.prefix(newChars.count))
                    }
                }
            }
        }
    }
}

public struct SlotSegmentCell: View {
    public let segment: String
    public let index: Int
    public let direction: SlotRollDirection
    public let font: Font
    public let foregroundColor: Color
    public let tracking: CGFloat
    public let stagger: Double
    public let rollDistance: CGFloat
    public let animateOnAppear: Bool
    public let trigger: AnyHashable?
    
    @State private var currentSegment: String
    @State private var previousSegment: String? = nil
    @State private var rollProgress: CGFloat = 1.0
    
    public init(
        segment: String,
        index: Int,
        direction: SlotRollDirection,
        font: Font,
        foregroundColor: Color,
        tracking: CGFloat,
        stagger: Double,
        rollDistance: CGFloat,
        animateOnAppear: Bool = false,
        trigger: AnyHashable? = nil
    ) {
        self.segment = segment
        self.index = index
        self.direction = direction
        self.font = font
        self.foregroundColor = foregroundColor
        self.tracking = tracking
        self.stagger = stagger
        self.rollDistance = rollDistance
        self.animateOnAppear = animateOnAppear
        self.trigger = trigger
        _currentSegment = State(initialValue: segment)
        _rollProgress = State(initialValue: animateOnAppear ? 0.0 : 1.0)
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            // Sizer: determines exact intrinsic width and height without GeometryReader explosion
            if !currentSegment.isEmpty {
                Text(currentSegment)
                    .font(font)
                    .tracking(tracking)
                    .opacity(0)
                    .accessibilityHidden(true)
            } else if let prev = previousSegment, !prev.isEmpty, rollProgress < 1.0 {
                Text(prev)
                    .font(font)
                    .tracking(tracking)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            
            // Rolling Face Layer
            ZStack(alignment: .center) {
                let inOffset = (direction == .down ? -rollDistance : rollDistance) * (1.0 - rollProgress)
                let outOffset = (direction == .down ? rollDistance : -rollDistance) * rollProgress
                
                // Outgoing face (slides out & fades)
                if let prev = previousSegment, !prev.isEmpty, rollProgress < 1.0 {
                    Text(prev)
                        .font(font)
                        .tracking(tracking)
                        .foregroundColor(foregroundColor)
                        .offset(y: outOffset)
                        .opacity(Double(max(0, 1.0 - rollProgress * 1.3)))
                }
                
                // Incoming face (slides in & settles)
                if !currentSegment.isEmpty {
                    Text(currentSegment)
                        .font(font)
                        .tracking(tracking)
                        .foregroundColor(foregroundColor)
                        .offset(y: inOffset)
                        .opacity(Double(min(1.0, 0.2 + rollProgress * 0.8)))
                }
            }
        }
        .clipped()
        .onAppear {
            if animateOnAppear {
                let delay = Double(index) * stagger
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                        rollProgress = 1.0
                    }
                }
            }
        }
        .onChange(of: segment) { oldVal, newVal in
            guard oldVal != newVal else { return }
            previousSegment = currentSegment
            currentSegment = newVal
            rollProgress = 0.0
            
            let delay = Double(index) * stagger
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                    rollProgress = 1.0
                }
            }
        }
        .onChange(of: trigger) { oldTrig, newTrig in
            guard oldTrig != newTrig else { return }
            if let boolVal = newTrig as? Bool, !boolVal {
                return
            }
            triggerRoll()
        }
    }
    
    private func triggerRoll() {
        guard !currentSegment.isEmpty else { return }
        previousSegment = currentSegment
        rollProgress = 0.0
        
        let delay = Double(index) * stagger
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.76)) {
                rollProgress = 1.0
            }
        }
    }
}
