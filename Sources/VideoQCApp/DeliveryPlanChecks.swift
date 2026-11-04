import Foundation
import VideoQCLib

// Delivery Plan checks: loudness and Frame Check on the plan's files (Line Check stays in the Scan tab), run only when asked (Run Checks).
// Built for a MacBook Air: one file at a time (two on Macs with 12+ cores), nothing while the Player plays (a running
// file is stopped and queued again), waits between files while the Mac is hot or in Low Power Mode. Results belong to
// a file version (size + modification date): a new export shows as not checked.

enum PlanCheckKind: String, CaseIterable, Codable, Sendable, Hashable {
    case loudness, frames

    var title: String {
        switch self {
        case .loudness: return "Loudness"
        case .frames: return "Frame Check"
        }
    }
}

struct PlanCheckOutcome: Codable, Equatable, Sendable {
    var passed: Bool
    var summary: String
}

/// One file version's results.
struct PlanFileChecks: Codable, Equatable, Sendable {
    var size: Int64
    var modified: Date
    var outcomes: [PlanCheckKind: PlanCheckOutcome] = [:]
}

/// A row's checks across its files, for the gutter ring, the card and "Pass All Clean".
struct PlanChecksSummary: Equatable, Sendable {
    enum Result: Equatable, Sendable { case notRun, partial, passed, failed }
    var result: Result
    /// "Loudness ✓ −14.0 LUFS · −1.2 dBTP", "Frame Check ✗ 2 flash frames"…
    var lines: [String]
    /// Failures only, for a "Needs Fix" note.
    var failures: [String]
}

/// Progress, observed only by the progress strip (≤ 5 updates a second while a file is checked).
@MainActor
final class PlanCheckProgress: ObservableObject {
    @Published var text = ""
    @Published var fraction: Double = 0
    @Published var waiting: String? = nil
}

@MainActor
final class PlanCheckQueue: ObservableObject {
    static let shared = PlanCheckQueue()

    /// By file. Published once per finished file.
    @Published private(set) var results: [URL: PlanFileChecks] = [:] { didSet { revision &+= 1 } }
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var running: Set<URL> = [] { didSet { revision &+= 1 } }
    /// Changes whenever a summary could (cache key for the plan's per-row summaries).
    private(set) var revision = 0
    let progress = PlanCheckProgress()

    /// The checks Run Checks runs (remembered).
    @Published var kinds: Set<PlanCheckKind> {
        didSet { UserDefaults.standard.set(kinds.map(\.rawValue), forKey: Self.kindsKey); revision &+= 1 }
    }

    /// Set by `ContentView`: checks never decode while the Player plays.
    var isPlayerPlaying = false {
        didSet { if isPlayerPlaying, !oldValue { yieldToPlayback() } }
    }

    private struct Job: Equatable { let url: URL; let kinds: Set<PlanCheckKind> }
    private var queue: [Job] = []
    private var done = 0
    private var total = 0
    private var workers: Task<Void, Never>?
    private var scanners: [URL: FrameCheckScanner] = [:]
    private var interrupted: Set<URL> = []
    private var saveTask: Task<Void, Never>?
    private var loaded = false

