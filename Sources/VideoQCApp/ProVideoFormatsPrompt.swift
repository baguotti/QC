import AppKit
import VideoQCLib

/// Offered once per session when an MXF is opened without Apple's Pro Video Formats installed.
@MainActor
enum ProVideoFormatsPrompt {
    private static var hasShown = false

    static func showIfNeeded(for url: URL) {
        guard !hasShown, ProVideoFormats.needsInstall(for: url) else { return }
        hasShown = true
        let alert = NSAlert()
        alert.messageText = "\(url.pathExtension.uppercased()) needs Apple's Pro Video Formats"
        alert.informativeText = "Pro Video Formats is a free Apple update that adds MXF, AVC-Intra, XAVC and DNxHD/HR. "
            + "Software Update offers it on Macs with Final Cut Pro, Motion or Compressor installed. Restart QCpie after installing."
        alert.addButton(withTitle: "Open Software Update")
        alert.addButton(withTitle: "Learn More")
        alert.addButton(withTitle: "Cancel")
        let link: String
        switch alert.runModal() {
        case .alertFirstButtonReturn: link = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
        case .alertSecondButtonReturn: link = "https://support.apple.com/101631"
        default: return
        }
        if let target = URL(string: link) { NSWorkspace.shared.open(target) }
    }
}
