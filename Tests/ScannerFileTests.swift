import Foundation
@preconcurrency import AVFoundation
import Testing
@testable import VideoQCLib

@Suite("Scanner file handling")
struct ScannerFileTests {

    @Test("An unreadable video is flagged, not reported clean or dropped")
    func unreadableVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("broken.mp4")
        try Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }).write(to: url)

        let line = await VideoScanner().scanSingleVideo(url: url, config: QCConfig(), fileIndex: 1, totalFiles: 1, flaggedSoFar: 0)
        #expect(line.readError != nil)
        #expect(line.isFlagged)

        let frame = await FrameCheckScanner().scanBatch([url]) { _ in }
        #expect(frame.count == 1)
        #expect(frame.first?.readError != nil)
        #expect(frame.first?.isFlagged == true)
    }

    @Test("Stopping a Line Check leaves out a half-checked clean file but keeps one with findings")
    func stoppedScan() async throws {
        var lined = Scenes.picture()
        lined.drawEdgeLine(.bottom, thickness: 2, color: Scenes.green)
        let clean = try await TestClips.ntscOn600TimeBase(Scenes.picture(), frames: 90)
        let flagged = try await TestClips.ntscOn600TimeBase(lined, frames: 90)
        defer { for url in [clean, flagged] { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }

        let full = await VideoScanner().scanBatch(videoURLs: [clean], config: LineCase.greenConfig, progressHandler: { _ in })
        #expect(full.count == 1)
        #expect(full.first?.stoppedEarly == false)
        #expect(full.first?.isFlagged == false)

        // Progress arrives after the first 15 frames: stopping there leaves most of each 90-frame clip unchecked.
        for (url, kept) in [(clean, false), (flagged, true)] {
            let scanner = VideoScanner()
            let results = await scanner.scanBatch(videoURLs: [url], config: LineCase.greenConfig, progressHandler: { _ in scanner.cancel() })
            #expect(results.count == (kept ? 1 : 0))
            if kept {
                #expect(results.first?.stoppedEarly == true)
                #expect(results.first?.isFlagged == true)
            }
        }
    }

    @Test("The end-frame check names the last frame on a 600 time base")
    func endFrameTimecode() async throws {
        let url = try await TestClips.ntscOn600TimeBase(Scenes.solid(Scenes.black), frames: 60)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        let fps = Double(try await track.load(.nominalFrameRate))

        let check = await DeliverablesInspector.checkEndFrame(url: url)
        #expect(check.verdict == .black)
        #expect(check.timecode == TimecodeFormatter.format(frameIndex: 59, fps: fps))
    }
}
