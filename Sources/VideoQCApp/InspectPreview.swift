import SwiftUI
import AVFoundation
import VideoQCLib

// Inspect's preview: the selected file at a glance, play/pause and fast scrubbing only. In the bottom of Inspect's left
// panel or its own window (`InspectPreviewWindow`). A separate `AVPlayer` + bare `AVPlayerLayer` like the Frame.io
// preview: never the Player's engine or its still-frame layers (a glance, not a QC view).
// Light on purpose: a file loads only after the selection rests (holding ↓ through 50 files loads nothing), one player is
// reused, nothing plays by itself, and the player is emptied while no preview is on screen.

@MainActor
final class InspectPreview: ObservableObject {
    static let shared = InspectPreview()

    let player = AVPlayer()
    /// 10 Hz while playing, observed only by the transport.
    let clock = PreviewClock()

    @Published private(set) var url: URL?
    @Published private(set) var kind: MediaKind?
    /// Sound is on unless the speaker is toggled off (remembered).
    @Published var isMuted = UserDefaults.standard.bool(forKey: "inspectPreviewMuted") {
        didSet {
            player.isMuted = isMuted
            UserDefaults.standard.set(isMuted, forKey: "inspectPreviewMuted")
        }
    }

    private var wanted: URL?
    private var visible = 0
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var playWhenLoaded = false
    private var seeking = false
    private var pendingSeek: Double?

    private init() {
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause
    }

    /// The selected file changed. Loads after a short rest, and only while a preview is on screen.
    func select(_ url: URL?) {
        wanted = url
        loadTask?.cancel()
        guard visible > 0 else { return }
        guard url != self.url else { return }
        loadTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            load(wanted)
        }
    }

    func appeared() {
        visible += 1
        guard visible == 1 else { return }
        if wanted != url { load(wanted) } else { startIfWanted() }
    }

    func disappeared() {
        visible = max(0, visible - 1)
        guard visible == 0 else { return }
        // A moment later: moving between the panel and the window, the other preview may appear just after this one
        // goes, and the player (and its playback) carries straight over.
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard visible == 0 else { return }
            loadTask?.cancel()
            load(nil)
        }
    }

    /// Space: play / pause. False when there's nothing to play (the key goes on).
    func togglePlay() -> Bool {
        // ↓ then Space within the selection's rest: play the file now selected, not the one still loaded.
        if loadPendingSelection(play: true) { return true }
        guard visible > 0, url != nil, kind == .video || kind == .audio, player.currentItem != nil else { return false }
        if player.rate != 0 {
            player.pause()
        } else {
            if let item = player.currentItem, item.duration.isNumeric, player.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) {
                player.seek(to: .zero)
            }
            player.play()
        }
        return true
    }

    func pause() { if player.rate != 0 { player.pause() } }

    /// Double-click in Inspect: show this file now (no rest) and play it once a preview is on screen.
    func playNow(_ url: URL) {
        wanted = url
        loadTask?.cancel()
        playWhenLoaded = true
        guard visible > 0 else { return }   // the panel is opening: `appeared` loads and plays
        if url != self.url { load(url) } else { startIfWanted() }
    }

    private func startIfWanted() {
        guard playWhenLoaded, player.currentItem != nil else { return }
        playWhenLoaded = false
        if let item = player.currentItem, item.duration.isNumeric, player.currentTime() >= item.duration - CMTime(value: 1, timescale: 30) {
            player.seek(to: .zero)
        }
        player.play()
    }

    /// J / L: play backwards / forwards, faster on each press (1×, 2×, 4×, 8×); K pauses. False with nothing loaded.
    func shuttle(_ direction: Int) -> Bool {
        if direction > 0, loadPendingSelection(play: true) { return true }
        guard visible > 0, kind == .video || kind == .audio, let item = player.currentItem else { return false }
        if direction == 0 { player.pause(); return true }
        let rate = player.rate
        if direction > 0 {
            player.rate = rate > 0 ? min(8, rate * 2) : 1
        } else {
            guard item.canPlayReverse else { return step(-1) }
            player.rate = rate < 0 ? max(-8, rate * 2) : -1
        }
        return true
    }

    /// ← / →: pause and step frames (⇧: ten).
    func step(_ frames: Int) -> Bool {
        if loadPendingSelection(play: false) { return true }
        guard visible > 0, kind == .video, let item = player.currentItem else { return false }
        player.pause()
        item.step(byCount: frames)
        return true
    }

    /// A key pressed while the selection is still resting acts on the file now selected: load it at once (and play
    /// it for L). True when it did.
    private func loadPendingSelection(play: Bool) -> Bool {
        guard visible > 0, let wanted, wanted != url else { return false }
        let kind = QCUtilities.mediaKind(of: wanted)
        guard kind == .video || kind == .audio else { return false }
        if play { playNow(wanted) } else { loadTask?.cancel(); load(wanted) }
        return true
    }

    /// Fast scrubbing: lands on nearby keyframes, and only the latest target is sought while one is in flight.
    func scrub(to seconds: Double) {
        if seeking { pendingSeek = seconds; return }
        seeking = true
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.scrub(to: next)
                }
            }
        }
    }

    private func load(_ url: URL?) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        clock.reset()
        self.url = url
        kind = url.flatMap { QCUtilities.mediaKind(of: $0) }
        guard let url, kind == .video || kind == .audio else {
            player.replaceCurrentItem(with: nil)
            playWhenLoaded = false
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: url)))
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock.tick(time: time.seconds, duration: self.player.currentItem?.duration.seconds, isPlaying: self.player.rate != 0)
            }
        }
        startIfWanted()
        let asset = player.currentItem?.asset   // the item's own asset: no second open of the file
        Task {
            let rate = (try? await asset?.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)).map(Double.init) ?? 0
            guard self.url == url else { return }
            clock.fps = rate > 0 && rate < 1000 ? rate : 25   // inf from a damaged header made the timecode Int(NaN)
        }
    }
}

