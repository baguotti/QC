import Foundation

/// The bundled ffprobe (`scripts/build_ffprobe.sh`): reads the specs of files macOS can't open (WebM, MKV, AVI, VP9,
/// AV1 on older Macs…) for Inspect. Nothing is decoded for viewing. Runs only after AVFoundation failed, off the main
/// thread, a few at a time, with a timeout (a stalled network drive mustn't hang Inspect).
public enum FFprobe {
    /// The parts of ffprobe's JSON QCpie uses.
    public struct Probe: Sendable, Equatable {
        public struct Stream: Sendable, Equatable {
            public var index = 0
            public var type = ""            // video, audio, subtitle, data, attachment
            public var codec = ""           // ffprobe's codec_name: "vp9", "pcm_s24le"
            public var profile = ""
            public var width = 0, height = 0
            /// Pixel shape (`sample_aspect_ratio` "16:15" for DV PAL), 1 when square or unknown.
            public var pixelAspect = 1.0
            public var avgFrameRate = 0.0, realFrameRate = 0.0
            public var fieldOrder = ""
            public var rotation = 0.0       // display matrix, degrees counter-clockwise
            public var sampleRate = 0, channels = 0, bitsPerSample = 0
            public var bitRate = 0
            public var duration = 0.0
            public var language = ""
            public var isAttachedPicture = false   // cover art in an audio file
            public var hasClosedCaptions = false
        }
        public var formatName = ""
        public var duration = 0.0
        /// The first timestamp (MPEG-TS starts at 1.4 s, broadcast files at 10:00:00:00): packet times are absolute.
        public var startTime = 0.0
        public var bitRate = 0
        public var streams: [Stream] = []
        /// Presentation times of the first video stream's packets in the first seconds, as read (decode order).
        public var videoPacketTimes: [Double] = []

        public var video: Stream? { streams.first { $0.type == "video" && !$0.isAttachedPicture && $0.width > 0 } }
        public var audio: [Stream] { streams.filter { $0.type == "audio" } }
    }

    /// Seconds of packets read to measure the frame rate (container headers are often wrong: WebM written at a variable
    /// rate says 60, DV says 60000).
    static let packetSeconds = 5
    static let timeout: Duration = .seconds(20)

