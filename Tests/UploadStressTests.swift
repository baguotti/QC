import Foundation
import Testing
@testable import QCpie

/// Frame.io with a round-trip time on every call, counting how many creates run at once.
actor SlowFrameIO: UploadAPI {
    let base: FakeFrameIO
    let latency: Duration
    private(set) var creating = 0
    private(set) var peakCreating = 0
    private(set) var statusCalls = 0
    private(set) var listings = 0

    init(base: FakeFrameIO, latency: Duration) {
        self.base = base
        self.latency = latency
    }

    func createLocalUpload(account: String, folder: String, name: String, size: Int64) async throws -> FrameIO.LocalUpload {
        creating += 1
        peakCreating = max(peakCreating, creating)
        defer { creating -= 1 }
        try await Task.sleep(for: latency)
        return try await base.createLocalUpload(account: account, folder: folder, name: name, size: size)
    }
    func deleteFile(account: String, id: String) async throws { try await base.deleteFile(account: account, id: id) }
    func uploadStatus(account: String, id: String) async throws -> FrameIO.UploadStatus {
        statusCalls += 1
        try await Task.sleep(for: latency)
        return try await base.uploadStatus(account: account, id: id)
    }
    func createFolder(account: String, parent: String, name: String) async throws -> FrameIO.Item {
        try await Task.sleep(for: latency)
        return try await base.createFolder(account: account, parent: parent, name: name)
    }
    func children(account: String, folder: String, thumbnails: Bool) async throws -> [FrameIO.Item] {
        listings += 1
        try await Task.sleep(for: latency)
        return try await base.children(account: account, folder: folder, thumbnails: thumbnails)
    }
}

final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UploadOutcome: Int] = [:]
    private var started = 0
    func start() { lock.withLock { started += 1 } }
    func finish(_ outcome: UploadOutcome) { lock.withLock { counts[outcome, default: 0] += 1 } }
    var startedCount: Int { lock.withLock { started } }
    func count(_ outcome: UploadOutcome) -> Int { lock.withLock { counts[outcome] ?? 0 } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
}

extension UploadOutcome: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .uploaded: hasher.combine(0)
        case .skipped: hasher.combine(1)
        case .cancelled: hasher.combine(2)
        case .failed(let message): hasher.combine(3); hasher.combine(message)
        }
    }
}

// Nested in the serialized upload suite: both use `StubStorage`'s shared state, so they mustn't run at the same time.
extension UploadEngineTests {
@Suite("Upload engine at scale")
struct Stress {
    static let partSize: Int64 = 256 * 1024

    /// `count` files of `bytes` each in `folders` subfolders of a temporary folder.
    private func makeFiles(count: Int, bytes: Int, folders: Int) throws -> [(url: URL, folder: String)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stress-\(UUID().uuidString)")
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        return try (0..<count).map { index in
            let folder = "Sub \(index % max(1, folders))"
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(String(format: "clip_%04d.mov", index))
            try data.write(to: url)
            return (url, folder)
        }
    }

    private func item(_ name: String, size: Int64) throws -> FrameIO.Item {
        let json: [String: Any] = ["id": "old-\(name)", "name": name, "type": "file", "file_size": size, "status": "uploaded"]
        return try JSONDecoder().decode(FrameIO.Item.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("Hundreds of files: every one arrives, file and stream limits hold, already-uploaded ones are skipped")
    func hundredsOfFiles() async throws {
        StubStorage.reset()
        StubStorage.delay = 0.02
        let small = try makeFiles(count: 400, bytes: 64 * 1024, folders: 1)
        let large = try makeFiles(count: 6, bytes: Int(Self.partSize) * 6 + 99, folders: 1)
        // The destination already holds 3,000 other files plus 50 of these (same name and size: skipped).
        let base = FakeFrameIO(partSize: Self.partSize)
        var existing = try (0..<3000).map { try item("other_\($0).mov", size: 1234) }
        existing += try small.prefix(50).map { try item($0.url.lastPathComponent, size: 64 * 1024) }
        await base.setExisting(existing)
        let api = SlowFrameIO(base: base, latency: .milliseconds(30))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stress-store-\(UUID().uuidString)")
        let store = UploadResumeStore(directory: directory)
        var limits = UploadEngine.Limits()
        limits.maxBackoff = 0.01
        limits.tuneInterval = 60
        limits.createInterval = .zero   // the pacing has its own test
        let engine = UploadEngine(api: api, session: UploadEngine.makeSession(protocolClasses: [StubStorage.self]), store: store,
                                  progress: UploadProgress(), network: OnlineNetwork(), limits: limits)
        let work = (small + large).map {
            UploadWork(jobID: UUID(), files: [$0.url], sizes: [Int64((try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)], folders: [])
        }
        let box = CountBox()
        let clock = ContinuousClock()
        let started = clock.now
        await engine.run(work, account: "acc", folder: "root",
                         onStart: { _ in box.start() }, onFinish: { _, outcome in box.finish(outcome) })
        let elapsed = clock.now - started
        let peakCreates = await api.peakCreating
        let listings = await api.listings
        print("STRESS \(work.count) files in \(elapsed); peak creates \(peakCreates), peak PUTs \(StubStorage.peakInFlight), listings \(listings)")

        #expect(box.total == work.count)
        #expect(box.count(.uploaded) == work.count - 50)
        #expect(box.count(.skipped) == 50)
        #expect(peakCreates <= limits.maxFiles)
        #expect(StubStorage.peakInFlight <= limits.maxStreams)
        #expect(listings == 1)   // the destination is listed once, not per file
        #expect(await store.snapshot.files.isEmpty)
    }

    @Test("Creates are paced to Frame.io's 5 a second, however many files are waiting")
    func createPacing() async throws {
        StubStorage.reset()
        let files = try makeFiles(count: 16, bytes: 4096, folders: 1)
        let api = SlowFrameIO(base: FakeFrameIO(partSize: Self.partSize), latency: .milliseconds(1))
        var limits = UploadEngine.Limits()
        limits.tuneInterval = 60
        let engine = UploadEngine(api: api, session: UploadEngine.makeSession(protocolClasses: [StubStorage.self]),
                                  store: UploadResumeStore(directory: nil), progress: UploadProgress(), network: OnlineNetwork(),
                                  limits: limits)
        let box = CountBox()
        let clock = ContinuousClock()
        let started = clock.now
        await engine.run(files.map { UploadWork(jobID: UUID(), files: [$0.url], sizes: [4096], folders: []) },
                         account: "acc", folder: "root", onStart: { _ in }, onFinish: { _, outcome in box.finish(outcome) })
        let elapsed = clock.now - started
        #expect(box.count(.uploaded) == 16)
        // 16 creates at least 210 ms apart: 15 gaps.
        #expect(elapsed >= .milliseconds(15 * 210))
    }
}
}