// MARK: - Views

/// The preview: picture (or still / audio card), then the transport. `placement` picks the header's button.
struct InspectPreviewPanel: View {
    enum Placement { case panel, window }
    let placement: Placement
    let isLightMode: Bool

    @ObservedObject private var preview = InspectPreview.shared
    @AppStorage(InspectPreviewWindow.poppedOutKey) private var poppedOut = false
    /// The docked preview folded away (arrow in its header). Its player is emptied while folded.
    @AppStorage("inspectPreviewCollapsed") private var collapsed = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if placement == .panel {
                HStack(spacing: 6) {
                    Button { withAnimation(Motion.list) { collapsed.toggle() } } label: {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                            .foregroundColor(palette.textMuted)
                            .frame(width: StudioTheme.scale(14))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tip(collapsed ? "Show the preview." : "Hide the preview.")
                    Text("Preview")
                        .font(.ui(size: 12, weight: .semibold))
                        .foregroundColor(palette.textMuted)
                    Spacer(minLength: 4)
                    if !poppedOut {
                        Button { openWindow(id: InspectPreviewWindow.id) } label: {
                            Image(systemName: "macwindow.on.rectangle")
                                .font(.system(size: StudioTheme.scaleFont(10), weight: .medium))
                        }
                        .buttonStyle(TransportIconButtonStyle())
                        .tip("Open the preview in its own window, to make it bigger or move it to another screen.")
                    }
                }
            }
            if placement == .panel && collapsed && !poppedOut {
                EmptyView()
            } else if placement == .panel && poppedOut {
                HStack(spacing: 8) {
                    Text("The preview is in its own window.")
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textSubtle)
                    Spacer(minLength: 4)
                    Button("Dock Here", action: dock).font(.ui(size: 11))
                }
            } else {
                picture
                    .aspectRatio(placement == .panel ? 16 / 9 : nil, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: placement == .window ? .infinity : nil)
                    .background(Color.black)   // design-ok: the media well
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .contextMenu { if let url = preview.url { fileMenu(url) } }
                InspectPreviewTransport(isLightMode: isLightMode)
                    .opacity(preview.kind == .video || preview.kind == .audio ? 1 : 0.4)
                    .disabled(!(preview.kind == .video || preview.kind == .audio))
                if placement == .window {
                    HStack {
                        Text(preview.url?.lastPathComponent ?? "")
                            .font(.ui(size: 11))
                            .foregroundColor(palette.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button("Dock in Inspect", action: dock).font(.ui(size: 11))
                    }
                }
            }
        }
        // Counts as an on-screen preview only while it shows a picture: not folded, not handed to the window.
        .onAppear { if showsPicture { preview.appeared() } }
        .onDisappear { if showsPicture { preview.disappeared() } }
        .onChange(of: showsPicture) { _, shows in shows ? preview.appeared() : preview.disappeared() }
    }

    private var showsPicture: Bool { placement == .window || (!poppedOut && !collapsed) }

    /// The list's main actions for the file shown (right-click on the picture).
    @ViewBuilder
    private func fileMenu(_ url: URL) -> some View {
        Button("Open in Player") { DeliveryPlanStore.post(.play, url) }
        Button("Media Info") { NotificationCenter.default.post(name: InspectPreview.showInfo, object: url) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        let rows = DeliveryPlanStore.shared.rowIDs(forFiles: [url])
        if !rows.isEmpty {
            Divider()
            Menu("Set Plan Status") {
                ForEach(PlanQCStatus.allCases, id: \.self) { status in
                    Button("\(status.title)  \(status.shortcut)") { DeliveryPlanStore.shared.setStatus(status, rowIDs: rows) }
                }
                Divider()
                Button("Clear Status") { DeliveryPlanStore.shared.setStatus(nil, rowIDs: rows) }
            }
            Button("Run Plan Checks") {
                let store = DeliveryPlanStore.shared, queue = PlanCheckQueue.shared
                queue.loadIfNeeded()
                let ids = Set(rows)   // a set: with 1,000 files selected, an array lookup per row was ~1 M comparisons
                let stamps = store.rows.filter { ids.contains($0.id) }.flatMap { store.fileStamps($0) }.filter { $0.url == url }
                queue.enqueue(Array(stamps.prefix(1)), kinds: queue.kinds)
            }
        }
        Divider()
        if placement == .window {
            Button("Dock in Inspect", action: dock)
        } else {
            Button("Open in Its Own Window") { openWindow(id: InspectPreviewWindow.id) }
        }
    }

    @ViewBuilder
    private var picture: some View {
        GeometryReader { geo in
            ZStack {
                if let url = preview.url {
                    switch preview.kind {
                    case .audio:
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: StudioTheme.scaleFont(26)))
                                .foregroundColor(Color.white.opacity(0.55))   // design-ok: on the black media well
                            Text(url.lastPathComponent)
                                .font(.ui(size: 11, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.8))   // design-ok: on the black media well
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 12)
                    default:
                        // The thumbnail shows at once; the player's first frame covers it when ready (clear layer).
                        if geo.size.width > 1 {   // not at the first 0-wide layout pass (a needless small fetch)
                            AssetThumbnailView(fileURL: url, width: geo.size.width, height: geo.size.height, cornerRadius: 0)   // design-ok: fills the preview frame, which is rounded
                        }
                        if preview.kind == .video { PreviewPlayerView(player: preview.player, clearBackground: true) }
                    }
                } else {
                    Text("Select a file")
                        .font(.ui(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))   // design-ok: on the black media well
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Back into Inspect's panel; clears the flag itself (a window that isn't open never runs its onDisappear).
    private func dock() {
        poppedOut = false
        dismissWindow(id: InspectPreviewWindow.id)
    }
}

