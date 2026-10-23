import AppKit
import SwiftUI

/// Title bar hidden: puts the window buttons (traffic lights) inside the tab strip and lets the strip's empty space drag
/// the window (double-click zooms), like Premiere Pro.
struct TabStripWindowChrome: NSViewRepresentable {
    /// Height of the strip; the buttons are centred on `buttonCenterFromTop`.
    let height: CGFloat
    let buttonCenterFromTop: CGFloat
    let leading: CGFloat

    /// Width the buttons take from the strip's leading edge (three buttons plus a gap before the tabs).
    static func reservedWidth(leading: CGFloat) -> CGFloat { leading + 2 * buttonSpacing + 14 + 18 }
    static let buttonSpacing: CGFloat = 20

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.height = height
        view.buttonCenterFromTop = buttonCenterFromTop
        view.leading = leading
        view.placeButtons()
    }

    final class ChromeView: NSView {
        var height: CGFloat = 42
        var buttonCenterFromTop: CGFloat = 21
        var leading: CGFloat = 20
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
            // AppKit lays the title bar out again on these; put the buttons back each time.
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.placeButtons() }
                })
            }
            placeButtons()
        }

        override func layout() {
            super.layout()
            placeButtons()
        }

        func placeButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let top = window.frame.height
            if container.frame.height != height || container.frame.maxY != top {
                container.frame = NSRect(x: container.frame.minX, y: top - height, width: container.frame.width, height: height)
            }
            if titlebar.frame.height != height {
                titlebar.frame = NSRect(x: titlebar.frame.minX, y: 0, width: titlebar.frame.width, height: height)
            }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for (i, type) in types.enumerated() {
                guard let button = window.standardWindowButton(type) else { continue }
                let origin = NSPoint(x: leading + CGFloat(i) * TabStripWindowChrome.buttonSpacing,
                                     y: (height - buttonCenterFromTop - button.frame.height / 2).rounded())
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }
    }
}
