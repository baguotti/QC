import AppKit
import AVFoundation
import Combine
import SwiftUI
import VideoQCLib

/// Space (or double-click) in the Frame.io browser: a preview of the selected file streamed from Frame.io, without
/// downloading it. Video plays the `efficient` proxy (the 180p one while an upload or download runs, to leave them the
/// bandwidth); an image shows Frame.io's full-size web image; audio streams the original (Frame.io makes no audio
/// proxy). ← → ↑ ↓ move through the list (the selection follows, and clicking another row
/// previews it), Space or Esc closes. A proxy is for recognising a file, never for judging picture quality: the
/// panel says so. The player and its clock live here and in `PreviewTransport`, so playback never redraws the browser.
@MainActor
final class FrameIOPreview: ObservableObject {
    static let shared = FrameIOPreview()

    enum Content: Equatable {
        case loading
        case video
        case audio
        case image(URL)
        case unavailable(String)
    }

    @Published private(set) var item: FrameIO.Item?
    @Published private(set) var content: Content = .loading
    /// The proxy's frame size, once known ("Proxy 1280×720").
    @Published private(set) var proxySize: CGSize?
    @Published private(set) var isLowResolution = false
    /// What the badge says: "Proxy", "Original" (audio) or "Preview" (an image).
    @Published private(set) var source = "Proxy"

    let player = AVPlayer()
    let clock = PreviewClock()
    var isOpen: Bool { item != nil }

    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var selectionWatch: AnyCancellable?
    private var pathWatch: AnyCancellable?

    private init() {
        // Clicking another row while the preview is open previews that one, like Quick Look.
        // An emptied selection (the file was deleted, or Esc cleared it) closes it.
        selectionWatch = FrameIOBrowser.shared.$selection.removeDuplicates().sink { [weak self] selection in
            guard let self, self.isOpen else { return }
            if selection.isEmpty { self.close(); return }
            guard selection.count == 1, let id = selection.first, id != self.item?.id,
                  let item = FrameIOBrowser.shared.visibleItems.first(where: { $0.id == id }), Self.canPreview(item) else { return }
            self.show(item)
        }
        // Going somewhere else in the browser (a pasted link, signing out) closes it.
        pathWatch = FrameIOBrowser.shared.$path.dropFirst().sink { [weak self] _ in self?.close() }
    }

    /// "auto" (180p while a transfer runs), "sharp" or "small" (User Settings → Frame.io).
    static let qualityKey = "prefFrameioPreviewQuality"

    static func canPreview(_ item: FrameIO.Item) -> Bool { item.type == "file" || item.isVersionStack }

    /// Space: opens the selected file (the first previewable one in list order), or closes. False when there's nothing
    /// to preview, so the key goes on.
    func toggle() -> Bool {
        if isOpen { close(); return true }
        let browser = FrameIOBrowser.shared
        guard !browser.selection.isEmpty,
              let item = browser.visibleItems.first(where: { browser.selection.contains($0.id) && Self.canPreview($0) }) else { return false }
        show(item)
        return true
    }

    /// Double-click on a file (or a version in a stack): previews it, like Space.
    func preview(_ item: FrameIO.Item) {
        guard Self.canPreview(item), item.id != self.item?.id else { return }
        show(item)
    }

    /// ← → ↑ ↓ while open: the previous or next previewable item in the list. False when closed (the key goes on).
    func step(_ delta: Int) -> Bool {
        guard let current = item else { return false }
        let items = FrameIOBrowser.shared.visibleItems.filter(Self.canPreview)
        guard let index = items.firstIndex(where: { $0.id == current.id }) else { close(); return true }
        let next = index + delta
        guard items.indices.contains(next) else { return true }
        FrameIOBrowser.shared.reveal(items[next].id)   // previews it through the selection watch
        return true
    }

    func close() {
        guard isOpen else { return }
        loadTask?.cancel()
        stopPlayback()
        withAnimation(Motion.fade) { item = nil }
    }

    /// Download in the panel: the usual Download… (asks where), after pausing.
    func download() {
        guard let item, let account = FrameIOBrowser.shared.accountID else { return }
        player.pause()
        DownloadQueue.shared.download([item], account: account)
    }

    /// Changed in the last 2 hours: Frame.io may still be making its proxies.
    private static func isRecent(_ item: FrameIO.Item) -> Bool {
        guard let stamp = item.updatedAt ?? item.createdAt else { return false }
        let date = fractionalDates.date(from: stamp) ?? plainDates.date(from: stamp)
        return date.map { -$0.timeIntervalSinceNow < 2 * 3600 } ?? false
    }
    private static let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDates = ISO8601DateFormatter()

