import Foundation
import VideoToolbox
import MediaToolbox

/// Apple's Pro Video Formats (MXF, AVC-Intra, XAVC, DNxHD/HR…). Installed by Software Update on Macs with
/// Final Cut Pro, Motion or Compressor; AVFoundation only uses them in apps that register them.
public enum ProVideoFormats {
    /// Containers that only open with Pro Video Formats installed.
    public static let extensions: Set<String> = ["mxf"]

    /// Call once at launch, before any media is opened. Costs ~17 ms, so it only runs when the formats are installed.
    public static func register() {
        guard isInstalled else { return }
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        MTRegisterProfessionalVideoWorkflowFormatReaders()
    }

    public static var isInstalled: Bool {
        let folder = URL(fileURLWithPath: "/Library/Video/Professional Video Workflow Plug-Ins")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return items.contains { !$0.hasPrefix(".") }
    }

    public static func needsInstall(for url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased()) && !isInstalled
    }

    static func openError(for url: URL) -> String {
        needsInstall(for: url) ? "Needs Apple Pro Video Formats" : "Couldn't open the video"
    }
}
