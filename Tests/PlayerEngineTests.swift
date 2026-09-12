import Foundation
import CoreMedia
import Testing
@testable import QCpie
@testable import VideoQCLib

@Suite("PlayerEngine State Invariant Tests")
struct PlayerEngineTests {
    
    // MARK: - Initial State
    
    @Test @MainActor
    func initialEngineState() {
        let engine = PlayerEngine()
        #expect(engine.compareMode == .single)
        #expect(engine.audioSlot == .slotA)
        #expect(engine.isLinked == true)
        #expect(engine.isBlinkCompareB == false)
        #expect(engine.clipInfoOverlayMode == .resolution)
        #expect(engine.showResolutionLabels == true)
        #expect(engine.rate == 0.0)
        #expect(engine.isPlaying == false)
        #expect(engine.slotA.url == nil)
        #expect(engine.slotB.url == nil)
    }
    
    // MARK: - Slot Swap Invariants
    
    @Test @MainActor
    func slotSwapPreservesAllFields() {
        let engine = PlayerEngine()
        let urlA = URL(fileURLWithPath: "/tmp/videoA.mov")
        let urlB = URL(fileURLWithPath: "/tmp/videoB.mp4")
        
        engine.slotA.url = urlA
        engine.slotA.fileName = "videoA.mov"
        engine.slotA.resolution = "1920x1080"
        engine.slotA.fps = 29.97
        engine.slotA.codec = "h264"
        engine.slotA.duration = CMTime(seconds: 120, preferredTimescale: 600)
        engine.slotA.videoSize = CGSize(width: 1920, height: 1080)
        engine.slotA.totalFrames = 3600
        
        engine.slotB.url = urlB
        engine.slotB.fileName = "videoB.mp4"
        engine.slotB.resolution = "3840x2160"
        engine.slotB.fps = 60.0
        engine.slotB.codec = "prores"
        engine.slotB.duration = CMTime(seconds: 60, preferredTimescale: 600)
        engine.slotB.videoSize = CGSize(width: 3840, height: 2160)
        engine.slotB.totalFrames = 3600
        
        engine.swapSlots()
        
        // Slot B should now contain slot A's previous metadata
        #expect(engine.slotB.url == urlA)
        #expect(engine.slotB.fileName == "videoA.mov")
        #expect(engine.slotB.resolution == "1920x1080")
        #expect(engine.slotB.fps == 29.97)
        #expect(engine.slotB.codec == "h264")
        #expect(engine.slotB.duration == CMTime(seconds: 120, preferredTimescale: 600))
        #expect(engine.slotB.videoSize == CGSize(width: 1920, height: 1080))
        #expect(engine.slotB.totalFrames == 3600)
        
        // Slot A should now contain slot B's previous metadata
        #expect(engine.slotA.url == urlB)
        #expect(engine.slotA.fileName == "videoB.mp4")
        #expect(engine.slotA.resolution == "3840x2160")
        #expect(engine.slotA.fps == 60.0)
        #expect(engine.slotA.codec == "prores")
        #expect(engine.slotA.duration == CMTime(seconds: 60, preferredTimescale: 600))
        #expect(engine.slotA.videoSize == CGSize(width: 3840, height: 2160))
        #expect(engine.slotA.totalFrames == 3600)
    }
    
    // MARK: - Clear Slot B Invariants
    
    @Test @MainActor
    func clearSlotBResetsToSingle() {
        let engine = PlayerEngine()
        engine.slotB.url = URL(fileURLWithPath: "/tmp/videoB.mp4")
        engine.slotB.fileName = "videoB.mp4"
        engine.slotB.resolution = "1920x1080"
        engine.slotB.codec = "h264"
        engine.compareMode = .splitVertical
        engine.isBlinkCompareB = false
        
        engine.clearSlotB()
        
        #expect(engine.slotB.url == nil)
        #expect(engine.slotB.fileName.isEmpty)
        #expect(engine.slotB.resolution.isEmpty)
        #expect(engine.slotB.codec.isEmpty)
        #expect(engine.slotB.duration == .zero)
        #expect(engine.slotB.totalFrames == 0)
        #expect(engine.compareMode == .single)
        #expect(engine.audioSlot == .slotA)
    }
    
