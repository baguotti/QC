import Foundation
import AVFoundation

public struct DeliverableValidation: Equatable, Sendable {
    public let isDurationMismatch: Bool
    public let expectedDurationSeconds: Double?
    public let durationMismatchDetail: String?
    
    public let isRatioMismatch: Bool
    public let expectedRatioString: String?
    public let ratioMismatchDetail: String?
    
    public let isAudioMute: Bool
    public let audioMuteDetail: String?
    
    public var hasAnyMismatch: Bool {
        isDurationMismatch || isRatioMismatch
    }
    
    public var summaryString: String {
        var parts: [String] = []
        if let d = durationMismatchDetail { parts.append(d) }
        if let r = ratioMismatchDetail { parts.append(r) }
        if parts.isEmpty {
            return isAudioMute ? (audioMuteDetail ?? "MUTE") : "MATCHED"
        }
        if let a = audioMuteDetail { parts.append(a) }
        return parts.joined(separator: " • ")
    }
    
    public init(
        isDurationMismatch: Bool = false,
        expectedDurationSeconds: Double? = nil,
        durationMismatchDetail: String? = nil,
        isRatioMismatch: Bool = false,
        expectedRatioString: String? = nil,
        ratioMismatchDetail: String? = nil,
        isAudioMute: Bool = false,
        audioMuteDetail: String? = nil
    ) {
        self.isDurationMismatch = isDurationMismatch
        self.expectedDurationSeconds = expectedDurationSeconds
        self.durationMismatchDetail = durationMismatchDetail
        self.isRatioMismatch = isRatioMismatch
        self.expectedRatioString = expectedRatioString
        self.ratioMismatchDetail = ratioMismatchDetail
        self.isAudioMute = isAudioMute
        self.audioMuteDetail = audioMuteDetail
    }
}

/// Column sort options for Deliverables Specs Table (Finder-like sorting)
public enum SpecsSortColumn: String, CaseIterable, Equatable, Sendable {
    case name = "name"
    case timecode = "timecode"
    case ratio = "ratio"
    case fps = "fps"
    case size = "size"
    case date = "date"
    case videoCodec = "videoCodec"
    case audioCodec = "audioCodec"
    case path = "path"
    
    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .timecode: return "Timecode / Duration"
        case .ratio: return "Ratio & Size"
        case .fps: return "Frame Rate (FPS)"
        case .size: return "File Size"
        case .date: return "Creation Date"
        case .videoCodec: return "Video Codec"
        case .audioCodec: return "Audio Spec"
        case .path: return "File Path"
        }
    }
}

public struct DeliverableAsset: Identifiable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let fileName: String
    public let fileSizeBytes: Int64
    public let formattedFileSize: String
    public let width: Int
    public let height: Int
    public let resolutionString: String
    public let aspectRatioString: String
    public let durationSeconds: Double
    public let formattedDuration: String
    public let totalFrames: Int
    public let timecode: String
    public let fps: Double
    public let videoCodec: String
    public let audioCodec: String
    public let audioBitrate: String
    public let audioFormatDetail: String
    public let audioConfig: String
    public let audioPeakDB: Double?
    public let audioLevelString: String
    public let isAudioMute: Bool
    public let container: String
    public let creationDate: Date?
    public let formattedCreationDate: String
    public let hasSubtitles: Bool
    public let subtitlesInfo: String
    public let validation: DeliverableValidation
    
    public var hasAudio: Bool {
        audioConfig != "NONE" && audioCodec != "NONE"
    }
    
    public init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String,
        fileSizeBytes: Int64,
        formattedFileSize: String,
        width: Int,
        height: Int,
        resolutionString: String,
        aspectRatioString: String,
        durationSeconds: Double,
        formattedDuration: String,
        totalFrames: Int,
        timecode: String,
        fps: Double,
        videoCodec: String,
        audioCodec: String = "NONE",
        audioBitrate: String = "--",
        audioFormatDetail: String = "",
        audioConfig: String,
        audioPeakDB: Double? = nil,
        audioLevelString: String = "--",
        isAudioMute: Bool = false,
        container: String,
        creationDate: Date? = nil,
        formattedCreationDate: String = "--",
        hasSubtitles: Bool = false,
        subtitlesInfo: String = "NONE",
        validation: DeliverableValidation = DeliverableValidation()
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.formattedFileSize = formattedFileSize
        self.width = width
        self.height = height
        self.resolutionString = resolutionString
        self.aspectRatioString = aspectRatioString
        self.durationSeconds = durationSeconds
        self.formattedDuration = formattedDuration
        self.totalFrames = totalFrames
        self.timecode = timecode
        self.fps = fps
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.audioFormatDetail = audioFormatDetail
        self.audioConfig = audioConfig
        self.audioPeakDB = audioPeakDB
        self.audioLevelString = audioLevelString
        self.isAudioMute = isAudioMute
        self.container = container
        self.creationDate = creationDate
        self.formattedCreationDate = formattedCreationDate
        self.hasSubtitles = hasSubtitles
        self.subtitlesInfo = subtitlesInfo
        self.validation = validation
    }
}
