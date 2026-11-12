import Foundation
import os
import VideoQCLib

/// Whether the Player is playing or scrubbing, readable from any thread (uploads ease off and scan helpers pause).
enum PlaybackActivity {
    private static let state = OSAllocatedUnfairLock(initialState: (playing: false, scrubbing: false))

    static func setPlaying(_ value: Bool) { state.withLock { $0.playing = value } }
    static func setScrubbing(_ value: Bool) { state.withLock { $0.scrubbing = value } }
    static var isPlaying: Bool { state.withLock { $0.playing } }
    static var isBusy: Bool { state.withLock { $0.playing || $0.scrubbing } }
}

/// The Subs & Graphics helper processes this Mac gets (`PictureTextWorkers`).
enum ScanWorkers {
    /// QCpie's own executable, set at launch (nil in tests: no helpers there).
    @MainActor static var executable: URL?

    @MainActor static var options: PictureTextWorkers.Options? {
        let count = PictureTextWorkers.recommendedCount()
        guard count > 0, let executable else { return nil }
        return PictureTextWorkers.Options(executable: executable, count: count) {
            let info = ProcessInfo.processInfo
            return PlaybackActivity.isBusy || info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        }
    }
}
