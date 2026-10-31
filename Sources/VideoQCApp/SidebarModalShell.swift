import SwiftUI
import AppKit

/// Window-style modal with a source list on the left and a detail pane on the right (Premiere Pro preferences,
/// Apple Help): used by User Settings and the User Guide.
struct SidebarModalShell<Sidebar: View, Detail: View>: View {
    @Binding var isPresented: Bool
    let title: String
    var width: CGFloat = 720
    var height: CGFloat = 500
    var sidebarWidth: CGFloat = 180
    var footnote: String? = nil
    /// When set, the window can be resized by dragging its corners; the size is remembered under this key.
    var resizeKey: String? = nil
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @State private var size: CGSize?
    @State private var dragStart: CGSize?
    /// A resize cursor is pushed (hover events can arrive unpaired: pop only what was pushed).
    @State private var cursorPushed = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        ZStack {
            Color.black.opacity(isPresented ? 0.55 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                Text(title)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(palette.bgCardHeader)

                Rectangle().fill(palette.borderLine).frame(height: 1)

                HStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            sidebar
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: sidebarWidth)
                    .background(palette.bgCardSubtle)

                    Rectangle().fill(palette.borderLine).frame(width: 1)

                    ScrollView(.vertical, showsIndicators: true) {
                        detail
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .background(palette.bgPanel)
                }

                Rectangle().fill(palette.borderLine).frame(height: 1)

                HStack {
                    if let footnote {
                        Text(footnote)
                            .font(.ui(size: 11))
                            .foregroundColor(palette.textMuted)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Text("Done")
                            .font(.ui(size: 12, weight: .medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 5)
                            .foregroundColor(palette.primaryBtnFg)
                            .background(palette.primaryBtnBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.bgCardHeader)
            }
            .frame(width: currentSize.width, height: currentSize.height)
            .background(palette.bgPanel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.borderStrong, lineWidth: 1))
            .overlay { if resizeKey != nil { resizeCorners } }
            .shadow(color: Color.black.opacity(0.45), radius: 28, x: 0, y: 14)

            Button("") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(isPresented)
    }

    private var currentSize: CGSize {
        if let size { return size }
        if let resizeKey, let saved = UserDefaults.standard.string(forKey: resizeKey).map(NSSizeFromString),
           saved.width > 0 { return clamped(saved) }
        return CGSize(width: width, height: height)
    }

    private func clamped(_ s: CGSize) -> CGSize {
        let screen = NSApp.keyWindow?.frame.size ?? CGSize(width: 1600, height: 1000)
        return CGSize(width: min(max(s.width, width * 0.8), screen.width - 40),
                      height: min(max(s.height, 380), screen.height - 40))
    }

    /// Invisible hit areas on the four corners. The modal stays centred, so each side moves by half the size change:
    /// the size grows by twice the drag to keep the corner under the cursor. Measured in global space, since the
    /// corners themselves move while dragging (local coordinates would feed that motion back and jitter).
    private var resizeCorners: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) { corner(-1, -1); Spacer(); corner(1, -1) }
            Spacer()
            HStack(spacing: 0) { corner(-1, 1); Spacer(); corner(1, 1) }
        }
    }

    private func corner(_ dx: CGFloat, _ dy: CGFloat) -> some View {
        Color.clear
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? currentSize
                    dragStart = start
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        size = clamped(CGSize(width: start.width + value.translation.width * 2 * dx,
                                              height: start.height + value.translation.height * 2 * dy))
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    if let resizeKey, let size { UserDefaults.standard.set(NSStringFromSize(size), forKey: resizeKey) }
                })
            .onHover { inside in
                guard inside != cursorPushed else { return }
                cursorPushed = inside
                guard inside else { NSCursor.pop(); return }
                if #available(macOS 15, *) {
                    let position: NSCursor.FrameResizePosition = dy < 0 ? (dx < 0 ? .topLeft : .topRight) : (dx < 0 ? .bottomLeft : .bottomRight)
                    NSCursor.frameResize(position: position, directions: .all).push()
                } else {
                    NSCursor.crosshair.push()
                }
            }
    }

    private func dismiss() {
        withAnimation(Motion.fade) { isPresented = false }
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
}

/// A selectable source-list row (sidebar).
struct SidebarRow: View {
    let title: String
    var icon: String? = nil
    var indent: Bool = false
    let isSelected: Bool
    let isLightMode: Bool
    let action: () -> Void

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: StudioTheme.scaleFont(11)))
                        .frame(width: 14)
                        .foregroundColor(isSelected ? .white : palette.textMuted)
                }
                Text(title)
                    .font(.ui(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .white : palette.textMain)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent ? 18 : 8)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? palette.accentBlue : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
