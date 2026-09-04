import Foundation
import AVFoundation
import Combine
import CoreMedia
import AppKit
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
    
    public var id: String { rawValue }
}

public enum SlotTarget: String, Sendable {
    case slotA
    case slotB
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
    
    public let player = AVPlayer()
    
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
    @Published public var activeTarget: SlotTarget = .slotA
    @Published public var compareMode: CompareMode = .single
    @Published public var splitPosition: CGFloat = 0.5
    @Published public var isLinked: Bool = true
    @Published public var audioSlot: SlotTarget = .slotA {
        didSet {
            updateAudioVolumes()
        }
    }
    @Published public var isBlinkCompareB: Bool = false
    
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
    
    // Glitch Markers from Line Scanner
    @Published public var markersMap: [URL: [PlayerTimelineMarker]] = [:]
    @Published public var activeMarkers: [PlayerTimelineMarker] = []
    private var pendingInitialSeekFrame: Int? = nil
    
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
    
    private var isSeeking: Bool = false
    private var pendingSeekTime: CMTime? = nil
    private var pendingSeekCompletion: (@MainActor @Sendable () -> Void)? = nil
    
    private var isSeekingB: Bool = false
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
    
    public func loadVideo(url: URL, into target: SlotTarget = .slotA, initialSeekFrame: Int? = nil) {
        if target == .slotA || slotA.url == nil {
            loadVideoIntoSlotA(url: url, initialSeekFrame: initialSeekFrame)
        } else {
            loadVideoIntoSlotB(url: url)
        }
    }
    
    private func loadVideoIntoSlotA(url: URL, initialSeekFrame: Int? = nil) {
        self.activeMarkers = markersMap[url] ?? []
        
        if slotA.url == url {
            if let frame = initialSeekFrame {
                seek(toFrame: frame)
            }
            return
        }
        
        self.pendingInitialSeekFrame = initialSeekFrame
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
        self.isSeeking = false
        self.pendingSeekTime = nil
        self.pendingSeekCompletion = nil
        
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        slotA.player.replaceCurrentItem(with: item)
        slotA.player.automaticallyWaitsToMinimizeStalling = false
        
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
            }
        
        Task {
            await extractMetadata(asset: asset, for: .slotA)
        }
        
