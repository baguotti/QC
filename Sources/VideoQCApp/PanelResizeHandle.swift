import SwiftUI
import AppKit

/// Vertical divider that resizes the panel it is overlaid on (trailing edge): a hairline that brightens on hover and
/// turns accent while dragging, with the system resize cursor (AppKit cursor rect). The grab area stays inside the
/// panel: the video viewport sets its own cursor on every mouse move and would override a handle overlapping it.
/// Double-click restores the default width.
struct PanelResizeHandle: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double
    let isLightMode: Bool
    let help: String
    /// The panel edge the handle sits on: `.leading` for a panel on the right (dragging left widens it).
    var edge: HorizontalEdge = .trailing

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startWidth = 0.0

    static let hitWidth: CGFloat = 12
    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        ZStack(alignment: edge == .trailing ? .trailing : .leading) {
            ResizeCursorArea()
            Rectangle()
                .fill(isDragging ? palette.accentBlue : (isHovering ? Self.hoverLine(isLightMode) : Color.clear))
                .frame(width: isDragging ? 2 : 1)
                .allowsHitTesting(false)
        }
        .frame(width: Self.hitWidth)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Motion.hover, value: isHovering)
        .onTapGesture(count: 2) {
            withAnimation(Motion.sleeve) { width = min(range.upperBound, defaultWidth) }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        startWidth = width
                        NSCursor.resizeLeftRight.push()   // keep the cursor while the pointer outruns the handle
                    }
                    let delta = Double(value.translation.width) * (edge == .trailing ? 1 : -1)
                    let clamped = min(range.upperBound, max(range.lowerBound, startWidth + delta))
                    if abs(width - clamped) > 0.5 { width = clamped }
                }
                .onEnded { _ in
                    isDragging = false
                    NSCursor.pop()
                }
        )
        .explain(help)
    }

    /// Hover colour for resize hairlines: a step brighter than `borderStrong`.
    static func hoverLine(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.48) : Color(white: 0.46)
    }
}

/// Transparent area that shows the left/right resize cursor (AppKit cursor rect).
struct ResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {}

    final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // gestures stay with SwiftUI
    }
}
