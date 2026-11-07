import Foundation
import os
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
import UniformTypeIdentifiers
@preconcurrency import VideoToolbox
import VideoQCLib

/// Scrubbing: the drag path (no @Published mutations, see docs/architecture/player.md §5) and zoom/pan.
extension PlayerEngine {
    // MARK: - Scrubbing & Seeking
    
    /// Initiates interactive scrubbing: remembers active playback state and temporarily halts playback during dragging
    public func startScrubbing() {
        guard !self.isScrubbing, hasTimeline else { return }
        cancelSlotBRelock()
        self.wasPlayingBeforeScrub = (self.isPlaying || self.rate != 0.0 || self.isSlowStepping)
        self.playbackRateBeforeScrub = (self.rate != 0.0) ? self.rate : 1.0
        self.isScrubbing = true
        self.isScrubSeekingA = false
        self.pendingScrubTimeA = nil
        self.isScrubSeekingB = false
        self.pendingScrubTimeB = nil
        
        if self.wasPlayingBeforeScrub {
            stopSlowStep()
            slotA.player.pause()
            slotB.player.pause()
            self.rate = 0.0
            // Keep isPlaying = true so UI controls (e.g. Play/Pause button) stay in playing context
            self.isPlaying = true
        }
    }
    
    /// High-performance interactive scrubbing: updates UI synchronously at 120 FPS lockstep with mouse drag
    public func scrubTo(progress: Double) {
        if !self.isScrubbing {
            startScrubbing()
            guard self.isScrubbing else { return }
        }
        let clamped = min(1.0, max(0.0, progress))
        
        let durSecs = CMTimeGetSeconds(duration)
        guard durSecs > 0 && durSecs.isFinite && !durSecs.isNaN else { return }
        let currSecs = clamped * durSecs
        let fps = max(1.0, activeFps)
        let calcVal = currSecs * fps + 1e-4
        let frameIdx = (calcVal.isFinite && !calcVal.isNaN) ? max(0, min(max(0, totalFrames - 1), Int(floor(calcVal)))) : 0
        
        let targetSecs = (Double(frameIdx) + 0.5) / fps
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        
        // Zero SwiftUI objectWillChange storm during active mouse drag.
        // Pure seek dispatch directly to independent hardware compositor layers.
        dispatchScrubSeek(timeA: targetTime)
    }
    
    // MARK: - Dedicated Interactive Scrub Seek Pipeline (Unblocked Parallel Hardware Decoding)
    
    private func dispatchScrubSeek(timeA: CMTime) {
        guard slotA.player.currentItem != nil else { return }
        let fpsA = max(1.0, activeFps)
        let tolA = CMTime(seconds: 2.0 / fpsA, preferredTimescale: 60000)
        
        if isScrubSeekingA {
            pendingScrubTimeA = timeA
        } else {
            isScrubSeekingA = true
            dispatchScrubSeekSlotA(to: timeA, tolerance: tolA)
        }
        
        let hasSlotB = (self.compareMode != .single || self.isBlinkCompareB) && self.isLinked && self.slotB.url != nil && self.slotB.player.currentItem != nil
        if hasSlotB {
            let offsetSecs = Double(self.slotB.slipOffsetFrames) / max(1.0, self.slotB.fps)
            let targetSecsB = max(0.0, CMTimeGetSeconds(timeA) + offsetSecs)
            let timeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
            let fpsB = max(1.0, self.slotB.fps)
            let tolB = CMTime(seconds: 2.0 / fpsB, preferredTimescale: 60000)
            
            if isScrubSeekingB {
                pendingScrubTimeB = timeB
            } else {
                isScrubSeekingB = true
                dispatchScrubSeekSlotB(to: timeB, tolerance: tolB)
            }
        }
    }
    
