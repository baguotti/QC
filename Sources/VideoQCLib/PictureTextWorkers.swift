import Foundation
import os

/// Helper processes for Check Subs & Graphics. Vision reads one frame at a time per process (2, 4 or 8 threads: the
/// same time), while separate processes run side by side (4 ≈ 3× on an M4 Max), so a scan on a Mac with the memory
/// for it also starts copies of QCpie in worker mode (`flag`). Each reads one file at a time and sends back its
/// `PictureTextScanner.Reading`; classifying stays in the app.
///
/// Protocol: JSON lines. App → worker: `{"file": path}` or `{"pause": true/false}`. Worker → app: `{"file", "share"}`
/// while reading, then `{"file", "reading"}`. The worker quits when its input closes (the scan ended or was
/// cancelled, or QCpie quit or crashed), paused or not; it never writes to QCpie's log file.
public final class PictureTextWorkers: @unchecked Sendable {
    public static let flag = "--picture-text-worker"

    public struct Options: Sendable {
        public var executable: URL
        public var count: Int
        /// Checked a few times a second: true holds the workers mid-file (playback, Low Power Mode, a hot Mac).
        public var shouldPause: @Sendable () -> Bool

        public init(executable: URL, count: Int, shouldPause: @escaping @Sendable () -> Bool) {
            self.executable = executable
            self.count = count
            self.shouldPause = shouldPause
        }
    }

    /// Each worker takes ~200 MB (Vision's text models and decode buffers): none on 8 GB Macs, 2 on 16 GB, 4 above
    /// (more add little: 8 processes ≈ 3.2× against 4 ≈ 3×).
    public static func recommendedCount(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let gigabytes = Double(memory) / 1_073_741_824
        return gigabytes < 12 ? 0 : gigabytes < 24 ? 2 : 4
    }

    let workers: [Worker]
    private let timer: DispatchSourceTimer

    /// Starts up to `options.count` workers, no more than the files beyond the app's own two lanes; nil when none.
    init?(options: Options, files: Int, isCancelled: @escaping @Sendable () -> Bool) {
        let wanted = min(options.count, files - 2)
        guard wanted > 0 else { return nil }
        let paused = options.shouldPause()
        workers = (0..<wanted).compactMap { _ in Worker(executable: options.executable, paused: paused) }
        guard !workers.isEmpty else {
            Log.inspect.error("Subs & graphics: no helper process started (\(options.executable.path))")
            return nil
        }
        Log.inspect.notice("Subs & graphics: reading with \(workers.count) helper process(es)")
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        let workers = workers
        let wasPaused = OSAllocatedUnfairLock(initialState: paused)
        timer.setEventHandler {
            if isCancelled() { workers.forEach { $0.stop() }; return }
            let paused = options.shouldPause()
            guard wasPaused.withLock({ was in defer { was = paused }; return was != paused }) else { return }
            workers.forEach { $0.setPaused(paused) }
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        workers.forEach { $0.stop() }
    }

    /// Never fails on a non-finite number: a reading that can't be encoded would leave its lane waiting forever.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    struct Message: Codable {
        var file: String?
        var pause: Bool?
        var share: Double?
        var reading: PictureTextScanner.Reading?
    }

    /// The app's handle on one worker process.
    final class Worker: @unchecked Sendable {
        private struct Pending {
            let path: String
            let reading: @Sendable (Double) -> Void
            let done: CheckedContinuation<PictureTextScanner.Reading?, Never>
        }

        private let process = Process()
        private let input: FileHandle
        private let lock = NSLock()
        private let writeLock = NSLock()
        private var pending: Pending?
        private var ended = false

        init?(executable: URL, paused: Bool) {
            let toWorker = Pipe(), fromWorker = Pipe()
            process.executableURL = executable
            process.arguments = [PictureTextWorkers.flag]
            process.standardInput = toWorker
            process.standardOutput = fromWorker
            process.standardError = FileHandle.nullDevice
            process.qualityOfService = .utility
            input = toWorker.fileHandleForWriting
            // A write after the worker went away fails instead of killing QCpie with SIGPIPE.
            _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
            process.terminationHandler = { [weak self] _ in self?.end() }
            do { try process.run() } catch { return nil }
            if paused { setPaused(true) }
            let output = fromWorker.fileHandleForReading
            Thread { [weak self] in
                PictureTextWorkers.forEachLine(of: output) { self?.handle($0) }
                self?.end()
            }.start()
        }

