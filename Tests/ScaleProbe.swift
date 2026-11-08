import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

/// Timing probe (not a regression test): prints how list algorithms grow with input size.
@Suite("Scale probe", .disabled(if: ProcessInfo.processInfo.environment["QCPIE_SCALE_PROBE"] == nil))
struct ScaleProbe {
    func time(_ label: String, _ body: () -> Void) {
        let t = Date(); body(); print(String(format: "SCALE %@: %.3f s", label, Date().timeIntervalSince(t)))
    }

    @Test func sequences() {
        for n in [5_000, 20_000, 80_000] {
            let urls = (0..<n).map { URL(fileURLWithPath: "/seq/shot_\(String(format: "%06d", $0)).exr") }
            time("sequence detect \(n) frames") { _ = ImageSequenceDetector.detect(urls) }
            let mixed = (0..<n).map { URL(fileURLWithPath: "/d/clip_\($0 % 977)_\($0).mov") }
            time("sequence detect \(n) movies") { _ = ImageSequenceDetector.detect(mixed) }
        }
    }

    @Test func plan() {
        for n in [1_000, 4_000] {
            var csv = "\"Code\",\"File Name\",\"Length\",\"Resolution\"\n"
            for i in 0..<n { csv += "\"KL\(10000 + i)\",\"CAMPAIGN_SHOT\(i % 50)_\(i % 3 == 0 ? "9x16" : "16x9")_15s_KL\(10000 + i)\",\"15s\",\"1920x1080\"\n" }
            var rows: [PlanRow] = []
            time("plan parse \(n) rows") { rows = PlanParser.rows(csv: csv, tab: "T") }
            let files = (0..<n).map { i in PlanFile(url: URL(fileURLWithPath: "/d/CAMPAIGN_SHOT\(i % 50)_\(i % 3 == 0 ? "9x16" : "16x9")_15s_KL\(10000 + i).mp4"), width: 1920, height: 1080, seconds: 15, fps: 25, bytes: 1, codec: "H.264", hasAudio: true) }
            time("plan match \(n)×\(n)") { _ = PlanMatcher.match(rows: rows, files: files) }
            let noCodes = files.map { PlanFile(url: URL(fileURLWithPath: "/d/" + $0.url.lastPathComponent.replacingOccurrences(of: "_KL", with: "_X")), width: 1920, height: 1080, seconds: 15, fps: 25, bytes: 1, codec: "H.264", hasAudio: true) }
            time("plan match \(n)×\(n) no codes") { _ = PlanMatcher.match(rows: rows, files: noCodes) }
        }
    }

    @Test func naturalSortAndCSV() {
        for n in [10_000, 40_000] {
            let names = (0..<n).map { "Clip \(($0 * 7919) % n) v\($0 % 9).mov" }
            time("natural sort \(n)") { _ = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        }
    }
}
