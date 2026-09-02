import Foundation
import CoreGraphics

public enum SubtitleRegion: String, CaseIterable, Identifiable, Sendable {
    case lowerThird = "Lower 35% (Standard Subs)"
    case center = "Center Screen"
    case fullFrame = "Full Frame"
    
    public var id: String { rawValue }
}

public enum VideoExpectedContent: String, Sendable {
    case cleanFeed = "CLEAN / TEXTLESS"
    case subtitled = "SUBTITLED / CAPTIONED"
    case unspecified = "STANDARD / UNSPECIFIED"
}

public struct TextDetection: Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let confidence: Float
    public let boundingBox: CGRect
    public let location: String
    
    public init(id: UUID = UUID(), text: String, confidence: Float, boundingBox: CGRect, location: String) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.location = location
    }
}

public struct LogoDetection: Identifiable, Sendable {
    public let id: UUID
    public let typeDescription: String
    public let location: String
    public let boundingBox: CGRect
    
    public init(id: UUID = UUID(), typeDescription: String, location: String, boundingBox: CGRect) {
        self.id = id
        self.typeDescription = typeDescription
        self.location = location
        self.boundingBox = boundingBox
    }
}

public struct SubtitleSegment: Identifiable, Sendable {
    public let id: UUID
    public let startFrame: Int
    public let endFrame: Int
    public let startTimecode: String
    public let endTimecode: String
    public let text: String
    public let location: String
    public let durationSeconds: Double
    public let frameCount: Int
    
    public init(
        id: UUID = UUID(),
        startFrame: Int,
        endFrame: Int,
        startTimecode: String,
        endTimecode: String,
        text: String,
        location: String,
        durationSeconds: Double,
        frameCount: Int
    ) {
        self.id = id
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTimecode = startTimecode
        self.endTimecode = endTimecode
        self.text = text
        self.location = location
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
    }
}

public struct LogoSegment: Identifiable, Sendable {
    public let id: UUID
    public let startFrame: Int
    public let endFrame: Int
    public let startTimecode: String
    public let endTimecode: String
    public let description: String
    public let location: String
    public let durationSeconds: Double
    public let frameCount: Int
    
    public init(
        id: UUID = UUID(),
        startFrame: Int,
        endFrame: Int,
        startTimecode: String,
        endTimecode: String,
        description: String,
        location: String,
        durationSeconds: Double,
        frameCount: Int
    ) {
        self.id = id
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTimecode = startTimecode
        self.endTimecode = endTimecode
        self.description = description
        self.location = location
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
    }
}

public struct VideoTextQCResult: Identifiable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let fileName: String
    public let totalFrames: Int
    public let durationSeconds: Double
    public let fps: Double
    public let resolution: String
    public let subtitleSegments: [SubtitleSegment]
    public let logoSegments: [LogoSegment]
    public let expectedContent: VideoExpectedContent
    public let isCleanViolation: Bool
    public let isMissingExpectedSubs: Bool
    public let statusSummary: String
    
    public var isFlagged: Bool {
        isCleanViolation || isMissingExpectedSubs || (!subtitleSegments.isEmpty && expectedContent == .cleanFeed) || (!logoSegments.isEmpty && expectedContent == .cleanFeed)
    }
    
    public var hasSubtitles: Bool {
        !subtitleSegments.isEmpty
    }
    
    public var hasLogos: Bool {
        !logoSegments.isEmpty
    }
    
    public init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String,
        totalFrames: Int,
        durationSeconds: Double,
        fps: Double,
        resolution: String,
        subtitleSegments: [SubtitleSegment],
        logoSegments: [LogoSegment],
        expectedContent: VideoExpectedContent,
        isCleanViolation: Bool,
        isMissingExpectedSubs: Bool,
        statusSummary: String
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.totalFrames = totalFrames
        self.durationSeconds = durationSeconds
        self.fps = fps
        self.resolution = resolution
        self.subtitleSegments = subtitleSegments
        self.logoSegments = logoSegments
        self.expectedContent = expectedContent
        self.isCleanViolation = isCleanViolation
        self.isMissingExpectedSubs = isMissingExpectedSubs
        self.statusSummary = statusSummary
    }
}

public struct TextQCConfig: Sendable {
    public var region: SubtitleRegion
    public var detectSubtitles: Bool
    public var detectLogos: Bool
    public var sampleRateFps: Double // e.g. 2.0 frames/sec for fast scanning
    public var strictCleanEnforcement: Bool
    
    public init(
        region: SubtitleRegion = .lowerThird,
        detectSubtitles: Bool = true,
        detectLogos: Bool = true,
        sampleRateFps: Double = 3.0,
        strictCleanEnforcement: Bool = true
    ) {
        self.region = region
        self.detectSubtitles = detectSubtitles
        self.detectLogos = detectLogos
        self.sampleRateFps = sampleRateFps
        self.strictCleanEnforcement = strictCleanEnforcement
    }
}
