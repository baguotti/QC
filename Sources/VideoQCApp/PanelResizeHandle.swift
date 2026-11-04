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
    /// Extra grab area outside the panel, across the edge. 0 next to the video viewport (it sets its own cursor on
    /// every mouse move); elsewhere 6 makes the edge easy to catch. The panel must sit above its neighbour (zIndex).
    var reach: CGFloat = 0

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startWidth = 0.0

    static let hitWidth: CGFloat = 16
    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        // [inside the panel | line at the edge | reach outside], laid out from the panel's edge outward.
        HStack(spacing: 0) {
            if edge == .leading { Color.clear.frame(width: reach) }
            ZStack(alignment: edge == .trailing ? .trailing : .leading) {
                Color.clear
                Rectangle()
                    .fill(isDragging ? palette.accentBlue : (isHovering ? Self.hoverLine(isLightMode) : Color.clear))
                    .frame(width: isDragging ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .frame(width: Self.hitWidth)
            if edge == .trailing { Color.clear.frame(width: reach) }
        }
        .background(ResizeCursorArea())
        .offset(x: edge == .trailing ? reach : -reach)
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

/// A side panel that owns its width (remembered under `widthKey`) and its resize handle: dragging re-lays out this panel
/// and its neighbours, never re-runs the view that built it (`ContentView`, the whole window).
struct ResizableSidePanel<Content: View>: View {
    let edge: HorizontalEdge
    let range: ClosedRange<Double>
    let defaultWidth: Double
    let isLightMode: Bool
    let help: String
    @ViewBuilder let content: () -> Content
    @AppStorage private var width: Double

    init(widthKey: String, edge: HorizontalEdge, range: ClosedRange<Double>, defaultWidth: Double, isLightMode: Bool,
         help: String, @ViewBuilder content: @escaping () -> Content) {
        self.edge = edge
        self.range = range
        self.defaultWidth = defaultWidth
        self.isLightMode = isLightMode
        self.help = help
        self.content = content
        _width = AppStorage(wrappedValue: defaultWidth, widthKey)
    }

    var body: some View {
        content()
            .frame(width: min(range.upperBound, max(range.lowerBound, width)))
            .overlay(alignment: edge == .trailing ? .trailing : .leading) {
                PanelResizeHandle(width: $width, range: range, defaultWidth: defaultWidth, isLightMode: isLightMode,
                                  help: help, edge: edge == .trailing ? .trailing : .leading, reach: 6)
            }
            .zIndex(1)   // above the neighbour the handle reaches into
    }
}
