import SwiftUI
import AppKit
import VideoQCLib

// MARK: - Media Info Loader

/// Reads a file's media info for `MediaInfoPanel`. Owned by the drawer that shows the panel, not by the panel, so
/// switching to another drawer tab and back doesn't read the file again. Keeps the last file's info until the next
/// one is read (no flash of the spinner between files).
@MainActor
final class MediaInfoLoader: ObservableObject {
    @Published private(set) var info: ExtendedMediaInfo?
    /// The file inspected here when the drawer had no `DeliverableAsset` for it.
    @Published private(set) var inspectedAsset: DeliverableAsset?
    @Published private(set) var isLoading = false

    /// Call from `.task(id: url)`: a newer call cancels this one, which then leaves the published values alone.
    func load(_ url: URL?, asset: DeliverableAsset?) async {
        guard let url else {
            info = nil
            inspectedAsset = nil
            isLoading = false
            return
        }
        isLoading = true
        let inspected = asset == nil ? await DeliverablesInspector.inspectFile(url: url) : nil
        guard !Task.isCancelled else { return }
        let extracted = await ExtendedMediaInfo.extract(url: url, baseAsset: asset ?? inspected)
        guard !Task.isCancelled else { return }
        inspectedAsset = inspected
        info = extracted
        isLoading = false
    }
}

// MARK: - Media Info Panel

/// A file's container, tracks and timing, with Specs / Reveal buttons: the Player's review sleeve and the Upload
/// tab's drawer both show this.
struct MediaInfoPanel: View {
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    var url: URL?
    /// The file's asset when the caller has it (the Inspect list); otherwise the loader inspects the file.
    var asset: DeliverableAsset?
    @ObservedObject var loader: MediaInfoLoader
    var isLightMode: Bool
    var emptyTitle = "No Media Loaded"
    var emptyMessage = "Load a deliverable in Slot A or B to inspect container tracks and metadata."
    var onToast: (String) -> Void
    var onCopySpecs: ((String) -> Void)? = nil
    var onRevealInFinder: ((URL) -> Void)? = nil

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var effectiveAsset: DeliverableAsset? { asset ?? loader.inspectedAsset }

    var body: some View {
        VStack(spacing: 0) {
            if url == nil {
                placeholder
            } else if loader.isLoading && loader.info == nil {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("Reading Media info...")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(palette.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgPanel)
            } else if let info = loader.info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        fileView(info: info)
                        tracksView(info: info)
                    }
                    .padding(12)
                }
                .background(palette.bgMain)

                Rectangle().fill(palette.borderLine).frame(height: 1)

