import Foundation
import Testing
@testable import VideoQCLib

/// Opt-in: `CROP_SAMPLES=<folder of .mp4 versions> swift test -c release -Xswiftc -enable-testing --filter CropMatchSamples`
/// prints every shot Crop Match finds (the master is the longest). Does nothing without the variable.
@Suite("Crop Match samples")
struct CropMatchSamples {
    @Test("Prints the shots found in a real master and cutdowns")
    func samples() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CROP_SAMPLES"] else { return }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".mp4") }.sorted()
            .map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
        let start = Date()
        let run = try #require(await CropMatcher().run(master: nil, files: files) { _ in })
        print("SAMPLE master:", run.masterName, "time", Date().timeIntervalSince(start))
        for r in run.results {
            print("SAMPLE ==", r.fileName, "fps", r.fps, "frames", r.totalFrames, r.skipped ?? "", r.readError ?? "")
            for s in r.shots {
                print("SAMPLE   c\(s.start)-\(s.end) m\(s.masterStart.map(String.init) ?? "-")-\(s.masterEnd.map(String.init) ?? "-") like \(String(format: "%.3f", s.likeness)) speed \(String(format: "%.2f", s.speed)) \(s.verdict) shift (\(String(format: "%.1f", s.shift.x)), \(String(format: "%.1f", s.shift.y))) scale \(String(format: "%.4f", s.scale)) pair \(s.measuredCutdownFrame.map(String.init) ?? "-")/\(s.measuredMasterFrame.map(String.init) ?? "-")")
            }
        }
    }
}
