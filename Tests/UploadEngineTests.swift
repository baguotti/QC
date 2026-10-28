import Foundation
import Testing
@testable import QCpie

// MARK: - Simulated storage server

/// Pre-signed part URLs of `FakeFrameIO` are answered here: bodies are kept per URL path, and a scripted list of
/// failures per part (`URLError` codes or HTTP statuses) is played before the part succeeds.
final class StubStorage: URLProtocol, @unchecked Sendable {
    enum Failure: Sendable { case network(URLError.Code), status(Int, String) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var failures: [String: [Failure]] = [:]
    nonisolated(unsafe) private static var attempts: [String: Int] = [:]
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var onRequest: (@Sendable (String) -> Void)?

    static func reset() {
        lock.withLock { bodies = [:]; failures = [:]; attempts = [:]; delay = 0; onRequest = nil }
    }

    static func fail(_ path: String, with list: [Failure]) { lock.withLock { failures[path] = list } }
    static func body(_ path: String) -> Data? { lock.withLock { bodies[path] } }
    static func attempts(_ path: String) -> Int { lock.withLock { attempts[path] ?? 0 } }
    static var receivedPaths: Set<String> { lock.withLock { Set(bodies.keys) } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "s3.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.read(request)
        let delay = Self.lock.withLock { Self.delay }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let failure: Failure? = Self.lock.withLock {
                Self.attempts[path, default: 0] += 1
                guard var list = Self.failures[path], !list.isEmpty else { return nil }
                let first = list.removeFirst()
                Self.failures[path] = list
                return first
            }
            Self.lock.withLock { Self.onRequest }?(path)
            switch failure {
            case .network(let code)?:
                client?.urlProtocol(self, didFailWithError: URLError(code))
            case .status(let status, let text)?:
                respond(status, text)
            case nil:
                Self.lock.withLock { Self.bodies[path] = body }
                respond(200, "")
            }
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ text: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

// MARK: - Fake Frame.io

actor FakeFrameIO: UploadAPI {
    let partSize: Int64
    var expiresIn: Int = 3600
    private(set) var created: [String] = []
    private(set) var deleted: [String] = []
    var existing: [FrameIO.Item] = []
    /// The next create reaches "Frame.io" (a placeholder appears in the folder) but its reply is lost.
    var loseNextCreateReply = false
    /// Deletes fail with a server error this many times.
    var failingDeletes = 0

    init(partSize: Int64) { self.partSize = partSize }

    func setExpiresIn(_ seconds: Int) { expiresIn = seconds }

    func createLocalUpload(account: String, folder: String, name: String, size: Int64) async throws -> FrameIO.LocalUpload {
        let id = "upload\(created.count)"
        created.append(id)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let signed = formatter.string(from: Date())
        let count = Int((size + partSize - 1) / partSize)
        let parts = (0..<count).map { index -> [String: Any] in
            ["size": min(partSize, size - Int64(index) * partSize),
             "url": "https://s3.test/\(id)/\(index)?X-Amz-Date=\(signed)&X-Amz-Expires=\(expiresIn)"]
        }
        let json: [String: Any] = ["id": id, "media_type": "video/quicktime", "upload_urls": parts]
        if loseNextCreateReply {
            loseNextCreateReply = false
            let placeholder: [String: Any] = ["id": id, "name": name, "type": "file", "file_size": size, "status": "created",
                                              "created_at": ISO8601DateFormatter().string(from: Date())]
            existing.append(try JSONDecoder().decode(FrameIO.Item.self, from: JSONSerialization.data(withJSONObject: placeholder)))
            throw URLError(.timedOut)
        }
        return try JSONDecoder().decode(FrameIO.LocalUpload.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func deleteFile(account: String, id: String) async throws {
        if failingDeletes > 0 {
            failingDeletes -= 1
            throw FrameIO.Failure.http(503, "")
        }
        deleted.append(id)
    }

    func loseNextReply() { loseNextCreateReply = true }
    func failDeletes(_ count: Int) { failingDeletes = count }

    func uploadStatus(account: String, id: String) async throws -> FrameIO.UploadStatus {
        try JSONDecoder().decode(FrameIO.UploadStatus.self, from: Data(#"{"upload_complete": true, "upload_failed": false}"#.utf8))
    }

    func createFolder(account: String, parent: String, name: String) async throws -> FrameIO.Item {
        try JSONDecoder().decode(FrameIO.Item.self, from: Data(#"{"id": "folder-\#(name)", "name": "\#(name)", "type": "folder"}"#.utf8))
    }

    func children(account: String, folder: String, thumbnails: Bool) async throws -> [FrameIO.Item] { existing }
}

struct OnlineNetwork: NetworkStatus {
    var isOnline: Bool { true }
    func waitUntilOnline() async {}
}

// MARK: - Tests

@Suite("Frame.io upload engine", .serialized)
struct UploadEngineTests {
    static let partSize: Int64 = 256 * 1024

    private func makeFile(bytes: Int) throws -> (url: URL, data: Data) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip.mov")
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: url)
        return (url, data)
    }

    private func makeEngine(_ api: UploadAPI, store: UploadResumeStore, giveUpAfter: TimeInterval = 60) -> UploadEngine {
        var limits = UploadEngine.Limits()
        limits.maxBackoff = 0.01
        limits.tuneInterval = 60
        limits.giveUpAfter = giveUpAfter
        return UploadEngine(api: api, session: UploadEngine.makeSession(protocolClasses: [StubStorage.self]), store: store,
                            progress: UploadProgress(), network: OnlineNetwork(), limits: limits)
    }

    private func assembled(_ upload: String, parts: Int) -> Data {
        (0..<parts).reduce(into: Data()) { $0 += StubStorage.body("/\(upload)/\($1)") ?? Data() }
    }

    /// Runs one file and returns its outcome.
    private func upload(_ engine: UploadEngine, _ file: URL, size: Int) async -> UploadOutcome? {
        let result = OutcomeBox()
        await engine.run([UploadWork(jobID: UUID(), files: [file], sizes: [Int64(size)], folders: [])], account: "acc", folder: "root",
                         onStart: { _ in }, onFinish: { _, outcome in result.set(outcome) })
        return result.value
    }

    @Test("A multi-part file arrives intact and leaves nothing to resume")
    func multipart() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: Int(Self.partSize) * 5 + 1234)
        let api = FakeFrameIO(partSize: Self.partSize)
        let store = UploadResumeStore(directory: nil)
        let outcome = await upload(makeEngine(api, store: store), file, size: data.count)
        #expect(outcome == .uploaded)
        #expect(assembled("upload0", parts: 6) == data)
        #expect(await store.snapshot.files.isEmpty)
    }

    @Test("Dropped connections and server errors are retried, part by part")
    func transientFailures() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: Int(Self.partSize) * 4)
        StubStorage.fail("/upload0/1", with: [.network(.networkConnectionLost), .network(.timedOut)])
        StubStorage.fail("/upload0/2", with: [.status(503, "Slow Down")])
        StubStorage.fail("/upload0/3", with: [.status(400, "<Code>RequestTimeout</Code>")])
        let outcome = await upload(makeEngine(FakeFrameIO(partSize: Self.partSize), store: UploadResumeStore(directory: nil)), file, size: data.count)
        #expect(outcome == .uploaded)
        #expect(assembled("upload0", parts: 4) == data)
        #expect(StubStorage.attempts("/upload0/0") == 1)
        #expect(StubStorage.attempts("/upload0/1") == 3)
        #expect(StubStorage.attempts("/upload0/2") == 2)
    }

    @Test("Pausing keeps the sent parts; resuming sends only the rest, to the same upload")
    func pauseAndResume() async throws {
        StubStorage.reset()
        let parts = 12
        let (file, data) = try makeFile(bytes: Int(Self.partSize) * parts)
        let api = FakeFrameIO(partSize: Self.partSize)
        let file1 = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
        let store = UploadResumeStore(directory: file1)
        StubStorage.delay = 0.05

        let run = Task { await upload(makeEngine(api, store: store), file, size: data.count) }
        while StubStorage.receivedPaths.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        run.cancel()
        #expect(await run.value == .cancelled)
        await store.flush()

        // A new session (quit and relaunch): the saved state is read back from disk.
        let saved = UploadResumeStore.load(from: file1)
        let sentBefore = saved.files[file.path]?.done ?? []
        #expect(sentBefore.count >= 3 && sentBefore.count < parts)
        let attemptsBefore = (0..<parts).map { StubStorage.attempts("/upload0/\($0)") }

        StubStorage.delay = 0
        let resumed = UploadResumeStore(directory: nil, state: saved)
        #expect(await upload(makeEngine(api, store: resumed), file, size: data.count) == .uploaded)
        #expect(await api.created == ["upload0"])
        #expect(assembled("upload0", parts: parts) == data)
        for index in sentBefore { #expect(StubStorage.attempts("/upload0/\(index)") == attemptsBefore[index]) }
        #expect(await resumed.snapshot.files.isEmpty)
    }

    @Test("Expired links start the file over with a new upload and delete the old placeholder")
    func expiredLinks() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: Int(Self.partSize) * 3)
        for index in 0..<3 { StubStorage.fail("/upload0/\(index)", with: [.status(403, "<Message>Request has expired</Message>")]) }
        let api = FakeFrameIO(partSize: Self.partSize)
        #expect(await upload(makeEngine(api, store: UploadResumeStore(directory: nil)), file, size: data.count) == .uploaded)
        #expect(await api.created == ["upload0", "upload1"])
        #expect(assembled("upload1", parts: 3) == data)
        try await Task.sleep(for: .milliseconds(100))   // the delete is detached
        #expect(await api.deleted == ["upload0"])
    }

    @Test("Saved links about to expire aren't resumed: the file starts over")
    func savedLinksNearExpiry() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: Int(Self.partSize) * 2)
        let api = FakeFrameIO(partSize: Self.partSize)
        await api.setExpiresIn(60)   // inside the 10-minute margin
        let first = try await api.createLocalUpload(account: "acc", folder: "root", name: "clip.mov", size: Int64(data.count))
        let modified = try UploadEngine.checkedModificationDate(of: file, size: Int64(data.count))
        let record = UploadResumeStore.SavedFile(path: file.path, size: Int64(data.count), modified: modified, account: "acc",
                                                 folderID: "root", placeholderID: first.id, mediaType: nil,
                                                 parts: first.uploadURLs.map { .init(size: $0.size, url: $0.url) }, done: [0])
        #expect(record.expires(within: 600))
        await api.setExpiresIn(3600)
        let store = UploadResumeStore(directory: nil)
        await store.putFile(record)
        #expect(await upload(makeEngine(api, store: store), file, size: data.count) == .uploaded)
        #expect(await api.created == ["upload0", "upload1"])
        #expect(assembled("upload1", parts: 2) == data)
    }