        /// The file's reading, or nil when the worker went away before finishing it.
        func read(_ url: URL, reading: @escaping @Sendable (Double) -> Void) async -> PictureTextScanner.Reading? {
            await withCheckedContinuation { continuation in
                let started = lock.withLock {
                    guard !ended else { return false }
                    pending = Pending(path: url.path, reading: reading, done: continuation)
                    return true
                }
                guard started else { continuation.resume(returning: nil); return }
                if !send(Message(file: url.path)) { finish(nil) }
            }
        }

        func setPaused(_ paused: Bool) { _ = send(Message(pause: paused)) }

        func stop() {
            try? input.close()
            if process.isRunning { process.terminate() }
            end()
        }

        private func send(_ message: Message) -> Bool {
            guard let data = try? PictureTextWorkers.encoder.encode(message) else { return false }
            return writeLock.withLock { (try? input.write(contentsOf: data + [10])) != nil }
        }

        private func handle(_ line: Data) {
            guard let message = try? PictureTextWorkers.decoder.decode(Message.self, from: line), let file = message.file else { return }
            if let reading = message.reading {
                finish(reading, path: file)
            } else if let share = message.share, let pending = lock.withLock({ pending?.path == file ? pending : nil }) {
                pending.reading(share)
            }
        }

        private func finish(_ reading: PictureTextScanner.Reading?, path: String? = nil) {
            let done = lock.withLock { () -> Pending? in
                guard let pending, path == nil || pending.path == path else { return nil }
                self.pending = nil
                return pending
            }
            done?.done.resume(returning: reading)
        }

        private func end() {
            lock.withLock { ended = true }
            finish(nil)
        }
    }

    // MARK: - Worker process

    /// The worker process's whole life: serves the app until its input closes, then exits.
    public static func runProcess() -> Never {
        Task.detached {
            await serve(input: .standardInput, output: .standardOutput)
            exit(0)
        }
        dispatchMain()
    }

    /// Reads the files sent on `input` one at a time, writing progress and readings to `output`; returns when `input`
    /// closes (abandoning a file part-read).
    static func serve(input: FileHandle, output: FileHandle) async {
        let gate = Gate()
        let (files, queued) = AsyncStream.makeStream(of: URL.self)
        Thread {
            forEachLine(of: input) { line in
                guard let message = try? PictureTextWorkers.decoder.decode(Message.self, from: line) else { return }
                if let pause = message.pause { gate.setPaused(pause) }
                if let file = message.file { queued.yield(URL(fileURLWithPath: file)) }
            }
            gate.end()
            queued.finish()
        }.start()
        let writeLock = NSLock()
        @Sendable func send(_ message: Message) {
            guard let data = try? PictureTextWorkers.encoder.encode(message) else { return }
            writeLock.withLock { _ = try? output.write(contentsOf: data + [10]) }
        }
        for await url in files {
            // Checked before every frame: holds the read while paused, stops it when the input closed.
            let reading = await PictureTextScanner.read(url, isCancelled: { gate.waitWhilePaused() }) { share in
                send(Message(file: url.path, share: share))
            }
            if gate.hasEnded { return }
            send(Message(file: url.path, reading: reading))
        }
    }

    /// Pause and end, shared by the worker's input thread and its reading thread.
    final class Gate: @unchecked Sendable {
        private let condition = NSCondition()
        private var paused = false
        private var ended = false

        var hasEnded: Bool { condition.withLock { ended } }

        func setPaused(_ value: Bool) { condition.withLock { paused = value; condition.broadcast() } }
        func end() { condition.withLock { ended = true; condition.broadcast() } }

        /// Waits while paused; true once ended.
        func waitWhilePaused() -> Bool {
            condition.withLock {
                while paused && !ended { condition.wait() }
                return ended
            }
        }
    }

    /// Calls `body` with each line as it arrives, until the other end closes. A plain `read`: `FileHandle.read(upToCount:)`
    /// waits for the whole count, so a short message would sit unread.
    static func forEachLine(of handle: FileHandle, _ body: (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(handle.fileDescriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            // Only the new bytes are searched: a long film's reading is one line of several MB.
            var searchFrom = buffer.endIndex
            buffer.append(chunk, count: count)
            while let newline = buffer[searchFrom...].firstIndex(of: 10) {
                body(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
                searchFrom = buffer.startIndex
            }
        }
    }
}