    private static let kindsKey = "planCheckKinds"
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QCpie/DeliveryPlan/checks.json")
    }

    private init() {
        let saved = (UserDefaults.standard.array(forKey: Self.kindsKey) as? [String])?.compactMap(PlanCheckKind.init(rawValue:))
        kinds = Set(saved ?? PlanCheckKind.allCases)
    }

    /// Results from disk, once (off the main thread).
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        Task {
            let url = Self.fileURL
            let saved = await Task.detached(priority: .utility) { () -> [String: PlanFileChecks] in
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: PlanFileChecks].self, from: $0) } ?? [:]
            }.value
            var merged = Dictionary(uniqueKeysWithValues: saved.map { (URL(fileURLWithPath: $0.key), $0.value) })
            merged.merge(results) { _, new in new }
            if merged != results { results = merged }
        }
    }

    // MARK: Results

    /// The file's results if they belong to this version of it.
    func checks(for url: URL, size: Int64, modified: Date?) -> PlanFileChecks? {
        guard let r = results[url], r.size == size, modified.map({ abs($0.timeIntervalSince(r.modified)) < 1 }) ?? true else { return nil }
        return r
    }

    /// `files`: the row's files with their size and date (from the plan store). Ready = every kind in `kinds` passed.
    func summary(files: [(url: URL, size: Int64, modified: Date?)], kinds: Set<PlanCheckKind>) -> PlanChecksSummary {
        guard !files.isEmpty else { return PlanChecksSummary(result: .notRun, lines: [], failures: []) }
        var lines: [String] = [], failures: [String] = []
        var missing = false, failed = false
        for file in files {
            let current = checks(for: file.url, size: file.size, modified: file.modified)
            let prefix = files.count > 1 ? file.url.lastPathComponent + ": " : ""
            for kind in PlanCheckKind.allCases {
                guard let outcome = current?.outcomes[kind] else {
                    if kinds.contains(kind) { missing = true }
                    continue
                }
                lines.append("\(prefix)\(kind.title) \(outcome.passed ? "✓" : "✗") \(outcome.summary)")
                if !outcome.passed { failed = true; failures.append("\(prefix)\(kind.title): \(outcome.summary)") }
            }
        }
        if running.contains(where: { url in files.contains { $0.url == url } }) { lines.insert("Checking…", at: 0) }
        let result: PlanChecksSummary.Result = failed ? .failed : missing ? (lines.isEmpty ? .notRun : .partial) : .passed
        return PlanChecksSummary(result: result, lines: lines, failures: failures)
    }

    // MARK: Queue

    /// Queues files for the given checks, skipping files whose current version already has them.
    func enqueue(_ files: [(url: URL, size: Int64, modified: Date?)], kinds: Set<PlanCheckKind>) {
        loadIfNeeded()
        var added = 0
        var queued = Set(queue.map(\.url))   // a set: 1,000+ files would otherwise be ~500k comparisons on the main thread
        for file in files {
            let have = Set(checks(for: file.url, size: file.size, modified: file.modified)?.outcomes.keys.map { $0 } ?? [])
            let need = kinds.subtracting(have)
            guard !need.isEmpty, !queued.contains(file.url), !running.contains(file.url) else { continue }
            queue.append(Job(url: file.url, kinds: need))
            queued.insert(file.url)
            added += 1
        }
        guard added > 0 else { return }
        total += added
        start()
    }

    func pause() { isPaused = true; updateWaiting() }
    func resume() { isPaused = false; updateWaiting() }

    /// Stops after cancelling the files being checked; their partial results are dropped.
    func stop() {
        queue.removeAll()
        isPaused = false   // else the next Run Checks would sit at "Paused"
        for (_, scanner) in scanners { scanner.cancel() }
        workers?.cancel()
    }

    private func start() {
        guard workers == nil else { return }
        isRunning = true
        let width = ProcessInfo.processInfo.activeProcessorCount >= 12 && !ProcessInfo.processInfo.isLowPowerModeEnabled ? 2 : 1
        workers = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<width { group.addTask { await self.work() } }
            }
            workers = nil
            isRunning = false
            running = []
            done = 0
            total = 0
            progress.text = ""
            progress.fraction = 0
            progress.waiting = nil
        }
    }

    private var mustWait: String? {
        if isPaused { return "Paused" }
        if isPlayerPlaying { return "Waiting while the Player plays" }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return "Waiting: the Mac is hot" }
        return nil
    }

    private func updateWaiting() { progress.waiting = isRunning ? mustWait : nil }

    private func work() async {
        while !Task.isCancelled {
            // Between files only: wait out pause, playback and heat.
            while let reason = mustWait, !Task.isCancelled {
                progress.waiting = reason
                try? await Task.sleep(for: .milliseconds(500))
            }
            progress.waiting = nil
            guard !Task.isCancelled, !queue.isEmpty else { return }
            let job = queue.removeFirst()
            running.insert(job.url)
            let outcome = await check(job)
            running.remove(job.url)
            if interrupted.remove(job.url) != nil {
                queue.insert(job, at: 0)   // stopped for playback: again later
                continue
            }
            done += 1
            if let outcome { store(job.url, outcome) }
        }
    }

    /// Playback started on this Mac: stop the files being checked now (decoding competes with it) and queue them again.
    private func yieldToPlayback() {
        for (url, scanner) in scanners {
            interrupted.insert(url)
            scanner.cancel()
        }
        updateWaiting()
    }

    private func check(_ job: Job) async -> PlanFileChecks? {
        let url = job.url
        let stamp = await Task.detached(priority: .utility) { () -> (Int64, Date)? in
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return ((a[.size] as? NSNumber)?.int64Value ?? 0, a[.modificationDate] as? Date ?? .distantPast)
        }.value
        guard let stamp else { return nil }
        var result = PlanFileChecks(size: stamp.0, modified: stamp.1)
        if let old = results[url], old.size == result.size, abs(old.modified.timeIntervalSince(result.modified)) < 1 {
            result.outcomes = old.outcomes
        }
        let kind = QCUtilities.mediaKind(of: url)
        let name = url.lastPathComponent
        let order = PlanCheckKind.allCases.filter(job.kinds.contains)
        for (i, check) in order.enumerated() {
            if Task.isCancelled || interrupted.contains(url) { return nil }
            setProgress(name, step: i, of: order.count, fraction: 0, kind: check)
            switch check {
            case .loudness:
                guard kind != .image else { result.outcomes[.loudness] = Self.notApplicable("image"); continue }
                let levels = await DeliverablesInspector.extractAudioLevels(for: url)
                if let m = levels.loudness {
                    let (verdict, issues) = LoudnessTarget.current.evaluate(m)
                    let figures = m.integrated.map { String(format: "%.1f LUFS · %.1f dBTP", $0, m.truePeak) }
                    result.outcomes[.loudness] = PlanCheckOutcome(passed: verdict != .fail,
                                                                  summary: ((figures.map { [$0] } ?? []) + issues).joined(separator: " · "))
                } else {
                    result.outcomes[.loudness] = PlanCheckOutcome(passed: true, summary: "No audio")
                }
            case .frames:
                guard kind == .video else { result.outcomes[.frames] = Self.notApplicable(kind == .image ? "image" : "audio"); continue }
                let scanner = FrameCheckScanner()
                scanners[url] = scanner
                let frameResults = await scanner.scanBatch([url], concurrency: 1) { p in
                    Task { @MainActor in
                        self.setProgress(name, step: i, of: order.count,
                                         fraction: p.totalFrames > 0 ? Double(p.frame) / Double(p.totalFrames) : 0, kind: check)
                    }
                }
                scanners[url] = nil
                if interrupted.contains(url) || Task.isCancelled { return nil }
                if let r = frameResults.first {
                    result.outcomes[.frames] = PlanCheckOutcome(passed: !r.isFlagged, summary: r.verdict)
                }
            }
        }
        scanners[url] = nil
        return result
    }

    /// A check that doesn't apply to this kind of file counts as passed (else such files would be queued forever).
    private static func notApplicable(_ what: String) -> PlanCheckOutcome { PlanCheckOutcome(passed: true, summary: "n/a (\(what))") }

    private var lastProgress = Date.distantPast

    /// ≤ 5 updates a second.
    private func setProgress(_ name: String, step: Int, of steps: Int, fraction: Double, kind: PlanCheckKind) {
        let now = Date()
        guard fraction == 0 || now.timeIntervalSince(lastProgress) > 0.2 else { return }
        lastProgress = now
        let overall = (Double(done) + (Double(step) + fraction) / Double(max(1, steps))) / Double(max(1, total))
        progress.fraction = overall
        progress.text = "\(min(done + 1, total)) of \(total) · \(kind.title) · \(name)"
    }

    private func store(_ url: URL, _ checks: PlanFileChecks) {
        results[url] = checks
        // Results of renamed, moved or deleted files would pile up across projects: keep the newest 3,000.
        if results.count > 3_000 {
            let drop = results.sorted { $0.value.modified < $1.value.modified }.prefix(results.count - 3_000).map(\.key)
            for key in drop { results[key] = nil }
        }
        saveTask?.cancel()
        let snapshot = Dictionary(uniqueKeysWithValues: results.map { ($0.key.path, $0.value) })
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let url = Self.fileURL
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
            }
        }
    }
}

/// Per-row check summaries for the plan panel, rebuilt only when checks, matching or files change (the panel redraws on
/// every Inspect selection; recomputing 1,000+ summaries each time was felt on a MacBook Air).
@MainActor
final class PlanChecksSummaryCache {
    private var key: (Int, Int) = (-1, -1)
    private var summaries: [String: PlanChecksSummary] = [:]

    func summary(_ row: PlanRow, store: DeliveryPlanStore, queue: PlanCheckQueue) -> PlanChecksSummary {
        let current = (queue.revision, store.matchRevision)
        if current != key { key = current; summaries = [:] }
        if let cached = summaries[row.id] { return cached }
        let summary = queue.summary(files: store.fileStamps(row), kinds: queue.kinds)
        summaries[row.id] = summary
        return summary
    }
}
