import SwiftUI
import AppKit
import VideoQCLib

/// "Assets" block of the left panels: a segmented Change | Add | Refresh control, then the loaded folder (or files)
/// with a per-kind breakdown ("6 videos · 2 images · 1 audio").
struct AssetSourcePanel: View {
    let folderURL: URL?
    let files: [URL]
    let isBusy: Bool
    let isLightMode: Bool
    let onSelect: (_ append: Bool) -> Void
    let onRefresh: () -> Void

    /// Recomputed only when the file list changes, not on every window re-render.
    @State private var breakdownText = ""

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assets")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundColor(palette.textMuted)

            HStack(alignment: .center, spacing: 10) {
                if !files.isEmpty {
                    Image(systemName: folderURL == nil ? "doc.on.doc" : "folder")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(palette.accentBlue)
                    summary
                } else {
                    Text("No assets loaded")
                        .font(.ui(size: 12))
                        .foregroundColor(palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                controls
            }
        }
        .onChange(of: files, initial: true) { _, new in breakdownText = Self.breakdown(new) }
    }

    private var controls: some View {
        let isEmpty = folderURL == nil && files.isEmpty
        return HStack(spacing: 0) {
            segment(isEmpty ? "Select…" : "Change",
                    tint: isEmpty ? palette.accentBlue : palette.textMain,
                    help: isEmpty ? "Choose video files or a folder to inspect." : "Replace the loaded assets with a new folder or file selection.") {
                onSelect(false)
            }
            divider
            segment("Add", tint: palette.textMain,
                    help: "Add more files or folders to the current list.") {
                onSelect(true)
            }
            divider
            segment("Refresh", tint: isEmpty ? palette.textSubtle : palette.textMain,
                    help: "Rescan the loaded folders and files for added, removed or changed media.") {
                onRefresh()
            }
            .disabled(isEmpty)
        }
        .disabled(isBusy)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.bgSubtle.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderLine, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(palette.borderLine).frame(width: 1, height: StudioTheme.scale(14))
    }

    private func segment(_ title: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: StudioTheme.scaleFont(11.5), weight: .medium))
                .lineLimit(1)
            .foregroundColor(tint)
            .padding(.horizontal, StudioTheme.scale(9))
            .frame(height: StudioTheme.scale(26))
            .contentShape(Rectangle())
        }
        .buttonStyle(TransportIconButtonStyle())
        .explain(help)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.ui(size: 13, weight: .semibold))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(breakdownText)
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .explain(folderURL?.path ?? "\(files.count) files loaded directly")
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folderURL?.path ?? files.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(folderURL.map { [$0] } ?? files)
            }
        }
    }

    private var title: String {
        if let folderURL { return folderURL.lastPathComponent }
        if files.count == 1, let first = files.first { return first.lastPathComponent }
        return "\(files.count) files"
    }

    /// "6 videos · 2 images · 1 audio"; image sequences read as one video each.
    static func breakdown(_ files: [URL]) -> String {
        var videos = 0, images = 0, audio = 0
        let sequences = ImageSequenceStore.shared
        for url in files {
            switch QCUtilities.mediaKind(of: url) {
            case .video: videos += 1
            case .image: if sequences.sequence(for: url) != nil { videos += 1 } else { images += 1 }
            case .audio: audio += 1
            case nil: break
            }
        }
        let parts = [(videos, "video", "videos"), (images, "image", "images"), (audio, "audio", "audio")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        return parts.isEmpty ? "No media" : parts.joined(separator: " · ")
    }
}