    private func dispatchScrubSeekSlotA(to time: CMTime, tolerance: CMTime) {
        slotA.player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            let run = { @MainActor in
                guard let self = self else { return }
                self.isScrubSeekingA = false
                
                guard self.isScrubbing else {
                    self.pendingScrubTimeA = nil
                    return
                }
                
                if finished {
                    let currSecs = CMTimeGetSeconds(time)
                    let fps = max(1.0, self.activeFps)
                    let frameIdx = max(0, min(max(0, self.totalFrames - 1), Int(floor(currSecs * fps + 1e-4))))
                    if self.currentFrame != frameIdx {
                        self.currentFrame = frameIdx
                        self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: self.activeFps)
                    }
                }
                
                if let next = self.pendingScrubTimeA {
                    self.pendingScrubTimeA = nil
                    self.isScrubSeekingA = true
                    let fpsA = max(1.0, self.activeFps)
                    let tolA = CMTime(seconds: 2.0 / fpsA, preferredTimescale: 60000)
                    self.dispatchScrubSeekSlotA(to: next, tolerance: tolA)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { run() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { run() } }
            }
        }
    }
    
    private func dispatchScrubSeekSlotB(to time: CMTime, tolerance: CMTime) {
        slotB.player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            let run = { @MainActor in
                guard let self = self else { return }
                self.isScrubSeekingB = false
                
                guard self.isScrubbing else {
                    self.pendingScrubTimeB = nil
                    return
                }
                
                if let next = self.pendingScrubTimeB {
                    self.pendingScrubTimeB = nil
                    self.isScrubSeekingB = true
                    let fpsB = max(1.0, self.slotB.fps)
                    let tolB = CMTime(seconds: 2.0 / fpsB, preferredTimescale: 60000)
                    self.dispatchScrubSeekSlotB(to: next, tolerance: tolB)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { run() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { run() } }
            }
        }
    }
    
    /// Concludes interactive scrubbing: if previously playing, resumes playback from the new point; if paused, stays paused
    public func endScrubbing(at progress: Double) {
        let clamped = min(1.0, max(0.0, progress))
        self.isScrubbing = false
        self.pendingScrubTimeA = nil
        self.pendingScrubTimeB = nil
        self.isScrubSeekingA = false
        self.isScrubSeekingB = false
        self.currentProgress = clamped
        
        let durSecs = CMTimeGetSeconds(duration)
        let fps = max(1.0, activeFps)
        let currSecs = (durSecs > 0 && durSecs.isFinite && !durSecs.isNaN) ? clamped * durSecs : 0.0
        let calcVal = currSecs * fps + 1e-4
        let frameIdx = (calcVal.isFinite && !calcVal.isNaN) ? max(0, min(max(0, totalFrames - 1), Int(floor(calcVal)))) : 0
        self.currentFrame = frameIdx
        self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
        
        let targetTime = CMTime(seconds: currSecs, preferredTimescale: 60000)
        self.currentTime = targetTime
        self.slotA.currentTime = targetTime
        
        if (self.compareMode != .single || self.isBlinkCompareB) && self.isLinked && self.slotB.url != nil {
            let offsetSecs = Double(self.slotB.slipOffsetFrames) / max(1.0, self.slotB.fps)
            let targetSecsB = max(0.0, currSecs + offsetSecs)
            self.slotB.currentTime = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
        }
        
        let shouldResume = self.wasPlayingBeforeScrub
        let resumeRate = self.playbackRateBeforeScrub
        self.wasPlayingBeforeScrub = false
        
        if shouldResume {
            let isNearEnd = (durSecs > 0 && currSecs >= durSecs - 0.05)
            if isNearEnd && !isLooping {
                pause()
            } else {
                self.isPlaying = true
                let resumeTol = CMTime(seconds: 1.0 / max(1.0, activeFps), preferredTimescale: 60000)
                seek(toTime: targetTime, tolerance: resumeTol) { [weak self] in
                    guard let self = self else { return }
                    self.setPlaybackRate(resumeRate)
                }
            }
        } else {
            // Stay paused: exact frame seek with zero tolerance
            pause()
            seek(toFrame: frameIdx)
        }
    }
    
    public func seek(toProgress progress: Double, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let durSecs = CMTimeGetSeconds(duration)
        guard durSecs > 0 else {
            completion?()
            return
        }
        let clamped = min(1.0, max(0.0, progress))
        let targetSecs = clamped * durSecs
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        seek(toTime: targetTime, completion: completion)
    }
    
    public func seek(toTime time: CMTime, tolerance: CMTime? = nil, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard slotA.player.currentItem != nil else {
            completion?()
            return
        }
        cancelSlotBRelock()

        if isSeeking {
            pendingSeekTime = time
            pendingSeekTolerance = tolerance
            // Chained, not replaced: an earlier caller's completion (resume playback after a loop wrap) must still run.
            if let completion = completion {
                let earlier = pendingSeekCompletion
                pendingSeekCompletion = { earlier?(); completion() }
            }
            return
        }
        
        isSeeking = true
        let curCompletion = completion
        let generation = seekGeneration
        
        // Exact frame accuracy by default unless explicit tolerance is provided
        let tol: CMTime = tolerance ?? .zero
        
        let hasSlotB = (self.compareMode != .single || self.isBlinkCompareB) && self.isLinked && self.slotB.url != nil && self.slotB.player.currentItem != nil
        let offsetSeconds = hasSlotB ? (Double(self.slotB.slipOffsetFrames) / max(1.0, self.slotB.fps)) : 0.0
        let targetSecsB = hasSlotB ? max(0.0, CMTimeGetSeconds(time) + offsetSeconds) : 0.0
        let targetTimeB = hasSlotB ? CMTime(seconds: targetSecsB, preferredTimescale: 60000) : .zero
        
        let lock = OSAllocatedUnfairLock(initialState: (completedA: false, completedB: !hasSlotB))
        
        let checkParallelDone = { @MainActor in
            let (doneA, doneB) = lock.withLock { ($0.completedA, $0.completedB) }
            guard doneA && doneB else { return }
            self.isSeeking = false
            
            if self.pendingSeekTime == nil {
                self.updateCurrentTime(time: time)
            }
            
            if !self.isPlaying && !self.isScrubbing {
                self.notifySeekSettled()
            }
            
            if generation == self.seekGeneration { curCompletion?() }

            if let nextTime = self.pendingSeekTime {
                let nextComp = self.pendingSeekCompletion
                let nextTol = self.pendingSeekTolerance
                self.pendingSeekTime = nil
                self.pendingSeekTolerance = nil
                self.pendingSeekCompletion = nil
                self.seek(toTime: nextTime, tolerance: nextTol, completion: nextComp)
            }
        }
        
        // Parallel dispatch to Slot A
        slotA.player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            let runSlotA = { @MainActor in
                guard let self = self else { return }
                lock.withLock { $0.completedA = true }
                self.notifyFrameDecoded(.slotA, at: time)
                checkParallelDone()
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { runSlotA() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { runSlotA() } }
            }
        }
        
        // Parallel dispatch to Slot B
        if hasSlotB {
            slotB.player.seek(to: targetTimeB, toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
                let runSlotB = { @MainActor in
                    guard let self = self else { return }
                    lock.withLock { $0.completedB = true }
                    self.notifyFrameDecoded(.slotB, at: targetTimeB)
                    checkParallelDone()
                }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { runSlotB() }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { runSlotB() } }
                }
            }
        }
    }
    
    // MARK: - Zoom & Pan Controls
    
    public func setZoomFit() {
        self.isFitZoom = true
        self.zoomScale = 1.0
        self.panOffset = .zero
    }
    
    public func setZoomLevel(_ scale: CGFloat) {
        self.isFitZoom = false
        self.zoomScale = scale
    }

    
}
