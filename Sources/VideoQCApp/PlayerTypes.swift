import Foundation
import os
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
import UniformTypeIdentifiers
@preconcurrency import VideoToolbox
import VideoQCLib

// Types around PlayerEngine: slots, compare modes, frame extraction, transport snapshot, playback clock.
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
        // A capture can arrive before the load's `setURL` (separate tasks): never read the previous file's generator.
        let isStale = fallbackURL.map { $0.standardizedFileURL != currentURL?.standardizedFileURL } ?? false
        if generator == nil || isStale, let url = fallbackURL ?? currentURL {
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
    @Published public var mediaKind: MediaKind = .video
    /// Set when the slot plays an image sequence (mediaKind is then .video: it uses the normal video pipeline).
    public var sequence: ImageSequence? = nil
    /// The sequence's decoded-frame cache (shared with its compositor); paused frames are read from it directly.
    var sequenceSource: SequenceFrameSource? = nil
    /// Images and the audio info card: shown on the still frame layer instead of decoded video frames.
    public var stillImage: CGImage? = nil
    public var lastDecodedFrame: CGImage? = nil
    /// The file's modification date when it was loaded: the same path re-exported since is loaded again.
    var loadedModificationDate: Date? = nil
    /// The video track has a rotation / flip (portrait phone clips). Its frames only reach the video output upright
    /// through a video composition, so one stays installed at EV 0 too (pass-through).
    var isRotated = false
    
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
        guard let bytes = QCUtilities.fileSize(of: url) else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    
    /// Header line under the file name: images have no frame rate, audio has no picture size.
    public var infoLine: String {
        switch mediaKind {
        case .video: return "\(resolution) · \(QCUtilities.formatFPS(fps)) fps · \(codec)"
        case .image: return "\(resolution) · \(codec)"
        case .audio: return "Audio · \(codec)"
        }
    }
    
    public var displayResolution: String {
        if mediaKind == .audio { return "AUDIO" }
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
    public let showLegalZebra: Bool
    public let showLineMarks: Bool
    /// Line Check found lines in a loaded clip, A or B (the line-marks toggle shows only then).
    public let hasLineMarks: Bool
    public let legalRangePreset: String
    public let clipInfoOverlayMode: ClipInfoOverlayMode
    public let lastScreenshotPreset: ScreenshotPreset
    public let hasActiveURL: Bool
    public let notesCount: Int
    public let hasSubtitles: Bool
    public let showSubtitles: Bool
    /// Slot A can play/step/scrub (not a still image).
    public let hasTimeline: Bool
    /// Slot A is a video (exposure applies).
    public let hasVideo: Bool
    
    public init(
        isPlaying: Bool,
        rate: Float,
        isLooping: Bool,
        safeAreaMode: SafeAreaMode,
        isNineBySixteen: Bool,
        showCenterCrosshair: Bool,
        showLegalZebra: Bool,
        showLineMarks: Bool,
        hasLineMarks: Bool,
        legalRangePreset: String,
        clipInfoOverlayMode: ClipInfoOverlayMode,
        lastScreenshotPreset: ScreenshotPreset,
        hasActiveURL: Bool,
        notesCount: Int,
        hasSubtitles: Bool,
        showSubtitles: Bool,
        hasTimeline: Bool,
        hasVideo: Bool
    ) {
        self.isPlaying = isPlaying
        self.rate = rate
        self.isLooping = isLooping
        self.safeAreaMode = safeAreaMode
        self.isNineBySixteen = isNineBySixteen
        self.showCenterCrosshair = showCenterCrosshair
        self.showLegalZebra = showLegalZebra
        self.showLineMarks = showLineMarks
        self.hasLineMarks = hasLineMarks
        self.legalRangePreset = legalRangePreset
        self.clipInfoOverlayMode = clipInfoOverlayMode
        self.lastScreenshotPreset = lastScreenshotPreset
        self.hasActiveURL = hasActiveURL
        self.notesCount = notesCount
        self.hasSubtitles = hasSubtitles
        self.showSubtitles = showSubtitles
        self.hasTimeline = hasTimeline
        self.hasVideo = hasVideo
    }
}

/// Line Check's findings for one clip, by frame, for the Player's line marks. `size` is the decoded picture
/// (`naturalSize`, before rotation); detections are already in on-screen orientation.
public struct LineMarkFrames: Sendable {
    public let size: CGSize
    public let frames: [Int: [LineDetection]]
}

// MARK: - Playback Clock

/// Per-frame playhead state, published separately from `PlayerEngine.objectWillChange` so that only the
/// timecode readouts and the timeline playhead re-render at frame / scrub rate (not the whole view tree).
@MainActor
public final class PlaybackClock: ObservableObject {
    @Published public internal(set) var currentTimecode: String = "00:00:00:00"
    @Published public internal(set) var currentFrame: Int = 0
    @Published public internal(set) var currentProgress: Double = 0.0 // 0.0 ... 1.0
}

/// Exposure read by the video composition handler at render time, so EV changes never replace
/// `AVPlayerItem.videoComposition` (a replacement rebuilds the render pipeline and drops frames).
final class ExposureValueBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0.0)
    var value: Double { state.withLock { $0 } }
    func set(_ newValue: Double) { state.withLock { $0 = newValue } }
}
