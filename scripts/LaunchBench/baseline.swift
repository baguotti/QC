import SwiftUI

/// Empty SwiftUI app with one window: the launch floor QCpie is compared against.
@main struct Baseline: App {
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene { Window("Baseline", id: "main") { Text("Baseline").frame(width: 1200, height: 800) } }
}
