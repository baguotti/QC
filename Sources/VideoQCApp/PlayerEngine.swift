import Foundation
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
@preconcurrency import VideoToolbox
import VideoQCLib

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
    @Published public var currentTime: CMTime = .zero
    @Published public var videoSize: CGSize = CGSize(width: 1920, height: 1080)
    @Published public var totalFrames: Int = 0
    @Published public var slipOffsetFrames: Int = 0
    
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
    
    public init(id: SlotTarget) {
        self.id = id
        player.automaticallyWaitsToMinimizeStalling = false
    }
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
            if !hasMatchingAspectRatios && (compareMode == .splitVertical || compareMode == .splitHorizontal || compareMode == .difference || compareMode == .overlay) {
                compareMode = .sideBySide
            }
        }
    }
    @Published public var splitPosition: CGFloat = 0.5
    
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
        if !hasMatchingAspectRatios {
            if compareMode == .splitVertical || compareMode == .splitHorizontal || compareMode == .difference || compareMode == .overlay {
                compareMode = .sideBySide
            }
        } else {
            if compareMode == .single {
                compareMode = .splitVertical
            }
        }
    }
    @Published public var isLinked: Bool = true
    @Published public var audioSlot: SlotTarget = .slotA {
        didSet {
            updateAudioVolumes()
        }
    }
    @Published public var isBlinkCompareB: Bool = false
    @Published public var showClipNamesOverlay: Bool = false
    
    // MARK: - Backwards Compatible Single-Player Properties (Reflects Slot A / Master)
    
    @Published public var activeURL: URL? = nil
    @Published public var activeFileName: String = ""
    @Published public var activeResolution: String = ""
    @Published public var activeFps: Double = 25.0
    @Published public var activeCodec: String = ""
    @Published public var videoSize: CGSize = CGSize(width: 1920, height: 1080)
    
    @Published public var currentTime: CMTime = .zero
    @Published public var duration: CMTime = .zero
    @Published public var currentTimecode: String = "00:00:00:00"
    @Published public var durationTimecode: String = "00:00:00:00"
    @Published public var currentProgress: Double = 0.0 // 0.0 ... 1.0
    @Published public var currentFrame: Int = 0
    @Published public var totalFrames: Int = 0
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
    
    public var showTitleSafe: Bool {
        get { safeAreaMode != .off }
        set { safeAreaMode = newValue ? .standard : .off }
    }
    
    // Video Exposure Adjustment (EV stops: -5.0 to +5.0)
    @Published public var exposureEV: Double = 0.0 {
        didSet {
            updateVideoCompositions()
        }
    }
    
    public func resetExposure() {
        self.exposureEV = 0.0
    }
    
    // MARK: - Exposure Video Composition (Hardware-Accelerated Playback)
    
    public func updateVideoCompositions() {
        updateComposition(for: slotA)
        updateComposition(for: slotB)
    }
    
    private func updateComposition(for slot: PlayerSlot) {
        guard let item = slot.player.currentItem else { return }
        if abs(exposureEV) < 0.001 {
            if item.videoComposition != nil {
                item.videoComposition = nil
            }
            return
        }
        let ev = self.exposureEV
        let asset = item.asset
        let comp = AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage
            guard let filter = CIFilter(name: "CIExposureAdjust") else {
                request.finish(with: source, context: nil)
                return
            }
            filter.setValue(source, forKey: kCIInputImageKey)
            filter.setValue(ev, forKey: kCIInputEVKey)
            if let output = filter.outputImage {
                request.finish(with: output, context: nil)
            } else {
                request.finish(with: source, context: nil)
            }
        })
        item.videoComposition = comp
    }
    
    // Glitch Markers from Line Scanner
    @Published public var markersMap: [URL: [PlayerTimelineMarker]] = [:]
    @Published public var activeMarkers: [PlayerTimelineMarker] = []
    
    // Review Notes from Companion Sidecar (.qcnotes)
    @Published public var activeNotes: [QCFileNote] = []
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
    private var lastDriftCorrectionTime: Date = .distantPast
    
    public init() {
        slotA.player.automaticallyWaitsToMinimizeStalling = false
        slotB.player.automaticallyWaitsToMinimizeStalling = false
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
    
    public func loadVideo(url: URL, into target: SlotTarget = .slotA, initialSeekFrame: Int? = nil, autoplay: Bool = false) {
        let shouldAutoplay = autoplay && isAutoplayEnabled
        if target == .slotA || slotA.url == nil {
            loadVideoIntoSlotA(url: url, initialSeekFrame: initialSeekFrame, autoplay: shouldAutoplay)
        } else {
            loadVideoIntoSlotB(url: url, autoplay: shouldAutoplay)
        }
    }
    
    private func loadVideoIntoSlotA(url: URL, initialSeekFrame: Int? = nil, autoplay: Bool = false) {
        self.activeMarkers = markersMap[url] ?? []
        
        if slotA.url == url {
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
        
        slotA.url = url
        slotA.fileName = url.lastPathComponent
        self.activeURL = url
        self.activeFileName = url.lastPathComponent
        self.currentTime = .zero
        self.currentProgress = 0.0
        self.currentTimecode = "00:00:00:00"
        self.panOffset = .zero
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
        updateComposition(for: slotA)
        
        itemPresentationSizeCancellable = item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .filter { $0.width > 0 && $0.height > 0 }
            .first()
            .sink { [weak self] size in
                guard let self = self, self.slotA.url == url else { return }
                self.slotA.videoSize = size
                self.videoSize = size
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
        if slotB.url == url {
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
        
        slotB.url = url
        slotB.fileName = url.lastPathComponent
        slotB.slipOffsetFrames = 0
        
        let asset = AVURLAsset(url: url)
        Task { [slotB] in
            await slotB.frameExtractor.setURL(url)
        }
        
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        slotB.attachVideoOutput(to: item)
        
        slotB.player.replaceCurrentItem(with: item)
        slotB.player.automaticallyWaitsToMinimizeStalling = false
        updateComposition(for: slotB)
        
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
                
                self.duration = dur
                self.activeFps = detectedFps
                self.activeResolution = resStr
                self.activeCodec = codecStr
                self.videoSize = detectedSize
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
                self.slotB.duration = dur
                self.slotB.fps = detectedFps
                self.slotB.resolution = resStr
                self.slotB.codec = codecStr
                self.slotB.videoSize = detectedSize
                self.slotB.totalFrames = totFrames
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
    
    public func swapSlots() {
        guard slotA.url != nil || slotB.url != nil else { return }
        let wasPlaying = self.isPlaying
        pause()
        
        let tempURL_A = slotA.url
        let tempFileName_A = slotA.fileName
        let tempRes_A = slotA.resolution
        let tempFps_A = slotA.fps
        let tempCodec_A = slotA.codec
        let tempDur_A = slotA.duration
        let tempSize_A = slotA.videoSize
        let tempTotal_A = slotA.totalFrames
        let tempTime_A = slotA.player.currentTime()
        let tempSlip = slotB.slipOffsetFrames
        
        let tempURL_B = slotB.url
        let tempFileName_B = slotB.fileName
        let tempRes_B = slotB.resolution
        let tempFps_B = slotB.fps
        let tempCodec_B = slotB.codec
        let tempDur_B = slotB.duration
        let tempSize_B = slotB.videoSize
        let tempTotal_B = slotB.totalFrames
        let tempTime_B = slotB.player.currentTime()
        
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
        
        slotA.url = tempURL_B
        slotA.fileName = tempFileName_B
        slotA.resolution = tempRes_B
        slotA.fps = tempFps_B
        slotA.codec = tempCodec_B
        slotA.duration = tempDur_B
        slotA.videoSize = tempSize_B
        slotA.totalFrames = tempTotal_B
        if let urlA = tempURL_B {
            let itemA = AVPlayerItem(asset: AVURLAsset(url: urlA))
            itemA.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            slotA.attachVideoOutput(to: itemA)
            slotA.player.replaceCurrentItem(with: itemA)
            slotA.player.seek(to: tempTime_B, toleranceBefore: .zero, toleranceAfter: .zero)
            updateComposition(for: slotA)
            
            itemPresentationSizeCancellable = itemA.publisher(for: \.presentationSize)
                .receive(on: DispatchQueue.main)
                .filter { $0.width > 0 && $0.height > 0 }
                .first()
                .sink { [weak self] size in
                    guard let self = self, self.slotA.url == urlA else { return }
                    self.slotA.videoSize = size
                    self.videoSize = size
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
        
        slotB.url = tempURL_A
        slotB.fileName = tempFileName_A
        slotB.resolution = tempRes_A
        slotB.fps = tempFps_A
        slotB.codec = tempCodec_A
        slotB.duration = tempDur_A
        slotB.videoSize = tempSize_A
        slotB.totalFrames = tempTotal_A
        slotB.slipOffsetFrames = -tempSlip
        if let urlB = tempURL_A {
            let itemB = AVPlayerItem(asset: AVURLAsset(url: urlB))
            itemB.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            slotB.attachVideoOutput(to: itemB)
            slotB.player.replaceCurrentItem(with: itemB)
            slotB.player.seek(to: tempTime_A, toleranceBefore: .zero, toleranceAfter: .zero)
            updateComposition(for: slotB)
            
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
            await slotA.frameExtractor.setURL(tempURL_B)
            await slotB.frameExtractor.setURL(tempURL_A)
        }
        
        self.activeURL = slotA.url
        self.activeFileName = slotA.fileName
        self.activeResolution = slotA.resolution
        self.activeFps = slotA.fps
        self.activeCodec = slotA.codec
        self.videoSize = slotA.videoSize
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
        slotB.slipOffsetFrames = 0
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
        Task { [slotA] in
            await slotA.frameExtractor.setURL(nil)
        }
        activeMarkers = []
        durationTimecode = "00:00:00:00"
        currentTimecode = "00:00:00:00"
        isPlaying = false
        rate = 0.0
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
        let validModes: [CompareMode] = hasMatchingAspectRatios
            ? CompareMode.allCases
            : [.sideBySide, .sideBySideVertical, .single]
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
        let targetTimeB = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        seekSlotB(to: targetTimeB)
    }
    
    private func seekSlotB(to time: CMTime, tolerance: CMTime = .zero, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard slotB.url != nil, slotB.player.currentItem != nil else {
            completion?()
            return
        }
        if isSeekingB {
            pendingSeekTimeB = time
            return
        }
        isSeekingB = true
        slotB.player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            let runCompletion = { @MainActor in
                guard let self = self else { return }
                self.isSeekingB = false
                completion?()
                if !self.isPlaying && !self.isScrubbing {
                    self.objectWillChange.send()
                }
                if let nextB = self.pendingSeekTimeB {
                    self.pendingSeekTimeB = nil
                    self.seekSlotB(to: nextB, tolerance: tolerance)
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
            if timeB.isValid && timeB.isNumeric {
                self.slotB.currentTime = timeB
            }
            
            // Continuous drift correction during linked playback (throttled, only if drift > 0.15s)
            if self.isLinked && self.isPlaying && self.rate != 0 && !self.isSeekingB {
                let now = Date()
                if now.timeIntervalSince(self.lastDriftCorrectionTime) > 1.5 {
                    let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                    let expectedSecsB = currSecs + offsetSecs
                    let actualSecsB = CMTimeGetSeconds(timeB)
                    if abs(actualSecsB - expectedSecsB) > 0.15 {
                        self.lastDriftCorrectionTime = now
                        let targetTimeB = CMTime(seconds: max(0.0, expectedSecsB), preferredTimescale: 60000)
                        let tol = CMTime(value: 1, timescale: 30)
                        self.seekSlotB(to: targetTimeB, tolerance: tol) { [weak self] in
                            guard let self = self, self.isPlaying, self.rate != 0 else { return }
                            self.slotB.player.playImmediately(atRate: self.rate)
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
        slotA.player.pause()
        slotB.player.pause()
        self.rate = 0.0
        self.isPlaying = false
        self.isScrubbing = false
        self.isSeeking = false
        self.wasPlayingBeforeScrub = false
        self.shuttleStateText = "PAUSE"
        if let currentItem = slotA.player.currentItem, currentItem.status == .readyToPlay {
            let pausedTime = slotA.player.currentTime()
            if pausedTime.isValid && pausedTime.isNumeric {
                updateCurrentTime(time: pausedTime)
            }
        }
    }
    
    public func setPlaybackRate(_ newRate: Float) {
        stopSlowStep()
        self.rate = newRate
        self.isPlaying = (newRate != 0.0)
        self.isScrubbing = false
        
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
        
        if abs(currSecsB - targetSecs) > frameDur * 2.0 {
            let targetTimeB = CMTime(seconds: targetSecs, preferredTimescale: 60000)
            seekSlotB(to: targetTimeB) { [weak self] in
                guard let self = self, self.isPlaying, self.rate == newRate else { return }
                self.slotB.player.playImmediately(atRate: newRate)
            }
        } else {
            slotB.player.playImmediately(atRate: newRate)
        }
        
        slotA.player.playImmediately(atRate: newRate)
        updateShuttleText(for: newRate)
    }
    
    private func updateShuttleText(for newRate: Float) {
        if newRate == 0.0 {
            shuttleStateText = "PAUSE"
        } else if newRate > 0.0 {
            shuttleStateText = newRate == 1.0 ? "PLAY 1x" : "FWD \(Int(newRate))x"
        } else {
            shuttleStateText = newRate == -1.0 ? "REV 1x" : "REV \(Int(abs(newRate)))x"
        }
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
        self.wasPlayingBeforeScrub = (self.isPlaying || self.rate != 0.0 || self.isSlowStepping)
        self.playbackRateBeforeScrub = (self.rate != 0.0) ? self.rate : 1.0
        self.isScrubbing = true
        
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
        let clamped = min(1.0, max(0.0, progress))
        
        let durSecs = CMTimeGetSeconds(duration)
        if durSecs > 0 && durSecs.isFinite && !durSecs.isNaN {
            let currSecs = clamped * durSecs
            let fps = max(1.0, activeFps)
            let calcVal = currSecs * fps + 1e-4
            let frameIdx = (calcVal.isFinite && !calcVal.isNaN) ? max(0, min(max(0, totalFrames - 1), Int(floor(calcVal)))) : 0
            if frameIdx != self.currentFrame {
                self.currentFrame = frameIdx
                self.currentProgress = clamped
                self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
                
                let targetSecs = (Double(frameIdx) + 0.5) / fps
                let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
                self.currentTime = targetTime
                self.slotA.currentTime = targetTime
                seek(toTime: targetTime)
            }
        } else {
            if abs(self.currentProgress - clamped) > 1e-4 {
                self.currentProgress = clamped
            }
        }
    }
    
    /// Concludes interactive scrubbing: if previously playing, resumes playback from the new point; if paused, stays paused
    public func endScrubbing(at progress: Double) {
        let clamped = min(1.0, max(0.0, progress))
        self.isScrubbing = false
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
        
        // Fast seek during interactive scrubbing:
        // When sweeping across the timeline, use keyframe/fast tolerance (.positiveInfinity)
        // so AVPlayer / VideoToolbox seeks in <1ms without reconstructing deep GOP inter-frame chains.
        // When paused or concluding scrub, tolerance is .zero for pixel-perfect frame accuracy.
        let tol: CMTime
        if let explicitTol = tolerance {
            tol = explicitTol
        } else if isScrubbing {
            tol = .positiveInfinity
        } else {
            tol = .zero
        }
        
        slotA.player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            let runCompletion = { @MainActor in
                guard let self = self else { return }
                self.isSeeking = false
                
                // When not scrubbing, update time and progress (e.g. playback, jumps, frame step)
                // During scrubbing, scrubTo(progress:) already eagerly updates UI at 120 FPS
                if !self.isScrubbing && self.pendingSeekTime == nil {
                    self.updateCurrentTime(time: time)
                }
                
                if !self.isPlaying && !self.isScrubbing {
                    self.objectWillChange.send()
                }
                
                if self.isLinked && self.slotB.url != nil && self.slotB.player.currentItem != nil {
                    let offsetSeconds = Double(self.slotB.slipOffsetFrames) / max(1.0, self.slotB.fps)
                    let targetSecsB = max(0.0, CMTimeGetSeconds(time) + offsetSeconds)
                    let targetTimeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
                    let tolB = tolerance ?? (self.isScrubbing ? tol : .zero)
                    self.seekSlotB(to: targetTimeB, tolerance: tolB)
                }
                
                curCompletion?()
                
                if let nextTime = self.pendingSeekTime {
                    let nextComp = self.pendingSeekCompletion
                    let nextTol = self.pendingSeekTolerance
                    self.pendingSeekTime = nil
                    self.pendingSeekTolerance = nil
                    self.pendingSeekCompletion = nil
                    self.seek(toTime: nextTime, tolerance: nextTol, completion: nextComp)
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
    
    public func captureCurrentFrame(for slot: SlotTarget = .slotA, at time: CMTime? = nil) async -> CGImage? {
        let currentSlot = (slot == .slotA) ? slotA : slotB
        guard let url = currentSlot.url else { return nil }
        let rawTime = time ?? currentSlot.player.currentTime()
        guard rawTime.isValid && rawTime.isNumeric else { return nil }
        let fps = max(1.0, currentSlot.fps)
        let rawSecs = CMTimeGetSeconds(rawTime)
        guard rawSecs.isFinite && !rawSecs.isNaN else { return nil }
        // Snap to exact frame-center PTS so AVAssetImageGenerator zero tolerance lands squarely inside target frame
        let frameIdx = max(0, Int(floor(rawSecs * fps + 1e-4)))
        let targetSecs = (Double(frameIdx) + 0.5) / fps
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        return await currentSlot.frameExtractor.capture(at: targetTime, fallbackURL: url)
    }
    
    /// Exports the current video frame as a medium-quality JPEG (quality ~0.65)
    public func exportCurrentFrameAsJPEG(for slot: SlotTarget = .slotA, to destinationURL: URL, quality: CGFloat = 0.65) async throws {
        guard let cgImage = await captureCurrentFrame(for: slot) else {
            throw NSError(domain: "PlayerEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to capture video frame at current playhead."])
        }
        
        let exposedImage = ExposureAdjuster.shared.applyExposure(to: cgImage, ev: exposureEV)
        let bitmapRep = NSBitmapImageRep(cgImage: exposedImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to JPEG format."])
        }
        
        try jpegData.write(to: destinationURL, options: .atomic)
    }
}