    // MARK: - Aspect Ratio & Compare Mode Enforcement
    
    @Test @MainActor
    func compareModeRequiresMatchingAspectFlags() {
        #expect(CompareMode.single.requiresMatchingAspect == false)
        #expect(CompareMode.splitVertical.requiresMatchingAspect == true)
        #expect(CompareMode.splitHorizontal.requiresMatchingAspect == true)
        #expect(CompareMode.difference.requiresMatchingAspect == true)
        #expect(CompareMode.overlay.requiresMatchingAspect == true)
        #expect(CompareMode.sideBySide.requiresMatchingAspect == false)
        #expect(CompareMode.sideBySideVertical.requiresMatchingAspect == false)
    }
    
    @Test @MainActor
    func mismatchedAspectRatioEnforcesValidMode() {
        let engine = PlayerEngine()
        engine.slotA.url = URL(fileURLWithPath: "/tmp/horizontal.mov")
        engine.slotA.videoSize = CGSize(width: 1920, height: 1080) // 16:9
        
        engine.slotB.url = URL(fileURLWithPath: "/tmp/vertical.mov")
        engine.slotB.videoSize = CGSize(width: 1080, height: 1920) // 9:16
        
        #expect(engine.hasMatchingAspectRatios == false)
        
        // Split vertical requires matching aspect -> redirected to side-by-side
        engine.compareMode = .splitVertical
        #expect(engine.compareMode == .sideBySide)
        
        // Split horizontal requires matching aspect -> redirected to side-by-side
        engine.compareMode = .splitHorizontal
        #expect(engine.compareMode == .sideBySide)
        
        // Difference requires matching aspect -> redirected to side-by-side
        engine.compareMode = .difference
        #expect(engine.compareMode == .sideBySide)
        
        // Overlay requires matching aspect -> redirected to side-by-side
        engine.compareMode = .overlay
        #expect(engine.compareMode == .sideBySide)
        
        // Side-by-side vertical does not require matching aspect -> allowed
        engine.compareMode = .sideBySideVertical
        #expect(engine.compareMode == .sideBySideVertical)
        
        // Side-by-side horizontal does not require matching aspect -> allowed
        engine.compareMode = .sideBySide
        #expect(engine.compareMode == .sideBySide)
        
        // Single does not require matching aspect -> allowed
        engine.compareMode = .single
        #expect(engine.compareMode == .single)
    }
    
    @Test @MainActor
    func matchingAspectRatioAllowsSplitModes() {
        let engine = PlayerEngine()
        engine.slotA.url = URL(fileURLWithPath: "/tmp/clipA.mov")
        engine.slotA.videoSize = CGSize(width: 1920, height: 1080)
        
        engine.slotB.url = URL(fileURLWithPath: "/tmp/clipB.mov")
        engine.slotB.videoSize = CGSize(width: 3840, height: 2160) // Both 16:9
        
        #expect(engine.hasMatchingAspectRatios == true)
        
        engine.compareMode = .splitVertical
        #expect(engine.compareMode == .splitVertical)
        
        engine.compareMode = .splitHorizontal
        #expect(engine.compareMode == .splitHorizontal)
        
        engine.compareMode = .difference
        #expect(engine.compareMode == .difference)
        
        engine.compareMode = .overlay
        #expect(engine.compareMode == .overlay)
    }
    
    // MARK: - Slot B Load Compare Mode Behavior
    
    @Test @MainActor
    func loadSlotBPreservesCompareModeWhenAlreadyInAB() {
        let engine = PlayerEngine()
        let urlA = URL(fileURLWithPath: "/tmp/slotA.mov")
        let urlB1 = URL(fileURLWithPath: "/tmp/slotB_v1.mov")
        let urlB2 = URL(fileURLWithPath: "/tmp/slotB_v2.mov")
        
        // Load Slot A first
        engine.loadVideo(url: urlA, into: .slotA)
        #expect(engine.slotA.url?.path == urlA.path)
        
        // Load Slot B initial (was not in AB mode)
        engine.loadVideo(url: urlB1, into: .slotB)
        #expect(engine.slotB.url?.path == urlB1.path)
        #expect(engine.compareMode == .single)
        
        // User selects side-by-side compare mode
        engine.compareMode = .sideBySide
        #expect(engine.compareMode == .sideBySide)
        
        // Load a second clip into Slot B while already in AB mode
        engine.loadVideo(url: urlB2, into: .slotB)
        #expect(engine.slotB.url?.path == urlB2.path)
        // Compare mode MUST be preserved
        #expect(engine.compareMode == .sideBySide)
    }
    