        updateAudioVolumes()
    }
    
    private func loadVideoIntoSlotB(url: URL) {
        if slotB.url == url {
            return
        }
        
        pause()
        
        isSeekingB = false
        pendingSeekTimeB = nil
        
        slotB.url = url
        slotB.fileName = url.lastPathComponent
        slotB.slipOffsetFrames = 0
        
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        slotB.player.replaceCurrentItem(with: item)
        slotB.player.automaticallyWaitsToMinimizeStalling = false
        
        itemPresentationSizeCancellableB = item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .filter { $0.width > 0 && $0.height > 0 }
            .first()
            .sink { [weak self] size in
                guard let self = self, self.slotB.url == url else { return }
                self.slotB.videoSize = size
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
            }
        
        Task {
            await extractMetadata(asset: asset, for: .slotB)
        }
        
        if compareMode == .single {
            compareMode = .splitVertical
        }
        
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
            let totFrames = Int(round(durSecs * roundedFps))
            
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
                
                if let frame = self.pendingInitialSeekFrame {
                    self.pendingInitialSeekFrame = nil
                    self.seek(toFrame: frame)
                }
                self.currentTimecode = TimecodeFormatter.format(time: .zero, fps: detectedFps)
            } else {
                self.slotB.duration = dur
                self.slotB.fps = detectedFps
                self.slotB.resolution = resStr
                self.slotB.codec = codecStr
                self.slotB.videoSize = detectedSize
                self.slotB.totalFrames = totFrames
                self.syncSlotBToMaster()
            }
        } catch {
            print("[PlayerEngine] Error loading metadata: \(error)")
        }
    }
    
    private func fourCCToString(_ fourCC: FourCharCode) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((fourCC >> 24) & 0xff) ?? " "),
            Character(UnicodeScalar((fourCC >> 16) & 0xff) ?? " "),
            Character(UnicodeScalar((fourCC >> 8) & 0xff) ?? " "),
            Character(UnicodeScalar(fourCC & 0xff) ?? " ")
        ]
        let raw = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
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
            slotA.player.replaceCurrentItem(with: itemA)
            slotA.player.seek(to: tempTime_B, toleranceBefore: .zero, toleranceAfter: .zero)
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
            slotB.player.replaceCurrentItem(with: itemB)
            slotB.player.seek(to: tempTime_A, toleranceBefore: .zero, toleranceAfter: .zero)
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
        }
        
        updateCurrentTime(time: slotA.player.currentTime())
        updateAudioVolumes()
    }
    
    public func clearSlotB() {
        slotB.player.pause()
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
        isSeekingB = false
        pendingSeekTimeB = nil
        compareMode = .single
        audioSlot = .slotA
        isBlinkCompareB = false
        updateAudioVolumes()
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
        let all = CompareMode.allCases
        if let idx = all.firstIndex(of: compareMode) {
            let nextIdx = (idx + 1) % all.count
            compareMode = all[nextIdx]
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
            Task { @MainActor in
                guard let self = self else { return }
                self.isSeekingB = false
                completion?()
                if let nextB = self.pendingSeekTimeB {
                    self.pendingSeekTimeB = nil
                    self.seekSlotB(to: nextB, tolerance: tolerance)
                }
            }
        }
    }
    
    // MARK: - Time Observers
    
    private func setupTimeObserver() {
        let interval = CMTime(value: 1, timescale: 60)
        let token = slotA.player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self, !self.isScrubbing else { return }
                self.updateCurrentTime(time: time)
            }
        }
        tokens.timeObserverToken = token
        tokens.player = slotA.player
    }
    
    private func updateCurrentTime(time: CMTime) {
        self.currentTime = time
        self.slotA.currentTime = time
        let durSecs = CMTimeGetSeconds(duration)
        let currSecs = CMTimeGetSeconds(time)
        
        if durSecs > 0 {
            self.currentProgress = min(1.0, max(0.0, currSecs / durSecs))
        } else {
            self.currentProgress = 0.0
        }
        
        let fps = max(1.0, activeFps)
        let frameIdx = max(0, min(max(0, totalFrames - 1), Int(floor(currSecs * fps + 1e-4))))
        self.currentFrame = frameIdx
        self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
        
        if slotB.url != nil && slotB.player.currentItem != nil {
            let timeB = slotB.player.currentTime()
            self.slotB.currentTime = timeB
            
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
        if totalFrames > 0 {
            self.currentProgress = min(1.0, max(0.0, Double(targetFrame) / Double(max(1, totalFrames - 1))))
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
        self.shuttleStateText = "PAUSE"
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
        pause()
        guard slotA.player.currentItem != nil else { return }
        let currFrame = self.currentFrame
        let targetFrame = max(0, min(max(0, self.totalFrames - 1), currFrame + (forward ? 1 : -1)))
        guard targetFrame != currFrame else { return }
        
        self.currentFrame = targetFrame
        self.currentTimecode = TimecodeFormatter.format(frameIndex: targetFrame, fps: activeFps)
        if totalFrames > 0 {
            self.currentProgress = min(1.0, max(0.0, Double(targetFrame) / Double(max(1, totalFrames - 1))))
        }
        seek(toFrame: targetFrame)
    }
    
    public func stepSeconds(_ delta: Double) {
        pause()
        let currSecs = CMTimeGetSeconds(currentTime)
        let durSecs = CMTimeGetSeconds(duration)
        let targetSecs = min(max(0.0, currSecs + delta), durSecs)
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        seek(toTime: targetTime)
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
    
    /// High-performance interactive scrubbing: updates UI synchronously at 120 FPS lockstep with mouse drag
    public func scrubTo(progress: Double) {
        let clamped = min(1.0, max(0.0, progress))
        self.isScrubbing = true
        self.currentProgress = clamped
        
        let durSecs = CMTimeGetSeconds(duration)
        if durSecs > 0 {
            let currSecs = clamped * durSecs
            let fps = max(1.0, activeFps)
            let frameIdx = max(0, min(max(0, totalFrames - 1), Int(floor(currSecs * fps + 1e-4))))
            self.currentFrame = frameIdx
            self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
            
            let targetTime = CMTime(seconds: currSecs, preferredTimescale: 60000)
            self.currentTime = targetTime
            self.slotA.currentTime = targetTime
        }
        
        seek(toProgress: clamped)
    }
    
    /// Concludes interactive scrubbing: settles playhead and seeks to pixel-perfect frame with zero tolerance
    public func endScrubbing(at progress: Double) {
        let clamped = min(1.0, max(0.0, progress))
        self.isScrubbing = false
        self.currentProgress = clamped
        
        let durSecs = CMTimeGetSeconds(duration)
        if durSecs > 0 {
            let currSecs = clamped * durSecs
            let fps = max(1.0, activeFps)
            let frameIdx = max(0, min(max(0, totalFrames - 1), Int(floor(currSecs * fps + 1e-4))))
            self.currentFrame = frameIdx
            self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
            
            // Final exact frame seek with zero tolerance
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
    
    public func seek(toTime time: CMTime, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard slotA.player.currentItem != nil else {
            completion?()
            return
        }
        
        if isSeeking {
            pendingSeekTime = time
            if let completion = completion {
                pendingSeekCompletion = completion
            }
            return
        }
        
        isSeeking = true
        let curCompletion = completion
        
        // Fast seek during interactive scrubbing: 1-frame tolerance allows hardware decoder to stream at full speed
        // Exact frame seeks (pause, arrow keys, end of scrub) use .zero tolerance.
        let tol: CMTime = isScrubbing ? CMTime(seconds: 1.0 / max(1.0, activeFps), preferredTimescale: 60000) : .zero
        
        slotA.player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isSeeking = false
                
                // When not scrubbing, update time and progress (e.g. playback, jumps, frame step)
                // During scrubbing, scrubTo(progress:) already eagerly updates UI at 120 FPS
                if !self.isScrubbing && self.pendingSeekTime == nil {
                    self.updateCurrentTime(time: time)
                }
                
                if self.isLinked && self.slotB.url != nil && self.slotB.player.currentItem != nil {
                    let offsetSeconds = Double(self.slotB.slipOffsetFrames) / max(1.0, self.slotB.fps)
                    let targetSecsB = max(0.0, CMTimeGetSeconds(time) + offsetSeconds)
                    let targetTimeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
                    let tolB = self.isScrubbing ? CMTime(seconds: 1.0 / max(1.0, self.slotB.fps), preferredTimescale: 60000) : .zero
                    self.seekSlotB(to: targetTimeB, tolerance: tolB)
                }
                
                curCompletion?()
                
                if let nextTime = self.pendingSeekTime {
                    let nextComp = self.pendingSeekCompletion
                    self.pendingSeekTime = nil
                    self.pendingSeekCompletion = nil
                    self.seek(toTime: nextTime, completion: nextComp)
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
    
    public func resetPan() {
        self.panOffset = .zero
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
        seek(toTime: targetTime, completion: completion)
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
        let targetURL = (slot == .slotA) ? slotA.url : slotB.url
        guard let url = targetURL else { return nil }
        let targetTime = time ?? ((slot == .slotA) ? slotA.player.currentTime() : slotB.player.currentTime())
        return await Task.detached {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            do {
                let (cgImage, _) = try await gen.image(at: targetTime)
                return cgImage
            } catch {
                return nil
            }
        }.value
    }
    
    /// Exports the current video frame as a medium-quality JPEG (quality ~0.65)
    public func exportCurrentFrameAsJPEG(for slot: SlotTarget = .slotA, to destinationURL: URL, quality: CGFloat = 0.65) async throws {
        guard let cgImage = await captureCurrentFrame(for: slot) else {
            throw NSError(domain: "PlayerEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to capture video frame at current playhead."])
        }
        
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to JPEG format."])
        }
        
        try jpegData.write(to: destinationURL, options: .atomic)
    }
}
