import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

/// Whole flows through the app's models on real clips, for bugs that unit tests of one function don't see
/// (Inspect listing one file of a full queue, the updater installing the plugin's disk image).
@MainActor @Suite("App flows", .serialized)
struct AppFlowTests {
    /// `count` copies of one short clip in a fresh folder; the caller removes the folder.
    private func queue(_ count: Int, frame: SyntheticFrame = Scenes.picture()) async throws -> [URL] {
        let first = try await TestClips.ntscOn600TimeBase(frame, frames: 12)
        let folder = first.deletingLastPathComponent()
        return try (0..<count).map { index in
            let url = folder.appendingPathComponent("clip_\(index).mov")
            try FileManager.default.copyItem(at: first, to: url)
            return url
        } .sorted { $0.path < $1.path }
    }

    private func settle(_ specs: SpecsState, until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test("Inspect lists the whole queue after Media Info read one clip")
    func inspectListsTheQueueAfterMediaInfo() async throws {
        let clips = try await queue(4)
        defer { try? FileManager.default.removeItem(at: clips[0].deletingLastPathComponent()) }
        let specs = SpecsState()
        specs.queueChanged(.replaced, queue: clips, inspectShown: false) { true }   // player busy: nothing prewarmed
        #expect(await specs.details(for: clips[2]) != nil)                          // Media Info shows a clip
        #expect(specs.deliverableAssets.isEmpty)

        specs.queueChanged(.inspectOpened, queue: clips, inspectShown: true) { false }
        await settle(specs) { specs.deliverableAssets.count == 4 && !specs.isInspectingDeliverables }
        #expect(specs.deliverableAssets.map(\.fileURL.lastPathComponent) == clips.map(\.lastPathComponent))
    }

    @Test("Files added on another tab appear when Inspect opens, read in the background meanwhile")
    func addedFilesAppearInInspect() async throws {
        let clips = try await queue(3)
        defer { try? FileManager.default.removeItem(at: clips[0].deletingLastPathComponent()) }
        let specs = SpecsState()
        specs.queueChanged(.replaced, queue: Array(clips.prefix(2)), inspectShown: true) { false }
        await settle(specs) { specs.deliverableAssets.count == 2 }

        specs.queueChanged(.added([clips[2]]), queue: clips, inspectShown: false) { false }
        #expect(specs.deliverableAssets.count == 2)                // the list is left alone on other tabs
        await settle(specs) { specs.cachedDetails(for: clips[2]) != nil }
        #expect(specs.cachedDetails(for: clips[2]) != nil)         // read in the background

        specs.queueChanged(.inspectOpened, queue: clips, inspectShown: true) { false }
        #expect(specs.deliverableAssets.count == 3)                // listed at once, no second read
        #expect(!specs.isInspectingDeliverables)
    }

    @Test("Line Check findings reach the Player as timeline markers and per-frame line marks")
    func lineCheckReachesThePlayer() async throws {
        var lined = Scenes.picture()
        lined.drawEdgeLine(.bottom, thickness: 2, color: Scenes.green)
        let url = try await TestClips.ntscOn600TimeBase(lined, frames: 30)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let results = await VideoScanner().scanBatch(videoURLs: [url], config: LineCase.greenConfig, progressHandler: { _ in })
        #expect(results.first?.isFlagged == true)

        let engine = PlayerEngine()
        engine.setScanResults(results)
        let marks = try #require(engine.lineMarks[url.standardizedFileURL])
        #expect(marks.frames[10]?.first?.edge == .bottom)
        #expect(engine.markersMap[url.standardizedFileURL]?.isEmpty == false)
        engine.setScanResults([])
        #expect(engine.lineMarks.isEmpty)
    }

    @Test("The updater takes QCpie.dmg whatever else a release carries")
    func updaterPicksTheApp() {
        let release = ["LineFinder-0.0.7.ccx", "LineFinder-0.0.7.dmg", "LineFinder-0.0.7.pkg", "LineFinderAnalysis-0.0.6.zip", "QCpie.dmg"]
        #expect(UpdateManager.appDiskImage(among: release) == "QCpie.dmg")
        #expect(UpdateManager.appDiskImage(among: ["LineFinder-0.0.7.dmg", "notes.txt"]) == nil)
        #expect(UpdateManager.appDiskImage(among: ["QCpie-0.9.dmg"]) == "QCpie-0.9.dmg")
    }
}