    private func show(_ item: FrameIO.Item) {
        loadTask?.cancel()
        stopPlayback()
        content = .loading
        proxySize = nil
        // A recent file may have no proxy yet: ask first, and if so say so in a toast instead of opening an empty panel.
        let deferOpen = !isOpen && Self.isRecent(item)
        if !deferOpen {
            if !isOpen { withAnimation(Motion.fade) { self.item = item } } else { self.item = item }
        }
        guard let account = FrameIOBrowser.shared.accountID, let fileID = item.isVersionStack ? item.headVersion?.id : item.id else {
            self.item = item
            content = .unavailable("This stack has no version to preview.")
            return
        }
        let quality = UserDefaults.standard.string(forKey: Self.qualityKey) ?? "auto"
        let busy = quality == "small" || (quality == "auto" && (UploadQueue.shared.isRunning || DownloadQueue.shared.isRunning))
        loadTask = Task {
            do {
                let file = try await FrameIO.shared.previewFile(account: account, file: fileID)
                guard !Task.isCancelled, deferOpen ? !isOpen : self.item?.id == item.id else { return }
                let links = file.mediaLinks
                let kind = file.mediaType?.split(separator: "/").first.map(String.init) ?? ""
                let small = links?.videoH264180?.stream, sharp = links?.efficient?.stream
                let still = links?.highQuality?.stream ?? links?.thumbnailHighQuality?.url.flatMap(URL.init(string:))
                    ?? links?.original?.inlineURL.flatMap(URL.init(string:))
                let audio = links?.efficient?.stream ?? links?.original?.downloadURL.flatMap(URL.init(string:))
                let hasPreview = still != nil || (kind == "audio" ? audio != nil : (sharp ?? small) != nil)
                if deferOpen {
                    guard hasPreview else {
                        FrameIOBrowser.shared.notify("Frame.io is still processing “\(file.name ?? item.title)”. Try the preview again in a minute.")
                        return
                    }
                    withAnimation(Motion.fade) { self.item = item }
                }
                if kind == "image", let still {
                    source = "Preview"
                    content = .image(still)
                } else if kind == "audio", let original = audio {
                    source = links?.efficient?.stream == nil ? "Original" : "Proxy"
                    isLowResolution = false
                    play(original, as: .audio)
                } else if kind != "image", kind != "audio", let stream = (busy ? small : nil) ?? sharp ?? small {
                    source = "Proxy"
                    isLowResolution = stream == small
                    play(stream, as: .video)
                } else if let still {
                    source = "Preview"
                    content = .image(still)
                } else {
                    content = .unavailable(Self.isRecent(item)
                        ? "Frame.io is still processing this file. Try again in a minute."
                        : "Frame.io hasn't made a preview of this file. The project may not allow previews.")
                }
            } catch {
                guard !Task.isCancelled, deferOpen ? !isOpen : self.item?.id == item.id else { return }
                if deferOpen { withAnimation(Motion.fade) { self.item = item } }
                content = .unavailable("Couldn't load the preview: \(UploadEngine.describe(error))")
            }
        }
    }

    private func play(_ url: URL, as kind: Content) {
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        content = kind
        clock.reset()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock.tick(time: time.seconds, duration: self.player.currentItem?.duration.seconds, isPlaying: self.player.rate != 0)
            }
        }
        player.play()
        guard kind == .video else { clock.fps = 25; return }
        Task {
            let (size, rate) = await Self.videoFormat(of: url)
            guard (player.currentItem?.asset as? AVURLAsset)?.url == url else { return }
            proxySize = size
            clock.fps = rate > 0 ? rate : 25
        }
    }

    /// The proxy's frame size and rate (read from its own asset, off the main actor).
    nonisolated private static func videoFormat(of url: URL) async -> (CGSize?, Double) {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else { return (nil, 0) }
        let size = try? await track.load(.naturalSize)
        let rate = (try? await track.load(.nominalFrameRate)).map(Double.init) ?? 0
        return (size, rate)
    }

    private func stopPlayback() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// The preview's playhead, observed only by its transport bar (10 Hz while playing).
@MainActor
final class PreviewClock: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    var fps: Double = 25

    func reset() { time = 0; duration = 0; isPlaying = false }

    func tick(time: Double, duration: Double?, isPlaying: Bool) {
        if time.isFinite, abs(time - self.time) > 0.001 { self.time = time }
        if let duration, duration.isFinite, duration != self.duration { self.duration = duration }
        if isPlaying != self.isPlaying { self.isPlaying = isPlaying }
    }
}

// MARK: - Views

/// Drawn over the browser; observes only the preview (not the browser's list).
struct FrameIOPreviewOverlay: View {
    @ObservedObject private var preview = FrameIOPreview.shared
    let isLightMode: Bool

