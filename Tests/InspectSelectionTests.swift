import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

/// Actions on Inspect's selection (plan status, batch, ⌥1–⌥6) must never reach files a filter or search hides.
@MainActor
@Suite("Inspect selection")
struct InspectSelectionTests {
    private func asset(_ name: String) -> DeliverableAsset {
        DeliverableAsset(fileURL: URL(fileURLWithPath: "/d/\(name)"), fileName: name, fileSizeBytes: 1, formattedFileSize: "1 B",
                         width: 1920, height: 1080, resolutionString: "1920 x 1080", aspectRatioString: "16:9",
                         durationSeconds: 1, formattedDuration: "1.00s", totalFrames: 25, timecode: "00:00:01:00", fps: 25,
                         videoCodec: "H.264", audioConfig: "NONE", container: "MP4")
    }

    @Test("Filtering drops hidden files from the selection; clearing the filter doesn't bring them back")
    func filterPrunesSelection() async {
        let specs = SpecsState()
        specs.deliverableAssets = [asset("A_clean.mp4"), asset("B_logo.mp4"), asset("C_clean.mp4")]
        _ = specs.displayedAssets(filter: "", mask: MediaKindFilter.all)
        specs.selectedDeliverableURLs = Set(specs.deliverableAssets.map(\.fileURL))

        let shown = specs.displayedAssets(filter: "clean", mask: MediaKindFilter.all)
        #expect(shown.count == 2)
        await Task.yield(); await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(specs.selectedDeliverableURLs == Set(shown.map(\.fileURL)))

        _ = specs.displayedAssets(filter: "", mask: MediaKindFilter.all)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(specs.selectedDeliverableURLs.count == 2)
    }
}

/// Loading folders and adding files in quick succession: inspections finish in any order, and the list must end up
/// as the last replace plus whatever was appended after it.
@MainActor
@Suite("Inspect batch order")
struct InspectBatchOrderTests {
    private func files(_ prefix: String, _ n: Int, in dir: URL) throws -> [URL] {
        try (0..<n).map { i in
            let url = dir.appendingPathComponent("\(prefix)_\(i).mp4")
            try Data("not a video".utf8).write(to: url)
            return url
        }
    }

    @Test("Replace, append, replace, append: the result is the last replace plus later appends")
    func rapidLoads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("InspectOrder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try files("a", 40, in: dir), b = try files("b", 3, in: dir), c = try files("c", 5, in: dir), d = try files("d", 2, in: dir)
        let specs = SpecsState()
        specs.inspectDeliverablesBatch(urls: a)                 // big and slow: lands last
        specs.inspectDeliverablesBatch(urls: b, append: true)   // belongs to the old queue
        specs.inspectDeliverablesBatch(urls: c)                 // replaces everything
        specs.inspectDeliverablesBatch(urls: d, append: true)
        for _ in 0..<200 where specs.isInspectingDeliverables { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        let names = Set(specs.deliverableAssets.map(\.fileURL.lastPathComponent))
        #expect(names == Set((c + d).map(\.lastPathComponent)), "got \(names.sorted())")
        #expect(!specs.isInspectingDeliverables)
    }
}
