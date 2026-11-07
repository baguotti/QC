import Combine
import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

/// Scan progress changes ~5 times a second. A publish from ScannerState redraws the whole window (ContentView owns
/// it), so progress must publish only from its own object.
@MainActor
@Suite("Scan progress")
struct ScanProgressTests {
    @Test("Progress updates notify ScanProgress, not ScannerState")
    func progressDoesNotRedrawWindow() {
        let scanner = ScannerState()
        var scannerChanges = 0, progressChanges = 0
        let a = scanner.objectWillChange.sink { scannerChanges += 1 }
        let b = scanner.progress.objectWillChange.sink { progressChanges += 1 }

        scanner.progressInfo = VideoScanner.ScanProgress(currentFileIndex: 1, totalFiles: 3, currentFileName: "a.mov",
                                                         currentFrame: 10, totalFramesInFile: 100, fps: 900, flaggedVideosCount: 0)
        scanner.frameCheckProgress = FrameCheckScanner.ScanProgress(fileIndex: 1, totalFiles: 3, fileName: "a.mov",
                                                                    frame: 10, totalFrames: 100, speed: 900)
        scanner.frameCheckProgress = nil

        #expect(scannerChanges == 0)
        #expect(progressChanges == 3)
        #expect(scanner.progress.line?.currentFrame == 10)
        #expect(scanner.frameCheckProgress == nil)
        _ = (a, b)
    }
}