/// Play / pause, scrubber, time and speaker. The only view observing the 10 Hz clock.
private struct InspectPreviewTransport: View {
    let isLightMode: Bool
    @ObservedObject private var clock = InspectPreview.shared.clock
    @ObservedObject private var preview = InspectPreview.shared
    @State private var scrubbing: Double?

    var body: some View {
        let palette = StudioPalette(isLightMode)
        HStack(spacing: 6) {
            Button { _ = preview.togglePlay() } label: {
                Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .bold))
                    .frame(width: StudioTheme.scale(20), height: StudioTheme.scale(20))
                    .foregroundColor(palette.textMain)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .tip("Play or pause the preview (Space).")
            Slider(value: Binding(get: { scrubbing ?? clock.time },
                                  set: { scrubbing = $0; preview.scrub(to: $0) }),
                   in: 0...max(clock.duration, 0.01)) { editing in
                if !editing { scrubbing = nil }
            }
            .controlSize(.mini)
            Text(timecode(scrubbing ?? clock.time))
                .font(.ui(size: 10))
                .monospacedDigit()
                .foregroundColor(palette.textMuted)
            Button { preview.isMuted.toggle() } label: {
                Image(systemName: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .medium))
                    .frame(width: StudioTheme.scale(20), height: StudioTheme.scale(20))
                    .foregroundColor(preview.isMuted ? palette.textMuted : palette.textMain)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TransportIconButtonStyle())
            .tip(preview.isMuted ? "Turn the preview's sound on." : "Mute the preview.")
        }
    }

    private func timecode(_ seconds: Double) -> String {
        TimecodeFormatter.format(frameIndex: Int((max(seconds, 0) * clock.fps).rounded(.down)), fps: clock.fps)
    }
}

/// The popped-out preview (any size, any screen).
struct InspectPreviewWindow: View {
    static let id = "inspectPreview"
    static let poppedOutKey = "inspectPreviewPoppedOut"

    @AppStorage("isLightMode") private var isLightMode = false
    @AppStorage(poppedOutKey) private var poppedOut = false

    var body: some View {
        InspectPreviewPanel(placement: .window, isLightMode: isLightMode)
            .padding(12)
            .frame(minWidth: 320, idealWidth: 640, minHeight: 240, idealHeight: 420)
            .background(StudioPalette(isLightMode).bgPanel)
            .preferredColorScheme(isLightMode ? .light : .dark)
            .onAppear { poppedOut = true }
            .onDisappear { poppedOut = false }
    }
}

extension InspectPreview {
    /// Posted with a URL from the preview's right-click menu: `ContentView` opens Media Info for it.
    static let showInfo = Notification.Name("QCpieInspectPreviewShowInfo")
}
