import Foundation
import CryptoKit
import Testing
@testable import QCpie

private func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }
private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// S3's ETag for `data` split into `parts` the way Frame.io splits uploads.
private func s3ETag(_ data: Data, parts: Int) -> String {
    guard parts > 1 else { return hex(md5(data)) }
    let size = (data.count + parts - 1) / parts
    let digests = stride(from: 0, to: data.count, by: size).map { md5(data.subdata(in: $0..<min($0 + size, data.count))) }
    return hex(md5(digests.reduce(into: Data()) { $0.append($1) })) + "-\(digests.count)"
}

private func fixedPartETag(_ data: Data, partSize: Int) -> String {
    let digests = stride(from: 0, to: data.count, by: partSize).map { md5(data.subdata(in: $0..<min($0 + partSize, data.count))) }
    return hex(md5(digests.reduce(into: Data()) { $0.append($1) })) + "-\(digests.count)"
}

/// An upload API whose uploaded originals download from the stub CDN (for the stored-file check).
actor StoredFrameIO: UploadAPI {
    let base: FakeFrameIO
    init(partSize: Int64) { base = FakeFrameIO(partSize: partSize) }

    func createLocalUpload(account: String, folder: String, name: String, size: Int64) async throws -> FrameIO.LocalUpload {
        try await base.createLocalUpload(account: account, folder: folder, name: name, size: size)
    }
    func deleteFile(account: String, id: String) async throws { try await base.deleteFile(account: account, id: id) }
    func uploadStatus(account: String, id: String) async throws -> FrameIO.UploadStatus { try await base.uploadStatus(account: account, id: id) }
    func createFolder(account: String, parent: String, name: String) async throws -> FrameIO.Item {
        try await base.createFolder(account: account, parent: parent, name: name)
    }
    func children(account: String, folder: String, thumbnails: Bool) async throws -> [FrameIO.Item] {
        try await base.children(account: account, folder: folder, thumbnails: thumbnails)
    }
    func originalDownloadURL(account: String, file: String) async throws -> URL? { URL(string: "https://s3.test/stored/\(file)") }
}

@Suite("Transfer fingerprints and reports")
struct TransferVerificationTests {
    // MARK: Fingerprints

    @Test("S3 ETags are read as plain or multipart MD5s, anything else is ignored")
    func etags() {
        #expect(TransferChecksum.normalizedETag("\"782E7AA4D244511D0156156349E66C56\"") == "782e7aa4d244511d0156156349e66c56")
        #expect(TransferChecksum.normalizedETag("\"b3b15e4be7cec0966f78998dc7440b6b-21\"") == "b3b15e4be7cec0966f78998dc7440b6b-21")
        #expect(TransferChecksum.normalizedETag("W/\"782e7aa4d244511d0156156349e66c56\"") == nil)
        #expect(TransferChecksum.normalizedETag("\"abc\"") == nil)
        #expect(TransferChecksum.normalizedETag(nil) == nil)
        #expect(TransferChecksum.partCount(of: "b3b15e4be7cec0966f78998dc7440b6b-21") == 21)
        #expect(TransferChecksum.partCount(of: "782e7aa4d244511d0156156349e66c56") == 1)
    }

    @Test("Frame.io's part layout, as measured on a 400 MiB upload")
    func layout() {
        #expect(TransferChecksum.partSize(size: 419_430_400, parts: 21) == 19_972_877)
        #expect(TransferChecksum.partSize(size: 3_145_728, parts: 1) == 3_145_728)
    }

    @Test("Reading a file back gives its MD5 and the multipart ETag S3 would give it")
    func readBack() throws {
        let data = Data((0..<1_000_003).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString)")
        try data.write(to: url)
        for parts in [1, 2, 3, 21] {
            let check = try TransferChecksum.readBack(url, partSize: TransferChecksum.partSize(size: Int64(data.count), parts: parts))
            #expect(check.md5 == hex(md5(data)))
            #expect(check.etag == s3ETag(data, parts: parts))
        }
    }

    // MARK: Report

