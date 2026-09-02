import Foundation
import AVFoundation

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
    public let audioConfig: String
    public let container: String
    
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
        audioConfig: String,
        container: String
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
        self.audioConfig = audioConfig
        self.container = container
    }
}
