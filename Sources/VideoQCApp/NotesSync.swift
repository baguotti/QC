import Foundation
import CryptoKit
import VideoQCLib

/// Syncs notes sidecars through the QCpie Cloudflare Worker (`server/notes-sync`).
/// Everything is derived from the shared password: the room id (server path), each clip id (HMAC of file name + size,
/// so collaborators can keep files anywhere) and the ChaChaPoly key, so the server only stores opaque blobs.
/// Only the clip whose notes are shown is polled; saves push immediately, failed pushes retry on the next poll.
actor NotesSync {
    static let shared = NotesSync()
    static let passwordKey = "notesSyncPassword"
    static let didMergeRemoteNotes = Notification.Name("QCpieNotesSyncDidMergeRemoteNotes")

    /// Posted on the main thread as the notification's `object` when a sync changed a clip's notes on disk.
    struct Change: Sendable {
        let url: URL
        let notes: [QCFileNote]
        /// The local notes the merge started from; edits made since are merged on top by the receiver.
        let localSnapshot: [QCFileNote]
    }

    struct Keys: Sendable {
        let room: String
        let clipKey: Data
        let sealKey: Data
    }

    /// Notes as of the last successful sync of a clip: the base of the three-way merge.
    private struct Base: Codable {
        var version: Int
        var notes: [QCFileNote]
    }

    private enum Remote {
        case unchanged
        case document(version: Int, data: Data?)
    }

    private enum SyncError: Error {
        case server(Int)
        case unreadable
        case conflict
    }

    private let pollInterval: Duration = .seconds(10)
    private var keys: Keys?
    private var activeURL: URL?
    private var pending: Set<URL> = []
    private var running: Set<URL> = []
    private var rerun: Set<URL> = []
    private var bases: [String: Base] = [:]
    private var pollTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    nonisolated static var isAvailable: Bool { AppConfig.notesSyncServerURL != nil }

    // MARK: - Configuration

    /// Applies the password from Settings (empty turns sync off) and starts or stops polling.
    func configure(password: String) {
        let newKeys = Self.deriveKeys(password: password)
        guard newKeys?.room != keys?.room else { return }
        keys = newKeys
        bases = [:]
        pending = []
        pollTask?.cancel()
        pollTask = nil
        guard newKeys != nil, Self.isAvailable else {
            Task { @MainActor in NotesSyncStatus.shared.update(Self.isAvailable ? .off : .unavailable) }
            return
        }
        Task { @MainActor in NotesSyncStatus.shared.update(.on) }
        pollTask = Task { [pollInterval] in
            while !Task.isCancelled {
                await self.poll()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// The clip whose notes are on screen: synced now and on every poll.
    func setActive(_ url: URL?) async {
        activeURL = url
        if let url { await sync(url) }
    }

    /// Call after notes were saved to disk.
    func push(_ url: URL) async {
        await sync(url)
    }

    private func poll() async {
        for url in pending.union(activeURL.map { [$0] } ?? []) {
            await sync(url)
        }
    }

    // MARK: - Sync

    private func sync(_ url: URL) async {
        guard let keys, Self.isAvailable else { return }
        if running.contains(url) {
            rerun.insert(url)
            return
        }
        running.insert(url)
        defer { running.remove(url) }
        repeat {
            rerun.remove(url)
            do {
                try await syncOnce(url, keys: keys)
                pending.remove(url)
                await MainActor.run { NotesSyncStatus.shared.update(.upToDate) }
            } catch is CancellationError {
                return
            } catch SyncError.unreadable {
                await MainActor.run { NotesSyncStatus.shared.update(.failed("Server notes can't be read with this password")) }
            } catch SyncError.server(let code) where code != 0 {
                pending.insert(url)
                await MainActor.run { NotesSyncStatus.shared.update(.failed("Server replied \(code)")) }
            } catch {
                pending.insert(url)
                await MainActor.run { NotesSyncStatus.shared.update(.offline) }
            }
        } while rerun.contains(url) && self.keys?.room == keys.room
    }

    private func syncOnce(_ url: URL, keys: Keys) async throws {
        guard let clip = Self.clipID(for: url, key: keys.clipKey) else { return }
        for _ in 0..<3 {
            let local = await QCNotesManager.shared.loadNotes(for: url)
            let base = loadBase(clip: clip, room: keys.room)
            let remote: Base
            switch try await fetch(room: keys.room, clip: clip, since: base?.version) {
            case .unchanged:
                guard let base else { throw SyncError.unreadable }
                if Set(local) == Set(base.notes) { return }
                remote = base
            case .document(let version, let data):
                remote = Base(version: version, notes: try data.map { try open($0, clip: clip, keys: keys) } ?? [])
            }

            let merged = QCNotesManager.threeWayMerge(local: local, remote: remote.notes, base: base?.notes ?? [])
            var version = remote.version
            if Set(merged) != Set(remote.notes) {
                do {
                    version = try await upload(seal(merged, clip: clip, keys: keys), room: keys.room, clip: clip, base: remote.version)
                } catch SyncError.conflict {
                    continue
                }
            }
            storeBase(Base(version: version, notes: merged), clip: clip, room: keys.room)
            if Set(merged) != Set(local) {
                let fps = await QCNotesManager.shared.storedFps(for: url) ?? 25.0
                await QCNotesManager.shared.saveNotes(merged, for: url, fps: fps)
                let change = Change(url: url, notes: merged, localSnapshot: local)
                await MainActor.run {
                    NotificationCenter.default.post(name: Self.didMergeRemoteNotes, object: change)
                    NotesSyncStatus.shared.noteReceived()
                }
            }
            return
        }
        throw SyncError.conflict
    }

    // MARK: - Server

    private func endpoint(room: String, clip: String, since: Int? = nil) -> URL? {
        guard let server = AppConfig.notesSyncServerURL,
              var components = URLComponents(url: server.appendingPathComponent("v1/\(room)/\(clip)"), resolvingAgainstBaseURL: false)
        else { return nil }
        if let since { components.queryItems = [URLQueryItem(name: "since", value: String(since))] }
        return components.url
    }

    private func fetch(room: String, clip: String, since: Int?) async throws -> Remote {
        guard let url = endpoint(room: room, clip: clip, since: since) else { throw SyncError.server(0) }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return .unchanged }
        guard status == 200 else { throw SyncError.server(status) }
        struct Payload: Decodable { let version: Int; let data: String? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let blob = payload.data else { return .document(version: payload.version, data: nil) }
        guard let sealed = Data(base64Encoded: blob) else { throw SyncError.unreadable }
        return .document(version: payload.version, data: sealed)
    }

    /// Returns the new version; throws `.conflict` when another Mac wrote first.
    private func upload(_ sealed: Data, room: String, clip: String, base: Int) async throws -> Int {
        guard let url = endpoint(room: room, clip: clip) else { throw SyncError.server(0) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["base": base, "data": sealed.base64EncodedString()] as [String: Any])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 { throw SyncError.conflict }
        guard status == 200 else { throw SyncError.server(status) }
        struct Payload: Decodable { let version: Int }
        return try JSONDecoder().decode(Payload.self, from: data).version
    }

    // MARK: - Crypto

    /// Accepts any password of 8+ characters, case-insensitive (generated ones are uppercase).
    nonisolated static func deriveKeys(password: String) -> Keys? {
        let normalized = password.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count >= 8 else { return nil }
        let ikm = SymmetricKey(data: Data(normalized.utf8))
        func derive(_ info: String, _ count: Int) -> Data {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data("qcpie-notes-sync-v1".utf8),
                                   info: Data(info.utf8), outputByteCount: count)
                .withUnsafeBytes { Data($0) }
        }
        return Keys(room: hex(derive("room", 16)), clipKey: derive("clip", 32), sealKey: derive("seal", 32))
    }

    /// 20 random characters (~100 bits) in groups of five, without look-alike characters.
    nonisolated static func generatePassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let chars = (0..<20).map { _ in alphabet.randomElement()! }
        return stride(from: 0, to: chars.count, by: 5).map { String(chars[$0..<$0 + 5]) }.joined(separator: "-")
    }

    private nonisolated static func clipID(for url: URL, key: Data) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(name)|\(size)".utf8), using: SymmetricKey(data: key))
        return mac.withUnsafeBytes { hex(Data($0)) }
    }

    private func seal(_ notes: [QCFileNote], clip: String, keys: Keys) throws -> Data {
        let box = try ChaChaPoly.seal(try encoder.encode(notes), using: SymmetricKey(data: keys.sealKey), authenticating: Data(clip.utf8))
        return box.combined
    }

    private func open(_ sealed: Data, clip: String, keys: Keys) throws -> [QCFileNote] {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: keys.sealKey), authenticating: Data(clip.utf8)),
              let notes = try? decoder.decode([QCFileNote].self, from: plain)
        else { throw SyncError.unreadable }
        return notes
    }

    private nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Base Store (Application Support/QCpie/NotesSync/<room>/<clip>.json)

    private func baseURL(clip: String, room: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QCpie/NotesSync/\(room)/\(clip).json")
    }

    private func loadBase(clip: String, room: String) -> Base? {
        if let cached = bases[clip] { return cached }
        guard let url = baseURL(clip: clip, room: room),
              let data = try? Data(contentsOf: url),
              let base = try? decoder.decode(Base.self, from: data)
        else { return nil }
        bases[clip] = base
        return base
    }

    private func storeBase(_ base: Base, clip: String, room: String) {
        bases[clip] = base
        guard let url = baseURL(clip: clip, room: room), let data = try? encoder.encode(base) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Sync state for the Settings section. Publishes only when the state changes (not on every poll).
@MainActor
final class NotesSyncStatus: ObservableObject {
    static let shared = NotesSyncStatus()

    enum State: Equatable {
        case unavailable
        case off
        case on
        case upToDate
        case offline
        case failed(String)
    }

    @Published private(set) var state: State = NotesSync.isAvailable ? .off : .unavailable
    @Published private(set) var lastReceived: Date?

    func update(_ newState: State) {
        if state != newState { state = newState }
    }

    func noteReceived() {
        lastReceived = Date()
    }
}