    /// The bundled binary: the app's Resources/Helpers, else the repository's (debug runs and tests, after
    /// `scripts/build_ffprobe.sh`). `QCPIE_FFPROBE` overrides. Nil when there's none: files read as before.
    public static let executableURL: URL? = {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["QCPIE_FFPROBE"], fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Helpers/ffprobe"), fm.isExecutableFile(atPath: bundled.path) {
            return clearQuarantine(bundled) ? bundled : userCopy(of: bundled) ?? bundled
        }
        // `swift test` runs in the repository.
        let inRepository = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Helpers/ffprobe")
        if fm.isExecutableFile(atPath: inRepository.path) { return inRepository }
        // .build/<config>/QCpie → repository root.
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = dir else { break }
            let candidate = current.appendingPathComponent("Resources/Helpers/ffprobe")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }()

    public static var isAvailable: Bool { executableURL != nil }

    /// A QCpie copied from the downloaded disk image keeps the download's quarantine on every file in it: macOS then
    /// kills the unsigned helper on launch (SIGKILL, measured), and every file macOS can't open read as Unreadable.
    /// Opening QCpie was the user's approval of the app; its own helper is let run too. The signature isn't touched
    /// (extended attributes aren't sealed). Failing (a read-only volume) is logged and the probe fails as before.
    /// True when `url` isn't quarantined (any more).
    @discardableResult
    static func clearQuarantine(_ url: URL) -> Bool {
        let name = "com.apple.quarantine"
        guard getxattr(url.path, name, nil, 0, 0, 0) >= 0 else { return true }
        return removexattr(url.path, name, 0) == 0
    }

    /// The app's helper can't be cleared (an admin's copy run by a standard user, a read-only volume): a copy in
    /// Application Support, which this user owns, is cleared and run instead. Nil (logged) when that fails too.
    static func userCopy(of bundled: URL) -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let copy = support.appendingPathComponent("QCpie/Helpers/ffprobe")
        // The same build: size and date (a copy keeps the date), so an update's new helper replaces the old copy.
        func stamp(_ url: URL) -> [String]? {
            (try? fm.attributesOfItem(atPath: url.path)).map { ["\($0[.size] ?? "")", "\($0[.modificationDate] ?? "")"] }
        }
        let same = stamp(copy) != nil && stamp(copy) == stamp(bundled)
        if !(fm.isExecutableFile(atPath: copy.path) && same) {
            try? fm.removeItem(at: copy)
            do {
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: bundled, to: copy)
            } catch {
                Log.inspect.error("ffprobe is quarantined and couldn't be copied out: files macOS can't open will read as Unreadable", error)
                return nil
            }
        }
        guard clearQuarantine(copy) else {
            Log.inspect.error("ffprobe is quarantined and couldn't be cleared: files macOS can't open will read as Unreadable")
            return nil
        }
        return copy
    }

    /// Probes `url`; nil when ffprobe is missing, fails, times out or finds no audio or video.
    public static func probe(_ url: URL) async -> Probe? {
        guard let executable = executableURL else { return nil }
        await gate.enter()
        defer { Task { await gate.leave() } }
        // Inspect moved on (another batch) while this waited for a turn: don't start it.
        guard !Task.isCancelled, let data = await run(executable, arguments: [
            "-v", "error", "-of", "json", "-show_format", "-show_streams",
            "-show_entries", "packet=stream_index,pts_time", "-read_intervals", "%+\(packetSeconds)",
            input(url),
        ]) else { return nil }
        guard let probe = parse(data), probe.video != nil || !probe.audio.isEmpty else { return nil }
        return probe
    }

    /// The latest packet time of the first video (else audio) stream read from `seconds` (absolute) to the end of the
    /// file; nil when ffprobe fails or finds none. A file cut off after its header (a copy still running) ends early:
    /// its header still gives the full duration. Seeks to the keyframe before `seconds` (a long GOP is read from there).
    public static func lastPacketTime(_ url: URL, from seconds: Double, video: Bool) async -> Double? {
        guard let executable = executableURL else { return nil }
        await gate.enter()
        defer { Task { await gate.leave() } }
        guard !Task.isCancelled, let data = await run(executable, arguments: [
            "-v", "error", "-select_streams", video ? "v:0" : "a:0", "-read_intervals", String(format: "%.3f%%", max(0, seconds)),
            "-show_entries", "packet=pts_time", "-of", "csv=p=0", input(url),
        ]) else { return nil }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: ", "))) }.filter(\.isFinite).max()
    }

    /// The file as ffprobe's input: through the file protocol, so no name is read as a protocol or a pattern.
    static func input(_ url: URL) -> String { "file:" + url.path }

    /// At most four ffprobes at once (a folder of 300 MKVs mustn't start 300 processes).
    private static let gate = Gate(limit: 4)

    private actor Gate {
        let limit: Int
        var running = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
        init(limit: Int) { self.limit = limit }

        func enter() async {
            if running < limit { running += 1; return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func leave() {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
    }

    /// stdout of the run, or nil on a non-zero exit or after `timeout`. Waits through the termination handler
    /// (`waitUntilExit()` in async code hung after ffprobe had exited). At the timeout ffprobe is terminated, killed
    /// 2 s later, and the caller gets nil at once either way: a read stuck on a dead network drive can outlive a kill.
    static func run(_ executable: URL, arguments: [String], timeout: Duration = FFprobe.timeout) async -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let result = Once()
        process.terminationHandler = { finished in
            // The pipe is drained by the reader below; take what it read once ffprobe is gone.
            result.exited(status: finished.terminationStatus, signalled: finished.terminationReason == .uncaughtSignal)
        }
        var killer: Task<Void, Never>?
        let value = await withCheckedContinuation { continuation in
            result.set(continuation)
            do { try process.run() } catch {
                Log.inspect.error("ffprobe didn't start", error)
                result.finish(nil)
                return
            }
            // Read to the end on its own thread (the pipe would fill and stall ffprobe if left unread), then close it.
            let reading = output.fileHandleForReading
            Thread.detachNewThread {
                let data = reading.readDataToEndOfFile()
                try? reading.close()
                result.read(data)
            }
            let pid = process.processIdentifier
            killer = Task.detached {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, !result.isFinished else { return }
                Log.inspect.notice("ffprobe timed out after \(timeout) on \(arguments.last ?? "")")
                result.finish(nil, timedOut: true)
                process.terminate()
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        // Finished in time: drop the timer at once. Left sleeping it kept the process and its pipe for 20 s, and a few
        // hundred files would run out of descriptors (256 for an app opened from the Finder).
        if !result.timedOut { killer?.cancel() }
        // Killed by the system (e.g. macOS refusing to run the helper): logged, the file then reads as Unreadable.
        if !result.timedOut, let signal = result.signal { Log.inspect.error("ffprobe was killed by signal \(signal) on \(arguments.last ?? "")") }
        return value
    }

    /// The run's result, delivered once: when ffprobe has exited and its output is read, or at the timeout.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data?, Never>?
        private var data: Data?, status: Int32?
        private var done = false, didTimeOut = false, wasSignalled = false

        var isFinished: Bool { lock.withLock { done } }
        var timedOut: Bool { lock.withLock { didTimeOut } }
        /// The signal that ended ffprobe, if one did.
        var signal: Int32? { lock.withLock { wasSignalled ? status : nil } }
        func set(_ c: CheckedContinuation<Data?, Never>) { lock.withLock { continuation = c } }
        func read(_ d: Data) { lock.withLock { data = d }; deliverIfComplete() }
        func exited(status s: Int32, signalled: Bool) { lock.withLock { status = s; wasSignalled = signalled }; deliverIfComplete() }

        private func deliverIfComplete() {
            let ready: (Data?, Int32)? = lock.withLock { data != nil && status != nil ? (data, status!) : nil }
            if let (d, s) = ready { finish(s == 0 ? d : nil) }
        }

        func finish(_ value: Data?, timedOut: Bool = false) {
            let c: CheckedContinuation<Data?, Never>? = lock.withLock {
                guard !done else { return nil }
                done = true
                didTimeOut = timedOut
                defer { continuation = nil }
                return continuation
            }
            c?.resume(returning: value)
        }
    }

    // MARK: - Parsing

    public static func parse(_ data: Data) -> Probe? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var probe = Probe()
        if let format = root["format"] as? [String: Any] {
            probe.formatName = format["format_name"] as? String ?? ""
            probe.duration = number(format["duration"])
            probe.startTime = number(format["start_time"])
            probe.bitRate = int(format["bit_rate"])
        }
        for raw in root["streams"] as? [[String: Any]] ?? [] {
            var s = Probe.Stream()
            s.index = int(raw["index"], default: -1)
            s.type = raw["codec_type"] as? String ?? ""
            s.codec = raw["codec_name"] as? String ?? ""
            s.profile = raw["profile"] as? String ?? ""
            s.width = int(raw["width"])
            s.height = int(raw["height"])
            if let sar = raw["sample_aspect_ratio"] as? String {
                let parts = sar.split(separator: ":").compactMap { Double($0) }
                if parts.count == 2, parts[0] > 0, parts[1] > 0, (parts[0] / parts[1]).isFinite, (0.1...10).contains(parts[0] / parts[1]) {
                    s.pixelAspect = parts[0] / parts[1]
                }
            }
            s.avgFrameRate = rate(raw["avg_frame_rate"])
            s.realFrameRate = rate(raw["r_frame_rate"])
            s.fieldOrder = raw["field_order"] as? String ?? ""
            // Plausible values only (a damaged header's would overflow the bit rate maths).
            s.sampleRate = min(int(raw["sample_rate"]), 1_000_000)
            s.channels = min(int(raw["channels"]), 1_024)
            s.bitsPerSample = int(raw["bits_per_raw_sample"])
            if s.bitsPerSample == 0 { s.bitsPerSample = int(raw["bits_per_sample"]) }
            s.bitsPerSample = min(s.bitsPerSample, 64)
            s.bitRate = int(raw["bit_rate"])
            s.duration = number(raw["duration"])
            s.hasClosedCaptions = int(raw["closed_captions"]) != 0
            if let disposition = raw["disposition"] as? [String: Any] {
                s.isAttachedPicture = int(disposition["attached_pic"]) != 0
            }
            if let tags = raw["tags"] as? [String: Any] {
                let language = (tags["language"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                s.language = language.lowercased() == "und" ? "" : language
            }
            for side in raw["side_data_list"] as? [[String: Any]] ?? [] where side["rotation"] != nil {
                s.rotation = number(side["rotation"])
            }
            probe.streams.append(s)
        }
        if let videoIndex = probe.video?.index {
            // Packets without a time ("N/A": AVI, raw streams) are skipped, not read as 0 s.
            probe.videoPacketTimes = (root["packets"] as? [[String: Any]] ?? []).compactMap { packet in
                guard int(packet["stream_index"], default: -1) == videoIndex else { return nil }
                if let n = packet["pts_time"] as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
                guard let s = packet["pts_time"] as? String, let t = Double(s), t.isFinite else { return nil }
                return t
            }
        }
        return probe
    }

    /// ffprobe writes most numbers as strings ("2.008000"), some as numbers; "N/A" is 0.
    static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s), d.isFinite { return d }
        return 0
    }

    /// A whole number from ffprobe's JSON, clamped: a damaged header's "1e30" mustn't trap `Int(_:)`.
    static func int(_ value: Any?, default fallback: Int = 0) -> Int {
        guard value != nil else { return fallback }
        let d = number(value)
        return d >= 0 && d < 1e15 ? Int(d) : fallback
    }

    /// "30000/1001" → 29.97; "0/0" → 0.
    static func rate(_ value: Any?) -> Double {
        guard let s = value as? String else { return 0 }
        let parts = s.split(separator: "/")
        guard parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 else { return Double(s).flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        let r = n / d
        return r.isFinite ? r : 0
    }
}
