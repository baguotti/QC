import Foundation
import CoreMedia
import Testing
@testable import QCpie
@testable import VideoQCLib

// Swapping A and B keeps each clip where it was, image sequences included (their item is built after the swap).
// Uses local `_TEST` media; skipped without it.
@Suite("Player swap")
struct PlayerSwapTests {
    @Test @MainActor
    func swapKeepsSequencePosition() async throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("_TEST")
        let video = tests.appendingPathComponent("LNEH_ROUGHCUT_24fps_E1.4.mp4")
        guard FileManager.default.fileExists(atPath: video.path),
              FileManager.default.fileExists(atPath: tests.appendingPathComponent("seqtest/shot_0001.png").path) else { return }
        let frames = (1...118).map { tests.appendingPathComponent(String(format: "seqtest/shot_%04d.png", $0)) }
        let first = ImageSequenceStore.shared.collapse(frames).first!
        let engine = PlayerEngine()
        engine.isMuted = true
        engine.isLinked = false
        engine.loadVideo(url: first, into: .slotA)
        for _ in 0..<100 where engine.totalFrames == 0 { try await Task.sleep(for: .milliseconds(20)) }
        engine.loadVideo(url: video, into: .slotB)
        try await Task.sleep(for: .milliseconds(800))
        engine.seek(toFrame: 40)
        try await Task.sleep(for: .milliseconds(500))
        let fpsA = engine.activeFps
        engine.swapSlots()
        try await Task.sleep(for: .milliseconds(1500))
        let bFrame = Int(floor(CMTimeGetSeconds(engine.slotB.player.currentTime()) * fpsA + 1e-4))
        print("seq now in B at frame", bFrame, "sequence in B:", engine.slotB.sequence != nil)
        #expect(bFrame == 40)
    }
}
