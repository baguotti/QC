import Foundation
import CryptoKit

/// How a transferred file was checked. Frame.io's API exposes no checksum, but its storage does (measured, see
/// docs/architecture/frameio.md "Verified transfers"): each upload part's PUT answers with the part's MD5 as its `ETag`,
/// and an original downloads with its S3 `ETag`, the file's MD5 for a one-part upload or the MD5 of the parts' MD5s
/// plus "-N" for N parts.
struct TransferVerification: Codable, Equatable, Sendable {
    enum Level: String, Codable, Sendable {
        /// Checked against Frame.io's own fingerprint of the file.
        case verified
        /// The size matched, but no fingerprint could be compared.
        case sizeOnly
        case failed
    }

    var level: Level
    /// In words, for the log and the report.
    var method: String
    /// The whole file's MD5, when it was computed (downloads: from the file on disk).
    var md5: String?
    /// Frame.io's stored fingerprint (S3 ETag), when known.
    var etag: String?
    /// Image sequences: frames checked of all frames.
    var verifiedFiles: Int?
    var totalFiles: Int?

    var label: String {
        switch level {
        case .verified: return "Verified"
        case .sizeOnly: return "Size checked"
        case .failed: return "Verification failed"
        }
    }

    /// Several files (a sequence's frames) as one: verified only when every frame was.
    static func combined(_ items: [TransferVerification]) -> TransferVerification? {
        guard let first = items.first else { return nil }
        if items.count == 1 { return first }
        let verified = items.filter { $0.level == .verified }.count
        let level: Level = items.contains { $0.level == .failed } ? .failed : verified == items.count ? .verified : .sizeOnly
        let method = level == .verified ? first.method : items.first { $0.level == level }?.method ?? first.method
        return TransferVerification(level: level, method: method, verifiedFiles: verified, totalFiles: items.count)
    }
}

enum TransferChecksum {
    nonisolated static func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// An S3 ETag as a plain MD5 ("…") or a multipart one ("…-N"), lowercased without quotes; nil for anything else
    /// (an encrypted object's ETag isn't an MD5).
    nonisolated static func normalizedETag(_ header: String?) -> String? {
        guard var tag = header?.trimmingCharacters(in: .whitespaces) else { return nil }
        if tag.hasPrefix("W/") { return nil }
        tag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        let pieces = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let hash = pieces.first, hash.count == 32, hash.allSatisfy(\.isHexDigit) else { return nil }
        if pieces.count == 1 { return tag }
        guard pieces.count == 2, let count = Int(pieces[1]), count > 0 else { return nil }
        return tag
    }

    /// The part count of a multipart ETag ("…-N"), 1 for a plain MD5.
    nonisolated static func partCount(of etag: String) -> Int {
        etag.split(separator: "-").dropFirst().first.flatMap { Int($0) } ?? 1
    }

    /// The ETag S3 gives an object put together from parts with these MD5s (one part: that part's MD5).
    nonisolated static func compositeETag(partMD5s: [Data]) -> String {
        guard partMD5s.count > 1 else { return partMD5s.first.map { hex($0) } ?? "" }
        return hex(Insecure.MD5.hash(data: partMD5s.reduce(into: Data()) { $0.append($1) })) + "-\(partMD5s.count)"
    }

    /// Frame.io's part layout for a file it split into `parts`: every part `ceil(size / parts)` bytes, the last one the
    /// rest (measured: 419,430,400 bytes in 21 parts = 20 × 19,972,877 + 19,972,860).
    nonisolated static func partSize(size: Int64, parts: Int) -> Int64 {
        guard parts > 1 else { return size }
        return (size + Int64(parts) - 1) / Int64(parts)
    }

    struct ReadBack: Sendable {
        let md5: String
        let partMD5s: [Data]
        var etag: String { TransferChecksum.compositeETag(partMD5s: partMD5s) }
    }

    /// Reads `file` once from disk: its MD5, and the MD5 of every `partSize` piece (for comparing with a multipart
    /// ETag). The two hashes run side by side and the next 8 MB is read meanwhile (measured on a 2 GB file: 430 MB/s
    /// hashing in turn, 860 MB/s side by side, the speed of MD5 itself); a file in one piece is hashed once.
    /// `shouldStop` is checked between reads (cancellation).
    nonisolated static func readBack(_ file: URL, partSize: Int64, shouldStop: () -> Bool = { false }) throws -> ReadBack {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let whole = HashBox()
        let pieces = partSize < size ? PartHasher(partSize: partSize) : nil
        let chunk = 8 << 20
        var next = try handle.read(upToCount: chunk)
        while let data = next, !data.isEmpty {
            if shouldStop() { throw CancellationError() }
            let ahead = ReadAhead()
            // Each task touches only its own state: the two hashes and the next read.
            DispatchQueue.concurrentPerform(iterations: 3) { task in
                switch task {
                case 0: whole.hash.update(data: data)
                case 1: pieces?.update(data)
                default: ahead.result = Result { try handle.read(upToCount: chunk) }
                }
            }
            next = try ahead.result?.get()
        }
        let md5 = Data(whole.hash.finalize())
        return ReadBack(md5: hex(md5), partMD5s: pieces?.finish() ?? [md5])
    }

    private final class HashBox: @unchecked Sendable { var hash = Insecure.MD5() }
    private final class ReadAhead: @unchecked Sendable { var result: Result<Data?, Error>? }

    /// MD5s of consecutive `partSize` pieces of a stream fed in chunks.
    private final class PartHasher: @unchecked Sendable {
        let partSize: Int64
        private var hash = Insecure.MD5()
        private var inPart: Int64 = 0
        private var parts: [Data] = []

        init(partSize: Int64) { self.partSize = partSize }

        func update(_ data: Data) {
            var offset = 0
            while offset < data.count {
                let take = Int(min(Int64(data.count - offset), partSize - inPart))
                data.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[offset..<offset + take])) }
                offset += take
                inPart += Int64(take)
                if inPart == partSize {
                    parts.append(Data(hash.finalize()))
                    hash = Insecure.MD5()
                    inPart = 0
                }
            }
        }

        func finish() -> [Data] {
            if inPart > 0 || parts.isEmpty { parts.append(Data(hash.finalize())) }
            return parts
        }
    }
}

/// Each upload row's file verifications, recorded by the engine as files finish and taken by the queue for the log.
final class VerificationTally: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UUID: [TransferVerification]] = [:]

    func add(_ job: UUID, _ verification: TransferVerification) {
        lock.withLock { items[job, default: []].append(verification) }
    }

    func take(_ job: UUID) -> TransferVerification? {
        TransferVerification.combined(lock.withLock { items.removeValue(forKey: job) ?? [] })
    }
}
