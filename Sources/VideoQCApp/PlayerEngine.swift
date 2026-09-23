import Foundation
import os
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
import UniformTypeIdentifiers
@preconcurrency import VideoToolbox
import VideoQCLib

// MARK: - Screenshot Export Presets

public enum ScreenshotPreset: String, CaseIterable, Identifiable, Sendable {
    case jpgMedium = "JPG Medium"
    case jpgHigh = "JPG High"
    case pngMedium = "PNG Medium"
    case pngHigh = "PNG High"
    
    public var id: String { rawValue }
    
    public var fileExtension: String {
        switch self {
        case .jpgMedium, .jpgHigh:
            return "jpg"
        case .pngMedium, .pngHigh:
            return "png"
        }
    }
    
    public var utType: UTType {
        switch self {
        case .jpgMedium, .jpgHigh:
            return .jpeg
        case .pngMedium, .pngHigh:
            return .png
        }
    }
    
    public var description: String {
        switch self {
        case .jpgMedium:
            return "JPEG (Medium quality ~70%, source resolution)"
        case .jpgHigh:
            return "JPEG (High quality ~95%, source resolution)"
        case .pngMedium:
            return "PNG (Optimized compression, source resolution)"
        case .pngHigh:
            return "PNG (Master uncompressed RGBA, source resolution)"
        }
    }
}

public struct PlayerTimelineMarker: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let frameIndex: Int
    public let timecode: String
    public let edge: EdgeLocation?
    public let colorHex: String?
    public let label: String
    
    public init(
        id: UUID = UUID(),
        frameIndex: Int,
        timecode: String,
        edge: EdgeLocation? = nil,
        colorHex: String? = nil,
        label: String
    ) {
        self.id = id
        self.frameIndex = frameIndex
        self.timecode = timecode
        self.edge = edge
        self.colorHex = colorHex
        self.label = label
    }
}

// MARK: - Dual Video A/B Comparison Types

public enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case single = "Single (A)"
    case splitVertical = "Split Wipe (V)"
    case splitHorizontal = "Split Wipe (H)"
    case sideBySide = "Side-by-Side (H)"
    case sideBySideVertical = "Side-by-Side (V)"
    case difference = "Difference Mode"
    case overlay = "50% Opacity Overlay"
    
    public var id: String { rawValue }
    
    public var requiresMatchingAspect: Bool {
        switch self {
        case .splitVertical, .splitHorizontal, .difference, .overlay:
            return true
        case .single, .sideBySide, .sideBySideVertical:
            return false
        }
    }
}

public enum SlotTarget: String, Sendable {
    case slotA
    case slotB
}

public enum SafeAreaMode: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case standard = "Title & Action Safe"
    case tikTok = "TikTok Safe Area"
    
    public var id: String { rawValue }
}

// ARCHITECTURAL MANDATE:
// FrameExtractor provides thread-safe, sub-10ms uncompressed still frame captures for
// VideoViewportView's stillFrameLayerA/B, eliminating CoreMedia motion-downsampling during panning.
// Must maintain actor isolation to satisfy Swift 6 strict concurrency without data races.
// See AGENTS.md for full specification.
public actor FrameExtractor {
    private var generator: AVAssetImageGenerator?
    private var currentURL: URL?
    
    public init() {}
    
    public func setURL(_ url: URL?) {
        self.currentURL = url
        guard let url = url else {
            self.generator = nil
            return
        }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        self.generator = gen
    }
    
    public func capture(at time: CMTime, fallbackURL: URL? = nil) -> CGImage? {
        if generator == nil, let url = fallbackURL ?? currentURL {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            self.generator = gen
            self.currentURL = url
        }
        guard let gen = generator else { return nil }
        
        // 1. Try exact frame capture with zero tolerance
        do {
            var actualTime = CMTime.zero
            let cgImage = try gen.copyCGImage(at: time, actualTime: &actualTime)
            return cgImage
        } catch {
            // 2. If exact frame PTS failed (e.g. boundary offset), fallback with 0.02s tolerance
            let fallbackTol = CMTime(seconds: 0.02, preferredTimescale: 60000)
            gen.requestedTimeToleranceBefore = fallbackTol
            gen.requestedTimeToleranceAfter = fallbackTol
            defer {
                gen.requestedTimeToleranceBefore = .zero
                gen.requestedTimeToleranceAfter = .zero
            }
            do {
                var actualTime = CMTime.zero
                return try gen.copyCGImage(at: time, actualTime: &actualTime)
            } catch {
                return nil
            }
        }
    }
}

@MainActor
public final class PlayerSlot: ObservableObject {
    public let id: SlotTarget
    @Published public var url: URL? = nil
    @Published public var fileName: String = ""
    @Published public var resolution: String = ""
    @Published public var fps: Double = 25.0
    @Published public var codec: String = ""
    @Published public var duration: CMTime = .zero
    public var currentTime: CMTime = .zero
    @Published public var videoSize: CGSize = CGSize(width: 1920, height: 1080)
    @Published public var totalFrames: Int = 0
    @Published public var slipOffsetFrames: Int = 0
    public var lastDecodedFrame: CGImage? = nil
    
    public let frameExtractor = FrameExtractor()
    public let player = AVPlayer()
    public var videoOutput: AVPlayerItemVideoOutput? = nil
    
    public func attachVideoOutput(to item: AVPlayerItem) {
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        item.add(output)
        self.videoOutput = output
    }
    
    public func detachVideoOutput() {
        self.videoOutput = nil
    }
    
    public var aspectRatio: CGFloat {
        if let item = player.currentItem, item.presentationSize.width > 0, item.presentationSize.height > 0 {
            return item.presentationSize.width / item.presentationSize.height
        }
        if videoSize.width > 0 && videoSize.height > 0 {
            return videoSize.width / videoSize.height
        }
        return 16.0 / 9.0
    }
    
    public var isNineBySixteen: Bool {
        return abs(aspectRatio - (9.0 / 16.0)) < 0.03
    }
    
    public var aspectRatioDescription: String {
        let w = Int(round(videoSize.width))
        let h = Int(round(videoSize.height))
        if w <= 0 || h <= 0 { return "--" }
        
        let aspect = Double(w) / Double(h)
        if abs(aspect - 16.0 / 9.0) < 0.02 { return "16:9 (\(w)x\(h))" }
        if abs(aspect - 9.0 / 16.0) < 0.02 { return "9:16 (\(w)x\(h))" }
        if abs(aspect - 4.0 / 3.0) < 0.02 { return "4:3 (\(w)x\(h))" }
        if abs(aspect - 1.0) < 0.02 { return "1:1 (\(w)x\(h))" }
        if abs(aspect - 2.39) < 0.03 { return "2.39:1 (\(w)x\(h))" }
        if abs(aspect - 2.35) < 0.03 { return "2.35:1 (\(w)x\(h))" }
        if abs(aspect - 1.85) < 0.03 { return "1.85:1 (\(w)x\(h))" }
        
        let g = QCUtilities.gcd(w, h)
        let simpW = w / g
        let simpH = h / g
        if simpW <= 20 && simpH <= 20 {
            return "\(simpW):\(simpH) (\(w)x\(h))"
        }
        return String(format: "%.2f:1 (%dx%d)", aspect, w, h)
    }
    
    /// Resolved once per load off the main thread (read per viewport update by the clip info overlay).
    public var formattedFileSize: String = "--"
    
    nonisolated static func fileSizeText(for url: URL) -> String {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    
    public var displayResolution: String {
        if !resolution.isEmpty && resolution != "--" {
            return resolution
        }
        let w = Int(round(videoSize.width))
        let h = Int(round(videoSize.height))
        if w > 0 && h > 0 {
            return "\(w)x\(h)"
        }
        return "--"
    }
    
    public var displayCodec: String {
        if !codec.isEmpty && codec != "--" {
            return codec
        }
        return "--"
    }
    
    public var formattedDuration: String {
        let seconds = CMTimeGetSeconds(duration)
        if seconds.isNaN || seconds < 0 { return "00:00:00:00" }
        return TimecodeFormatter.format(time: duration, fps: fps)
    }
    
    public init(id: SlotTarget) {
        self.id = id
        player.automaticallyWaitsToMinimizeStalling = false
    }
}

// MARK: - Clip Info Overlay Mode

public enum ClipInfoOverlayMode: String, CaseIterable, Codable, Sendable {
    case off = "Off"
    case abOnly = "A / B"
    case resolution = "Resolution"
    case fileName = "File Name"
    case fullDetails = "Full Info"
    
    public var next: ClipInfoOverlayMode {
        switch self {
        case .off: return .abOnly
        case .abOnly: return .resolution
        case .resolution: return .fileName
        case .fileName: return .fullDetails
        case .fullDetails: return .off
        }
    }
}

// MARK: - Transport State Snapshot

public struct TransportState: Equatable, Sendable {
    public let isPlaying: Bool
    public let rate: Float
    public let isLooping: Bool
    public let safeAreaMode: SafeAreaMode
    public let isNineBySixteen: Bool
    public let showCenterCrosshair: Bool
    public let clipInfoOverlayMode: ClipInfoOverlayMode
    public let lastScreenshotPreset: ScreenshotPreset
    public let hasActiveURL: Bool
    public let notesCount: Int
    
