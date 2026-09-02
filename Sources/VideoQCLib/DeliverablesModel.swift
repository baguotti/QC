import Foundation
import AVFoundation

public struct DeliverableValidation: Equatable, Sendable {
    public let isDurationMismatch: Bool
    public let expectedDurationSeconds: Double?
    public let durationMismatchDetail: String?
    
    public let isRatioMismatch: Bool
    public let expectedRatioString: String?
    public let ratioMismatchDetail: String?
    
    public var hasAnyMismatch: Bool {
        isDurationMismatch || isRatioMismatch
    }
    
    public var summaryString: String {
        if !hasAnyMismatch { return "MATCHED" }
        var parts: [String] = []
        if let d = durationMismatchDetail { parts.append(d) }
        if let r = ratioMismatchDetail { parts.append(r) }
        return parts.joined(separator: " • ")
    }
    
    public init(
        isDurationMismatch: Bool = false,
        expectedDurationSeconds: Double? = nil,
        durationMismatchDetail: String? = nil,
        isRatioMismatch: Bool = false,
        expectedRatioString: String? = nil,
        ratioMismatchDetail: String? = nil
    ) {
        self.isDurationMismatch = isDurationMismatch
        self.expectedDurationSeconds = expectedDurationSeconds
        self.durationMismatchDetail = durationMismatchDetail
        self.isRatioMismatch = isRatioMismatch
        self.expectedRatioString = expectedRatioString
        self.ratioMismatchDetail = ratioMismatchDetail
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
    public let container: String
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
        container: String,
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
        self.container = container
        self.validation = validation
    }
}
