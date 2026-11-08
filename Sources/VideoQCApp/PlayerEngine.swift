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
            UploadThrottle.setPlaying(isPlaying)
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
    /// Behind the picture (User Settings); the viewport applies it on change only.
    @Published var viewerBackground: ViewerBackground = .current {
        didSet { UserDefaults.standard.set(viewerBackground.rawValue, forKey: UserPreferences.viewerBackgroundKey) }
    }
    
    // Legal-range zebra on paused frames; the preset is shared with Frame Check.
    @Published public var showLegalZebra: Bool = false
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
            legalRangePreset: legalRangePreset,
            clipInfoOverlayMode: clipInfoOverlayMode,
            lastScreenshotPreset: lastScreenshotPreset,
            hasActiveURL: activeURL != nil,
            notesCount: activeNotes.count,
            hasSubtitles: !subtitleCues.isEmpty || (slotB.url != nil && !subtitleCuesB.isEmpty),
            showSubtitles: showSubtitles,
            hasTimeline: hasTimeline,
            hasVideo: slotA.mediaKind == .video
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
        let key = WaveformKey(url: url, modified: slotA.loadedModificationDate)
        if let cached = waveformCache[key] {
            waveformPeaks = cached
            return
        }
        if !waveformPeaks.isEmpty { waveformPeaks = [] }
        let work = Task.detached(priority: .utility) { await AudioWaveform.peaks(url: url) }
        waveformTask = Task { [weak self] in
            let peaks = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, let peaks, self.slotA.url == url else { return }
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
    
    public func clearSubtitles() {
        subtitleLoadGeneration &+= 1
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
        if let url = subtitleSourceURL {
            unsavedSubtitleEdits[url.standardizedFileURL.path] = cues
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
        if let old = subtitleSourceURL {
            unsavedSubtitleEdits.removeValue(forKey: old.standardizedFileURL.path)
        }
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
    func autoLoadSubtitles(for mediaURL: URL?) {
        clearSubtitles()
        guard let mediaURL = mediaURL else { return }
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
    private var exposureTeardownTask: Task<Void, Never>? = nil
    
    public func updateVideoCompositions() {
        exposureTeardownTask?.cancel()
        exposureTeardownTask = nil
        if abs(exposureEV) >= 0.001 {
            installExposureComposition(for: slotA)
            installExposureComposition(for: slotB)
            return
        }
        // A sequence's composition is its compositor (it applies EV itself): never remove it.
        // Nor a rotated clip's (it keeps the frames upright).
        let tearA = slotA.sequence == nil && !slotA.isRotated ? slotA.player.currentItem : nil
        let tearB = slotB.sequence == nil && !slotB.isRotated ? slotB.player.currentItem : nil
        guard tearA?.videoComposition != nil || tearB?.videoComposition != nil else { return }
        // Debounced so dragging EV through 0 doesn't rebuild the render pipeline twice.
        exposureTeardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, abs(self.exposureEV) < 0.001 else { return }
            if self.slotA.sequence == nil && !self.slotA.isRotated { self.slotA.player.currentItem?.videoComposition = nil }
            if self.slotB.sequence == nil && !self.slotB.isRotated { self.slotB.player.currentItem?.videoComposition = nil }
        }
    }
    
    func installExposureComposition(for slot: PlayerSlot) {
        guard abs(exposureEV) >= 0.001 || slot.isRotated, slot.mediaKind == .video, slot.sequence == nil,
              let item = slot.player.currentItem, item.videoComposition == nil else { return }
        let box = exposureBox
        item.videoComposition = AVVideoComposition(asset: item.asset, applyingCIFiltersWithHandler: { @Sendable request in
            let ev = box.value
            guard abs(ev) >= 0.001 else {
                request.finish(with: request.sourceImage, context: nil)
                return
            }
            request.finish(with: request.sourceImage.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev]), context: nil)
        })
    }
    
    /// A paused frame is only re-composited by a seek, and a seek to the exact current time is a no-op in
    /// AVFoundation, so nudge within the same frame to re-render it with the new exposure.
    func refreshPausedFramesForExposure() {
        guard !isPlaying, !isScrubbing, slotA.mediaKind == .video, slotA.player.currentItem != nil else { return }
        seek(toTime: nudgedFrameTime(frame: currentFrame, fps: activeFps, current: slotA.player.currentTime()))
        
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
    
    // Review Notes from Companion Sidecar (.qcnotes)
    @Published public var activeNotes: [QCFileNote] = []
    @Published public var activeNotesURL: URL? = nil
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
    @Published public var isScrubbing: Bool = false
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
