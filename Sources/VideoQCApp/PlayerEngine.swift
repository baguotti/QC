import Foundation
import AVFoundation
import Combine
import CoreMedia
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

@MainActor
public final class PlayerEngine: ObservableObject {
    
    // MARK: - Published Properties
    
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
            player.volume = isMuted ? 0.0 : volume
        }
    }
    @Published public var isMuted: Bool = false {
        didSet {
            player.volume = isMuted ? 0.0 : volume
        }
    }
    
    @Published public var shuttleStateText: String = "PAUSE"
    @Published public var isScrubbing: Bool = false
    
    // MARK: - Internal AVPlayer
    
    public let player = AVPlayer()
    
    private final class TokenBox: @unchecked Sendable {
        var timeObserverToken: Any? = nil
    }
    private let tokens = TokenBox()
    private var cancellables = Set<AnyCancellable>()
    
    private var isSeeking: Bool = false
    private var pendingSeekTime: CMTime? = nil
    
    public init() {
        setupTimeObserver()
        setupEndObserver()
    }
    
    deinit {
        if let token = tokens.timeObserverToken {
            player.removeTimeObserver(token)
        }
    }
    
    // MARK: - Asset Loading
    
    public func loadVideo(url: URL, initialSeekFrame: Int? = nil) {
        self.activeMarkers = markersMap[url] ?? []
        
        if activeURL == url {
            if let frame = initialSeekFrame {
                seek(toFrame: frame)
            }
            return
        }
        
        self.pendingInitialSeekFrame = initialSeekFrame
        player.pause()
        self.rate = 0.0
        self.isPlaying = false
        self.shuttleStateText = "PAUSE"
        
        self.activeURL = url
        self.activeFileName = url.lastPathComponent
        self.currentTime = .zero
        self.currentProgress = 0.0
        self.currentTimecode = "00:00:00:00"
        self.panOffset = .zero
        
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        
        Task {
            await extractMetadata(asset: asset)
        }
    }
    
    private func extractMetadata(asset: AVURLAsset) async {
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
                if nominalRate > 1.0 {
                    detectedFps = Double(nominalRate)
                }
                
                let descriptions = try await vTrack.load(.formatDescriptions)
                if let firstDesc = descriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    codecStr = fourCCToString(subType)
                }
            }
            
            let durSecs = CMTimeGetSeconds(dur)
            let roundedFps = max(1.0, detectedFps)
            let totFrames = Int(round(durSecs * roundedFps))
            
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
    
    // MARK: - Time Observers
    
    private func setupTimeObserver() {
        let interval = CMTime(value: 1, timescale: 60)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self, !self.isScrubbing else { return }
                self.updateCurrentTime(time: time)
            }
        }
        tokens.timeObserverToken = token
    }
    
    private func updateCurrentTime(time: CMTime) {
        self.currentTime = time
        let durSecs = CMTimeGetSeconds(duration)
        let currSecs = CMTimeGetSeconds(time)
        
        if durSecs > 0 {
            self.currentProgress = min(1.0, max(0.0, currSecs / durSecs))
        } else {
            self.currentProgress = 0.0
        }
        
        let frameIdx = Int(round(currSecs * max(1.0, activeFps)))
        self.currentFrame = frameIdx
        self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
        
        // Reverse playback loop handling
        if self.rate < 0 && currSecs <= 0.05 && self.isLooping && durSecs > 0.5 {
            self.seek(toProgress: 0.999) { [weak self] in
                guard let self = self else { return }
                self.player.rate = self.rate
            }
        }
    }
    
    private func setupEndObserver() {
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let item = notification.object as? AVPlayerItem, item == self.player.currentItem {
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
        guard player.currentItem != nil else { return }
        
        // If at the end, restart from beginning
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
        guard player.currentItem != nil else { return }
        
        // If at the beginning and looping, wrap to end
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
        guard player.currentItem != nil else { return }
        
        // Stop normal hardware playback
        player.pause()
        self.rate = 0.0
        
        if slowStepTimer == nil {
            // First press: start very slowly forward (2 fps)
            slowDirection = .forward
            slowSpeedIndex = 0
        } else if slowDirection == .forward {
            // Further presses accelerate the frame-by-frame speed
            slowSpeedIndex = min(slowSpeeds.count - 1, slowSpeedIndex + 1)
        } else {
            // In reverse: reduce reverse speed or switch to forward
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
        guard player.currentItem != nil else { return }
        
        // Stop normal hardware playback
        player.pause()
        self.rate = 0.0
        
        if slowStepTimer == nil {
            // First press: start very slowly in reverse (2 fps)
            slowDirection = .reverse
            slowSpeedIndex = 0
        } else if slowDirection == .reverse {
            // Further presses accelerate the reverse frame-by-frame speed
            slowSpeedIndex = min(slowSpeeds.count - 1, slowSpeedIndex + 1)
        } else {
            // In forward: reduce forward speed or switch to reverse
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
        
        // Step the first frame immediately
        executeSingleFrameStep(forward: isFwd)
        
        slowStepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.executeSingleFrameStep(forward: isFwd)
            }
        }
    }
    
    private func executeSingleFrameStep(forward: Bool) {
        guard let item = player.currentItem else { return }
        let durSecs = CMTimeGetSeconds(duration)
        let currSecs = CMTimeGetSeconds(currentTime)
        let frameDuration = 1.0 / max(1.0, activeFps)
        
        // Boundary checking and loop wrap-around
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
        
        let step = forward ? 1 : -1
        item.step(byCount: step)
        let newSecs = max(0.0, min(durSecs, currSecs + Double(step) * frameDuration))
        updateCurrentTime(time: CMTime(seconds: newSecs, preferredTimescale: 600))
    }
    
    public func togglePlayPause() {
        if isSlowStepping || rate != 0.0 {
            pause()
        } else {
            pressL()
        }
    }
    
    public func pause() {
        stopSlowStep()
        player.pause()
        self.rate = 0.0
        self.isPlaying = false
        self.shuttleStateText = "PAUSE"
    }
    
    private func setPlaybackRate(_ newRate: Float) {
        stopSlowStep()
        self.rate = newRate
        self.isPlaying = (newRate != 0.0)
        player.rate = newRate
        
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
        guard let item = player.currentItem else { return }
        item.step(byCount: forward ? 1 : -1)
        updateCurrentTime(time: item.currentTime())
    }
    
    public func stepSeconds(_ delta: Double) {
        pause()
        let currSecs = CMTimeGetSeconds(currentTime)
        let durSecs = CMTimeGetSeconds(duration)
        let targetSecs = min(max(0.0, currSecs + delta), durSecs)
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 600)
        seek(toTime: targetTime)
    }
    
    public func jumpToBeginning() {
        pause()
        seek(toTime: .zero)
    }
    
    public func jumpToEnd() {
        pause()
        seek(toTime: duration)
    }
    
    // MARK: - Scrubbing & Seeking
    
    public func seek(toProgress progress: Double, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let durSecs = CMTimeGetSeconds(duration)
        guard durSecs > 0 else { return }
        let clamped = min(1.0, max(0.0, progress))
        let targetSecs = clamped * durSecs
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 600)
        seek(toTime: targetTime, completion: completion)
    }
    
    public func seek(toTime time: CMTime, completion: (@MainActor @Sendable () -> Void)? = nil) {
        if isSeeking {
            pendingSeekTime = time
            return
        }
        
        isSeeking = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isSeeking = false
                self.updateCurrentTime(time: time)
                completion?()
                
                if let nextTime = self.pendingSeekTime {
                    self.pendingSeekTime = nil
                    self.seek(toTime: nextTime)
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
        let targetSecs = Double(frameIndex) / fps
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 600)
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
    
    // MARK: - Pixel-Perfect Still Frame Capture
    
    public func captureCurrentFrame(at time: CMTime? = nil) async -> CGImage? {
        guard let url = activeURL else { return nil }
        let target = time ?? currentTime
        return await Task.detached {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            do {
                let (cgImage, _) = try await gen.image(at: target)
                return cgImage
            } catch {
                return nil
            }
        }.value
    }
}
