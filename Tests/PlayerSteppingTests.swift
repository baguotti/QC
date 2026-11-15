import Foundation
import CoreMedia
import Combine
import QuartzCore
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

    // Playback draws the frame for the next vsync, so the picture can be a frame ahead of the player at a pause: the
    // playhead moves to the picture. A frame behind (a long frame of a variable-rate clip) is left alone.
    @Test @MainActor
    func pauseMovesThePlayheadToTheFrameOnScreen() async throws {
        // Any local `_TEST` clip of 200 frames or more; skipped without one.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("_TEST")
        let clips = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.path < $1.path }
        guard let url = clips.first else { return }
        let engine = PlayerEngine()
        engine.isMuted = true
        engine.loadVideo(url: url, into: .slotA)
        for _ in 0..<100 where engine.totalFrames == 0 { try await Task.sleep(for: .milliseconds(20)) }
        guard engine.totalFrames >= 200 else { return }
        func playerFrame() -> Int { Int(floor(CMTimeGetSeconds(engine.slotA.player.currentTime()) * engine.activeFps + 1e-4)) }
        func playThenPause(shownAhead offset: Int) async throws -> (stopped: Int, clock: Int, player: Int) {
            engine.seek(toFrame: 120)
            try await Task.sleep(for: .milliseconds(500))
            engine.play()
            try await Task.sleep(for: .milliseconds(400))
            let stopped = playerFrame()
            // What the viewport records per drawn frame: the presentation time of the frame on screen (a little inside
            // the frame: a 1/60000 s timescale can't hold a 23.976 fps frame boundary exactly).
            engine.slotA.shownFrame = (CMTime(seconds: (Double(stopped + offset) + 0.1) / engine.activeFps, preferredTimescale: 60000), CACurrentMediaTime())
            engine.pause()
            let clock = engine.currentFrame
            try await Task.sleep(for: .milliseconds(600))
            return (stopped, clock, playerFrame())
        }
        let ahead = try await playThenPause(shownAhead: 1)
        // The player can advance a frame or two between the read above and the pause (a loaded machine): then picture
        // and player already agree. Never left before the frame on screen.
        #expect(ahead.clock >= ahead.stopped + 1)
        #expect(ahead.player == ahead.clock)
        let behind = try await playThenPause(shownAhead: -1)
        #expect(behind.clock >= behind.stopped)
        #expect(behind.player == behind.clock)
        #expect(!engine.isSeeking)
    }
}

// Clip loads read the file's date and build the exposure composition off the main thread; the results still arrive.
@Suite("Player loading")
struct PlayerLoadingTests {
    @MainActor
    private func clip() -> URL? {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("_TEST")
        let clips = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension.lowercased() == "mp4" }.sorted { $0.path < $1.path }
        return clips.first
    }

    @Test @MainActor
    func exposureCompositionArrivesAndLeaves() async throws {
        guard let url = clip() else { return }
        let engine = PlayerEngine()
        engine.isMuted = true
        engine.exposureEV = 1
        engine.loadVideo(url: url, into: .slotA)
        for _ in 0..<150 where engine.slotA.player.currentItem?.videoComposition == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(engine.slotA.player.currentItem?.videoComposition != nil)
        #expect(engine.slotA.loadedModificationDate != nil)
        engine.exposureEV = 0
        // Removed 400 ms after EV settles at 0; polled, as a loaded machine (the release build's test run) takes longer.
        for _ in 0..<150 where engine.slotA.player.currentItem?.videoComposition != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(engine.slotA.player.currentItem?.videoComposition == nil)
    }

    @Test @MainActor
    func reopeningTheClipInAJumpsWithoutReloading() async throws {
        guard let url = clip() else { return }
        let engine = PlayerEngine()
        engine.isMuted = true
        engine.loadVideo(url: url, into: .slotA)
        for _ in 0..<100 where engine.totalFrames == 0 || engine.slotA.loadedModificationDate == nil { try await Task.sleep(for: .milliseconds(20)) }
        let item = engine.slotA.player.currentItem
        engine.loadVideo(url: url, into: .slotA, initialSeekFrame: 40)
        for _ in 0..<100 where engine.currentFrame != 40 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.currentFrame == 40)
        #expect(engine.slotA.player.currentItem === item)
    }
}
