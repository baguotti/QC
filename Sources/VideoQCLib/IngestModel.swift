import Foundation
import CoreMedia

// MARK: - Ingest File Classification

public enum IngestFileCategory: String, CaseIterable, Sendable, Codable {
    case rawFootage = "Raw Footage"
    case transcode = "Transcode"
    case cameraReport = "Camera Report"
    case locationAudio = "Location Audio"
    case lut = "Shooting LUT"
    case other = "Other"
    
    public var iconName: String {
        switch self {
        case .rawFootage: return "film"
        case .transcode: return "play.rectangle"
        case .cameraReport: return "doc.text"
        case .locationAudio: return "waveform"
        case .lut: return "paintpalette"
        case .other: return "doc"
        }
    }
}

// MARK: - Ingest Media Metadata

public struct IngestMediaMetadata: Sendable, Codable, Equatable {
    public let width: Int
    public let height: Int
    public let resolutionString: String
    public let aspectRatioString: String
    public let fps: Double
    public let durationSeconds: Double
    public let formattedDuration: String
    public let totalFrames: Int
    public let timecode: String
    public let videoCodec: String
    public let audioCodec: String
    public let audioConfig: String
    public let cameraMakeModel: String?
    public let container: String
    public let creationDate: Date?
    public let formattedCreationDate: String
    
    public init(
        width: Int,
        height: Int,
        resolutionString: String,
        aspectRatioString: String,
        fps: Double,
        durationSeconds: Double,
        formattedDuration: String,
        totalFrames: Int,
        timecode: String,
        videoCodec: String,
        audioCodec: String = "NONE",
        audioConfig: String = "NONE",
        cameraMakeModel: String? = nil,
        container: String,
        creationDate: Date? = nil,
        formattedCreationDate: String = "--"
    ) {
        self.width = width
        self.height = height
        self.resolutionString = resolutionString
        self.aspectRatioString = aspectRatioString
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.formattedDuration = formattedDuration
        self.totalFrames = totalFrames
        self.timecode = timecode
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioConfig = audioConfig
        self.cameraMakeModel = cameraMakeModel
        self.container = container
        self.creationDate = creationDate
        self.formattedCreationDate = formattedCreationDate
    }
}

// MARK: - Ingest Item

public struct IngestItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let fileURL: URL
    public let relativePath: String
    public let fileName: String
    public let fileSizeBytes: Int64
    public let formattedFileSize: String
    public var fileCategory: IngestFileCategory
    public let mediaMetadata: IngestMediaMetadata?
    
    public init(
        id: UUID = UUID(),
        fileURL: URL,
        relativePath: String,
        fileName: String,
        fileSizeBytes: Int64,
        formattedFileSize: String,
        fileCategory: IngestFileCategory,
        mediaMetadata: IngestMediaMetadata? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.formattedFileSize = formattedFileSize
        self.fileCategory = fileCategory
        self.mediaMetadata = mediaMetadata
    }
}

// MARK: - Ingest Manifest

public struct IngestManifest: Sendable, Equatable {
    // 1. Job Header
    public var jobName: String = ""
    public var ingestedBy: String = ""
    public var dateIngested: Date = Date()
    public var receivedVia: String = "DROPBOX"
    public var addedToClientDrives: Bool = false
    
    // 2. Elements Received (Toggles)
    public var hasRawFootage: Bool = false
    public var hasTranscodes: Bool = false
    public var hasCameraReports: Bool = false
    public var hasLocationAudio: Bool = false
    public var hasShootingLUTs: Bool = false
    
    // 3. Footage Details
    public var rawMediaCodec: String = ""
    public var transcodeCodec: String = ""
    public var cameraUsed: String = ""
    public var shootingResolution: String = ""
    public var mainFPS: String = ""
    
    // 4. VFX & Physical Source
    public var isVFXProject: Bool = false
    public var hdSource: String = ""
    
    // 5. General Notes / Flags
    public var flagNotes: String = ""
    
    // 6. Collected Items
    public var items: [IngestItem] = []
    
    public init() {}
}

// MARK: - DIT Report Record

public struct IngestDITRecord: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let fileName: String
    public let fields: [String: String]
    
    public init(id: UUID = UUID(), fileName: String, fields: [String: String]) {
        self.id = id
        self.fileName = fileName
        self.fields = fields
    }
    
    public var fps: String? {
        fields.first { key, _ in
            let k = key.lowercased()
            return k == "fps" || k == "frame rate" || k == "framerate" || k == "fps/timebase"
        }?.value
    }
    
    public var resolution: String? {
        fields.first { key, _ in
            let k = key.lowercased()
            return k == "resolution" || k == "res" || k == "dimensions" || k == "size"
        }?.value
    }
    
    public var codec: String? {
        fields.first { key, _ in
            let k = key.lowercased()
            return k == "codec" || k == "format" || k == "compression"
        }?.value
    }
    
    public var duration: String? {
        fields.first { key, _ in
            let k = key.lowercased()
            return k == "duration" || k == "time" || k == "tc" || k == "length"
        }?.value
    }
}

// MARK: - Ingest Discrepancy Flag

public enum FlagSeverity: String, Sendable, CaseIterable {
    case critical = "CRITICAL"
    case warning = "WARNING"
    case info = "INFO"
    
    public var sortOrder: Int {
        switch self {
        case .critical: return 0
        case .warning: return 1
        case .info: return 2
        }
    }
}

public struct IngestFlag: Identifiable, Sendable, Equatable {
    public let id: String
    public let severity: FlagSeverity
    public let title: String
    public let detail: String
    public let fileName: String
    
    public init(severity: FlagSeverity, title: String, detail: String, fileName: String) {
        self.id = "\(severity.rawValue):\(fileName):\(title)"
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fileName = fileName
    }
}