    public init(
        isPlaying: Bool,
        rate: Float,
        isLooping: Bool,
        safeAreaMode: SafeAreaMode,
        isNineBySixteen: Bool,
        showCenterCrosshair: Bool,
        clipInfoOverlayMode: ClipInfoOverlayMode,
        lastScreenshotPreset: ScreenshotPreset,
        hasActiveURL: Bool,
        notesCount: Int
    ) {
        self.isPlaying = isPlaying
        self.rate = rate
        self.isLooping = isLooping
        self.safeAreaMode = safeAreaMode
        self.isNineBySixteen = isNineBySixteen
        self.showCenterCrosshair = showCenterCrosshair
        self.clipInfoOverlayMode = clipInfoOverlayMode
        self.lastScreenshotPreset = lastScreenshotPreset
        self.hasActiveURL = hasActiveURL
        self.notesCount = notesCount
    }
}

// MARK: - Playback Clock

/// Per-frame playhead state, published separately from `PlayerEngine.objectWillChange` so that only the
/// timecode readouts and the timeline playhead re-render at frame / scrub rate (not the whole view tree).
@MainActor
public final class PlaybackClock: ObservableObject {
    @Published public fileprivate(set) var currentTimecode: String = "00:00:00:00"
    @Published public fileprivate(set) var currentFrame: Int = 0
    @Published public fileprivate(set) var currentProgress: Double = 0.0 // 0.0 ... 1.0
}

/// Exposure read by the video composition handler at render time, so EV changes never replace
/// `AVPlayerItem.videoComposition` (a replacement rebuilds the render pipeline and drops frames).
private final class ExposureValueBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0.0)
    var value: Double { state.withLock { $0 } }
    func set(_ newValue: Double) { state.withLock { $0 = newValue } }
}

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
    @Published public var splitPosition: CGFloat = 0.5
    @Published public var lastScreenshotPreset: ScreenshotPreset = .jpgMedium
    
    public var hasMatchingAspectRatios: Bool {
        guard slotB.url != nil else { return true }
        let aspectA = slotA.aspectRatio
        let aspectB = slotB.aspectRatio
        guard aspectA > 0, aspectB > 0 else { return true }
        return abs(aspectA - aspectB) / max(aspectA, aspectB) < 0.02
    }
    
    public var canUseSplitWipe: Bool {
        return hasMatchingAspectRatios
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
    @Published public var isLinked: Bool = true
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
        }
    }
    @Published public var clipInfoOverlayMode: ClipInfoOverlayMode = .resolution
    @Published public var showResolutionLabels: Bool = true
    
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
    public var activeCodec: String { slotA.codec }
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
    @Published public var isPlaying: Bool = false
    @Published public var isLooping: Bool = true
    
    // Zoom & Pan
    @Published public var zoomScale: CGFloat = 1.0
    @Published public var isFitZoom: Bool = true
    @Published public var panOffset: CGSize = .zero
    
    // Crosshair & Guides
    @Published public var showCenterCrosshair: Bool = false
    @Published public var safeAreaMode: SafeAreaMode = .off
    
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
            clipInfoOverlayMode: clipInfoOverlayMode,
            lastScreenshotPreset: lastScreenshotPreset,
            hasActiveURL: activeURL != nil,
            notesCount: activeNotes.count
        )
    }
    
    public func resetDroppedFrames() {}
    
    // MARK: - Exposure Video Composition (Single Exposure Pipeline)
    //
    // The composition is the only place exposure is applied to decoded video: AVPlayerLayer (scrub) and
    // AVPlayerItemVideoOutput (playback & paused stills) both receive composited frames, so the viewport must
    // never re-apply exposure to video output buffers. The handler reads `exposureBox` per frame, so EV changes
    // never replace the composition. Installed when EV leaves 0, removed once EV settles back at 0.
    
    private let exposureBox = ExposureValueBox()
    private var exposureTeardownTask: Task<Void, Never>? = nil
    
    public func updateVideoCompositions() {
        exposureTeardownTask?.cancel()
        exposureTeardownTask = nil
        if abs(exposureEV) >= 0.001 {
            installExposureComposition(for: slotA)
            installExposureComposition(for: slotB)
            return
        }
        guard slotA.player.currentItem?.videoComposition != nil || slotB.player.currentItem?.videoComposition != nil else { return }
        // Debounced so dragging EV through 0 doesn't rebuild the render pipeline twice.
        exposureTeardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, abs(self.exposureEV) < 0.001 else { return }
            self.slotA.player.currentItem?.videoComposition = nil
            self.slotB.player.currentItem?.videoComposition = nil
        }
    }
    
    private func installExposureComposition(for slot: PlayerSlot) {
        guard abs(exposureEV) >= 0.001, let item = slot.player.currentItem, item.videoComposition == nil else { return }
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
    private func refreshPausedFramesForExposure() {
        guard !isPlaying, !isScrubbing, slotA.player.currentItem != nil else { return }
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
    private var pendingInitialSeekFrame: Int? = nil
    private var pendingAutoplay: Bool = false
    private var pendingAutoplayB: Bool = false
    
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
    @Published public var isMuted: Bool = false {
        didSet {
            updateAudioVolumes()
        }
    }
    
    @Published public var shuttleStateText: String = "PAUSE"
    @Published public var isScrubbing: Bool = false
    public private(set) var wasPlayingBeforeScrub: Bool = false
    private var playbackRateBeforeScrub: Float = 1.0
    
    // Direct reference to Master player for backwards compatibility
    public var player: AVPlayer {
        return slotA.player
    }
    
    private final class TokenBox: @unchecked Sendable {
        var timeObserverToken: Any? = nil
        var player: AVPlayer? = nil
    }
    private let tokens = TokenBox()
    private var cancellables = Set<AnyCancellable>()
    private var itemStatusCancellable: AnyCancellable? = nil
    private var itemStatusCancellableB: AnyCancellable? = nil
    private var itemPresentationSizeCancellable: AnyCancellable? = nil
    private var itemPresentationSizeCancellableB: AnyCancellable? = nil
    
    public private(set) var isSeeking: Bool = false
    private var pendingSeekTime: CMTime? = nil
    private var pendingSeekTolerance: CMTime? = nil
    private var pendingSeekCompletion: (@MainActor @Sendable () -> Void)? = nil
    
    public private(set) var isSeekingB: Bool = false
    private var pendingSeekTimeB: CMTime? = nil
    private var pendingSeekCompletionB: (@MainActor @Sendable () -> Void)? = nil
    private var lastDriftCorrectionTime: Date = .distantPast

    // Hard re-sync of slot B during linked playback (see `relockSlotB`).
    private var isRelockingB: Bool = false
    private var relockGeneration: Int = 0
    private var relockHoldUntil: CFTimeInterval = 0
    private var lastRelockStart: CFTimeInterval = -.greatestFiniteMagnitude
    private var relockLead: Double = 0.25
    // pause() aligns slot B with an untracked seek; play must not start B while it is still in flight.
    private var isPauseAlignSeekPendingB: Bool = false
    
    // Dedicated interactive scrub seek state (independent hardware decoding pipelines)
    private var isScrubSeekingA: Bool = false
    private var pendingScrubTimeA: CMTime? = nil
    private var isScrubSeekingB: Bool = false
    private var pendingScrubTimeB: CMTime? = nil
    
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
    
    private func notifyFrameDecoded(_ slot: SlotTarget, at time: CMTime) {
        viewportObservers.removeAll { $0.owner == nil }
        for observer in viewportObservers {
            observer.frameDecoded(slot, time)
        }
    }
    
    private func notifySeekSettled() {
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
    
    // MARK: - Asset Loading
    
    public func loadVideo(url: URL, into target: SlotTarget = .slotA, initialSeekFrame: Int? = nil, autoplay: Bool = false, forceAutoplay: Bool = false) {
        let shouldAutoplay = forceAutoplay || (autoplay && isAutoplayEnabled)
        if target == .slotA || slotA.url == nil {
            loadVideoIntoSlotA(url: url, initialSeekFrame: initialSeekFrame, autoplay: shouldAutoplay)
        } else {
            loadVideoIntoSlotB(url: url, autoplay: shouldAutoplay)
        }
    }
    
    private func loadVideoIntoSlotA(url: URL, initialSeekFrame: Int? = nil, autoplay: Bool = false) {
        let stdURL = url.standardizedFileURL
        self.activeMarkers = markersMap[stdURL] ?? markersMap[url] ?? []
        
        if let currentA = slotA.url, currentA.standardizedFileURL.path == stdURL.path {
            if let frame = initialSeekFrame {
                seek(toFrame: frame)
            } else if autoplay {
                seek(toTime: .zero) { [weak self] in
                    self?.play()
                }
            }
            return
        }
        
        self.pendingInitialSeekFrame = initialSeekFrame
        self.pendingAutoplay = autoplay
        self.pendingAutoplayB = false
        pause()
        
        self.objectWillChange.send()
        slotA.url = stdURL
        slotA.fileName = stdURL.lastPathComponent
        slotA.formattedFileSize = "--"
        self.activeNotes = []
        self.activeNotesURL = nil
        self.currentTime = .zero
        self.currentProgress = 0.0
        self.currentTimecode = "00:00:00:00"
        self.panOffset = .zero
        self.resetDroppedFrames()
        self.isScrubbing = false
        self.wasPlayingBeforeScrub = false
        self.isSeeking = false
        self.pendingSeekTime = nil
        self.pendingSeekTolerance = nil
        self.pendingSeekCompletion = nil
        
        let asset = AVURLAsset(url: url)
        Task { [slotA] in
            await slotA.frameExtractor.setURL(url)
        }
        
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        slotA.attachVideoOutput(to: item)
        
        slotA.player.replaceCurrentItem(with: item)
        slotA.player.automaticallyWaitsToMinimizeStalling = false
        installExposureComposition(for: slotA)
        
        itemPresentationSizeCancellable = item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .filter { $0.width > 0 && $0.height > 0 }
            .first()
            .sink { [weak self] size in
                guard let self = self, self.slotA.url == url else { return }
                self.slotA.videoSize = size
            }
        
        itemStatusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .filter { $0 == .readyToPlay }
            .first()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.slotA.player.automaticallyWaitsToMinimizeStalling = false
                self.slotA.player.preroll(atRate: 1.0) { _ in }
                if self.pendingAutoplay {
                    self.pendingAutoplay = false
                    self.seek(toTime: .zero) { [weak self] in
                        self?.play()
                    }
                }
            }
        
        Task {
            await extractMetadata(asset: asset, for: .slotA)
        }
        
        updateAudioVolumes()
    }
    
    private func loadVideoIntoSlotB(url: URL, autoplay: Bool = false) {
        let stdURL = url.standardizedFileURL
        let wasInABMode = (slotB.url != nil)
        if let currentB = slotB.url, currentB.standardizedFileURL.path == stdURL.path {
            if autoplay {
                seek(toTime: .zero) { [weak self] in
                    self?.play()
                }
            }
            return
        }
        
        self.pendingAutoplayB = autoplay
        self.pendingAutoplay = false
        pause()
        
        isSeekingB = false
        pendingSeekTimeB = nil
        
        if !wasInABMode {
            self.compareMode = .single
            self.isBlinkCompareB = false
        }
        
        self.objectWillChange.send()
        slotB.url = stdURL
        slotB.fileName = stdURL.lastPathComponent
        slotB.formattedFileSize = "--"
        slotB.slipOffsetFrames = 0
        if activeTarget == .slotB {
            self.activeNotes = []
            self.activeNotesURL = nil
        }
        
        let asset = AVURLAsset(url: stdURL)
        Task { [slotB] in
            await slotB.frameExtractor.setURL(stdURL)
        }
        
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        slotB.attachVideoOutput(to: item)
        
        slotB.player.replaceCurrentItem(with: item)
        slotB.player.automaticallyWaitsToMinimizeStalling = false
        installExposureComposition(for: slotB)
        
        itemPresentationSizeCancellableB = item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .filter { $0.width > 0 && $0.height > 0 }
            .first()
            .sink { [weak self] size in
                guard let self = self, self.slotB.url == url else { return }
                self.slotB.videoSize = size
                self.enforceCompatibleCompareMode()
            }
        
        itemStatusCancellableB = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .filter { $0 == .readyToPlay }
            .first()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.slotB.player.automaticallyWaitsToMinimizeStalling = false
                self.slotB.player.preroll(atRate: 1.0) { _ in }
                self.syncSlotBToMaster()
                if self.pendingAutoplayB {
                    self.pendingAutoplayB = false
                    self.seek(toTime: .zero) { [weak self] in
                        self?.play()
                    }
                }
            }
        
        Task {
            await extractMetadata(asset: asset, for: .slotB)
        }
        
        enforceCompatibleCompareMode()
        
        updateAudioVolumes()
    }
    
    private func extractMetadata(asset: AVURLAsset, for target: SlotTarget) async {
        let fileURL = asset.url
        let fileSizeText = await Task.detached(priority: .utility) { PlayerSlot.fileSizeText(for: fileURL) }.value
        do {
            let dur = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            
            var detectedFps: Double = 25.0
            var resStr = "--"
            var codecStr = "--"
            var detectedSize = CGSize(width: 1920, height: 1080)
            
            if let vTrack = tracks.first {
                let naturalSize = try await vTrack.load(.naturalSize)
                let transform = try await vTrack.load(.preferredTransform)
                let transformedSize = naturalSize.applying(transform)
                let w = Int(abs(transformedSize.width))
                let h = Int(abs(transformedSize.height))
                resStr = "\(w)x\(h)"
                detectedSize = CGSize(width: max(1, w), height: max(1, h))
                
                let nominalRate = try await vTrack.load(.nominalFrameRate)
                let minFrameDur = try? await vTrack.load(.minFrameDuration)
                detectedFps = resolveAccurateFramerate(nominal: nominalRate, minFrameDuration: minFrameDur)
                
                let descriptions = try await vTrack.load(.formatDescriptions)
                if let firstDesc = descriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    codecStr = fourCCToString(subType)
                }
            }
            
            let durSecs = CMTimeGetSeconds(dur)
            let roundedFps = max(1.0, detectedFps)
            let totFrames: Int
            if durSecs.isFinite && !durSecs.isNaN && roundedFps.isFinite && !roundedFps.isNaN {
                totFrames = max(0, Int(round(durSecs * roundedFps)))
            } else {
                totFrames = 0
            }
            
            if target == .slotA {
                self.slotA.duration = dur
                self.slotA.fps = detectedFps
                self.slotA.resolution = resStr
                self.slotA.codec = codecStr
                self.slotA.videoSize = detectedSize
                self.slotA.totalFrames = totFrames
                self.slotA.formattedFileSize = fileSizeText
                
                self.duration = dur
                self.totalFrames = totFrames
                self.durationTimecode = TimecodeFormatter.format(time: dur, fps: detectedFps)
                self.setupTimeObserver()
                
                if let frame = self.pendingInitialSeekFrame {
                    self.pendingInitialSeekFrame = nil
                    self.seek(toFrame: frame)
                }
                if !self.isPlaying {
                    self.currentTimecode = TimecodeFormatter.format(time: self.currentTime, fps: detectedFps)
                }
                self.enforceCompatibleCompareMode()
            } else {
                self.objectWillChange.send()
                self.slotB.duration = dur
                self.slotB.fps = detectedFps
                self.slotB.resolution = resStr
                self.slotB.codec = codecStr
                self.slotB.videoSize = detectedSize
                self.slotB.totalFrames = totFrames
                self.slotB.formattedFileSize = fileSizeText
                self.syncSlotBToMaster()
                self.enforceCompatibleCompareMode()
            }
        } catch {
            print("[PlayerEngine] Error loading metadata: \(error)")
        }
    }
    
    private func fourCCToString(_ fourCC: FourCharCode) -> String {
        let raw = QCUtilities.fourCCToString(fourCC)
        switch raw.lowercased() {
        case "ap4h": return "ProRes 4444"
        case "apch": return "ProRes 422HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422LT"
        case "apco": return "ProRes 422Proxy"
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        default: return raw.uppercased()
        }
    }
    
    private func resolveAccurateFramerate(nominal: Float, minFrameDuration: CMTime?) -> Double {
        var rawFps = Double(nominal)
        if let minDur = minFrameDuration, minDur.isValid && minDur.seconds > 0 {
            rawFps = 1.0 / minDur.seconds
        }
        guard rawFps > 1.0 else { return 25.0 }
        
        // Snap to standard broadcast framerates with high precision to eliminate fractional drift
        if abs(rawFps - (24000.0 / 1001.0)) < 0.005 || abs(Double(nominal) - 23.976) < 0.005 { return 24000.0 / 1001.0 }
        if abs(rawFps - 24.0) < 0.005 || abs(Double(nominal) - 24.0) < 0.005 { return 24.0 }
        if abs(rawFps - 25.0) < 0.005 || abs(Double(nominal) - 25.0) < 0.005 { return 25.0 }
        if abs(rawFps - (30000.0 / 1001.0)) < 0.005 || abs(Double(nominal) - 29.97) < 0.005 { return 30000.0 / 1001.0 }
        if abs(rawFps - 30.0) < 0.005 || abs(Double(nominal) - 30.0) < 0.005 { return 30.0 }
        if abs(rawFps - (48000.0 / 1001.0)) < 0.005 { return 48000.0 / 1001.0 }
        if abs(rawFps - 48.0) < 0.005 { return 48.0 }
        if abs(rawFps - 50.0) < 0.005 { return 50.0 }
        if abs(rawFps - (60000.0 / 1001.0)) < 0.005 || abs(Double(nominal) - 59.94) < 0.005 { return 60000.0 / 1001.0 }
        if abs(rawFps - 60.0) < 0.005 || abs(Double(nominal) - 60.0) < 0.005 { return 60.0 }
        
        return rawFps
    }
    
    // MARK: - Dual Slot Operations
    
    @MainActor
    private struct SlotSnapshot {
        let url: URL?
        let fileName: String
        let resolution: String
        let fps: Double
        let codec: String
        let duration: CMTime
        let videoSize: CGSize
        let totalFrames: Int
        let formattedFileSize: String
        let currentTime: CMTime
        let lastDecodedFrame: CGImage?
        
        init(from slot: PlayerSlot) {
            self.url = slot.url
            self.fileName = slot.fileName
            self.resolution = slot.resolution
            self.fps = slot.fps
            self.codec = slot.codec
            self.duration = slot.duration
            self.videoSize = slot.videoSize
            self.totalFrames = slot.totalFrames
            self.formattedFileSize = slot.formattedFileSize
            self.currentTime = slot.player.currentTime()
            self.lastDecodedFrame = slot.lastDecodedFrame
        }
        
        func apply(to slot: PlayerSlot) {
            slot.url = url
            slot.fileName = fileName
            slot.resolution = resolution
            slot.fps = fps
            slot.codec = codec
            slot.duration = duration
            slot.videoSize = videoSize
            slot.totalFrames = totalFrames
            slot.formattedFileSize = formattedFileSize
            slot.lastDecodedFrame = lastDecodedFrame
        }
    }
    
    public func swapSlots() {
        guard slotA.url != nil || slotB.url != nil else { return }
        if isBlinkCompareB {
            isBlinkCompareB = false
        }
        let wasPlaying = self.isPlaying
        pause()
        
        let snapA = SlotSnapshot(from: slotA)
        let snapB = SlotSnapshot(from: slotB)
        let tempSlip = slotB.slipOffsetFrames
        
        // Detach both current items first to prevent NSInvalidArgumentException
        itemStatusCancellable?.cancel()
        itemStatusCancellable = nil
        itemPresentationSizeCancellable?.cancel()
        itemPresentationSizeCancellable = nil
        itemStatusCancellableB?.cancel()
        itemStatusCancellableB = nil
        itemPresentationSizeCancellableB?.cancel()
        itemPresentationSizeCancellableB = nil
        
        slotA.detachVideoOutput()
        slotB.detachVideoOutput()
        slotA.player.replaceCurrentItem(with: nil)
        slotB.player.replaceCurrentItem(with: nil)
        
        self.isSeeking = false
        self.pendingSeekTime = nil
        self.pendingSeekCompletion = nil
        self.isSeekingB = false
        self.pendingSeekTimeB = nil
        
        snapB.apply(to: slotA)
        if let urlA = snapB.url {
            let itemA = AVPlayerItem(asset: AVURLAsset(url: urlA))
            itemA.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            slotA.attachVideoOutput(to: itemA)
            slotA.player.replaceCurrentItem(with: itemA)
            slotA.player.seek(to: snapB.currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
            installExposureComposition(for: slotA)
            
            itemPresentationSizeCancellable = itemA.publisher(for: \.presentationSize)
                .receive(on: DispatchQueue.main)
                .filter { $0.width > 0 && $0.height > 0 }
                .first()
                .sink { [weak self] size in
                    guard let self = self, self.slotA.url == urlA else { return }
                    self.slotA.videoSize = size
                }
            
            itemStatusCancellable = itemA.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .filter { $0 == .readyToPlay }
                .first()
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    self.slotA.player.automaticallyWaitsToMinimizeStalling = false
                    self.slotA.player.preroll(atRate: 1.0) { _ in }
                }
        }
        
        self.objectWillChange.send()
        snapA.apply(to: slotB)
        slotB.slipOffsetFrames = -tempSlip
        if let urlB = snapA.url {
            let itemB = AVPlayerItem(asset: AVURLAsset(url: urlB))
            itemB.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            slotB.attachVideoOutput(to: itemB)
            slotB.player.replaceCurrentItem(with: itemB)
            slotB.player.seek(to: snapA.currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
            installExposureComposition(for: slotB)
            
            itemPresentationSizeCancellableB = itemB.publisher(for: \.presentationSize)
                .receive(on: DispatchQueue.main)
                .filter { $0.width > 0 && $0.height > 0 }
                .first()
                .sink { [weak self] size in
                    guard let self = self, self.slotB.url == urlB else { return }
                    self.slotB.videoSize = size
                    self.enforceCompatibleCompareMode()
                }
            
            itemStatusCancellableB = itemB.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .filter { $0 == .readyToPlay }
                .first()
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    self.slotB.player.automaticallyWaitsToMinimizeStalling = false
                    self.slotB.player.preroll(atRate: 1.0) { _ in }
                }
        }
        
        Task { [slotA, slotB] in
            await slotA.frameExtractor.setURL(snapB.url)
            await slotB.frameExtractor.setURL(snapA.url)
        }
        
        self.duration = slotA.duration
        self.totalFrames = slotA.totalFrames
        if let url = slotA.url {
            self.activeMarkers = markersMap[url] ?? []
            self.durationTimecode = TimecodeFormatter.format(time: slotA.duration, fps: slotA.fps)
        } else {
            self.activeMarkers = []
            self.durationTimecode = "00:00:00:00"
        }
        
        if slotB.url == nil {
            compareMode = .single
        } else {
            enforceCompatibleCompareMode()
        }
        
        updateCurrentTime(time: slotA.player.currentTime())
        updateAudioVolumes()
        
        if wasPlaying {
            self.play()
        }
    }
    
    public func clearSlotB() {
        self.objectWillChange.send()
        slotB.player.pause()
        slotB.detachVideoOutput()
        slotB.player.replaceCurrentItem(with: nil)
        itemStatusCancellableB?.cancel()
        itemStatusCancellableB = nil
        itemPresentationSizeCancellableB?.cancel()
        itemPresentationSizeCancellableB = nil
        slotB.url = nil
        slotB.fileName = ""
        slotB.resolution = ""
        slotB.codec = ""
        slotB.duration = .zero
        slotB.totalFrames = 0
        slotB.formattedFileSize = "--"
        slotB.slipOffsetFrames = 0
        slotB.lastDecodedFrame = nil
        Task { [slotB] in
            await slotB.frameExtractor.setURL(nil)
        }
        isSeekingB = false
        pendingSeekTimeB = nil
        compareMode = .single
        audioSlot = .slotA
        isBlinkCompareB = false
        pendingAutoplayB = false
        updateAudioVolumes()
    }
    
    public func clearSlotA() {
        self.objectWillChange.send()
        slotA.player.pause()
        slotA.detachVideoOutput()
        slotA.player.replaceCurrentItem(with: nil)
        itemStatusCancellable?.cancel()
        itemStatusCancellable = nil
        itemPresentationSizeCancellable?.cancel()
        itemPresentationSizeCancellable = nil
        pendingAutoplay = false
        slotA.url = nil
        slotA.fileName = ""
        slotA.resolution = ""
        slotA.codec = ""
        slotA.duration = .zero
        slotA.totalFrames = 0
        slotA.formattedFileSize = "--"
        slotA.lastDecodedFrame = nil
        Task { [slotA] in
            await slotA.frameExtractor.setURL(nil)
        }
        activeMarkers = []
        durationTimecode = "00:00:00:00"
        currentTimecode = "00:00:00:00"
        isPlaying = false
        rate = 0.0
        resetDroppedFrames()
        updateAudioVolumes()
    }
    
    public func unload() {
        clearSlotA()
        clearSlotB()
    }
    
    public func nudgeSlip(frames: Int) {
        slotB.slipOffsetFrames += frames
        syncSlotBToMaster()
    }
    
    public func resetSlip() {
        slotB.slipOffsetFrames = 0
        syncSlotBToMaster()
    }
    
    public func cycleCompareMode() {
        guard slotB.url != nil else { return }
        if isBlinkCompareB {
            isBlinkCompareB = false
        }
        let validModes: [CompareMode] = hasMatchingAspectRatios
            ? CompareMode.allCases
            : CompareMode.allCases.filter { !$0.requiresMatchingAspect }
        if let idx = validModes.firstIndex(of: compareMode) {
            let nextIdx = (idx + 1) % validModes.count
            compareMode = validModes[nextIdx]
        } else {
            compareMode = validModes.first ?? .sideBySide
        }
    }
    
    public func syncSlotBToMaster() {
        guard slotB.url != nil, slotB.player.currentItem != nil else { return }
        let masterSecs = CMTimeGetSeconds(slotA.player.currentTime())
        let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
        let targetSecs = max(0.0, masterSecs + offsetSecs)
        if isLinkedPlaybackRunning {
            // B is kept in phase by the PLL while playing; a plain seek would leave it behind by the seek latency.
            let driftSecs = CMTimeGetSeconds(slotB.player.currentTime()) - targetSecs
            if !driftSecs.isFinite || abs(driftSecs) > 0.5 / max(1.0, slotB.fps) || slotB.player.rate == 0 {
                relockSlotB()
            }
            return
        }
        let targetTimeB = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        seekSlotB(to: targetTimeB)
    }

    /// Linked playback with the master actually running (the only state in which slot B is phase-locked).
    private var isLinkedPlaybackRunning: Bool {
        isLinked && isPlaying && !isScrubbing && rate != 0 && slotA.player.rate != 0 && slotB.url != nil
    }

    /// Hard re-sync of slot B during linked playback. An exact seek into long-GOP media takes ~100–200 ms, so
    /// seeking B to A's *current* time and restarting it left B several frames behind every time and the stall
    /// recovery re-seeked it several times a second (B stuttered at ~6 fps after TAB, fast-forward or pause/play).
    /// B instead seeks ahead of A and is started with `setRate(_:time:atHostTime:)` at the host time A reaches
    /// that position: one seek, landing in phase. The lead adapts to the measured seek latency.
    private func relockSlotB() {
        guard !isRelockingB, !isSeekingB, isLinkedPlaybackRunning,
              let itemB = slotB.player.currentItem, itemB.status == .readyToPlay else { return }
        let secsA = CMTimeGetSeconds(slotA.player.currentTime())
        guard secsA.isFinite else { return }
        let playRate = rate
        let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
        let targetA = CMTime(seconds: secsA + relockLead * Double(playRate), preferredTimescale: 60000)
        let targetB = CMTime(seconds: max(0.0, CMTimeGetSeconds(targetA) + offsetSecs), preferredTimescale: 60000)
        let itemID = ObjectIdentifier(itemB)
        let generation = relockGeneration
        let seekStart = CACurrentMediaTime()

        isRelockingB = true
        relockHoldUntil = .greatestFiniteMagnitude
        lastRelockStart = seekStart
        slotB.player.pause()
        slotB.player.seek(to: targetB, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            let complete = { @MainActor in
                guard let self = self else { return }
                self.isRelockingB = false
                self.relockHoldUntil = 0
                guard finished, generation == self.relockGeneration, self.isLinkedPlaybackRunning, self.rate == playRate,
                      let currentB = self.slotB.player.currentItem, ObjectIdentifier(currentB) == itemID else { return }
                self.relockLead = min(1.0, max(0.15, (CACurrentMediaTime() - seekStart) * 1.5 + 0.05))
                self.slotB.player.automaticallyWaitsToMinimizeStalling = false
                let hostClock = CMClockGetHostTimeClock()
                // Host time at which A reaches targetA. If the seek overran the lead it is in the past and B starts
                // interpolated to A's current position, still in phase.
                guard let timebaseA = self.slotA.player.currentItem?.timebase else {
                    self.slotB.player.playImmediately(atRate: playRate)
                    return
                }
                let startHost = CMSyncConvertTime(targetA, from: timebaseA, to: hostClock)
                guard startHost.isValid else {
                    self.slotB.player.playImmediately(atRate: playRate)
                    return
                }
                self.slotB.player.setRate(playRate, time: targetB, atHostTime: startHost)
                let startsIn = max(0.0, CMTimeGetSeconds(CMTimeSubtract(startHost, CMClockGetTime(hostClock))))
                self.relockHoldUntil = CACurrentMediaTime() + startsIn + 0.15
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { complete() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { complete() } }
            }
        }
    }

    /// Explicit transport actions supersede an in-flight re-lock.
    private func cancelSlotBRelock() {
        relockGeneration &+= 1
        relockHoldUntil = 0
    }
    
    private func seekSlotB(to time: CMTime, tolerance: CMTime = .zero, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard slotB.url != nil, slotB.player.currentItem != nil else {
            completion?()
            return
        }
        if isSeekingB {
            pendingSeekTimeB = time
            pendingSeekCompletionB = completion
            return
        }
        isSeekingB = true
        slotB.player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            let runCompletion = { @MainActor in
                guard let self = self else { return }
                self.isSeekingB = false
                self.notifyFrameDecoded(.slotB, at: time)
                completion?()
                if !self.isPlaying && !self.isScrubbing {
                    self.notifySeekSettled()
                }
                if let nextB = self.pendingSeekTimeB {
                    let nextComp = self.pendingSeekCompletionB
                    self.pendingSeekTimeB = nil
                    self.pendingSeekCompletionB = nil
                    self.seekSlotB(to: nextB, tolerance: tolerance, completion: nextComp)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    runCompletion()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        runCompletion()
                    }
                }
            }
        }
    }
    
    // MARK: - Time Observers
    
    private func setupTimeObserver() {
        if let token = tokens.timeObserverToken, let player = tokens.player {
            player.removeTimeObserver(token)
            tokens.timeObserverToken = nil
            tokens.player = nil
        }
        let fps = max(1.0, activeFps)
        let interval = CMTime(seconds: 1.0 / fps, preferredTimescale: 60000)
        let token = slotA.player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self, !self.isScrubbing else { return }
                self.updateCurrentTime(time: time)
            }
        }
        tokens.timeObserverToken = token
        tokens.player = slotA.player
    }
    
    private func updateCurrentTime(time: CMTime) {
        guard time.isValid && time.isNumeric else { return }
        let currSecs = CMTimeGetSeconds(time)
        guard currSecs.isFinite && !currSecs.isNaN else { return }
        
        self.currentTime = time
        self.slotA.currentTime = time
        let durSecs = CMTimeGetSeconds(duration)
        
        let newProgress: Double
        if durSecs > 0 && durSecs.isFinite && !durSecs.isNaN {
            newProgress = min(1.0, max(0.0, currSecs / durSecs))
        } else {
            newProgress = 0.0
        }
        if abs(newProgress - self.currentProgress) >= 0.0005 || !self.isPlaying {
            self.currentProgress = newProgress
        }
        
        let fps = max(1.0, activeFps)
        let calcVal = currSecs * fps + 1e-4
        let frameIdx: Int
        if calcVal.isFinite && !calcVal.isNaN {
            frameIdx = max(0, min(max(0, totalFrames - 1), Int(floor(calcVal))))
        } else {
            frameIdx = 0
        }
        if self.currentFrame != frameIdx {
            self.currentFrame = frameIdx
            self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
        }
        
        if slotB.url != nil && slotB.player.currentItem != nil {
            let timeB = slotB.player.currentTime()
            if self.isLinked {
                let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                let targetSecsB = max(0.0, currSecs + offsetSecs)
                self.slotB.currentTime = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
            } else if timeB.isValid && timeB.isNumeric {
                self.slotB.currentTime = timeB
            }
            
            // Continuous drift correction during linked playback:
            // High-precision Phase-Locked Loop (PLL) micro-rate adjustment with stall recovery.
            // Samples both players synchronously on the main thread to eliminate observer dispatch skew.
            // Suspended while B is being re-locked and until it has started in phase (see relockSlotB).
            if isLinkedPlaybackRunning && !self.isSeekingB && !self.isRelockingB && CACurrentMediaTime() >= self.relockHoldUntil {
                let liveA = slotA.player.currentTime()
                let liveB = slotB.player.currentTime()
                if liveA.isValid && liveA.isNumeric && liveB.isValid && liveB.isNumeric {
                    let liveSecsA = CMTimeGetSeconds(liveA)
                    let liveSecsB = CMTimeGetSeconds(liveB)
                    if liveSecsA.isFinite && !liveSecsA.isNaN && liveSecsB.isFinite && !liveSecsB.isNaN {
                        let fpsB = max(1.0, slotB.fps)
                        let frameDurB = 1.0 / fpsB
                        let offsetSecs = Double(slotB.slipOffsetFrames) / fpsB
                        let expectedSecsB = max(0.0, liveSecsA + offsetSecs)
                        let drift = liveSecsB - expectedSecsB
                        let baseRate = self.rate
                        
                        let durSecsB = CMTimeGetSeconds(slotB.duration)
                        let isAtEndB = (durSecsB > 0 && durSecsB.isFinite && liveSecsB >= durSecsB - 0.05)
                        
                        if !isAtEndB {
                            // Stall Recovery: slotB stopped moving or fell drastically behind (>3.5 frames of wall-clock
                            // lag). Re-locked in phase with a single seek, at most once per second so a decoder that
                            // can't keep up (fast-forward) never loops on seeks.
                            let isStalledB = slotB.player.rate == 0.0 || abs(drift) > frameDurB * 3.5 * max(1.0, Double(abs(baseRate)))
                            if isStalledB && CACurrentMediaTime() - self.lastRelockStart >= 1.0 {
                                self.relockSlotB()
                            } else if abs(drift) > frameDurB * 0.75 {
                                // Gentle micro-rate adjustment (±1.5%) with 0.25s rate-settle debounce
                                let now = Date()
                                if now.timeIntervalSince(self.lastDriftCorrectionTime) >= 0.25 {
                                    self.lastDriftCorrectionTime = now
                                    let correctionFactor: Float = (drift < 0) ? 1.015 : 0.985
                                    let adjustedRate = baseRate * correctionFactor
                                    if abs(slotB.player.rate - adjustedRate) > 0.003 {
                                        slotB.player.rate = adjustedRate
                                    }
                                }
                            } else {
                                // In frame-accurate lockstep (within 3/4 frame): maintain exact base rate
                                if abs(slotB.player.rate - baseRate) > 0.001 {
                                    slotB.player.rate = baseRate
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Reverse playback loop handling
        if self.rate < 0 && currSecs <= 0.05 && self.isLooping && durSecs > 0.5 {
            self.seek(toProgress: 0.999) { [weak self] in
                guard let self = self else { return }
                self.setPlaybackRate(self.rate)
            }
        }
    }
    
    private func setupEndObserver() {
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let item = notification.object as? AVPlayerItem, item == self.slotA.player.currentItem {
                    self.handlePlaybackEnded()
                }
            }
            .store(in: &cancellables)
    }
    
    private func handlePlaybackEnded() {
        if isLooping {
            let savedRate = self.rate
            seek(toTime: .zero) { [weak self] in
                guard let self = self else { return }
                let resumeRate = savedRate > 0 ? savedRate : 1.0
                self.setPlaybackRate(resumeRate)
            }
        } else {
            pause()
        }
    }
    
    // MARK: - J-K-L Shuttle Engine
    
    public func pressL() {
        guard slotA.player.currentItem != nil else { return }
        
        if CMTimeGetSeconds(currentTime) >= CMTimeGetSeconds(duration) - 0.05 {
            seek(toTime: .zero) { [weak self] in
                self?.pressL()
            }
            return
        }
        
        let nextRate: Float
        if rate < 1.0 {
            nextRate = 1.0
        } else if rate == 1.0 {
            nextRate = 2.0
        } else if rate == 2.0 {
            nextRate = 4.0
        } else if rate == 4.0 {
            nextRate = 8.0
        } else if rate == 8.0 {
            nextRate = 16.0
        } else {
            nextRate = 1.0
        }
        setPlaybackRate(nextRate)
    }
    
    public func pressK() {
        pause()
    }
    
    public func pressJ() {
        guard slotA.player.currentItem != nil else { return }
        
        if CMTimeGetSeconds(currentTime) <= 0.05 && isLooping && CMTimeGetSeconds(duration) > 0.5 {
            seek(toProgress: 0.999) { [weak self] in
                self?.pressJ()
            }
            return
        }
        
        let nextRate: Float
        if rate > -1.0 {
            nextRate = -1.0
        } else if rate == -1.0 {
            nextRate = -2.0
        } else if rate == -2.0 {
            nextRate = -4.0
        } else if rate == -4.0 {
            nextRate = -8.0
        } else if rate == -8.0 {
            nextRate = -16.0
        } else {
            nextRate = -1.0
        }
        setPlaybackRate(nextRate)
    }
    
    // MARK: - Slow-Motion Frame-by-Frame Shuttle (Shift + L / Shift + J)
    
    public enum SlowDirection {
        case forward
        case reverse
    }
    
    private let slowSpeeds: [Double] = [2.0, 4.0, 8.0, 15.0, 24.0, 30.0]
    private var slowStepTimer: Timer? = nil
    private var slowDirection: SlowDirection = .forward
    private var slowSpeedIndex: Int = 0
    
    public var isSlowStepping: Bool {
        return slowStepTimer != nil
    }
    
    public func pressSlowL() {
        guard slotA.player.currentItem != nil else { return }
        
        // Stop normal playback if active
        if self.rate != 0.0 || slotA.player.rate != 0.0 {
            slotA.player.pause()
            slotB.player.pause()
            self.rate = 0.0
        }
        
        if slowStepTimer == nil {
            slowDirection = .forward
            slowSpeedIndex = 0
        } else if slowDirection == .forward {
            slowSpeedIndex = min(slowSpeeds.count - 1, slowSpeedIndex + 1)
        } else {
            if slowSpeedIndex > 0 {
                slowSpeedIndex -= 1
            } else {
                slowDirection = .forward
                slowSpeedIndex = 0
            }
        }
        
        startSlowStepTimer()
    }
    
    public func pressSlowJ() {
        guard slotA.player.currentItem != nil else { return }
        
        // Stop normal playback if active
        if self.rate != 0.0 || slotA.player.rate != 0.0 {
            slotA.player.pause()
            slotB.player.pause()
            self.rate = 0.0
        }
        
        if slowStepTimer == nil {
            slowDirection = .reverse
            slowSpeedIndex = 0
        } else if slowDirection == .reverse {
            slowSpeedIndex = min(slowSpeeds.count - 1, slowSpeedIndex + 1)
        } else {
            if slowSpeedIndex > 0 {
                slowSpeedIndex -= 1
            } else {
                slowDirection = .reverse
                slowSpeedIndex = 0
            }
        }
        
        startSlowStepTimer()
    }
    
    public func stopSlowStep() {
        slowStepTimer?.invalidate()
        slowStepTimer = nil
    }
    
    private func startSlowStepTimer() {
        stopSlowStep()
        
        let targetFps = slowSpeeds[slowSpeedIndex]
        let interval = 1.0 / targetFps
        let isFwd = (slowDirection == .forward)
        
        self.isPlaying = true
        let fpsText = String(format: "%.0f", targetFps)
        self.shuttleStateText = isFwd ? "SLOW FWD \(fpsText) FPS" : "SLOW REV -\(fpsText) FPS"
        
        executeSingleFrameStep(forward: isFwd)
        
        slowStepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.executeSingleFrameStep(forward: isFwd)
            }
        }
    }
    
    private func executeSingleFrameStep(forward: Bool) {
        guard slotA.player.currentItem != nil else { return }
        let durSecs = CMTimeGetSeconds(duration)
        let currSecs = CMTimeGetSeconds(currentTime)
        
        if forward && currSecs >= durSecs - 0.05 {
            if isLooping {
                seek(toTime: .zero)
            } else {
                stopSlowStep()
                pause()
            }
            return
        } else if !forward && currSecs <= 0.05 {
            if isLooping && durSecs > 0.5 {
                seek(toProgress: 0.999)
            } else {
                stopSlowStep()
                pause()
            }
            return
        }
        
        let currFrame = self.currentFrame
        let targetFrame = max(0, min(max(0, self.totalFrames - 1), currFrame + (forward ? 1 : -1)))
        guard targetFrame != currFrame else { return }
        
        self.currentFrame = targetFrame
        self.currentTimecode = TimecodeFormatter.format(frameIndex: targetFrame, fps: activeFps)
        let fps = max(1.0, activeFps)
        let targetSecs = (Double(targetFrame) + 0.5) / fps
        if durSecs > 0 {
            self.currentProgress = min(1.0, max(0.0, targetSecs / durSecs))
        }
        seek(toFrame: targetFrame)
    }
    
    public func togglePlayPause() {
        if isSlowStepping || rate != 0.0 {
            pause()
        } else {
            pressL()
        }
    }
    
    public func play() {
        setPlaybackRate(1.0)
    }
    
    public func pause() {
        stopSlowStep()
        cancelSlotBRelock()
        slotA.player.pause()
        slotB.player.pause()
        // Only assign changed values: every @Published write broadcasts objectWillChange to all observers.
        if rate != 0.0 { rate = 0.0 }
        if isPlaying { isPlaying = false }
        if isScrubbing { isScrubbing = false }
        self.isSeeking = false
        self.isScrubSeekingA = false
        self.pendingScrubTimeA = nil
        self.isScrubSeekingB = false
        self.pendingScrubTimeB = nil
        self.wasPlayingBeforeScrub = false
        if shuttleStateText != "PAUSE" { shuttleStateText = "PAUSE" }
        if let currentItem = slotA.player.currentItem, currentItem.status == .readyToPlay {
            let pausedTime = slotA.player.currentTime()
            if pausedTime.isValid && pausedTime.isNumeric {
                updateCurrentTime(time: pausedTime)
                
                // Align Slot B player accurately to the master paused frame
                if isLinked && slotB.url != nil && slotB.player.currentItem != nil {
                    let masterSecs = CMTimeGetSeconds(pausedTime)
                    let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                    let targetSecsB = max(0.0, masterSecs + offsetSecs)
                    let targetTimeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
                    self.slotB.currentTime = targetTimeB
                    self.isPauseAlignSeekPendingB = true
                    self.slotB.player.seek(to: targetTimeB, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.isPauseAlignSeekPendingB = false }
                        }
                    }
                }
            }
        }
    }
    
    public func setPlaybackRate(_ newRate: Float) {
        stopSlowStep()
        cancelSlotBRelock()
        if rate != newRate { rate = newRate }
        if isPlaying != (newRate != 0.0) { isPlaying = (newRate != 0.0) }
        if isScrubbing { isScrubbing = false }
        
        if newRate == 0.0 {
            pause()
            return
        }
        
        slotA.player.automaticallyWaitsToMinimizeStalling = false
        slotB.player.automaticallyWaitsToMinimizeStalling = false
        
        if !isLinked || slotB.url == nil {
            slotA.player.playImmediately(atRate: newRate)
            updateShuttleText(for: newRate)
            return
        }
        
        let masterSecs = CMTimeGetSeconds(slotA.player.currentTime())
        let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
        let targetSecs = max(0.0, masterSecs + offsetSecs)
        let currSecsB = CMTimeGetSeconds(slotB.player.currentTime())
        let frameDur = 1.0 / max(1.0, slotB.fps)
        
        let startBothPlayers = { @MainActor [weak self] in
            guard let self = self, self.isPlaying, self.rate == newRate else { return }
            self.slotB.player.playImmediately(atRate: newRate)
            self.slotA.player.playImmediately(atRate: newRate)
            self.updateShuttleText(for: newRate)
        }
        
        // A B seek still in flight (pause alignment, re-lock) would start B late: land it exactly first.
        if isSeekingB || isRelockingB || isPauseAlignSeekPendingB || abs(currSecsB - targetSecs) > frameDur * 1.5 {
            let targetTimeB = CMTime(seconds: targetSecs, preferredTimescale: 60000)
            seekSlotB(to: targetTimeB) {
                startBothPlayers()
            }
        } else {
            startBothPlayers()
        }
    }
    
    private func updateShuttleText(for newRate: Float) {
        let text: String
        if newRate == 0.0 {
            text = "PAUSE"
        } else if newRate > 0.0 {
            text = newRate == 1.0 ? "PLAY 1x" : "FWD \(Int(newRate))x"
        } else {
            text = newRate == -1.0 ? "REV 1x" : "REV \(Int(abs(newRate)))x"
        }
        if shuttleStateText != text { shuttleStateText = text }
    }
    
    // MARK: - Frame Stepping & Jumps
    
    public func stepFrame(forward: Bool) {
        stepFrames(count: 1, forward: forward)
    }
    
    public func stepFrames(count: Int, forward: Bool) {
        pause()
        guard slotA.player.currentItem != nil else { return }
        let currFrame = self.currentFrame
        let delta = forward ? count : -count
        let targetFrame = max(0, min(max(0, self.totalFrames - 1), currFrame + delta))
        guard targetFrame != currFrame else { return }
        
        self.currentFrame = targetFrame
        self.currentTimecode = TimecodeFormatter.format(frameIndex: targetFrame, fps: activeFps)
        let durSecs = CMTimeGetSeconds(duration)
        let fps = max(1.0, activeFps)
        let targetSecs = (Double(targetFrame) + 0.5) / fps
        if durSecs > 0 {
            self.currentProgress = min(1.0, max(0.0, targetSecs / durSecs))
        }
        seek(toFrame: targetFrame)
    }

    
    public func jumpToBeginning() {
        pause()
        self.currentFrame = 0
        self.currentTimecode = TimecodeFormatter.format(frameIndex: 0, fps: activeFps)
        self.currentProgress = 0.0
        seek(toFrame: 0)
    }
    
    public func jumpToEnd() {
        pause()
        let lastFrame = max(0, totalFrames - 1)
        self.currentFrame = lastFrame
        self.currentTimecode = TimecodeFormatter.format(frameIndex: lastFrame, fps: activeFps)
        self.currentProgress = 1.0
        seek(toFrame: lastFrame)
    }
    
    // MARK: - Scrubbing & Seeking
    
    /// Initiates interactive scrubbing: remembers active playback state and temporarily halts playback during dragging
    public func startScrubbing() {
        guard !self.isScrubbing else { return }
        cancelSlotBRelock()
        self.wasPlayingBeforeScrub = (self.isPlaying || self.rate != 0.0 || self.isSlowStepping)
        self.playbackRateBeforeScrub = (self.rate != 0.0) ? self.rate : 1.0
        self.isScrubbing = true
        self.isScrubSeekingA = false
        self.pendingScrubTimeA = nil
        self.isScrubSeekingB = false
        self.pendingScrubTimeB = nil
        
        if self.wasPlayingBeforeScrub {
            stopSlowStep()
            slotA.player.pause()
            slotB.player.pause()
            self.rate = 0.0
            // Keep isPlaying = true so UI controls (e.g. Play/Pause button) stay in playing context
            self.isPlaying = true
        }
    }
    
    /// High-performance interactive scrubbing: updates UI synchronously at 120 FPS lockstep with mouse drag
    public func scrubTo(progress: Double) {
        if !self.isScrubbing {
            startScrubbing()
        }
        #if DEBUG
        QCScrubDiagnostic.shared.recordScrubCall()
        #endif
        let clamped = min(1.0, max(0.0, progress))
        
        let durSecs = CMTimeGetSeconds(duration)
        guard durSecs > 0 && durSecs.isFinite && !durSecs.isNaN else { return }
        let currSecs = clamped * durSecs
        let fps = max(1.0, activeFps)
        let calcVal = currSecs * fps + 1e-4
        let frameIdx = (calcVal.isFinite && !calcVal.isNaN) ? max(0, min(max(0, totalFrames - 1), Int(floor(calcVal)))) : 0
        
        let targetSecs = (Double(frameIdx) + 0.5) / fps
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        
        // Zero SwiftUI objectWillChange storm during active mouse drag.
        // Pure seek dispatch directly to independent hardware compositor layers.
        dispatchScrubSeek(timeA: targetTime)
    }
    
    // MARK: - Dedicated Interactive Scrub Seek Pipeline (Unblocked Parallel Hardware Decoding)
    
    private func dispatchScrubSeek(timeA: CMTime) {
        guard slotA.player.currentItem != nil else { return }
        let fpsA = max(1.0, activeFps)
        let tolA = CMTime(seconds: 2.0 / fpsA, preferredTimescale: 60000)
        
        if isScrubSeekingA {
            pendingScrubTimeA = timeA
        } else {
            isScrubSeekingA = true
            dispatchScrubSeekSlotA(to: timeA, tolerance: tolA)
        }
        
        let hasSlotB = (self.compareMode != .single || self.isBlinkCompareB) && self.isLinked && self.slotB.url != nil && self.slotB.player.currentItem != nil
        if hasSlotB {
            let offsetSecs = Double(self.slotB.slipOffsetFrames) / max(1.0, self.slotB.fps)
            let targetSecsB = max(0.0, CMTimeGetSeconds(timeA) + offsetSecs)
            let timeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
            let fpsB = max(1.0, self.slotB.fps)
            let tolB = CMTime(seconds: 2.0 / fpsB, preferredTimescale: 60000)
            
            if isScrubSeekingB {
                pendingScrubTimeB = timeB
            } else {
                isScrubSeekingB = true
                dispatchScrubSeekSlotB(to: timeB, tolerance: tolB)
            }
        }
    }
    
    private func dispatchScrubSeekSlotA(to time: CMTime, tolerance: CMTime) {
        slotA.player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            let run = { @MainActor in
                guard let self = self else { return }
                self.isScrubSeekingA = false
                
                guard self.isScrubbing else {
                    self.pendingScrubTimeA = nil
                    return
                }
                
                #if DEBUG
                if finished {
                    QCScrubDiagnostic.shared.recordSeekCompleted()
                }
                #endif
                
                if finished {
                    let currSecs = CMTimeGetSeconds(time)
                    let fps = max(1.0, self.activeFps)
                    let frameIdx = max(0, min(max(0, self.totalFrames - 1), Int(floor(currSecs * fps + 1e-4))))
                    if self.currentFrame != frameIdx {
                        self.currentFrame = frameIdx
                        self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: self.activeFps)
                    }
                }
                
                if let next = self.pendingScrubTimeA {
                    self.pendingScrubTimeA = nil
                    self.isScrubSeekingA = true
                    let fpsA = max(1.0, self.activeFps)
                    let tolA = CMTime(seconds: 2.0 / fpsA, preferredTimescale: 60000)
                    self.dispatchScrubSeekSlotA(to: next, tolerance: tolA)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { run() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { run() } }
            }
        }
    }
    
    private func dispatchScrubSeekSlotB(to time: CMTime, tolerance: CMTime) {
        slotB.player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            let run = { @MainActor in
                guard let self = self else { return }
                self.isScrubSeekingB = false
                
                guard self.isScrubbing else {
                    self.pendingScrubTimeB = nil
                    return
                }
                
                if let next = self.pendingScrubTimeB {
                    self.pendingScrubTimeB = nil
                    self.isScrubSeekingB = true
                    let fpsB = max(1.0, self.slotB.fps)
                    let tolB = CMTime(seconds: 2.0 / fpsB, preferredTimescale: 60000)
                    self.dispatchScrubSeekSlotB(to: next, tolerance: tolB)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { run() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { run() } }
            }
        }
    }
    
    /// Concludes interactive scrubbing: if previously playing, resumes playback from the new point; if paused, stays paused
    public func endScrubbing(at progress: Double) {
        let clamped = min(1.0, max(0.0, progress))
        self.isScrubbing = false
        self.pendingScrubTimeA = nil
        self.pendingScrubTimeB = nil
        self.isScrubSeekingA = false
        self.isScrubSeekingB = false
        self.currentProgress = clamped
        
        let durSecs = CMTimeGetSeconds(duration)
        let fps = max(1.0, activeFps)
        let currSecs = (durSecs > 0 && durSecs.isFinite && !durSecs.isNaN) ? clamped * durSecs : 0.0
        let calcVal = currSecs * fps + 1e-4
        let frameIdx = (calcVal.isFinite && !calcVal.isNaN) ? max(0, min(max(0, totalFrames - 1), Int(floor(calcVal)))) : 0
        self.currentFrame = frameIdx
        self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
        
        let targetTime = CMTime(seconds: currSecs, preferredTimescale: 60000)
        self.currentTime = targetTime
        self.slotA.currentTime = targetTime
        
        if (self.compareMode != .single || self.isBlinkCompareB) && self.isLinked && self.slotB.url != nil {
            let offsetSecs = Double(self.slotB.slipOffsetFrames) / max(1.0, self.slotB.fps)
            let targetSecsB = max(0.0, currSecs + offsetSecs)
            self.slotB.currentTime = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
        }
        
        let shouldResume = self.wasPlayingBeforeScrub
        let resumeRate = self.playbackRateBeforeScrub
        self.wasPlayingBeforeScrub = false
        
        if shouldResume {
            let isNearEnd = (durSecs > 0 && currSecs >= durSecs - 0.05)
            if isNearEnd && !isLooping {
                pause()
            } else {
                self.isPlaying = true
                let resumeTol = CMTime(seconds: 1.0 / max(1.0, activeFps), preferredTimescale: 60000)
                seek(toTime: targetTime, tolerance: resumeTol) { [weak self] in
                    guard let self = self else { return }
                    self.setPlaybackRate(resumeRate)
                }
            }
        } else {
            // Stay paused: exact frame seek with zero tolerance
            pause()
            seek(toFrame: frameIdx)
        }
    }
    
    public func seek(toProgress progress: Double, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let durSecs = CMTimeGetSeconds(duration)
        guard durSecs > 0 else {
            completion?()
            return
        }
        let clamped = min(1.0, max(0.0, progress))
        let targetSecs = clamped * durSecs
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        seek(toTime: targetTime, completion: completion)
    }
    
    public func seek(toTime time: CMTime, tolerance: CMTime? = nil, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard slotA.player.currentItem != nil else {
            completion?()
            return
        }
        cancelSlotBRelock()

        if isSeeking {
            pendingSeekTime = time
            pendingSeekTolerance = tolerance
            if let completion = completion {
                pendingSeekCompletion = completion
            }
            return
        }
        
        isSeeking = true
        let curCompletion = completion
        
        // Exact frame accuracy by default unless explicit tolerance is provided
        let tol: CMTime = tolerance ?? .zero
        
        let hasSlotB = (self.compareMode != .single || self.isBlinkCompareB) && self.isLinked && self.slotB.url != nil && self.slotB.player.currentItem != nil
        let offsetSeconds = hasSlotB ? (Double(self.slotB.slipOffsetFrames) / max(1.0, self.slotB.fps)) : 0.0
        let targetSecsB = hasSlotB ? max(0.0, CMTimeGetSeconds(time) + offsetSeconds) : 0.0
        let targetTimeB = hasSlotB ? CMTime(seconds: targetSecsB, preferredTimescale: 60000) : .zero
        
        let lock = OSAllocatedUnfairLock(initialState: (completedA: false, completedB: !hasSlotB))
        
        let checkParallelDone = { @MainActor in
            let (doneA, doneB) = lock.withLock { ($0.completedA, $0.completedB) }
            guard doneA && doneB else { return }
            self.isSeeking = false
            
            if self.pendingSeekTime == nil {
                self.updateCurrentTime(time: time)
            }
            
            if !self.isPlaying && !self.isScrubbing {
                self.notifySeekSettled()
            }
            
            curCompletion?()
            
            #if DEBUG
            QCScrubDiagnostic.shared.recordSeekCompleted()
            #endif
            
            if let nextTime = self.pendingSeekTime {
                let nextComp = self.pendingSeekCompletion
                let nextTol = self.pendingSeekTolerance
                self.pendingSeekTime = nil
                self.pendingSeekTolerance = nil
                self.pendingSeekCompletion = nil
                self.seek(toTime: nextTime, tolerance: nextTol, completion: nextComp)
            }
        }
        
        // Parallel dispatch to Slot A
        let seekStartA = CFAbsoluteTimeGetCurrent()
        slotA.player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            let seekDurationMs = (CFAbsoluteTimeGetCurrent() - seekStartA) * 1000.0
            if seekDurationMs > 30.0 {
                print("⏱️ [SEEK SLOW] slotA.player.seek took \(String(format: "%.1f", seekDurationMs))ms for time \(CMTimeGetSeconds(time))s")
            }
            let runSlotA = { @MainActor in
                guard let self = self else { return }
                lock.withLock { $0.completedA = true }
                self.notifyFrameDecoded(.slotA, at: time)
                checkParallelDone()
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { runSlotA() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { runSlotA() } }
            }
        }
        
        // Parallel dispatch to Slot B
        if hasSlotB {
            slotB.player.seek(to: targetTimeB, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
                let runSlotB = { @MainActor in
                    guard let self = self else { return }
                    lock.withLock { $0.completedB = true }
                    self.notifyFrameDecoded(.slotB, at: targetTimeB)
                    checkParallelDone()
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { runSlotB() }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { runSlotB() } }
                }
            }
        }
    }
    
    // MARK: - Zoom & Pan Controls
    
    public func setZoomFit() {
        self.isFitZoom = true
        self.zoomScale = 1.0
        self.panOffset = .zero
    }
    
    public func setZoomLevel(_ scale: CGFloat) {
        self.isFitZoom = false
        self.zoomScale = scale
    }

    
    // MARK: - Frame-Accurate Seeking & Scan Markers
    
    public func seek(toFrame frameIndex: Int, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let fps = max(1.0, activeFps)
        let durSecs = CMTimeGetSeconds(duration)
        // Center the timestamp squarely in the middle of the frame window (+0.5/fps)
        // to avoid leading-edge sample rounding or codec presentation timestamp (PTS) truncation
        let desiredSecs = (Double(frameIndex) + 0.5) / fps
        let targetSecs = durSecs > 0 ? min(max(0.0, desiredSecs), max(0.0, durSecs - 0.001)) : desiredSecs
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        
        self.currentFrame = frameIndex
        self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIndex, fps: activeFps)
        if durSecs > 0 {
            self.currentProgress = min(1.0, max(0.0, targetSecs / durSecs))
        }
        self.currentTime = targetTime
        self.slotA.currentTime = targetTime
        
        seek(toTime: targetTime, completion: completion)
    }
    
    // MARK: - Review Note Navigation
    
    public func jumpToPreviousNote() {
        guard !activeNotes.isEmpty else { return }
        let sorted = activeNotes.sorted { $0.frameIndex < $1.frameIndex }
        let cur = currentFrame
        if let prev = sorted.last(where: { $0.frameIndex < cur }) {
            seek(toFrame: prev.frameIndex)
            pause()
        } else if let last = sorted.last {
            seek(toFrame: last.frameIndex)
            pause()
        }
    }
    
    public func jumpToNextNote() {
        guard !activeNotes.isEmpty else { return }
        let sorted = activeNotes.sorted { $0.frameIndex < $1.frameIndex }
        let cur = currentFrame
        if let next = sorted.first(where: { $0.frameIndex > cur }) {
            seek(toFrame: next.frameIndex)
            pause()
        } else if let first = sorted.first {
            seek(toFrame: first.frameIndex)
            pause()
        }
    }
    
    public func setScanResults(_ results: [VideoQCResult]) {
        var map: [URL: [PlayerTimelineMarker]] = [:]
        for res in results {
            var fileMarkers: [PlayerTimelineMarker] = []
            for seg in res.glitchSegments {
                let marker = PlayerTimelineMarker(
                    frameIndex: seg.startFrame,
                    timecode: seg.startTimecode,
                    edge: seg.edge,
                    colorHex: seg.detectedColor.hexString,
                    label: "\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX) @ \(seg.startTimecode)"
                )
                fileMarkers.append(marker)
            }
            map[res.fileURL] = fileMarkers
        }
        self.markersMap = map
        if let active = activeURL {
            self.activeMarkers = map[active] ?? []
        }
    }
    
    // MARK: - Pixel-Perfect Still Frame Capture (For export)
    
    /// Returns the frame as displayed, i.e. with the current exposure applied exactly once.
    public func captureCurrentFrame(for slot: SlotTarget = .slotA, at time: CMTime? = nil) async -> CGImage? {
        let currentSlot = (slot == .slotA) ? slotA : slotB
        guard let url = currentSlot.url else { return currentSlot.lastDecodedFrame }
        
        let targetTime: CMTime
        if let explicitTime = time, explicitTime.isValid, explicitTime.isNumeric {
            targetTime = explicitTime
        } else {
            if slot == .slotA {
                targetTime = (currentSlot.currentTime.isValid && currentSlot.currentTime.isNumeric) ? currentSlot.currentTime : currentSlot.player.currentTime()
            } else {
                if isLinked {
                    let timeA = (slotA.currentTime.isValid && slotA.currentTime.isNumeric) ? slotA.currentTime : slotA.player.currentTime()
                    let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                    let masterSecs = CMTimeGetSeconds(timeA)
                    let targetSecsB = max(0.0, (masterSecs.isFinite && !masterSecs.isNaN ? masterSecs : 0.0) + offsetSecs)
                    targetTime = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
                } else {
                    targetTime = (currentSlot.currentTime.isValid && currentSlot.currentTime.isNumeric) ? currentSlot.currentTime : currentSlot.player.currentTime()
                }
            }
        }
        
        guard targetTime.isValid && targetTime.isNumeric else { return currentSlot.lastDecodedFrame }
        let fps = max(1.0, currentSlot.fps)
        let rawSecs = CMTimeGetSeconds(targetTime)
        guard rawSecs.isFinite && !rawSecs.isNaN else { return currentSlot.lastDecodedFrame }
        
        // Snap to exact frame-center PTS so AVAssetImageGenerator zero tolerance lands squarely inside target frame
        let frameIdx = max(0, Int(floor(rawSecs * fps + 1e-4)))
        let targetSecs = (Double(frameIdx) + 0.5) / fps
        let centerTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        
        // 1. Try frame extractor (decodes without the exposure composition, so apply it here)
        if let extracted = await currentSlot.frameExtractor.capture(at: centerTime, fallbackURL: url) {
            let image = ExposureAdjuster.shared.applyExposure(to: extracted, ev: exposureEV)
            currentSlot.lastDecodedFrame = image
            return image
        }
        
        // 2. Try video output pixel buffer (already composited with exposure)
        if let output = currentSlot.videoOutput {
            var displayTime = CMTime.zero
            var pb = output.copyPixelBuffer(forItemTime: centerTime, itemTimeForDisplay: &displayTime)
            if pb == nil {
                pb = output.copyPixelBuffer(forItemTime: currentSlot.player.currentTime(), itemTimeForDisplay: &displayTime)
            }
            if let pb = pb {
                var cg: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
                if let cg = cg {
                    currentSlot.lastDecodedFrame = cg
                    return cg
                }
            }
        }
        
        // 3. Fallback to cached frame from viewport
        return currentSlot.lastDecodedFrame
    }
    
    // MARK: - Pixel-Perfect Frame & Compare Screenshot Export
    
    /// Captures the current visible frame or dual-slot A/B composition for screenshot export.
    /// Pure master frames with zero UI elements, timecode HUDs, or media info labels.
    public func captureCompositedScreenshotImage() async -> CGImage? {
        let isABActive = slotB.url != nil && (compareMode != .single || isBlinkCompareB)
        
        // 1. Blink compare: user is viewing 100% Slot B directly
        if isBlinkCompareB && slotB.url != nil {
            let timeA = (slotA.currentTime.isValid && slotA.currentTime.isNumeric) ? slotA.currentTime : slotA.player.currentTime()
            let timeB: CMTime
            if isLinked {
                let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                let masterSecs = CMTimeGetSeconds(timeA)
                let targetSecsB = max(0.0, (masterSecs.isFinite && !masterSecs.isNaN ? masterSecs : 0.0) + offsetSecs)
                timeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
            } else {
                timeB = (slotB.currentTime.isValid && slotB.currentTime.isNumeric) ? slotB.currentTime : slotB.player.currentTime()
            }
            guard let rawImage = await captureCurrentFrame(for: .slotB, at: timeB) ?? slotB.lastDecodedFrame else { return nil }
            return rawImage
        }
        
        // 2. Single slot capture
        if !isABActive || compareMode == .single {
            let targetSlot: SlotTarget = (activeTarget == .slotB && slotB.url != nil) ? .slotB : .slotA
            let rawImage = await captureCurrentFrame(for: targetSlot) ?? ((targetSlot == .slotB) ? slotB.lastDecodedFrame : slotA.lastDecodedFrame)
            guard let img = rawImage else { return nil }
            return img
        }
        
        // 3. Dual slot A/B compositing
        let timeA = (slotA.currentTime.isValid && slotA.currentTime.isNumeric) ? slotA.currentTime : slotA.player.currentTime()
        let timeB: CMTime
        if isLinked {
            let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
            let masterSecs = CMTimeGetSeconds(timeA)
            let targetSecsB = max(0.0, (masterSecs.isFinite && !masterSecs.isNaN ? masterSecs : 0.0) + offsetSecs)
            timeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
        } else {
            timeB = (slotB.currentTime.isValid && slotB.currentTime.isNumeric) ? slotB.currentTime : slotB.player.currentTime()
        }
        
        async let frameA = captureCurrentFrame(for: .slotA, at: timeA)
        async let frameB = captureCurrentFrame(for: .slotB, at: timeB)
        var (rawA, rawB) = await (frameA, frameB)
        
        if rawA == nil { rawA = slotA.lastDecodedFrame }
        if rawB == nil { rawB = slotB.lastDecodedFrame }
        
        guard let imgA = rawA else {
            return rawB
        }
        guard let imgB = rawB else {
            return imgA
        }
        
        // Captured frames are display-ready (exposure already applied once).
        let expA = imgA
        let expB = imgB
        
        let colorSpace = expA.colorSpace ?? expB.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        switch compareMode {
        case .single:
            return expA
            
        case .splitVertical:
            let outW = max(expA.width, expB.width)
            let outH = max(expA.height, expB.height)
            guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return expA
            }
            // Base: Slot B across entire frame
            ctx.draw(expB, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            
            // Left portion: Slot A
            let splitPos = max(0.0, min(1.0, splitPosition))
            let splitX = round(CGFloat(outW) * splitPos)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: splitX, height: CGFloat(outH)))
            ctx.draw(expA, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.restoreGState()
            
            // Cyan split wipe line at divider position
            let lineWidth = max(2.0, round(CGFloat(outW) / 960.0))
            let dividerRect = CGRect(x: splitX - (lineWidth / 2.0), y: 0, width: lineWidth, height: CGFloat(outH))
            ctx.setFillColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9)
            ctx.fill(dividerRect)
            
            return ctx.makeImage() ?? expA
            
        case .splitHorizontal:
            let outW = max(expA.width, expB.width)
            let outH = max(expA.height, expB.height)
            guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return expA
            }
            // Base: Slot B across entire frame (bottom)
            ctx.draw(expB, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            
            // Top portion: Slot A (in CGContext, y=0 is bottom, top is splitY to outH)
            let splitPos = max(0.0, min(1.0, splitPosition))
            let splitY = round(CGFloat(outH) * splitPos)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: splitY, width: CGFloat(outW), height: CGFloat(outH) - splitY))
            ctx.draw(expA, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.restoreGState()
            
            // Cyan split wipe line at divider position
            let lineHeight = max(2.0, round(CGFloat(outH) / 540.0))
            let dividerRect = CGRect(x: 0, y: splitY - (lineHeight / 2.0), width: CGFloat(outW), height: lineHeight)
            ctx.setFillColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9)
            ctx.fill(dividerRect)
            
            return ctx.makeImage() ?? expA
            
        case .sideBySide:
            let outW = expA.width + expB.width
            let outH = max(expA.height, expB.height)
            guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return expA
            }
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
            
            let rectA = CGRect(x: 0, y: (outH - expA.height) / 2, width: expA.width, height: expA.height)
            let rectB = CGRect(x: expA.width, y: (outH - expB.height) / 2, width: expB.width, height: expB.height)
            ctx.draw(expA, in: rectA)
            ctx.draw(expB, in: rectB)
            
            return ctx.makeImage() ?? expA
            
        case .sideBySideVertical:
            let outW = max(expA.width, expB.width)
            let outH = expA.height + expB.height
            guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return expA
            }
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
            
            // In CGContext, y=0 is bottom (Slot B) and top is Slot A
            let rectB = CGRect(x: (outW - expB.width) / 2, y: 0, width: expB.width, height: expB.height)
            let rectA = CGRect(x: (outW - expA.width) / 2, y: expB.height, width: expA.width, height: expA.height)
            ctx.draw(expB, in: rectB)
            ctx.draw(expA, in: rectA)
            
            return ctx.makeImage() ?? expA
            
        case .difference:
            let outW = max(expA.width, expB.width)
            let outH = max(expA.height, expB.height)
            guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return expA
            }
            ctx.draw(expA, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.setBlendMode(.difference)
            ctx.draw(expB, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.setBlendMode(.normal)
            
            return ctx.makeImage() ?? expA
            
        case .overlay:
            let outW = max(expA.width, expB.width)
            let outH = max(expA.height, expB.height)
            guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return expA
            }
            ctx.draw(expA, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.setAlpha(0.5)
            ctx.draw(expB, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            
            return ctx.makeImage() ?? expA
        }
    }
    
    /// Encodes a CGImage to the specified preset format and compression.
    public func encodeScreenshot(image: CGImage, preset: ScreenshotPreset) throws -> Data {
        switch preset {
        case .jpgMedium:
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.70]) else {
                throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to JPG Medium."])
            }
            return data
            
        case .jpgHigh:
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
                throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to JPG High."])
            }
            return data
            
        case .pngHigh:
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let data = bitmapRep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to PNG High."])
            }
            return data
            
        case .pngMedium:
            // PNG Medium: 100% source resolution with 24-bit RGB and SUB compression filter for lower bitrate
            let w = image.width
            let h = image.height
            let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let ctx24 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx24.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let img24 = ctx24.makeImage() {
                    let mutableData = NSMutableData()
                    if let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.png" as CFString, 1, nil) {
                        let options: [CFString: Any] = [
                            kCGImagePropertyPNGDictionary: [
                                kCGImagePropertyPNGCompressionFilter: 0x10
                            ]
                        ]
                        CGImageDestinationAddImage(dest, img24, options as CFDictionary)
                        if CGImageDestinationFinalize(dest) {
                            return mutableData as Data
                        }
                    }
                }
            }
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let data = bitmapRep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to PNG Medium."])
            }
            return data
        }
    }
}

#if DEBUG
@MainActor
public final class QCScrubDiagnostic {
    public static let shared = QCScrubDiagnostic()
    private var scrubCalls = 0
    private var seeksCompleted = 0
    private var lastLogged: CFAbsoluteTime = 0
    
    public func recordScrubCall() {
        scrubCalls += 1
        checkLog()
    }
    
    public func recordSeekCompleted() {
        seeksCompleted += 1
        checkLog()
    }
    
    private func checkLog() {
        let now = CFAbsoluteTimeGetCurrent()
        if lastLogged == 0 {
            lastLogged = now
            return
        }
        let elapsed = now - lastLogged
        if elapsed >= 1.0 {
            let scrubRate = Double(scrubCalls) / elapsed
            let seekRate = Double(seeksCompleted) / elapsed
            print("📊 [SCRUB DIAGNOSTIC] Mouse drag calls: \(String(format: "%.1f", scrubRate))/s | Seeks completed: \(String(format: "%.1f", seekRate))/s")
            scrubCalls = 0
            seeksCompleted = 0
            lastLogged = now
        }
    }
}
#endif
