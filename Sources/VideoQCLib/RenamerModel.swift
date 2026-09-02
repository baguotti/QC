import Foundation

public enum RenameMode: String, CaseIterable, Identifiable, Sendable {
    case template = "TEMPLATE"
    case findReplace = "FIND & REPLACE"
    case addText = "PREFIX / SUFFIX"
    
    public var id: String { rawValue }
}

public enum TextCaseOption: String, CaseIterable, Identifiable, Sendable {
    case uppercase = "UPPERCASE"
    case lowercase = "LOWERCASE"
    case capitalized = "TITLE CASE"
    case original = "ORIGINAL CASE"
    
    public var id: String { rawValue }
}

public enum RenameStatus: Equatable, Sendable {
    case pending
    case unchanged
    case excluded
    case collision(String)
    case renamed
    case error(String)
    
    public var badgeText: String {
        switch self {
        case .pending: return "READY"
        case .unchanged: return "NO CHANGE"
        case .excluded: return "EXCLUDED"
        case .collision(let reason): return "COLLISION: \(reason.uppercased())"
        case .renamed: return "RENAMED"
        case .error(let err): return "ERROR: \(err.uppercased())"
        }
    }
    
    public var isErrorOrCollision: Bool {
        switch self {
        case .collision, .error: return true
        default: return false
        }
    }
}

public struct RenameItem: Identifiable, Sendable {
    public let id: UUID
    public let asset: DeliverableAsset
    public let originalURL: URL
    public let originalName: String
    public let originalExtension: String
    public var proposedName: String
    public var proposedFullName: String {
        originalExtension.isEmpty ? proposedName : "\(proposedName).\(originalExtension)"
    }
    public var targetURL: URL {
        originalURL.deletingLastPathComponent().appendingPathComponent(proposedFullName)
    }
    public var status: RenameStatus
    public var collisionDetail: String?
    
    public init(
        id: UUID? = nil,
        asset: DeliverableAsset,
        originalURL: URL,
        originalName: String,
        originalExtension: String,
        proposedName: String,
        status: RenameStatus = .pending,
        collisionDetail: String? = nil
    ) {
        self.id = id ?? asset.id
        self.asset = asset
        self.originalURL = originalURL
        self.originalName = originalName
        self.originalExtension = originalExtension
        self.proposedName = proposedName
        self.status = status
        self.collisionDetail = collisionDetail
    }
}

public struct RenameTransaction: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let entries: [(oldURL: URL, newURL: URL)]
    
    public init(id: UUID = UUID(), timestamp: Date = Date(), entries: [(oldURL: URL, newURL: URL)]) {
        self.id = id
        self.timestamp = timestamp
        self.entries = entries
    }
}
