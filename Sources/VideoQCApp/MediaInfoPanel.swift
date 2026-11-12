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
                        summary(info: info)
                        if let asset = effectiveAsset, asset.pictureText != nil || asset.loudness != nil {
                            contentView(asset)
                        }
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
                            drawerInfoRow(label: "Codec:", value: track.codec)
                            if let asset = effectiveAsset {
                                drawerInfoRow(label: "Size:", value: "\(asset.width)×\(asset.height) (\(asset.aspectRatioString))")
                            }
                            drawerInfoRow(label: "FPS:", value: info.formattedFPS)
                            if info.videoBitrate != "--" {
                                drawerInfoRow(label: "Bit Rate:", value: info.videoBitrate)
                            }
                            colourRow(info: info)
                            drawerInfoRow(label: "Pixel Format:", value: info.pixelFormat)
                        } else if track.typeName.contains("AUDIO") {
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
                                Text(Self.breakable(fileName))
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
                                    
                                    Text(url.deletingLastPathComponent().lastPathComponent)
                                        .font(.ui(size: 10, weight: .medium))
                                        .foregroundColor(palette.textMain)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    
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
                            .help(url.path)
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
                            drawerInfoRow(label: "Duration:", value: "\(asset.timecode) · \(asset.totalFrames) f (\(asset.formattedDuration))")
                        }
                        drawerInfoRow(label: "Aspect:", value: asset.aspectRatioString)
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
    
    // MARK: Summary

    /// One line with what most checks need: size, aspect, rate, length, codecs, loudness.
    private func summary(info: ExtendedMediaInfo) -> some View {
        var parts: [String] = []
        if let asset = effectiveAsset {
            if asset.width > 0 { parts.append("\(asset.width)×\(asset.height)") }
            if !asset.aspectRatioString.isEmpty { parts.append(asset.aspectRatioString) }
        }
        if let fps = Double(info.fpsString), fps > 0 { parts.append("\(QCUtilities.formatFPS(fps)) fps") }
        if let asset = effectiveAsset, !info.isImage, asset.durationSeconds > 0 { parts.append(asset.formattedDuration) }
        // videoFormat defaults to "h264": only name it when there is a video track.
        if info.tracks.contains(where: { $0.typeName.hasPrefix("VIDEO") }) { parts.append(info.videoFormat.uppercased()) }
        if info.hasAudio {
            parts.append(info.audioChannels == "--" ? info.audioFormat.uppercased() : "\(info.audioFormat.uppercased()) \(info.audioChannels)")
            if let loudness = effectiveAsset?.loudness {
                parts.append(loudness.integrated.map { String(format: "%.1f LUFS", $0) } ?? "Silent")
            }
        }
        let text = parts.joined(separator: " · ")
        return Text(text)
            .font(.ui(size: 11, weight: .semibold))
            .foregroundColor(palette.textMain)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
            .contextMenu {
                Button("Copy") { copyToClipboard(text); onToast("Copied summary") }
            }
    }

    /// What Check Subs & Graphics and Check Loudness found; rows appear only for checks that have run.
    private func contentView(_ asset: DeliverableAsset) -> some View {
        let amber = TagTone.amber.color(palette.isLight)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Content")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMain)
            VStack(alignment: .leading, spacing: 4) {
                if let check = asset.pictureText {
                    if check.isUnavailable || check.isUnreadable {
                        drawerInfoRow(label: "Subtitles:", value: check.isUnreadable ? "Can't read" : "Not checked")
                    } else {
                        drawerInfoRow(label: "Subtitles:", value: Self.subtitles(check))
                        drawerInfoRow(label: "On Screen:", value: Self.graphics(check))
                    }
                }
                if asset.hasAudio, let loudness = asset.loudness {
                    if loudness.isSilent {
                        contentRow("Sound:", "Silent", color: amber)
                    } else if !loudness.channelNotes.isEmpty {
                        contentRow("Channels:", loudness.channelNotes.joined(separator: "\n"), color: amber)
                    } else {
                        drawerInfoRow(label: "Channels:", value: "No problems found")
                    }
                }
            }
            .padding(10)
            .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
        }
    }

    private func contentRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.ui(size: 11, weight: .medium))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
        }
        .padding(.vertical, 1.5)
    }

    private static func subtitles(_ check: PictureTextCheck) -> String {
        guard check.subtitlesLikely else { return "None" }
        let language = check.subtitleLanguage.map { Locale(identifier: "en").localizedString(forLanguageCode: $0) ?? $0.uppercased() }
        return "Burned in" + (language.map { " · \($0)" } ?? "")
    }

    /// "“LOGO” at 0.2 s, “SHOP NOW” at 28.5 s": the first four, then a count.
    private static func graphics(_ check: PictureTextCheck) -> String {
        guard !check.graphics.isEmpty else { return "No text graphics" }
        let shown = check.graphics.prefix(4).map { "“\($0.text)” at \(String(format: "%.1f", $0.start)) s" }
        let more = check.graphics.count > 4 ? "\n+\(check.graphics.count - 4) more" : ""
        return shown.joined(separator: "\n") + more
    }

    /// Primaries and transfer in one row; amber when untagged (players then guess, usually Rec.709).
    @ViewBuilder
    private func colourRow(info: ExtendedMediaInfo) -> some View {
        let untagged = info.primaries == "Untagged" || info.colorspace == "Untagged"
        HStack(alignment: .top, spacing: 6) {
            Text("Colour:")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .frame(width: 84, alignment: .leading)
            Text(info.primaries == info.colorspace ? info.primaries : "\(info.primaries) / \(info.colorspace)")
                .font(.ui(size: 11, weight: .medium))
                .foregroundColor(untagged ? TagTone.amber.color(palette.isLight) : palette.textMain)
                .fixedSize(horizontal: false, vertical: true)
                .help(untagged ? "Colour tags missing: players will guess, usually Rec.709." : "Primaries / transfer")
            Spacer(minLength: 2)
        }
        .padding(.vertical, 1.5)
    }

    /// Lets long underscored file names wrap at any character instead of mid-word on the few breaks they have.
    private static func breakable(_ name: String) -> String {
        name.map(String.init).joined(separator: "\u{200B}")
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