    @Test("The report lists every file with its fingerprints; the hash list holds paths relative to the run's folder")
    func report() {
        let check = TransferVerification(level: .verified, method: "Matches", md5: "782e7aa4d244511d0156156349e66c56", etag: "782e7aa4d244511d0156156349e66c56")
        let entry = UploadLogEntry(id: UUID(), name: "a, b.mov", destination: "/tmp/Run › Sub", bytes: 42, started: Date(), finished: Date(),
                                   outcome: .uploaded, message: nil, localPath: "/tmp/Run/Sub/a, b.mov", verification: check)
        let run = UploadLogRun(id: UUID(), kind: .download, started: Date(), finished: Date(), destination: "/tmp/Run",
                               keepStructure: false, entries: [entry])
        let csv = TransferReport.csv(run)
        #expect(csv.contains("\"a, b.mov\",Downloaded,Verified,Matches,42"))
        #expect(csv.contains("782e7aa4d244511d0156156349e66c56"))
        let mhl = TransferReport.mhl(run)
        #expect(mhl.contains("<file>Sub/a, b.mov</file>"))
        #expect(mhl.contains("<md5>782e7aa4d244511d0156156349e66c56</md5>"))
        #expect(mhl.contains("Each matched Frame.io"))
        // A file whose fingerprint couldn't be reproduced: its MD5 is listed, but not as compared.
        var sizeOnly = entry
        sizeOnly.verification = TransferVerification(level: .sizeOnly, method: "Downloaded twice", md5: "00", etag: nil)
        let mixed = UploadLogRun(id: UUID(), kind: .download, started: Date(), finished: Date(), destination: "/tmp/Run",
                                 keepStructure: false, entries: [entry, sizeOnly])
        #expect(TransferReport.mhl(mixed).contains("1 of 2 matched"))
    }

    @Test("Log entries saved before verification still load")
    func oldLogLoads() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"a.mov","destination":"x","bytes":1,"started":"2026-01-01T00:00:00Z","finished":"2026-01-01T00:00:01Z","outcome":"uploaded"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(UploadLogEntry.self, from: Data(json.utf8))
        #expect(entry.verification == nil)
    }
}

/// In the upload engine's suite: these share its storage stub, and suites run in parallel.
extension UploadEngineTests {
    static let verifyPartSize: Int64 = 256 * 1024

    // MARK: Uploads

    private func verifyFile(bytes: Int) throws -> (url: URL, data: Data) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip.mov")
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: url)
        return (url, data)
    }

    private func uploadEngine(_ api: UploadAPI) -> UploadEngine {
        var limits = UploadEngine.Limits()
        limits.maxBackoff = 0.01
        limits.tuneInterval = 60
        return UploadEngine(api: api, session: UploadEngine.makeSession(protocolClasses: [StubStorage.self]),
                            store: UploadResumeStore(directory: nil), progress: UploadProgress(), network: OnlineNetwork(), limits: limits)
    }

    private func verifiedUpload(_ engine: UploadEngine, _ file: URL, size: Int) async -> (UploadOutcome?, TransferVerification?) {
        let result = OutcomeBox()
        let job = UUID()
        await engine.run([UploadWork(jobID: job, files: [file], sizes: [Int64(size)], folders: [])], account: "acc", folder: "root",
                         onStart: { _ in }, onFinish: { _, outcome in result.set(outcome) })
        return (result.value, engine.verifications.take(job))
    }

    @Test("Every part is compared with the MD5 the storage answers; a one-part file is fully verified")
    func uploadVerified() async throws {
        StubStorage.reset()
        let (file, data) = try verifyFile(bytes: 1000)
        let (outcome, check) = await verifiedUpload(uploadEngine(FakeFrameIO(partSize: Self.verifyPartSize)), file, size: data.count)
        #expect(outcome == .uploaded)
        #expect(check?.level == .verified)
        #expect(check?.md5 == hex(md5(data)))
    }

    @Test("A multi-part upload is also checked as stored: the parts' fingerprint must match Frame.io's file")
    func uploadStoredMatches() async throws {
        StubStorage.reset()
        let (file, data) = try verifyFile(bytes: Int(Self.verifyPartSize) * 3 + 99)
        // The fake splits into fixed-size parts (the last one shorter), so the fingerprint comes from those.
        let expected = fixedPartETag(data, partSize: Int(Self.verifyPartSize))
        StubStorage.store("/stored/upload0", etag: expected)
        let (outcome, check) = await verifiedUpload(uploadEngine(StoredFrameIO(partSize: Self.verifyPartSize)), file, size: data.count)
        #expect(outcome == .uploaded)
        #expect(check?.level == .verified)
        #expect(check?.etag == expected)
        #expect(check?.method.contains("stored file matches") == true)
    }

    @Test("A stored file that doesn't match the parts sent fails the upload")
    func uploadStoredMismatch() async throws {
        StubStorage.reset()
        let (file, data) = try verifyFile(bytes: Int(Self.verifyPartSize) * 2 + 5)
        StubStorage.store("/stored/upload0", etag: "0123456789abcdef0123456789abcdef-3")
        let api = StoredFrameIO(partSize: Self.verifyPartSize)
        let (outcome, check) = await verifiedUpload(uploadEngine(api), file, size: data.count)
        #expect(check?.level == .failed)
        if case .failed = outcome {} else { Issue.record("expected a failure, got \(String(describing: outcome))") }
        // The damaged copy is deleted (else the next upload would skip the file as already there).
        for _ in 0..<100 where await !api.base.deleted.contains("upload0") { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await api.base.deleted.contains("upload0"))
    }

    @Test("A part confirmed with the wrong MD5 is sent again; one that keeps differing fails its file")
    func uploadPartMismatch() async throws {
        StubStorage.reset()
        let (file, data) = try verifyFile(bytes: Int(Self.verifyPartSize) * 2)
        StubStorage.answerWrongETag("/upload0/1", times: 1)
        let (outcome, check) = await verifiedUpload(uploadEngine(FakeFrameIO(partSize: Self.verifyPartSize)), file, size: data.count)
        #expect(outcome == .uploaded)
        #expect(check?.level == .verified)
        #expect(StubStorage.attempts("/upload0/1") == 2)

        StubStorage.reset()
        let (file2, data2) = try verifyFile(bytes: Int(Self.verifyPartSize) * 2)
        StubStorage.answerWrongETag("/upload0/0", times: 5)
        let (outcome2, _) = await verifiedUpload(uploadEngine(FakeFrameIO(partSize: Self.verifyPartSize)), file2, size: data2.count)
        #expect(outcome2 == .failed(UploadError.verificationFailed.localizedDescription))
        #expect(StubStorage.attempts("/upload0/0") == 3)
    }

    @Test("Storage that confirms nothing leaves the upload size-checked, not verified")
    func uploadUnconfirmed() async throws {
        StubStorage.reset()
        StubStorage.sendsETags = false
        let (file, data) = try verifyFile(bytes: 5000)
        let (outcome, check) = await verifiedUpload(uploadEngine(FakeFrameIO(partSize: Self.verifyPartSize)), file, size: data.count)
        #expect(outcome == .uploaded)
        #expect(check?.level == .sizeOnly)
        StubStorage.sendsETags = true
    }
}

