import SwiftUI
import VideoQCLib

/// A frame of `url` at `seconds`, small, from the shared thumbnail cache (decoded off the main thread, only when shown).
struct PictureTextThumb: View {
    let url: URL
    let seconds: Double
    let fps: Double
    let isLightMode: Bool
    /// When the appearance ends: the preview frame stays inside it (an end logo can sit in the clip's last frames).
    var until: Double? = nil
    var width: CGFloat = 128
    @State private var image: CGImage? = nil
    @State private var failed = false

    var body: some View {
        let palette = StudioPalette(isLightMode)
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                Text("No preview").font(.ui(size: 10)).foregroundColor(palette.textSubtle)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .task(id: "\(url.path)|\(seconds)") {
            // A moment into the appearance (its first sample can be mid-fade), but not past its end or the clip's.
            let rate = max(1, fps)
            let wanted = seconds + 0.25
            // `until` runs one sample (0.5 s) past the last frame the text was read on: stay at or before that frame.
            let time = until.map { min(wanted, max(seconds, $0 - PictureTextScanner.sampleInterval - 1 / rate)) } ?? seconds
            let frame = max(0, Int((time * rate).rounded(.down)))
            image = await GlitchThumbnailProvider.shared.getThumbnail(for: url, frameIndex: frame, fps: rate,
                                                                     targetSize: CGSize(width: width * 2, height: width * 2 * 9 / 16))
            failed = image == nil && !Task.isCancelled
        }
    }
}

/// The text read in a file's picture, appearance by appearance: a frame, the text, when. Click a row to open it in the
/// Player; Not a Graphic hides a misread or text in the footage (all its appearances, kept across checks).
struct PictureTextListPopover: View {
    let asset: DeliverableAsset
    let check: PictureTextCheck
    let isLightMode: Bool
    let onOpen: (Double) -> Void
    let onDismiss: (PictureTextCheck.Sighting) -> Void
    let onRestore: () -> Void

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    private func timecode(_ seconds: Double) -> String {
        TimecodeFormatter.format(frameIndex: max(0, Int((seconds * max(1, asset.fps)).rounded(.down))), fps: max(1, asset.fps))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Text on Screen")
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundColor(palette.textMain)
                Text(check.graphics.isEmpty
                     ? "None left: every reading was marked Not a Graphic."
                     : "Check each frame: misreads and text in the footage itself (a sign, a label) count too.")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(check.nameMismatches(for: asset.fileName), id: \.self) { mismatch in
                    Text(mismatch)
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(palette.alertRed)
                }
            }
            .padding(12)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(check.graphics.enumerated()), id: \.offset) { _, sighting in
                        row(sighting)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 380)
            if !check.dismissed.isEmpty {
                Rectangle().fill(palette.borderLine).frame(height: 1)
                HStack {
                    Text("\(check.dismissed.count) marked Not a Graphic")
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMuted)
                    Spacer()
                    Button("Restore", action: onRestore)
                        .font(.ui(size: 11))
                        .explain("Shows the texts marked Not a Graphic again for this file.")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 400)
        .background(palette.bgPanel)
    }

    private func row(_ sighting: PictureTextCheck.Sighting) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: { onOpen(sighting.start) }) {
                HStack(alignment: .top, spacing: 10) {
                    PictureTextThumb(url: asset.fileURL, seconds: sighting.start, fps: asset.fps, isLightMode: isLightMode, until: sighting.end)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sighting.text.replacingOccurrences(of: "\n", with: " "))
                            .font(.ui(size: 12, weight: .semibold))
                            .foregroundColor(palette.textMain)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(timecode(sighting.start)) – \(timecode(sighting.end))")
                            .font(.ui(size: 10))
                            .monospacedDigit()
                            .foregroundColor(palette.textMuted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .explain("Opens this moment in the Player.")
            Button(action: { onDismiss(sighting) }) {
                Image(systemName: "eye.slash")
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                    .foregroundColor(palette.textMuted)
                    .frame(width: StudioTheme.scale(22), height: StudioTheme.scale(22))
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .tip("Not a Graphic: hide this text for this file (a misread, or text in the footage).")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgCardSubtle))
    }
}

/// A cell that opens `content` in a popover when clicked.
struct ClickPopover<Label: View, Content: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content
    @State private var isShown = false

    var body: some View {
        Button(action: { isShown.toggle() }) { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $isShown, arrowEdge: .bottom) { content() }
    }
}
