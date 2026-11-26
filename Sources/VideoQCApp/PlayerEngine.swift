import Foundation
import os
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
import UniformTypeIdentifiers
@preconcurrency import VideoToolbox
import VideoQCLib

@MainActor
public final class PlayerEngine: ObservableObject {
    
    // MARK: - Dual Player Slots & Comparison State
    
    @Published public var slotA = PlayerSlot(id: .slotA)
    @Published public var slotB = PlayerSlot(id: .slotB)
    @Published public var activeTarget: SlotTarget = .slotA {
        didSet {
            enforceCompatibleSafeAreaMode()
        }
    }
    @Published public var compareMode: CompareMode = .single {
        didSet {
            if isBlinkCompareB {
                isBlinkCompareB = false
            }
            if !hasMatchingAspectRatios && compareMode.requiresMatchingAspect {
                compareMode = .sideBySide
            }
        }
    }
    // Not @Published: only the viewport reads it (imperatively), and a drag writes it per mouse event.
    public var splitPosition: CGFloat = 0.5
    @Published public var lastScreenshotPreset: ScreenshotPreset = .jpgMedium
    
    public var hasMatchingAspectRatios: Bool {
        guard slotB.url != nil else { return true }
        let aspectA = slotA.aspectRatio
        let aspectB = slotB.aspectRatio
        guard aspectA > 0, aspectB > 0 else { return true }
        return abs(aspectA - aspectB) / max(aspectA, aspectB) < 0.02
    }
    
    public var isNineBySixteen: Bool {
        if (compareMode == .sideBySide || compareMode == .sideBySideVertical) && slotB.url != nil {
            return slotA.isNineBySixteen || slotB.isNineBySixteen
        }
        let slot = (activeTarget == .slotB && compareMode != .single) ? slotB : slotA
        return slot.isNineBySixteen
    }
    
    public func enforceCompatibleSafeAreaMode() {
        if !isNineBySixteen && safeAreaMode == .tikTok {
            safeAreaMode = .standard
        }
    }
    
    public func cycleSafeAreaMode() {
        if isNineBySixteen {
            switch safeAreaMode {
            case .off:
                safeAreaMode = .standard
            case .standard:
                safeAreaMode = .tikTok
            case .tikTok:
                safeAreaMode = .off
            }
        } else {
            switch safeAreaMode {
            case .off, .tikTok:
                safeAreaMode = .standard
            case .standard:
                safeAreaMode = .off
            }
        }
    }
    
    public func enforceCompatibleCompareMode() {
        enforceCompatibleSafeAreaMode()
        guard slotB.url != nil else {
            if compareMode != .single {
                compareMode = .single
            }
            return
        }
        if !hasMatchingAspectRatios && compareMode.requiresMatchingAspect {
            compareMode = .sideBySide
        }
    }
    @Published public var isLinked: Bool = UserPreferences.linkSlots
    @Published public var audioSlot: SlotTarget = .slotA {
        didSet {
            updateAudioVolumes()
        }
    }
    @Published public var isBlinkCompareB: Bool = false {
        didSet {
            if isBlinkCompareB && compareMode != .single {
                isBlinkCompareB = false
                return
            }
            if isBlinkCompareB && isLinked && slotB.url != nil {
                syncSlotBToMaster()
            }
            // A/B audio: blinking between two audio files switches what you hear.
            if slotA.mediaKind == .audio && slotB.mediaKind == .audio && slotB.url != nil {
                audioSlot = isBlinkCompareB ? .slotB : .slotA
            }
        }
    }
    @Published public var clipInfoOverlayMode: ClipInfoOverlayMode = UserPreferences.clipInfoOverlay
    @Published public var showResolutionLabels: Bool = UserPreferences.clipInfoOverlay != .off
    
    public func cycleClipInfoOverlayMode() {
        self.clipInfoOverlayMode = self.clipInfoOverlayMode.next
        self.showResolutionLabels = (clipInfoOverlayMode != .off)
    }
    
    // MARK: - Backwards Compatible Single-Player Properties (Reflects Slot A / Master)
    
    public var activeURL: URL? { slotA.url }
    public var slotBURL: URL? { slotB.url }
    public var activeFileName: String { slotA.fileName }
    public var activeResolution: String { slotA.resolution }
    public var activeFps: Double { slotA.fps }
    public var videoSize: CGSize { slotA.videoSize }
    
    public var currentTime: CMTime = .zero
    @Published public var duration: CMTime = .zero
    @Published public var durationTimecode: String = "00:00:00:00"
    @Published public var totalFrames: Int = 0
    
    // Per-frame values live on `clock`; never re-add them as @Published on the engine.
    public let clock = PlaybackClock()
    
    public var currentTimecode: String {
        get { clock.currentTimecode }
        set { if clock.currentTimecode != newValue { clock.currentTimecode = newValue } }
    }
    
    public var currentFrame: Int {
        get { clock.currentFrame }
        set { if clock.currentFrame != newValue { clock.currentFrame = newValue } }
    }
    
    public var currentProgress: Double {
        get { clock.currentProgress }
        set { if clock.currentProgress != newValue { clock.currentProgress = newValue } }
    }
    @Published public var displayTimeAsFrames: Bool = false
    