/// In the download engine's suite: these share its CDN stub.
extension DownloadEngineTests {
    // MARK: Downloads

    private func verifyEngine() -> DownloadEngine {
        var limits = DownloadEngine.Limits()
        limits.chunkSize = 128 * 1024
        limits.maxBackoff = 0.01
        return DownloadEngine(api: FakeDownloads(), session: UploadEngine.makeSession(protocolClasses: [StubCDN.self]),
                              progress: UploadProgress(), network: OnlineNetwork(), limits: limits)
    }

    private func verifiedDownload(_ engine: DownloadEngine, _ body: Data) async throws -> (DownloadOutcome?, TransferVerification?, URL) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dlv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let item = DownloadItem(jobID: UUID(), fileID: "file1", name: "clip.mov", size: Int64(body.count), folders: [])
        let box = DownloadOutcomes()
        await engine.run([item], account: "acc", destination: destination, onStart: { _ in }, onFinish: { id, outcome in box.set(id, outcome) })
        return (box.values[item.jobID], engine.verifications.take(item.jobID), destination)
    }

    @Test("A download is read back from disk and matched with Frame.io's multipart fingerprint")
    func downloadVerified() async throws {
        StubCDN.reset()
        let body = Data((0..<(128 * 1024 * 5 + 321)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        StubCDN.serve("/file1", body)
        StubCDN.tag("/file1", [s3ETag(body, parts: 3)])
        let (outcome, check, folder) = try await verifiedDownload(verifyEngine(), body)
        #expect(outcome == .downloaded(folder.appendingPathComponent("clip.mov")))
        #expect(check?.level == .verified)
        #expect(check?.md5 == hex(md5(body)))
    }

    @Test("A fingerprint that never matches: downloaded twice; identical copies are kept as size-checked")
    func downloadUnreproducible() async throws {
        StubCDN.reset()
        let body = Data((0..<(128 * 1024 * 2)).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        StubCDN.serve("/file1", body)
        StubCDN.tag("/file1", ["0123456789abcdef0123456789abcdef-7"])
        let (outcome, check, folder) = try await verifiedDownload(verifyEngine(), body)
        #expect(outcome == .downloaded(folder.appendingPathComponent("clip.mov")))
        #expect(check?.level == .sizeOnly)
        #expect(StubCDN.requestCount == 4)
        #expect(try Data(contentsOf: folder.appendingPathComponent("clip.mov")) == body)
    }

    @Test("Chunks from two different stored files (replaced mid-download) fail the file")
    func downloadChangedOnFrameIO() async throws {
        StubCDN.reset()
        let body = Data((0..<(128 * 1024 * 3)).map { UInt8(truncatingIfNeeded: $0) })
        StubCDN.serve("/file1", body)
        StubCDN.tag("/file1", [hex(md5(body)), "0123456789abcdef0123456789abcdef"])
        let (outcome, _, folder) = try await verifiedDownload(verifyEngine(), body)
        #expect(outcome == .failed(DownloadError.changedOnFrameIO.localizedDescription))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