    @Test @MainActor
    func loadSlotBDefaultsToSingleWhenNotInAB() {
        let engine = PlayerEngine()
        let urlA = URL(fileURLWithPath: "/tmp/slotA.mov")
        let urlB = URL(fileURLWithPath: "/tmp/slotB.mov")
        
        engine.loadVideo(url: urlA, into: .slotA)
        #expect(engine.compareMode == .single)
        
        engine.loadVideo(url: urlB, into: .slotB)
        #expect(engine.compareMode == .single)
    }
    
    // MARK: - Clip Info Overlay Mode
    
    @Test @MainActor
    func cycleClipInfoOverlayModeWraps() {
        let engine = PlayerEngine()
        // Initial state is .resolution
        #expect(engine.clipInfoOverlayMode == .resolution)
        #expect(engine.showResolutionLabels == true)
        
        engine.cycleClipInfoOverlayMode()
        #expect(engine.clipInfoOverlayMode == .fileName)
        #expect(engine.showResolutionLabels == true)
        
        engine.cycleClipInfoOverlayMode()
        #expect(engine.clipInfoOverlayMode == .fullDetails)
        #expect(engine.showResolutionLabels == true)
        
        engine.cycleClipInfoOverlayMode()
        #expect(engine.clipInfoOverlayMode == .off)
        #expect(engine.showResolutionLabels == false)
        
        engine.cycleClipInfoOverlayMode()
        #expect(engine.clipInfoOverlayMode == .abOnly)
        #expect(engine.showResolutionLabels == true)
        
        engine.cycleClipInfoOverlayMode()
        #expect(engine.clipInfoOverlayMode == .resolution)
        #expect(engine.showResolutionLabels == true)
    }
    
    // MARK: - Dropped Frame Telemetry
    
    @Test @MainActor
    func droppedFrameTelemetryTracking() {
        let engine = PlayerEngine()
        #expect(engine.droppedFramesCount == 0)
        
        // Negative or zero drops ignored
        engine.recordDroppedFrames(0)
        engine.recordDroppedFrames(-5)
        #expect(engine.droppedFramesCount == 0)
        
        // Positive frame drops accumulate
        engine.recordDroppedFrames(2)
        #expect(engine.droppedFramesCount == 2)
        
        engine.recordDroppedFrames(1)
        #expect(engine.droppedFramesCount == 3)
        
        // Reset wipes count
        engine.resetDroppedFrames()
        #expect(engine.droppedFramesCount == 0)
    }
    
    @Test @MainActor
    func clearSlotAResetsDroppedFrames() {
        let engine = PlayerEngine()
        engine.recordDroppedFrames(5)
        #expect(engine.droppedFramesCount == 5)
        
        engine.clearSlotA()
        #expect(engine.droppedFramesCount == 0)
    }
    
    @Test @MainActor
    func playbackAfterPauseResetsDroppedFrames() {
        let engine = PlayerEngine()
        engine.recordDroppedFrames(4)
        #expect(engine.droppedFramesCount == 4)
        
        // Pausing preserves count for inspection
        engine.pause()
        #expect(engine.droppedFramesCount == 4)
        
        // Starting forward playback resets dropped frames
        engine.setPlaybackRate(1.0)
        #expect(engine.droppedFramesCount == 0)
        
        // Accumulate more during playback
        engine.recordDroppedFrames(2)
        #expect(engine.droppedFramesCount == 2)
        
        // Changing rate mid-playback (e.g. fast forward 2x) does not reset
        engine.setPlaybackRate(2.0)
        #expect(engine.droppedFramesCount == 2)
        
        // Pausing and then starting backward playback resets dropped frames
        engine.pause()
        #expect(engine.droppedFramesCount == 2)
        engine.setPlaybackRate(-1.0)
        #expect(engine.droppedFramesCount == 0)
    }
}
