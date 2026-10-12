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
    /// Set when the note text is edited after creation (absent in older files).
    public var editedAt: Date?
    /// Reply thread (absent in older files).
    public var replies: [QCNoteReply]
    
    public init(
        id: UUID = UUID(),
        frameIndex: Int,
        timecode: String,
        author: String,
        text: String,
        colorTag: String = "cyan",
        createdAt: Date = Date(),
        isResolved: Bool = false,
        editedAt: Date? = nil,
        replies: [QCNoteReply] = []
    ) {
        self.id = id
        self.frameIndex = frameIndex
        self.timecode = timecode
        self.author = author
        self.text = text
        self.colorTag = colorTag
        self.createdAt = createdAt
        self.isResolved = isResolved
        self.editedAt = editedAt
        self.replies = replies
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, frameIndex, timecode, author, text, colorTag, createdAt, isResolved, editedAt, replies
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        frameIndex = try c.decode(Int.self, forKey: .frameIndex)
        timecode = try c.decode(String.self, forKey: .timecode)
        author = try c.decode(String.self, forKey: .author)
        text = try c.decode(String.self, forKey: .text)
        colorTag = try c.decodeIfPresent(String.self, forKey: .colorTag) ?? "cyan"
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        isResolved = try c.decodeIfPresent(Bool.self, forKey: .isResolved) ?? false
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
        replies = try c.decodeIfPresent([QCNoteReply].self, forKey: .replies) ?? []
    }
}

/// A reply in a note's discussion thread.
public struct QCNoteReply: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var author: String
    public var text: String
    public var createdAt: Date
    
    public init(id: UUID = UUID(), author: String, text: String, createdAt: Date = Date()) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
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