                footer(info: info)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "info.circle")
                .font(.system(size: StudioTheme.scaleFont(26)))
                .foregroundColor(palette.textMuted.opacity(0.4))
            Text(emptyTitle)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text(emptyMessage)
                .font(.ui(size: 11))
                .foregroundColor(palette.textSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bgPanel)
    }
    // MARK: Tracks View
    
    private func tracksView(info: ExtendedMediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(info.isImage ? "Image" : "Track Inventory (\(info.tracks.count))")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMain)
            
            ForEach(info.tracks) { track in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(track.typeName)
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(track.typeName.contains("VIDEO") ? palette.accentPositive : (track.typeName.contains("AUDIO") ? palette.accentSlotB : palette.textMain))
                        Spacer()
                        Text(track.format.uppercased())
                            .font(.ui(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        if track.typeName == "IMAGE" {
                            ForEach(info.imageDetails) { row in drawerInfoRow(label: row.label, value: row.value) }
                        } else if track.typeName.contains("VIDEO") {
                            drawerInfoRow(label: "Format:", value: info.videoFormat)
                            drawerInfoRow(label: "Codec:", value: track.codec)
                            if let asset = effectiveAsset {
                                drawerInfoRow(label: "Size:", value: "\(asset.width)×\(asset.height) (\(asset.aspectRatioString))")
                            }
                            drawerInfoRow(label: "FPS:", value: info.formattedFPS)
                            if info.videoBitrate != "--" {
                                drawerInfoRow(label: "Bit Rate:", value: info.videoBitrate)
                            }
                            drawerInfoRow(label: "Colorspace:", value: info.colorspace)
                            drawerInfoRow(label: "Primaries:", value: info.primaries)
                            drawerInfoRow(label: "Pixel Format:", value: info.pixelFormat)
                            drawerInfoRow(label: "Decoder:", value: info.hwDecoder)
                        } else if track.typeName.contains("AUDIO") {
                            drawerInfoRow(label: "Format:", value: info.audioFormat)
                            drawerInfoRow(label: "Codec:", value: track.codec)
                            drawerInfoRow(label: "Channels:", value: info.audioChannels)
                            drawerInfoRow(label: "Sample Rate:", value: info.audioSampleRate != "--" ? "\(info.audioSampleRate) Hz" : "--")
                            if info.audioBitrate != "--" {
                                drawerInfoRow(label: "Bit Rate:", value: info.audioBitrate)
                            }
                            
                            let levelStr = (effectiveAsset?.audioLevelString.isEmpty == false && effectiveAsset?.audioLevelString != "--") ? (effectiveAsset?.audioLevelString ?? info.audioLevelString) : info.audioLevelString
                            let isMute = effectiveAsset?.isAudioMute ?? info.isAudioMute
                            if !levelStr.isEmpty && levelStr != "--" {
                                drawerAudioLevelRow(levelString: levelStr, isMute: isMute)
                            }
                            
                            if track.language != "Undetermined" {
                                drawerInfoRow(label: "Language:", value: track.language)
                            }
                        } else {
                            drawerInfoRow(label: "Format:", value: track.format)
                            drawerInfoRow(label: "Codec:", value: track.codec)
                            drawerInfoRow(label: "Details:", value: track.details)
                            if track.language != "Undetermined" {
                                drawerInfoRow(label: "Language:", value: track.language)
                            }
                        }
                    }
                }
                .padding(10)
                .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
            }
        }
    }
    
    // MARK: File View
    
    private func fileView(info: ExtendedMediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("File System")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(palette.textMain)
                
                VStack(alignment: .leading, spacing: 5) {
                    // File Name Row
                    let fileName = effectiveAsset?.fileName ?? url?.lastPathComponent ?? "UNKNOWN"
                    HStack(alignment: .top, spacing: 6) {
                        Text("File Name:")
                            .font(.ui(size: 11, weight: .semibold))
                            .foregroundColor(palette.textMuted)
                            .frame(width: 84, alignment: .leading)
                        
                        if let url = url {
                            Button(action: { revealInFinder(url) }) {
                                Text(fileName)
                                    .font(.ui(size: 11, weight: .semibold))
                                    .foregroundColor(palette.textMain)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                            .help("Left click to reveal in Finder")
                        } else {
                            Text(fileName)
                                .font(.ui(size: 11, weight: .semibold))
                                .foregroundColor(palette.textMain)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer(minLength: 2)
                        
                        Button(action: {
                            copyToClipboard(fileName)
                            onToast("Copied file name")
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                                .foregroundColor(palette.textSubtle)
                        }
                        .buttonStyle(.plain)
                        .help("Copy file name")
                    }
                    .padding(.vertical, 1)
                    
                    // Path with left-click to reveal in Finder
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Path:")
                                .font(.ui(size: 11, weight: .semibold))
                                .foregroundColor(palette.textMuted)
                            
                            Spacer()
                            
                            if let path = url?.path {
                                Button(action: {
                                    copyToClipboard(path)
                                    onToast("Copied path")
                                }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: StudioTheme.scaleFont(8)))
                                        Text("Copy")
                                            .font(.ui(size: 10, weight: .semibold))
                                    }
                                    .foregroundColor(palette.textMuted)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(palette.bgSubtle)
                                    .cornerRadius(3)
                                }
                                .buttonStyle(.plain)
                                .help("Copy full path")
                            }
                        }
                        
                        if let url = url {
                            Button(action: { revealInFinder(url) }) {
                                HStack(alignment: .center, spacing: 6) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: StudioTheme.scaleFont(9.5)))
                                        .foregroundColor(palette.accentBlue)
                                    
                                    Text(url.path)
                                        .font(.ui(size: 10, weight: .medium))
                                        .foregroundColor(palette.textMain)
                                        .lineLimit(3)
                                        .truncationMode(.middle)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    
                                    Spacer(minLength: 4)
                                    
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                                        .foregroundColor(palette.textMuted)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: Radius.control)
                                        .fill(palette.bgSubtle.opacity(0.8))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Radius.control)
                                                .stroke(palette.borderLine, lineWidth: 0.8)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                            .help("Left click to reveal in Finder")
                        }
                    }
                    .padding(.vertical, 2)
                    
                    drawerInfoRow(label: "Container:", value: ExtendedMediaInfo.containerType(for: url))
                    if let asset = effectiveAsset {
                        drawerInfoRow(label: "File Size:", value: "\(asset.formattedFileSize) (\(ExtendedMediaInfo.formattedByteString(asset.fileSizeBytes)))")
                        drawerInfoRow(label: "Created:", value: asset.formattedCreationDate)
                    }
                    drawerInfoRow(label: "Modified:", value: info.fileModifiedDate)
                }
                .padding(10)
                .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
            }
            
            if let asset = effectiveAsset {
                VStack(alignment: .leading, spacing: 6) {
                    Text(info.isImage ? "Raster" : "Timing & Raster")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(palette.textMain)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        if !info.isImage {
                            drawerInfoRow(label: "Duration:", value: "\(asset.timecode) (\(asset.formattedDuration))")
                            drawerInfoRow(label: "Frames:", value: "\(asset.totalFrames) frames")
                        }
                        drawerInfoRow(label: "Aspect:", value: asset.aspectRatioString)
                        drawerInfoRow(label: "Pixel Aspect:", value: "1.0 (Square)")
                        if asset.validation.hasAnyMismatch {
                            drawerInfoRow(label: "QC Alert:", value: asset.validation.summaryString)
                        } else {
                            drawerInfoRow(label: "Naming QC:", value: "All Tags Validated")
                        }
                    }
                    .padding(10)
                    .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
                }
            }
        }
    }
    
    // MARK: Info Row
    
    private func drawerInfoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .frame(width: 84, alignment: .leading)
            
            Text(value)
                .font(.ui(size: 11, weight: .medium))
                .foregroundColor(palette.textMain)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer(minLength: 2)
            
            if copyable {
                Button(action: {
                    copyToClipboard(value)
                    onToast("Copied \(label.replacingOccurrences(of: ":", with: ""))")
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                        .foregroundColor(palette.textSubtle)
                }
                .buttonStyle(.plain)
                .help("Copy \(label)")
            }
        }
        .padding(.vertical, 1.5)
    }
    
    private func drawerAudioLevelRow(levelString: String, isMute: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Levels:")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .frame(width: 84, alignment: .leading)
            
            HStack(spacing: 5) {
                Text(levelString.isEmpty ? (isMute ? "Mute" : "--") : levelString)
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(isMute ? palette.alertRed : palette.accentPositive)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        (isMute ? palette.alertRed : palette.accentPositive).opacity(0.12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke((isMute ? palette.alertRed : palette.accentPositive).opacity(0.35), lineWidth: 0.8)
                    )
                    .cornerRadius(3)
                
                if isMute {
                    Text("Silent")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(palette.alertRed)
                } else {
                    Text("Loudness")
                        .font(.ui(size: 10, weight: .medium))
                        .foregroundColor(palette.textMuted)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 1.5)
    }
    
    private func revealInFinder(_ url: URL) {
        if let onReveal = onRevealInFinder {
            onReveal(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
    
    // MARK: Media Info Footer
    
    private func footer(info: ExtendedMediaInfo) -> some View {
        HStack(spacing: 6) {
            if let asset = effectiveAsset {
                Button(action: {
                    let text = ExtendedMediaInfo.buildSpecsText(asset: asset, info: info)
                    copyToClipboard(text)
                    onCopySpecs?(text)
                    onToast("Copied specs to clipboard")
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                        Text("Specs")
                            .font(.ui(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .buttonStyle(.plain)
                .help("Copy formatted technical specifications")
            }
            
            if let url = url {
                Button(action: {
                    onRevealInFinder?(url) ?? NSWorkspace.shared.activateFileViewerSelecting([url])
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: StudioTheme.scaleFont(8.5), weight: .bold))
                        Text("Reveal")
                            .font(.ui(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .buttonStyle(.plain)
                .help("Reveal file in Finder")
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.bgPanel)
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
