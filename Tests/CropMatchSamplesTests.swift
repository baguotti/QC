import Foundation
import Testing
@testable import VideoQCLib

/// Opt-in: `CROP_SAMPLES=<folder of .mp4 versions> swift test -c release -Xswiftc -enable-testing --filter CropMatchSamples`
/// prints every set Crop Match finds (videos under the folder, subfolders included) and every shot. Does nothing without the variable.
@Suite("Crop Match samples")
struct CropMatchSamples {
    @Test("Prints the shots found in a real master and cutdowns")
    func samples() async throws {
        guard let folder = ProcessInfo.processInfo.environment["CROP_SAMPLES"] else { return }
        // Every video under the folder, subfolders included (as if all in one batch).
        let root = URL(fileURLWithPath: folder)
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
        let start = Date()
        let batch = await CropMatcher().run(files: files) { _ in }
        print("SAMPLE time", Date().timeIntervalSince(start), "sets", batch.runs.count, "singles", batch.singles.map(\.lastPathComponent))
        for run in batch.runs {
            print("SAMPLE ## \(run.title) | master \(run.labels[run.master] ?? run.masterName)")
            for r in run.results {
                print("SAMPLE ==", run.labels[r.fileURL] ?? r.fileName, "fps", r.fps, "frames", r.totalFrames, r.readError ?? "")
                for s in r.shots {
                    print("SAMPLE   c\(s.start)-\(s.end) m\(s.masterStart.map(String.init) ?? "-")-\(s.masterEnd.map(String.init) ?? "-") like \(String(format: "%.3f", s.likeness)) speed \(String(format: "%.2f", s.speed)) \(s.verdict) shift (\(String(format: "%.1f", s.shift.x)), \(String(format: "%.1f", s.shift.y))) scale \(String(format: "%.4f", s.scale)) pair \(s.measuredCutdownFrame.map(String.init) ?? "-")/\(s.measuredMasterFrame.map(String.init) ?? "-") fit \(String(format: "%.4f", s.fit)) asis \(String(format: "%.4f", s.fitAsIs))")
                }
            }
        }
    }
}