    @Test("A file that changes while uploading fails, and its placeholder is deleted")
    func fileChanged() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: Int(Self.partSize) * 3)
        StubStorage.onRequest = { path in
            guard path == "/upload0/0", let handle = try? FileHandle(forWritingTo: file) else { return }
            handle.seekToEndOfFile()
            handle.write(Data([1, 2, 3]))
            try? handle.close()
        }
        let api = FakeFrameIO(partSize: Self.partSize)
        let outcome = await upload(makeEngine(api, store: UploadResumeStore(directory: nil)), file, size: data.count)
        guard case .failed = outcome else { Issue.record("expected a failure, got \(String(describing: outcome))"); return }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await api.deleted == ["upload0"])
    }

    @Test("A finished file on Frame.io is skipped; an unfinished placeholder isn't")
    func skipsFinishedOnly() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: 1000)
        func item(_ status: String) throws -> FrameIO.Item {
            try JSONDecoder().decode(FrameIO.Item.self, from: Data(#"{"id": "x", "name": "clip.mov", "type": "file", "file_size": 1000, "status": "\#(status)"}"#.utf8))
        }
        let api = FakeFrameIO(partSize: Self.partSize)
        await api.setExisting([try item("uploaded")])
        #expect(await upload(makeEngine(api, store: UploadResumeStore(directory: nil)), file, size: data.count) == .skipped)
        await api.setExisting([try item("created")])
        #expect(await upload(makeEngine(api, store: UploadResumeStore(directory: nil)), file, size: data.count) == .uploaded)
    }

    @Test("Saved state survives a round trip to disk; parts don't rewrite the run; link expiry is read from the URL")
    func storeRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString)")
        let store = UploadResumeStore(directory: url)
        let part = UploadResumeStore.Part(size: 10, url: "https://s3.test/a/0?X-Amz-Date=20260101T000000Z&X-Amz-Expires=7200")
        await store.putFile(.init(path: "/a.mov", size: 10, modified: Date(timeIntervalSince1970: 1_000), account: "acc",
                                  folderID: "f", placeholderID: "p", mediaType: nil, parts: [part], done: [0]))
        await store.setRun(.init(account: "acc", folder: "f", destinationPath: "Project › Folder", keepStructure: true,
                                 jobs: [.init(path: "/a.mov", files: ["/a.mov"], sizes: [10], folders: [])]))
        await store.flush()
        let runFile = url.appendingPathComponent("upload-run.json")
        let runWritten = try FileManager.default.attributesOfItem(atPath: runFile.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(1100))
        await store.markDone("/a.mov", part: 0)
        await store.flush()
        #expect(try FileManager.default.attributesOfItem(atPath: runFile.path)[.modificationDate] as? Date == runWritten)
        let loaded = UploadResumeStore.load(from: url)
        #expect(loaded.files["/a.mov"]?.done == [0])
        #expect(loaded.run?.destinationPath == "Project › Folder")
        #expect(loaded.files["/a.mov"]?.expires == ISO8601DateFormatter().date(from: "2026-01-01T02:00:00Z"))
        await store.removeJob("/a.mov")
        #expect(await store.snapshot.run == nil)
    }

    @Test("Errors are classified for retrying")
    func classification() {
        #expect(UploadEngine.classify(PartFailure(status: 503, body: "", retryAfter: 3)) == .transient(retryAfter: 3))
        #expect(UploadEngine.classify(PartFailure(status: 400, body: "<Code>RequestTimeout</Code>", retryAfter: nil)) == .transient(retryAfter: nil))
        #expect(UploadEngine.classify(PartFailure(status: 403, body: "", retryAfter: nil)) == .expired)
        #expect(UploadEngine.classify(PartFailure(status: 400, body: "<Code>BadDigest</Code>", retryAfter: nil)) == .fatal)
        #expect(UploadEngine.classify(URLError(.networkConnectionLost)) == .transient(retryAfter: nil))
        #expect(UploadEngine.classify(UploadError.missing) == .fatal)
        #expect(UploadEngine.backoff(10, cap: 30) <= 37.5)
    }

    @Test("A lost reply when creating a file's upload is retried, and the empty twin it left is deleted")
    func lostCreateReply() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: Int(Self.partSize) * 2)
        let api = FakeFrameIO(partSize: Self.partSize)
        await api.loseNextReply()
        #expect(await upload(makeEngine(api, store: UploadResumeStore(directory: nil)), file, size: data.count) == .uploaded)
        #expect(await api.created == ["upload0", "upload1"])
        #expect(assembled("upload1", parts: 2) == data)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await api.deleted == ["upload0"])
    }

    @Test("Folder lookups ride out a dropped connection")
    func folderLookupRetried() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: 1000)
        let api = FlakyChildren(inner: FakeFrameIO(partSize: Self.partSize))
        let result = OutcomeBox()
        await makeEngine(api, store: UploadResumeStore(directory: nil)).run(
            [UploadWork(jobID: UUID(), files: [file], sizes: [Int64(data.count)], folders: ["Sub"])], account: "acc", folder: "root",
            onStart: { _ in }, onFinish: { _, outcome in result.set(outcome) })
        #expect(result.value == .uploaded)
        #expect(await api.calls >= 2)
    }

    @Test("Deletes that fail stay pending on disk and go through on the next try")
    func pendingDeletes() async throws {
        let api = FakeFrameIO(partSize: Self.partSize)
        await api.failDeletes(100)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deletes-\(UUID().uuidString)")
        let store = UploadResumeStore(directory: directory)
        await store.addDeletes([.init(account: "acc", id: "orphan")])
        makeEngine(api, store: store, giveUpAfter: 0.05).drainDeletes()
        try await Task.sleep(for: .milliseconds(300))
        await store.flush()
        #expect(UploadResumeStore.load(from: directory).deletes == [.init(account: "acc", id: "orphan")])

        await api.failDeletes(0)
        let relaunched = UploadResumeStore(directory: directory, state: UploadResumeStore.load(from: directory))
        makeEngine(api, store: relaunched).drainDeletes()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await api.deleted == ["orphan"])
        #expect(await relaunched.snapshot.deletes.isEmpty)
    }

    @Test("A part that keeps failing while online gives up after the time limit, with a readable reason")
    func givesUp() async throws {
        StubStorage.reset()
        let (file, data) = try makeFile(bytes: Int(Self.partSize))
        StubStorage.fail("/upload0/0", with: Array(repeating: .network(.networkConnectionLost), count: 1000))
        let outcome = await upload(makeEngine(FakeFrameIO(partSize: Self.partSize), store: UploadResumeStore(directory: nil), giveUpAfter: 0.3),
                                   file, size: data.count)
        #expect(outcome == .failed("The network connection was lost."))
        #expect(UploadEngine.describe(URLError(.notConnectedToInternet)) == "The Mac is offline.")
    }

    @Test("The stream gate limits parts in flight and lets a cancelled waiter go")
    func gate() async {
        let gate = TransferGate(limit: 2, byteBudget: 1 << 30)
        #expect(await gate.acquire(cost: 1))
        #expect(await gate.acquire(cost: 1))
        let waiter = Task { await gate.acquire(cost: 1) }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        #expect(await waiter.value == false)
        await gate.release(cost: 1)
        #expect(await gate.acquire(cost: 1))
    }
}