    var body: some View {
        if let item = preview.item {
            ZStack {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { preview.close() }
                FrameIOPreviewPanel(item: item, isLightMode: isLightMode)
                    .padding(32)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }
}

private struct FrameIOPreviewPanel: View {
    @ObservedObject private var preview = FrameIOPreview.shared
    let item: FrameIO.Item
    let isLightMode: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    private var badge: String {
        switch preview.content {
        case .video:
            guard let size = preview.proxySize, size.width > 0 else { return preview.source }
            return "\(preview.source) \(Int(size.width))×\(Int(size.height))"
        case .audio, .image: return preview.source
        case .loading, .unavailable: return ""
        }
    }

    private var badgeHelp: String {
        switch preview.content {
        case .audio: return preview.source == "Original"
            ? "Frame.io makes no audio proxy: this streams the original file." : "Frame.io's streaming proxy of the audio."
        case .image: return "Frame.io's full-size web image of the file (the original may be a different format or depth)."
        default: return preview.isLowResolution
            ? "Frame.io's smallest proxy, while a transfer is running. Not the original: don't judge picture quality from it."
            : "Frame.io's streaming proxy, not the original: for recognising the file, not for judging picture quality."
        }
    }

    private var icon: String {
        if item.isVersionStack { return "square.stack" }
        switch preview.content {
        case .audio: return "waveform"
        case .image: return "photo"
        default: return "film"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .semibold))
                    .foregroundColor(palette.textMuted)
                Text(item.isVersionStack ? (item.headVersion?.name ?? item.title) : item.title)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !badge.isEmpty {
                    Text(badge)
                        .font(.ui(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(palette.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle))
                        .explain(badgeHelp)
                }
                Spacer(minLength: 8)
                Text("← → Previous / Next")
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textSubtle)
                DrawerCloseButton(isLightMode: isLightMode) { preview.close() }
            }
            .headerBand(palette, horizontalPadding: 12)

            ZStack {
                Color.black
                switch preview.content {
                case .loading:
                    ProgressView().controlSize(.small)
                case .video:
                    PreviewPlayerView(player: preview.player)
                case .audio:
                    PreviewAudioView(name: item.isVersionStack ? (item.headVersion?.name ?? item.title) : item.title)
                case .image(let url):
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                case .unavailable(let message):
                    Text(message)
                        .font(.ui(size: 12))
                        .foregroundColor(Color.white.opacity(0.7))   // design-ok: text on the black video well
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: preview.content == .audio ? StudioTheme.scale(220) : .infinity)

            PreviewTransport(isLightMode: isLightMode, isVideo: preview.content == .video || preview.content == .audio)
        }
        .frame(maxWidth: 1100)
        .background(palette.bgPanel)
        .clipShape(RoundedRectangle(cornerRadius: Radius.container))
        .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine))
        .contentShape(Rectangle())   // clicks on the panel stay on it (only the backdrop closes)
    }

    private var aspect: CGFloat {
        if preview.content == .audio { return 4 }
        guard let size = preview.proxySize, size.width > 0, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }
}

/// Play/pause, timecode, scrubber and Download. The only view that observes the 10 Hz clock.
private struct PreviewTransport: View {
    @ObservedObject private var clock = FrameIOPreview.shared.clock
    let isLightMode: Bool
    let isVideo: Bool
    @State private var scrubbing: Double?

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var player: AVPlayer { FrameIOPreview.shared.player }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { clock.isPlaying ? player.pause() : player.play() }) {
                Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .bold))
                    .frame(width: StudioTheme.scale(24), height: StudioTheme.scale(26))
                    .foregroundColor(palette.textMain)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .disabled(!isVideo)
            .explain("Play or pause the preview.")
            Text(timecode(scrubbing ?? clock.time))
                .font(.ui(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(palette.textMain)
            Slider(value: Binding(get: { scrubbing ?? clock.time }, set: { scrubbing = $0 }),
                   in: 0...max(clock.duration, 0.01)) { editing in
                guard !editing, let target = scrubbing else { return }
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in scrubbing = nil }
                }
            }
            .controlSize(.small)
            .disabled(!isVideo || clock.duration <= 0)
            Text(timecode(clock.duration))
                .font(.ui(size: 11))
                .monospacedDigit()
                .foregroundColor(palette.textMuted)
            Button("Download…") { FrameIOPreview.shared.download() }
                .font(.ui(size: 11, weight: .semibold))
                .explain("Download the original file (asks where).")
        }
        .padding(.horizontal, 12)
        .frame(height: StudioTheme.scale(40))
        .background(palette.bgPanel)
        .overlay(alignment: .top) { Rectangle().fill(palette.borderLine).frame(height: 1) }
    }

    private func timecode(_ seconds: Double) -> String {
        TimecodeFormatter.format(frameIndex: Int((max(seconds, 0) * clock.fps).rounded(.down)), fps: clock.fps)
    }
}

/// Audio has no picture: the file's name over a quiet waveform glyph, on the same black well as video.
private struct PreviewAudioView: View {
    let name: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: StudioTheme.scaleFont(34), weight: .regular))
                .foregroundColor(Color.white.opacity(0.55))   // design-ok: on the black media well
            Text(name)
                .font(.ui(size: 12, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.8))   // design-ok: on the black media well
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 24)
    }
}

/// The proxy's picture: a bare `AVPlayerLayer` (no system controls), letterboxed on black.
private struct PreviewPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
