import AppKit
import SwiftUI

/// Title bar hidden: the tab strip's empty space drags the window (double-click zooms) and the system window buttons are
/// replaced by `WindowControls`, which sit in the strip like Premiere Pro's.
struct TabStripWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) { view.hideSystemButtons() }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // AppKit shows the buttons again when it rebuilds the title bar (e.g. leaving full screen).
            for name in [NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hideSystemButtons() }
                })
            }
            hideSystemButtons()
        }

        func hideSystemButtons() {
            guard let window else { return }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(type), !button.isHidden { button.isHidden = true }
            }
        }
    }
}

/// Close / minimise / full-screen buttons: grey until hovered, then the usual colours and symbols.
struct WindowControls: View {
    let isLightMode: Bool
    @State private var isHovered = false

    static let width: CGFloat = 3 * diameter + 2 * spacing
    private static let diameter: CGFloat = 12
    private static let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.spacing) {
            button(color: Color(red: 1, green: 0.373, blue: 0.341), symbol: "xmark") { $0.performClose(nil) }
            button(color: Color(red: 0.996, green: 0.737, blue: 0.180), symbol: "minus") { $0.miniaturize(nil) }
            button(color: Color(red: 0.157, green: 0.784, blue: 0.251), symbol: "arrow.up.left.and.arrow.down.right") { $0.toggleFullScreen(nil) }
        }
        .onHover { isHovered = $0 }
    }

    private func button(color: Color, symbol: String, action: @escaping (NSWindow) -> Void) -> some View {
        Button(action: {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow { action(window) }
        }) {
            Circle()
                .fill(isHovered ? color : Color(white: isLightMode ? 0.78 : 0.36))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: StudioTheme.scaleFont(6.5), weight: .heavy))
                        .foregroundColor(Color.black.opacity(0.55))
                        .opacity(isHovered ? 1 : 0)
                )
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
