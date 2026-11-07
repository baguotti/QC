import Foundation
import CoreMedia
import Combine
import Testing
@testable import QCpie

// A held arrow key steps faster than exact seeks land (5 ms apart here): the clock must only move forward and end on
// the last step. Uses a local `_TEST` clip; skipped without it.
@Suite("Player stepping")
struct PlayerSteppingTests {
    @Test @MainActor
    func heldKeyStepsNeverMoveTheClockBack() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("_TEST/LNEH_ROUGHCUT_24fps_E1.4.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let engine = PlayerEngine()
        engine.isMuted = true
        engine.loadVideo(url: url, into: .slotA)
        for _ in 0..<100 where engine.totalFrames == 0 { try await Task.sleep(for: .milliseconds(20)) }
        engine.seek(toFrame: 120)
        try await Task.sleep(for: .milliseconds(800))
        var history: [Int] = []
        let sub = engine.clock.$currentFrame.sink { history.append($0) }
        for _ in 0..<40 {
            engine.stepFrame(forward: true)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(1500))
        sub.cancel()
        let backSteps = zip(history, history.dropFirst()).filter { $1 < $0 }.count
        let playerFrame = Int(floor(CMTimeGetSeconds(engine.slotA.player.currentTime()) * engine.activeFps + 1e-4))
        print("final clock", engine.currentFrame, "player", playerFrame, "backward moves", backSteps, "isSeeking", engine.isSeeking)
        #expect(engine.currentFrame == 160)
        #expect(playerFrame == 160)
        #expect(backSteps == 0)
    }
}