    @Published public var rate: Float = 0.0
    @Published public var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            updateDisplaySleepAssertion()
            PlaybackActivity.setPlaying(isPlaying)
            // Drawings are on paused frames: playing ends draw mode (a click on the picture pauses again).
            if isPlaying, isDrawingNote { endDrawing(offerText: false) }
        }
    }
    /// Held while playing so the display doesn't sleep mid-review (released on pause).
    private var displaySleepActivity: NSObjectProtocol?
    
    private func updateDisplaySleepAssertion() {
        if isPlaying, displaySleepActivity == nil {
            displaySleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled], reason: "Playing video")
        } else if !isPlaying, let activity = displaySleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displaySleepActivity = nil
        }
    }
    @Published public var isLooping: Bool = UserPreferences.loop {
        didSet { if isLooping != oldValue { applyInOutRange() } }
    }
    /// In / Out points on slot A (I / O, frames, Out inclusive). With loop on, playback loops between them: the item's
    /// `forwardPlaybackEndTime` ends it at Out (no per-frame check) and the end handler seeks back to In.
    @Published public internal(set) var inFrame: Int?
    @Published public internal(set) var outFrame: Int?
    
    // Zoom & Pan
    @Published public var zoomScale: CGFloat = 1.0
    @Published public var isFitZoom: Bool = true
    // Not @Published: only the viewport reads it (imperatively), and panning writes it per mouse event.
    public var panOffset: CGSize = .zero
    
    // Crosshair & Guides
    @Published public var showCenterCrosshair: Bool = false
    @Published public var safeAreaMode: SafeAreaMode = UserPreferences.safeArea
    /// Viewer gamma (User Settings): read per frame by the composition through `gammaBox`, like EV.
    @Published var viewerGamma: ViewerGamma = .current {
        didSet {
            guard viewerGamma != oldValue else { return }
            UserDefaults.standard.set(viewerGamma.rawValue, forKey: UserPreferences.viewerGammaKey)
            gammaBox.set(viewerGamma.power)
            updateVideoCompositions()
            refreshPausedFramesForExposure()
        }
    }
    /// Behind the picture (User Settings); the viewport applies it on change only.
    @Published var viewerBackground: ViewerBackground = .current {
        didSet { UserDefaults.standard.set(viewerBackground.rawValue, forKey: UserPreferences.viewerBackgroundKey) }
    }
    
    // Legal-range zebra on paused frames; the preset is shared with Frame Check.
    @Published public var showLegalZebra: Bool = false
    /// Outlines Line Check's findings on paused frames (`VideoViewportView.updateLineMarks`).
    @Published public var showLineMarks: Bool = UserDefaults.standard.object(forKey: "prefShowLineMarks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showLineMarks, forKey: "prefShowLineMarks") }
    }
    @Published public var legalRangePreset: String = LegalRangeSpec.current.name {
        didSet { UserDefaults.standard.set(legalRangePreset, forKey: LegalRangeSpec.preferenceKey) }
    }
    
    // Video Exposure Adjustment (EV stops: -5.0 to +5.0)
    @Published public var exposureEV: Double = 0.0 {
        didSet {
            guard exposureEV != oldValue else { return }
            exposureBox.set(exposureEV)
            updateVideoCompositions()
            refreshPausedFramesForExposure()
        }
    }
    
    public func resetExposure() {
        self.exposureEV = 0.0
    }
    
    // MARK: - Discrete Transport State for Sub-Views
    
    public var transportState: TransportState {
        TransportState(
            isPlaying: isPlaying,
            rate: rate,
            isLooping: isLooping,
            safeAreaMode: safeAreaMode,
            isNineBySixteen: isNineBySixteen,
            showCenterCrosshair: showCenterCrosshair,
            showLegalZebra: showLegalZebra,
            showLineMarks: showLineMarks,
            hasLineMarks: [slotA.url, slotB.url].contains { $0.flatMap { lineMarks[$0.standardizedFileURL] } != nil },
            legalRangePreset: legalRangePreset,
            clipInfoOverlayMode: clipInfoOverlayMode,
            lastScreenshotPreset: lastScreenshotPreset,
            hasActiveURL: activeURL != nil,
            notesCount: activeNotes.count,
            hasSubtitles: !subtitleCues.isEmpty || (slotB.url != nil && !subtitleCuesB.isEmpty),
            showSubtitles: showSubtitles,
            hasTimeline: hasTimeline,
            hasVideo: slotA.mediaKind == .video,
            lutName: lutLabel,
            showLUTs: showLUTs,
            isDrawingNote: isDrawingNote
        )
    }
    
    // MARK: - Subtitles (.srt, shown over slot A)
    
    /// Waveforms are only decoded when the user turns them on (queue WAVE toggle).
    @Published public var drawsWaveforms: Bool = UserDefaults.standard.bool(forKey: "drawsWaveforms") {
        didSet {
            UserDefaults.standard.set(drawsWaveforms, forKey: "drawsWaveforms")
            refreshWaveform()
        }
    }
    
    /// Timeline waveform for slot A's audio (empty when off, for images and silent files). Published once per load.
    @Published public private(set) var waveformPeaks: [Float] = []
    /// By file and its modification date at load: a re-export at the same path (a fixed mix) showed the old waveform.
    private var waveformCache: [WaveformKey: [Float]] = [:]
    private struct WaveformKey: Hashable { let url: URL; let modified: Date? }
    private var waveformTask: Task<Void, Never>? = nil
    
    func refreshWaveform() {
        waveformTask?.cancel()
        waveformTask = nil
        guard drawsWaveforms, slotA.mediaKind != .image, let url = slotA.url else {
            if !waveformPeaks.isEmpty { waveformPeaks = [] }
            return
        }
        if !waveformPeaks.isEmpty { waveformPeaks = [] }
        waveformTask = Task { [weak self] in
            // The file's date is read here, off the main thread (it is the cache key: a re-export at the same path).
            let key = WaveformKey(url: url, modified: await Self.modificationDateOffMain(of: url))
            guard let self, !Task.isCancelled, self.slotA.url == url else { return }
            if let cached = self.waveformCache[key] {
                self.waveformPeaks = cached
                return
            }
            let work = Task.detached(priority: .utility) { await AudioWaveform.peaks(url: url) }
            let peaks = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let peaks, self.slotA.url == url else { return }
            if self.waveformCache.count >= 16 { self.waveformCache.removeAll() }
            self.waveformCache[key] = peaks
            self.waveformPeaks = peaks
        }
    }
    
    @Published public private(set) var subtitleCues: [SubtitleCue] = []
    /// Slot B's attached / sidecar .srt (read-only, shown in A/B modes that show B).
    @Published public private(set) var subtitleCuesB: [SubtitleCue] = []
    private var subtitleLoadGenerationB: Int = 0
    @Published public private(set) var subtitleFileName: String? = nil
    @Published public private(set) var subtitleSourceURL: URL? = nil
    @Published public private(set) var hasUnsavedSubtitleEdits: Bool = false
    /// The clip whose burned-in subtitles are shown as an unsaved draft (no .srt yet); nil for subtitles from a file.
    @Published public private(set) var pictureSubtitleClip: URL? = nil
    /// Lines of that draft worth a second look (low OCR confidence, unusually long). Lines are never added or
    /// removed by editing, so indices stay valid until the draft is replaced.
    @Published public private(set) var subtitleReviewLines: Set<Int> = []
    @Published public var showSubtitles: Bool = true
    /// Where subtitles sit over slot A, as fractions of the picture: x = centre, y = distance of the text's bottom
    /// edge from the picture's bottom. Set when a drag ends (never per mouse event); remembered across launches.
    @Published public var subtitlePosition: CGPoint = PlayerEngine.savedSubtitlePosition() {
        didSet {
            UserDefaults.standard.set(Double(subtitlePosition.x), forKey: "subtitlePositionX")
            UserDefaults.standard.set(Double(subtitlePosition.y), forKey: "subtitlePositionY")
        }
    }
    public static let defaultSubtitlePosition = CGPoint(x: 0.5, y: 0.06)
    
    private static func savedSubtitlePosition() -> CGPoint {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "subtitlePositionX") != nil, defaults.object(forKey: "subtitlePositionY") != nil else {
            return defaultSubtitlePosition
        }
        return CGPoint(x: defaults.double(forKey: "subtitlePositionX"), y: defaults.double(forKey: "subtitlePositionY"))
    }
    
    public func resetSubtitlePosition() {
        subtitlePosition = Self.defaultSubtitlePosition
    }
    /// Bumped on every text edit so the viewport overlay redraws the current line.
    public private(set) var subtitleRevision: Int = 0
    private var subtitleFormat = SubtitleFileFormat()
    private var subtitleLoadGeneration: Int = 0
    /// Unsaved edits per .srt (standardized path), restored if that file is opened again this session.
    /// App-wide, not per engine: closing the main window discards its engine, and the edits went with it.
    private static var unsavedSubtitleEdits: [String: [SubtitleCue]] = [:]
    private var unsavedSubtitleEdits: [String: [SubtitleCue]] {
        get { Self.unsavedSubtitleEdits }
        set { Self.unsavedSubtitleEdits = newValue }
    }
    private static var pictureReviewLines: [String: Set<Int>] = [:]
    /// Where an unsaved draft of `clip`'s burned-in subtitles is kept (also its name in the quit prompt).
    static func pictureSubtitleKey(for clip: URL) -> String {
        clip.standardizedFileURL.deletingPathExtension().path + " (read from picture).srt"
    }
    /// Key of the shown subtitles in `unsavedSubtitleEdits`.
    private var shownSubtitleKey: String? {
        subtitleSourceURL?.standardizedFileURL.path ?? pictureSubtitleClip.map(Self.pictureSubtitleKey)
    }
    /// .srt files with edits not saved yet (in memory only: asked about on quit).
    static var unsavedSubtitleFileNames: [String] { unsavedSubtitleEdits.keys.map { ($0 as NSString).lastPathComponent }.sorted() }
    
    /// Loads an .srt for the master clip. Returns false if the file has no readable cues.
    @discardableResult
    public func loadSubtitles(from url: URL) -> Bool {
        guard let file = try? SubtitleParser.loadFile(from: url), !file.cues.isEmpty else { return false }
        subtitleLoadGeneration &+= 1
        applySubtitleFile(file, from: url)
        showSubtitles = true
        // Remembered for the clip, so switching clips and back (or Specs) keeps it.
        if let media = slotA.url { SubtitleAttachments.setManual(url, for: media) }
        return true
    }
    
    private func applySubtitleFile(_ file: SubtitleFile, from url: URL) {
        let key = url.standardizedFileURL.path
        let pending = unsavedSubtitleEdits[key]
        if pictureSubtitleClip != nil { pictureSubtitleClip = nil }
        if !subtitleReviewLines.isEmpty { subtitleReviewLines = [] }
        subtitleFormat = file.format
        subtitleCues = pending ?? file.cues
        subtitleFileName = url.lastPathComponent
        subtitleSourceURL = url
        hasUnsavedSubtitleEdits = pending != nil
        subtitleRevision &+= 1
    }
    
    /// Lets the user pick an .srt for the master clip. Returns false if cancelled or unreadable.
    @discardableResult
    public func chooseAndLoadSubtitles() -> Bool {
        guard let mediaURL = slotA.url else { return false }
        let panel = NSOpenPanel()
        panel.title = "Import Subtitles"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.directoryURL = mediaURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let loaded = loadSubtitles(from: url)
        if !loaded { NSSound.beep() }
        return loaded
    }
    
    /// Whether `clip` has an unsaved draft of subtitles read from its picture.
    public func hasPictureSubtitleDraft(for clip: URL) -> Bool {
        unsavedSubtitleEdits[Self.pictureSubtitleKey(for: clip)] != nil
    }

    /// Shows subtitles read from `clip`'s picture as an unsaved draft (kept, and asked about on quit, until saved
    /// as an .srt or removed). A draft for a clip that isn't in slot A any more is kept for when it comes back.
    public func loadPictureSubtitles(_ cues: [SubtitleCue], review: Set<Int>, for clip: URL) {
        let key = Self.pictureSubtitleKey(for: clip)
        unsavedSubtitleEdits[key] = cues
        Self.pictureReviewLines[key] = review
        guard QCUtilities.isSameURL(slotA.url, clip) else { return }
        showPictureDraft(for: clip)
        showSubtitles = true
    }

    private func showPictureDraft(for clip: URL) {
        let key = Self.pictureSubtitleKey(for: clip)
        guard let cues = unsavedSubtitleEdits[key] else { return }
        subtitleLoadGeneration &+= 1
        subtitleFormat = SubtitleFileFormat()
        subtitleCues = cues
        subtitleFileName = (key as NSString).lastPathComponent
        subtitleSourceURL = nil
        pictureSubtitleClip = clip
        subtitleReviewLines = Self.pictureReviewLines[key] ?? []
        hasUnsavedSubtitleEdits = true
        subtitleRevision &+= 1
    }

    /// Remove Subtitles: a draft read from the picture is discarded (it exists nowhere else); a file stays on disk.
    public func removeSubtitles() {
        if let clip = pictureSubtitleClip {
            let key = Self.pictureSubtitleKey(for: clip)
            unsavedSubtitleEdits.removeValue(forKey: key)
            Self.pictureReviewLines.removeValue(forKey: key)
        }
        clearSubtitles()
    }

    public func clearSubtitles() {
        subtitleLoadGeneration &+= 1
        if pictureSubtitleClip != nil { pictureSubtitleClip = nil }
        if !subtitleReviewLines.isEmpty { subtitleReviewLines = [] }
        if !subtitleCues.isEmpty { subtitleCues = [] }
        if subtitleFileName != nil { subtitleFileName = nil }
        if subtitleSourceURL != nil { subtitleSourceURL = nil }
        if hasUnsavedSubtitleEdits { hasUnsavedSubtitleEdits = false }
    }
    
    /// Edits one line's text (kept in memory until saved).
    public func updateSubtitleText(at index: Int, to text: String) {
        guard subtitleCues.indices.contains(index), subtitleCues[index].text != text else { return }
        var cues = subtitleCues
        cues[index].text = text
        setEditedSubtitles(cues)
    }
    
    /// Replaces all lines at once (Replace All), as a single change.
    public func setEditedSubtitles(_ cues: [SubtitleCue]) {
        guard cues != subtitleCues else { return }
        subtitleRevision &+= 1
        subtitleCues = cues
        if !hasUnsavedSubtitleEdits { hasUnsavedSubtitleEdits = true }
        if let key = shownSubtitleKey {
            unsavedSubtitleEdits[key] = cues
        }
    }
    
    /// Writes the edited lines back to the .srt they came from.
    public func saveSubtitles() throws {
        guard let url = subtitleSourceURL else { throw CocoaError(.fileNoSuchFile) }
        try saveSubtitles(to: url)
    }
    
    /// Writes the lines to `url` (Save As); the new file becomes the subtitles' source.
    public func saveSubtitles(to url: URL) throws {
        try SubtitleParser.write(SubtitleFile(cues: subtitleCues, format: subtitleFormat), to: url)
        if let old = shownSubtitleKey {
            unsavedSubtitleEdits.removeValue(forKey: old)
            Self.pictureReviewLines.removeValue(forKey: old)
        }
        if pictureSubtitleClip != nil { pictureSubtitleClip = nil }
        if !subtitleReviewLines.isEmpty { subtitleReviewLines = [] }
        unsavedSubtitleEdits.removeValue(forKey: url.standardizedFileURL.path)
        let previous = subtitleSourceURL
        subtitleSourceURL = url
        subtitleFileName = url.lastPathComponent
        hasUnsavedSubtitleEdits = false
        // Attached to the clip, as a loaded .srt is: reopening the clip showed the old file, without these edits.
        // After the source is set, so the attachment observer sees the shown file and doesn't reload it.
        if let media = slotA.url, !QCUtilities.isSameURL(url, previous) {
            SubtitleAttachments.setManual(url, for: media)
        }
    }
    
    /// Picks up the clip's attached .srt, or `clip.srt` sitting next to `clip.mov` (read off the main thread).
    /// An unsaved draft read from the clip's picture comes first (it exists nowhere else), except when an .srt was
    /// just attached to the clip on purpose (`preferDraft: false`): then that file shows and the draft waits.
    func autoLoadSubtitles(for mediaURL: URL?, preferDraft: Bool = true) {
        clearSubtitles()
        guard let mediaURL = mediaURL else { return }
        if preferDraft, hasPictureSubtitleDraft(for: mediaURL) {
            showPictureDraft(for: mediaURL)
            return
        }
        let generation = subtitleLoadGeneration
        Task { [weak self] in
            let found: (URL, SubtitleFile)? = await Task.detached(priority: .utility) {
                guard let url = SubtitleAttachments.resolve(for: mediaURL),
                      let file = try? SubtitleParser.loadFile(from: url), !file.cues.isEmpty else { return nil }
                return (url, file)
            }.value
            guard let self, let (url, file) = found, generation == self.subtitleLoadGeneration else { return }
            self.applySubtitleFile(file, from: url)
        }
    }
    func autoLoadSubtitlesB(for mediaURL: URL?) {
        subtitleLoadGenerationB &+= 1
        if !subtitleCuesB.isEmpty { subtitleCuesB = [] }
        guard let mediaURL else { return }
        let generation = subtitleLoadGenerationB
        Task { [weak self] in
            let cues: [SubtitleCue] = await Task.detached(priority: .utility) {
                guard let url = SubtitleAttachments.resolve(for: mediaURL) else { return [] }
                return (try? SubtitleParser.loadFile(from: url))?.cues ?? []
            }.value
            guard let self, generation == self.subtitleLoadGenerationB, !cues.isEmpty else { return }
            self.subtitleCuesB = cues
        }
    }
    // MARK: - Exposure Video Composition (Single Exposure Pipeline)
    //
    // The composition is the only place exposure is applied to decoded video: AVPlayerLayer (scrub) and
    // AVPlayerItemVideoOutput (playback & paused stills) both receive composited frames, so the viewport must
    // never re-apply exposure to video output buffers. The handler reads `exposureBox` per frame, so EV changes
    // never replace the composition. Installed when EV leaves 0, removed once EV settles back at 0.
    
    let exposureBox = ExposureValueBox()
    /// The viewer gamma's power (0: macOS's own Rec.709 reading).
    let gammaBox = ExposureValueBox()
    private var exposureTeardownTask: Task<Void, Never>? = nil
    
    public func updateVideoCompositions() {
        exposureTeardownTask?.cancel()
        exposureTeardownTask = nil
        if abs(exposureEV) >= 0.001 || gammaBox.value > 0 {
            installExposureComposition(for: slotA)
            installExposureComposition(for: slotB)
            return
        }
        // A sequence's composition is its compositor (it applies EV and the LUT itself): never remove it.
        // Nor a rotated clip's (it keeps the frames upright), nor one showing a LUT.
        func removable(_ slot: PlayerSlot) -> AVPlayerItem? {
            slot.sequence == nil && !slot.isRotated && slot.lut.value == nil ? slot.player.currentItem : nil
        }
        guard removable(slotA)?.videoComposition != nil || removable(slotB)?.videoComposition != nil else { return }
        // Debounced so dragging EV through 0 doesn't rebuild the render pipeline twice.
        exposureTeardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, abs(self.exposureEV) < 0.001, self.gammaBox.value == 0 else { return }
            removable(self.slotA)?.videoComposition = nil
            removable(self.slotB)?.videoComposition = nil
        }
    }
    
    /// EV off 0, a rotation, a LUT or the broadcast viewer gamma: the frames go through the composition.
    private func needsComposition(_ slot: PlayerSlot) -> Bool {
        abs(exposureEV) >= 0.001 || slot.isRotated || slot.lut.value != nil || gammaBox.value > 0
    }
    
    /// Built asynchronously: the synchronous initializer loads the asset's tracks on the main thread (a clip on a slow
    /// share stalled the window when it loaded with EV ≠ 0 or a rotation). The paused frame is re-rendered once installed.
    func installExposureComposition(for slot: PlayerSlot) {
        guard needsComposition(slot), slot.mediaKind == .video, slot.sequence == nil,
              let item = slot.player.currentItem, item.videoComposition == nil else { return }
        let box = exposureBox
        let lutBox = slot.lut
        let gammaBox = gammaBox
        let asset = item.asset
        Task { [weak self] in
            guard let composition = try? await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { @Sendable request in
                let ev = box.value
                var image = request.sourceImage
                if let lut = lutBox.value { image = image.applyingLUT(lut) }
                if abs(ev) >= 0.001 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev]) }
                // Last: how the result is shown (a display transform, after the grade).
                let gamma = gammaBox.value
                if gamma > 0 { image = image.applyingDisplayGamma(gamma, source: request.sourceImage.colorSpace) }
                request.finish(with: image, context: nil)
            }) else { return }
            // Still wanted on the same item (EV back at 0, another clip, or another install got there first: nothing).
            guard let self, slot.player.currentItem === item, item.videoComposition == nil,
                  self.needsComposition(slot), slot.sequence == nil else { return }
            item.videoComposition = composition
            self.refreshPausedFramesForExposure()
        }
    }
    
    // MARK: - LUTs
    
    /// The LUT button's label: slot A's LUT, else slot B's, marked when it can't be read.
    private var lutLabel: String? {
        let slot = slotA.lutName != nil ? slotA : (slotB.url != nil && slotB.lutName != nil ? slotB : nil)
        guard let slot, let name = slot.lutName else { return nil }
        return LUTLibrary.displayName(name) + (slot.lutMissing ? " · can't be read" : "")
    }
    
    /// Shows or hides every assigned LUT (the viewport's LUT button, ⇧E); assignments stay.
    @Published public var showLUTs: Bool = UserDefaults.standard.object(forKey: "playerShowLUTs") as? Bool ?? true {
        didSet {
            guard showLUTs != oldValue else { return }
            UserDefaults.standard.set(showLUTs, forKey: "playerShowLUTs")
            refreshLUT(for: slotA)
            refreshLUT(for: slotB)
        }
    }
    
    /// Shows the LUT assigned to the slot's file. Called on every load (in place of installing the composition) and
    /// when assignments or the LUT switch change. A LUT read for the first time loads off the main thread; the previous
    /// file's LUT is never shown on the new one meanwhile.
    func refreshLUT(for slot: PlayerSlot) {
        let url = slot.url
        let name = url.flatMap { slot.mediaKind == .video ? LUTLibrary.shared.lutName(for: $0) : nil }
        if slot.lutName != name { slot.lutName = name }
        if slot.lutMissing { slot.lutMissing = false }
        guard let url, let wanted = showLUTs ? name : nil else { showLUT(nil, on: slot); return }
        if let cube = LUTLibrary.shared.cachedLUT(named: wanted) { showLUT(cube, on: slot); return }
        showLUT(nil, on: slot)
        Task { [weak self] in
            let cube = await LUTLibrary.shared.lut(named: wanted)
            guard let self, slot.url == url, self.showLUTs, LUTLibrary.shared.lutName(for: url) == wanted else { return }
            if cube == nil { slot.lutMissing = true }
            self.showLUT(cube, on: slot)
        }
    }
    
    /// The composition reads the box per frame: a change only installs one when none is there, or removes it at EV 0.
    private func showLUT(_ cube: CubeLUT?, on slot: PlayerSlot) {
        let changed = slot.lut.value != cube
        if changed {
            slot.lut.set(cube)
            // A paused sequence still is re-read when the viewport next checks it (its LUT is part of the check);
            // a LUT that finished loading after the load's own redraw needs one more.
            if slot.sequence != nil { objectWillChange.send() }
        }
        if slot.player.currentItem?.videoComposition == nil {
            installExposureComposition(for: slot)   // only when needed; refreshes the paused frame once installed
            return
        }
        guard changed else { return }
        if cube == nil { updateVideoCompositions() }
        refreshPausedFramesForExposure()
    }
    
    /// After the user assigns LUTs to files: the slots showing any of them.
    public func lutAssignmentsChanged(_ urls: [URL]) {
        let changed = Set(urls.map(\.standardizedFileURL))
        for slot in [slotA, slotB] where slot.url.map({ changed.contains($0.standardizedFileURL) }) == true {
            refreshLUT(for: slot)
        }
    }
    
    /// A paused frame is only re-composited by a seek, and a seek to the exact current time is a no-op in
    /// AVFoundation, so nudge within the same frame to re-render it with the new exposure.
    func refreshPausedFramesForExposure() {
        guard !isPlaying, !isScrubbing, slotA.mediaKind == .video, slotA.player.currentItem != nil else { return }
        // The nudge stays inside the frame, but the playhead would follow it: it's put back on the frame's centre.
        let frame = currentFrame, fps = max(1.0, activeFps)
        seek(toTime: nudgedFrameTime(frame: frame, fps: fps, current: slotA.player.currentTime())) { [weak self] in
            guard let self, self.currentFrame == frame else { return }
            self.updateCurrentTime(time: CMTime(seconds: (Double(frame) + 0.5) / fps, preferredTimescale: 60000))
        }
        
        let showsSlotB = slotB.url != nil && slotB.player.currentItem != nil && (compareMode != .single || isBlinkCompareB)
        guard showsSlotB && !isLinked else { return }
        let fpsB = max(1.0, slotB.fps)
        let currentB = slotB.player.currentTime()
        let secsB = CMTimeGetSeconds(currentB)
        guard secsB.isFinite else { return }
        seekSlotB(to: nudgedFrameTime(frame: Int(floor(secsB * fpsB + 1e-4)), fps: fpsB, current: currentB))
    }
    
    private func nudgedFrameTime(frame: Int, fps: Double, current: CMTime) -> CMTime {
        let safeFps = max(1.0, fps)
        let center = (Double(frame) + 0.5) / safeFps
        let isAtCenter = abs(CMTimeGetSeconds(current) - center) < 0.0001
        return CMTime(seconds: isAtCenter ? center + 0.25 / safeFps : center, preferredTimescale: 60000)
    }
    
    // Glitch Markers from Line Scanner
    @Published public var markersMap: [URL: [PlayerTimelineMarker]] = [:]
    @Published public var activeMarkers: [PlayerTimelineMarker] = []
    /// Set with `markersMap` (whose publish redraws the viewport); read only on paused frames.
    var lineMarks: [URL: LineMarkFrames] = [:] { didSet { lineMarksRevision &+= 1 } }
    private(set) var lineMarksRevision = 0
    
    // Review Notes from Companion Sidecar (.qcnotes)
    @Published public var activeNotes: [QCFileNote] = []
    @Published public var activeNotesURL: URL? = nil {
        didSet { if activeNotesURL != oldValue, isDrawingNote { endDrawing() } }   // another clip: another note list
    }
    
    // MARK: - Drawing on notes (Frame.io style)
    
    /// Draw mode (pencil, D): each stroke drawn on the paused picture goes into a note on that frame (the first one
    /// creates it). Set on entering and leaving only.
    @Published public private(set) var isDrawingNote = false
    /// The note this draw session's strokes go into, per frame (notes' own clock): coming back to a frame adds to
    /// its note instead of starting another.
    var drawingNotes: [Int: UUID] = [:]
    /// The note drawn on last (offered for its text when drawing ends).
    var lastDrawnNoteID: UUID? = nil
    /// Set by ContentView, which owns adding and saving notes: a finished stroke (x0, y0, x1, y1… in 0–1 of the
    /// picture, top-left).
    var onStrokeFinished: (([Double]) -> Void)? = nil
    /// Set by ContentView: draw mode ended, with the note last drawn on (to offer its text for editing).
    var onDrawingEnded: ((UUID?) -> Void)? = nil
    
    /// The notes clip is on screen, so there is a picture to draw on (in single view only slot A's or, while blinking,
    /// slot B's is).
    var notesPictureIsShown: Bool {
        let notesInB = notesTargetIsSlotB
        let slot = notesInB ? slotB : slotA
        guard slot.mediaKind == .video, slot.url != nil else { return false }
        // Difference and overlay blend the two pictures: strokes would be blended too (the line marks skip them as well).
        if compareMode == .difference || compareMode == .overlay { return false }
        if compareMode == .single { return notesInB == isBlinkCompareB }
        return true
    }
    
    /// false when there is no picture to draw on (the caller says why).
    @discardableResult
    public func toggleDrawMode() -> Bool {
        if isDrawingNote { endDrawing(); return true }
        guard notesPictureIsShown else { return false }
        pause()
        drawingNotes = [:]
        lastDrawnNoteID = nil
        isDrawingNote = true
        return true
    }
    
    /// Done, Esc or D. Nothing is lost: every stroke was saved with its note when drawn.
    /// `offerText`: the drawer opens the last note for its text (not when playback ended drawing).
    public func endDrawing(offerText: Bool = true) {
        guard isDrawingNote else { return }
        let last = lastDrawnNoteID
        drawingNotes = [:]
        lastDrawnNoteID = nil
        isDrawingNote = false
        if offerText { onDrawingEnded?(last) }
    }
    var pendingInitialSeekFrame: Int? = nil
    var pendingAutoplay: Bool = false
    var pendingAutoplayB: Bool = false
    /// Set by a swap: slot B's clip keeps the position it had in A instead of jumping to A's on load.
    var slotBKeepsPosition = false
    
    // Autoplay on selection
    @Published public var isAutoplayEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "isAutoplayEnabled") != nil {
            return UserDefaults.standard.bool(forKey: "isAutoplayEnabled")
        }
        return true
    }() {
        didSet {
            UserDefaults.standard.set(isAutoplayEnabled, forKey: "isAutoplayEnabled")
        }
    }
    
    // Audio
    @Published public var volume: Float = 1.0 {
        didSet {
            updateAudioVolumes()
        }
    }
    @Published public var isMuted: Bool = UserPreferences.startMuted {
        didSet {
            updateAudioVolumes()
        }
    }
    
    @Published public var shuttleStateText: String = "PAUSE"
    @Published public var isScrubbing: Bool = false {
        didSet { if isScrubbing != oldValue { PlaybackActivity.setScrubbing(isScrubbing) } }
    }
    public internal(set) var wasPlayingBeforeScrub: Bool = false
    var playbackRateBeforeScrub: Float = 1.0
    
    // Direct reference to Master player for backwards compatibility
    public var player: AVPlayer {
        return slotA.player
    }
    
    final class TokenBox: @unchecked Sendable {
        var timeObserverToken: Any? = nil
        var player: AVPlayer? = nil
    }
    let tokens = TokenBox()
    var cancellables = Set<AnyCancellable>()
    var itemStatusCancellable: AnyCancellable? = nil
    var itemStatusCancellableB: AnyCancellable? = nil
    var itemPresentationSizeCancellable: AnyCancellable? = nil
    var itemPresentationSizeCancellableB: AnyCancellable? = nil
    
    public internal(set) var isSeeking: Bool = false
    /// Bumped by every load request per slot: a same-clip request still reading the file's date is dropped by a newer one.
    var loadRequestA = 0
    var loadRequestB = 0
    /// Counts issued slot A seeks: a completion that isn't the latest one's is stale (see `seek(toTime:)`).
    var seekSerial: Int = 0
    /// Bumped by `pause()`: a seek's completion only runs if nothing paused since it was issued.
    var seekGeneration: Int = 0
    var pendingSeekTime: CMTime? = nil
    var pendingSeekTolerance: CMTime? = nil
    var pendingSeekCompletion: (@MainActor @Sendable () -> Void)? = nil
    
    public internal(set) var isSeekingB: Bool = false
    var pendingSeekTimeB: CMTime? = nil
    var pendingSeekCompletionB: (@MainActor @Sendable () -> Void)? = nil
    var lastDriftCorrectionTime: Date = .distantPast

    // Hard re-sync of slot B during linked playback (see `relockSlotB`).
    var isRelockingB: Bool = false
    var relockGeneration: Int = 0
    var relockHoldUntil: CFTimeInterval = 0
    var lastRelockStart: CFTimeInterval = -.greatestFiniteMagnitude
    var relockLead: Double = 0.25
    // pause() aligns slot B with an untracked seek; play must not start B while it is still in flight.
    var isPauseAlignSeekPendingB: Bool = false
    
    // Dedicated interactive scrub seek state (independent hardware decoding pipelines)
    var isScrubSeekingA: Bool = false
    var pendingScrubTimeA: CMTime? = nil
    var isScrubSeekingB: Bool = false
    var pendingScrubTimeB: CMTime? = nil
    
    // Viewport presentation hooks. Several viewports can be live at once (player tab + fullscreen overlay),
    // so each registers its own hooks instead of sharing a single callback.
    private struct ViewportObserver {
        weak var owner: AnyObject?
        let frameDecoded: @MainActor (SlotTarget, CMTime) -> Void
        let seekSettled: @MainActor () -> Void
    }
    private var viewportObservers: [ViewportObserver] = []
    
    /// `frameDecoded` fires when a seek has decoded the target frame; `seekSettled` fires when a paused seek
    /// completes (replaces a full `objectWillChange` broadcast that re-rendered the whole view tree per step).
    public func attachViewport(
        _ owner: AnyObject,
        frameDecoded: @escaping @MainActor (SlotTarget, CMTime) -> Void,
        seekSettled: @escaping @MainActor () -> Void
    ) {
        viewportObservers.removeAll { $0.owner == nil || $0.owner === owner }
        viewportObservers.append(ViewportObserver(owner: owner, frameDecoded: frameDecoded, seekSettled: seekSettled))
    }
    
    public func detachViewport(_ owner: AnyObject) {
        viewportObservers.removeAll { $0.owner == nil || $0.owner === owner }
    }
    
    func notifyFrameDecoded(_ slot: SlotTarget, at time: CMTime) {
        viewportObservers.removeAll { $0.owner == nil }
        for observer in viewportObservers {
            observer.frameDecoded(slot, time)
        }
    }
    
    func notifySeekSettled() {
        viewportObservers.removeAll { $0.owner == nil }
        for observer in viewportObservers {
            observer.seekSettled()
        }
    }
    
    public init() {
        gammaBox.set(viewerGamma.power)
        slotA.player.automaticallyWaitsToMinimizeStalling = false
        slotB.player.automaticallyWaitsToMinimizeStalling = false
        slotA.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        slotB.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        setupTimeObserver()
        setupEndObserver()
        setupSubtitleAttachmentObserver()
        updateAudioVolumes()
    }
    
    deinit {
        if let token = tokens.timeObserverToken, let player = tokens.player {
            player.removeTimeObserver(token)
        }
    }
    
    // MARK: - Audio Routing
    
    public func updateAudioVolumes() {
        if isMuted {
            slotA.player.volume = 0.0
            slotB.player.volume = 0.0
        } else {
            switch audioSlot {
            case .slotA:
                slotA.player.volume = volume
                slotB.player.volume = 0.0
            case .slotB:
                slotA.player.volume = 0.0
                slotB.player.volume = volume
            }
        }
    }
    
    
    /// A file the player couldn't open (still being rendered or copied, damaged, an unsupported codec): shown as a
    /// message instead of an empty viewport. Published once per failed load.
    public struct LoadFailure: Equatable {
        public let id = UUID()
        public let message: String
    }
    @Published public internal(set) var loadFailure: LoadFailure?
    public enum SlowDirection {
        case forward
        case reverse
    }
    
    let slowSpeeds: [Double] = [2.0, 4.0, 8.0, 15.0, 24.0, 30.0]
    var slowStepTimer: Timer? = nil
    var slowDirection: SlowDirection = .forward
    var slowSpeedIndex: Int = 0
    
}
