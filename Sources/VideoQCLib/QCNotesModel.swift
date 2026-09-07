import Foundation

/// A single timecoded review note associated with a specific frame of a media file.
public struct QCFileNote: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var frameIndex: Int
    public var timecode: String
    public var author: String
    public var text: String
    public var colorTag: String
    public var createdAt: Date
    public var isResolved: Bool
    
    public init(
        id: UUID = UUID(),
        frameIndex: Int,
        timecode: String,
        author: String,
        text: String,
        colorTag: String = "cyan",
        createdAt: Date = Date(),
        isResolved: Bool = false
    ) {
        self.id = id
        self.frameIndex = frameIndex
        self.timecode = timecode
        self.author = author
        self.text = text
        self.colorTag = colorTag
        self.createdAt = createdAt
        self.isResolved = isResolved
    }
}

/// The document structure serialized into the companion `.qcnotes` sidecar JSON file.
public struct QCNotesDocument: Codable, Sendable {
    public var version: Int
    public var mediaFileName: String
    public var fps: Double
    public var lastModified: Date
    public var notes: [QCFileNote]
    
    public init(
        version: Int = 1,
        mediaFileName: String,
        fps: Double,
        lastModified: Date = Date(),
        notes: [QCFileNote] = []
    ) {
        self.version = version
        self.mediaFileName = mediaFileName
        self.fps = fps
        self.lastModified = lastModified
        self.notes = notes
    }
}