final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: UploadOutcome?
    var value: UploadOutcome? { lock.withLock { outcome } }
    func set(_ new: UploadOutcome) { lock.withLock { outcome = new } }
}

extension FakeFrameIO {
    func setExisting(_ items: [FrameIO.Item]) { existing = items }
}

/// `children` drops its first connection.
actor FlakyChildren: UploadAPI {
    let inner: FakeFrameIO
    private(set) var calls = 0
    init(inner: FakeFrameIO) { self.inner = inner }
    func createLocalUpload(account: String, folder: String, name: String, size: Int64) async throws -> FrameIO.LocalUpload {
        try await inner.createLocalUpload(account: account, folder: folder, name: name, size: size)
    }
    func deleteFile(account: String, id: String) async throws { try await inner.deleteFile(account: account, id: id) }
    func uploadStatus(account: String, id: String) async throws -> FrameIO.UploadStatus { try await inner.uploadStatus(account: account, id: id) }
    func createFolder(account: String, parent: String, name: String) async throws -> FrameIO.Item {
        try await inner.createFolder(account: account, parent: parent, name: name)
    }
    func children(account: String, folder: String, thumbnails: Bool) async throws -> [FrameIO.Item] {
        calls += 1
        if calls == 1 { throw URLError(.networkConnectionLost) }
        return try await inner.children(account: account, folder: folder, thumbnails: thumbnails)
    }
}
