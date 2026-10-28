import Foundation
import Testing
@testable import QCpie

// MARK: - Simulated CDN

/// Serves `GET` with `Range` for files registered by path, like Frame.io's CDN. Links carry `v=<n>`; a path can
/// refuse links older than a version (403, an expired link), and scripted failures play before a range succeeds.
final class StubCDN: URLProtocol, @unchecked Sendable {
    enum Failure: Sendable { case network(URLError.Code), status(Int) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var files: [String: Data] = [:]
    nonisolated(unsafe) private static var minimumVersion: [String: Int] = [:]
    nonisolated(unsafe) private static var failures: [String: [Failure]] = [:]
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) static var delay: TimeInterval = 0

    static func reset() { lock.withLock { files = [:]; minimumVersion = [:]; failures = [:]; requests = 0; delay = 0 } }
    static func serve(_ path: String, _ data: Data) { lock.withLock { files[path] = data } }
    static func expireBefore(_ path: String, version: Int) { lock.withLock { minimumVersion[path] = version } }
    /// Failures for the range starting at `offset` of `path`.
    static func fail(_ path: String, at offset: Int64, with list: [Failure]) { lock.withLock { failures["\(path)@\(offset)"] = list } }
    static var requestCount: Int { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cdn.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path
        let version = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value.flatMap(Int.init) ?? 0
        let header = request.value(forHTTPHeaderField: "Range") ?? ""
        let bounds = header.replacingOccurrences(of: "bytes=", with: "").split(separator: "-").compactMap { Int64($0) }
        let delay = Self.lock.withLock { Self.delay }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let (data, minimum, failure): (Data?, Int, Failure?) = Self.lock.withLock {
                Self.requests += 1
                let key = "\(path)@\(bounds.first ?? 0)"
                var failure: Failure?
                if var list = Self.failures[key], !list.isEmpty {
                    failure = list.removeFirst()
                    Self.failures[key] = list
                }
                return (Self.files[path], Self.minimumVersion[path] ?? 0, failure)
            }
            if case .network(let code)? = failure { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
            if case .status(let status)? = failure { respond(status, Data(), range: nil); return }
            guard let data else { respond(404, Data(), range: nil); return }
            guard version >= minimum else { respond(403, Data("<Message>Request has expired</Message>".utf8), range: nil); return }
            guard bounds.count == 2 else { respond(200, data, range: nil); return }
            // A request left over from an earlier test can ask past a newer, smaller file: answer like a CDN would.
            guard bounds[0] < Int64(data.count) else { respond(416, Data(), range: nil); return }
            let slice = data.subdata(in: Int(bounds[0])..<Int(min(bounds[1] + 1, Int64(data.count))))
            respond(206, slice, range: "bytes \(bounds[0])-\(bounds[1])/\(data.count)")
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ body: Data, range: String?) {
        let headers = range.map { ["Content-Range": $0, "Accept-Ranges": "bytes"] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

actor FakeDownloads: DownloadAPI {
    private var linkVersion = 0
    private(set) var linksGiven = 0
    var tree: [String: [FrameIO.Item]] = [:]

    func originalDownloadURL(account: String, file: String) async throws -> URL? {
        linkVersion += 1
        linksGiven += 1
        return URL(string: "https://cdn.test/\(file)?v=\(linkVersion)")
    }

    func children(account: String, folder: String, thumbnails: Bool) async throws -> [FrameIO.Item] { tree[folder] ?? [] }

    func setTree(_ tree: [String: [FrameIO.Item]]) { self.tree = tree }
}

// MARK: - Tests

@Suite("Frame.io download engine", .serialized)
struct DownloadEngineTests {
    static let chunk: Int64 = 128 * 1024

    private func data(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }) }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func engine(_ api: DownloadAPI) -> DownloadEngine {
        var limits = DownloadEngine.Limits()
        limits.chunkSize = Self.chunk
        limits.maxBackoff = 0.01
        return DownloadEngine(api: api, session: UploadEngine.makeSession(protocolClasses: [StubCDN.self]), progress: UploadProgress(),
                              network: OnlineNetwork(), limits: limits)
    }

    private func download(_ engine: DownloadEngine, _ items: [DownloadItem], to destination: URL) async -> [UUID: DownloadOutcome] {
        let box = DownloadOutcomes()
        await engine.run(items, account: "acc", destination: destination, onStart: { _ in }, onFinish: { id, outcome in box.set(id, outcome) })
        return box.values
    }

    @Test("A file arrives intact from parallel ranges, under its own name, with no partial file left")
    func chunked() async throws {
        StubCDN.reset()
        let body = data(Int(Self.chunk) * 6 + 777)
        StubCDN.serve("/file1", body)
        let destination = try folder()
        let item = DownloadItem(jobID: UUID(), fileID: "file1", name: "clip.mov", size: Int64(body.count), folders: [])
        let outcome = await download(engine(FakeDownloads()), [item], to: destination)[item.jobID]
        #expect(outcome == .downloaded(destination.appendingPathComponent("clip.mov")))
        #expect(try Data(contentsOf: destination.appendingPathComponent("clip.mov")) == body)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["clip.mov"])
        #expect(StubCDN.requestCount == 7)
    }

    @Test("Dropped connections and server errors are retried per range")
    func retries() async throws {
        StubCDN.reset()
        let body = data(Int(Self.chunk) * 3)
        StubCDN.serve("/file1", body)
        StubCDN.fail("/file1", at: Self.chunk, with: [.network(.networkConnectionLost), .status(503)])
        let destination = try folder()
        let item = DownloadItem(jobID: UUID(), fileID: "file1", name: "clip.mov", size: Int64(body.count), folders: [])
        #expect(await download(engine(FakeDownloads()), [item], to: destination)[item.jobID] == .downloaded(destination.appendingPathComponent("clip.mov")))
        #expect(try Data(contentsOf: destination.appendingPathComponent("clip.mov")) == body)
    }

    @Test("An expired link is fetched again and the download carries on")
    func expiredLink() async throws {
        StubCDN.reset()
        let body = data(Int(Self.chunk) * 2)
        StubCDN.serve("/file1", body)
        StubCDN.expireBefore("/file1", version: 2)   // the first link (v=1) is refused
        let api = FakeDownloads()
        let destination = try folder()
        let item = DownloadItem(jobID: UUID(), fileID: "file1", name: "clip.mov", size: Int64(body.count), folders: [])
        #expect(await download(engine(api), [item], to: destination)[item.jobID] == .downloaded(destination.appendingPathComponent("clip.mov")))
        #expect(try Data(contentsOf: destination.appendingPathComponent("clip.mov")) == body)
        #expect(await api.linksGiven >= 2)
    }

    @Test("Cancelling removes the partial file")
    func cancel() async throws {
        StubCDN.reset()
        let body = data(Int(Self.chunk) * 20)
        StubCDN.serve("/file1", body)
        StubCDN.delay = 0.05
        let destination = try folder()
        let item = DownloadItem(jobID: UUID(), fileID: "file1", name: "clip.mov", size: Int64(body.count), folders: [])
        let task = Task { await download(engine(FakeDownloads()), [item], to: destination) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        #expect(await task.value[item.jobID] == .cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("A taken name gets a number, Finder-style")
    func uniqueNames() async throws {
        StubCDN.reset()
        let body = data(1000)
        StubCDN.serve("/file1", body)
        let destination = try folder()
        try Data().write(to: destination.appendingPathComponent("clip.mov"))
        let item = DownloadItem(jobID: UUID(), fileID: "file1", name: "clip.mov", size: Int64(body.count), folders: ["Sub"])
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data().write(to: destination.appendingPathComponent("Sub/clip.mov"))
        #expect(await download(engine(FakeDownloads()), [item], to: destination)[item.jobID]
                == .downloaded(destination.appendingPathComponent("Sub/clip 2.mov")))
    }

    @Test("A file listed without a size comes down in one request")
    func unknownSize() async throws {
        StubCDN.reset()
        let body = data(5000)
        StubCDN.serve("/file1", body)
        let destination = try folder()
        let item = DownloadItem(jobID: UUID(), fileID: "file1", name: "clip.mov", size: 0, folders: [])
        #expect(await download(engine(FakeDownloads()), [item], to: destination)[item.jobID] == .downloaded(destination.appendingPathComponent("clip.mov")))
        #expect(try Data(contentsOf: destination.appendingPathComponent("clip.mov")) == body)
    }

    @Test("Two files with the same name in one folder both land, the second numbered")
    func sameNames() async throws {
        StubCDN.reset()
        StubCDN.serve("/file1", data(Int(Self.chunk) * 2))
        StubCDN.serve("/file2", data(Int(Self.chunk) * 2 + 9))
        let destination = try folder()
        let items = ["file1", "file2"].map { DownloadItem(jobID: UUID(), fileID: $0, name: "clip.mov", size: Int64(Self.chunk) * 2 + ($0 == "file2" ? 9 : 0), folders: []) }
        let outcomes = await download(engine(FakeDownloads()), items, to: destination)
        #expect(outcomes.values.allSatisfy { if case .downloaded = $0 { return true }; return false })
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
        #expect(names == ["clip.mov", "clip 2.mov"], "got \(names), outcomes \(outcomes)")
    }

    @Test("Names that would make folders on disk are made safe; progress counts bytes as they arrive")
    func safeNamesAndProgress() async throws {
        #expect(DownloadEngine.safeName("cut/v2: final.mov") == "cut-v2- final.mov")
        #expect(DownloadEngine.safeName("..") == "Untitled")
        StubCDN.reset()
        let body = data(Int(Self.chunk) + 100)
        StubCDN.serve("/file1", body)
        let progress = UploadProgress()
        var limits = DownloadEngine.Limits()
        limits.chunkSize = Self.chunk
        let engine = DownloadEngine(api: FakeDownloads(), session: UploadEngine.makeSession(protocolClasses: [StubCDN.self]),
                                    progress: progress, network: OnlineNetwork(), limits: limits)
        let item = DownloadItem(jobID: UUID(), fileID: "file1", name: "clip.mov", size: Int64(body.count), folders: [])
        _ = await download(engine, [item], to: try folder())
        #expect(progress.transferredBytes == Int64(body.count))
    }

    @Test("Folders expand to their files with structure; stacks download their current version")
    func expand() async throws {
        func item(_ json: String) throws -> FrameIO.Item { try JSONDecoder().decode(FrameIO.Item.self, from: Data(json.utf8)) }
        let api = FakeDownloads()
        await api.setTree([
            "folderA": [try item(#"{"id": "f1", "name": "a.mov", "type": "file", "file_size": 10}"#),
                        try item(#"{"id": "folderB", "name": "B", "type": "folder"}"#)],
            "folderB": [try item(#"{"id": "s1", "name": "Stack", "type": "version_stack", "head_version": {"id": "v3", "name": "b_v3.mov", "file_size": 30}}"#)]
        ])
        let top = [try item(#"{"id": "folderA", "name": "A", "type": "folder"}"#), try item(#"{"id": "f0", "name": "top.mov", "type": "file", "file_size": 5}"#)]
        let files = try await DownloadEngine.expand(top, account: "acc", api: api, retry: NetworkRetry(network: OnlineNetwork()))
        #expect(files.map(\.fileID) == ["f1", "v3", "f0"])
        #expect(files.map(\.folders) == [["A"], ["A", "B"], []])
        #expect(files.map(\.name) == ["a.mov", "b_v3.mov", "top.mov"])
    }
}

final class DownloadOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [UUID: DownloadOutcome] = [:]
    var values: [UUID: DownloadOutcome] { lock.withLock { outcomes } }
    func set(_ id: UUID, _ outcome: DownloadOutcome) { lock.withLock { outcomes[id] = outcome } }
}
