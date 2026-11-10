import Foundation
import os
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
import UniformTypeIdentifiers
@preconcurrency import VideoToolbox
import VideoQCLib

/// Slow-motion shuttle (⇧J / ⇧L) and frame stepping. The shuttle's timer state is stored in PlayerEngine.swift.
extension PlayerEngine {
    // MARK: - Slow-Motion Frame-by-Frame Shuttle (Shift + L / Shift + J)
    

    public var isSlowStepping: Bool {
        return slowStepTimer != nil
    }
    
    public func pressSlowL() {
        guard slotA.player.currentItem != nil else { return }
        
        // Stop normal playback if active
        if self.rate != 0.0 || slotA.player.rate != 0.0 {
            slotA.player.pause()
            slotB.player.pause()
            self.rate = 0.0
        }
        
        if slowStepTimer == nil {
            slowDirection = .forward
            slowSpeedIndex = 0
        } else if slowDirection == .forward {
            slowSpeedIndex = min(slowSpeeds.count - 1, slowSpeedIndex + 1)
        } else {
            if slowSpeedIndex > 0 {
                slowSpeedIndex -= 1
            } else {
                slowDirection = .forward
                slowSpeedIndex = 0
            }
        }
        
        startSlowStepTimer()
    }
    
    public func pressSlowJ() {
        guard slotA.player.currentItem != nil else { return }
        
        // Stop normal playback if active
        if self.rate != 0.0 || slotA.player.rate != 0.0 {
            slotA.player.pause()
            slotB.player.pause()
            self.rate = 0.0
        }
        
        if slowStepTimer == nil {
            slowDirection = .reverse
            slowSpeedIndex = 0
        } else if slowDirection == .reverse {
            slowSpeedIndex = min(slowSpeeds.count - 1, slowSpeedIndex + 1)
        } else {
            if slowSpeedIndex > 0 {
                slowSpeedIndex -= 1
            } else {
                slowDirection = .reverse
                slowSpeedIndex = 0
            }
        }
        
        startSlowStepTimer()
    }
    
    public func stopSlowStep() {
        slowStepTimer?.invalidate()
        slowStepTimer = nil
    }
    
    private func startSlowStepTimer() {
        stopSlowStep()
        
        let targetFps = slowSpeeds[slowSpeedIndex]
        let interval = 1.0 / targetFps
        let isFwd = (slowDirection == .forward)
        
        self.isPlaying = true
        let fpsText = String(format: "%.0f", targetFps)
        self.shuttleStateText = isFwd ? "SLOW FWD \(fpsText) FPS" : "SLOW REV -\(fpsText) FPS"
        
        executeSingleFrameStep(forward: isFwd)
        
        slowStepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.executeSingleFrameStep(forward: isFwd)
            }
        }
    }
    
    private func executeSingleFrameStep(forward: Bool) {
        guard slotA.player.currentItem != nil else { return }
        // Looping inside In–Out: wrap at the range ends.
        if isLooping, let range = loopRange {
            let wrap: Int? = forward ? (currentFrame >= range.end ? range.start : nil) : (currentFrame <= range.start ? range.end : nil)
            if let wrap {
                currentFrame = wrap
                currentTimecode = TimecodeFormatter.format(frameIndex: wrap, fps: activeFps)
                seek(toFrame: wrap)
                return
            }
        }
        let durSecs = CMTimeGetSeconds(duration)
        let currSecs = CMTimeGetSeconds(currentTime)
        
        if forward && currSecs >= durSecs - 0.05 {
            if isLooping {
                seek(toTime: .zero)
            } else {
                stopSlowStep()
                pause()
            }
            return
        } else if !forward && currSecs <= 0.05 {
            if isLooping && durSecs > 0.5 {
                seek(toProgress: 0.999)
            } else {
                stopSlowStep()
                pause()
            }
            return
        }
        
        let currFrame = self.currentFrame
        let targetFrame = max(0, min(max(0, self.totalFrames - 1), currFrame + (forward ? 1 : -1)))
        guard targetFrame != currFrame else { return }
        
        self.currentFrame = targetFrame
        self.currentTimecode = TimecodeFormatter.format(frameIndex: targetFrame, fps: activeFps)
        let fps = max(1.0, activeFps)
        let targetSecs = (Double(targetFrame) + 0.5) / fps
        if durSecs > 0 {
            self.currentProgress = min(1.0, max(0.0, targetSecs / durSecs))
        }
        seek(toFrame: targetFrame)
    }
    
    public func togglePlayPause() {
        if isSlowStepping || rate != 0.0 {
            pause()
        } else {
            pressL()
        }
    }
    
    /// False when slot A holds a still image: no playback, stepping or scrubbing.
    public var hasTimeline: Bool { slotA.mediaKind != .image }
    
    public func play() {
        setPlaybackRate(1.0)
    }
    
    public func pause() {
        stopSlowStep()
        cancelSlotBRelock()
        slotA.player.pause()
        slotB.player.pause()
        // Only assign changed values: every @Published write broadcasts objectWillChange to all observers.
        if rate != 0.0 { rate = 0.0 }
        if isPlaying { isPlaying = false }
        if isScrubbing { isScrubbing = false }
        self.isScrubSeekingA = false
        self.pendingScrubTimeA = nil
        self.isScrubSeekingB = false
        self.pendingScrubTimeB = nil
        self.wasPlayingBeforeScrub = false
        if shuttleStateText != "PAUSE" { shuttleStateText = "PAUSE" }
        // A seek in flight owns the playhead: the player reports the previous landed frame until it lands (re-reading
        // it here stepped back a frame during held-key stepping, and resetting `isSeeking` made the next step cancel
        // the in-flight seek instead of queueing behind it). Pausing drops its follow-up (e.g. play after a loop wrap).
        seekGeneration &+= 1
        self.pendingSeekTime = nil
        self.pendingSeekTolerance = nil
        self.pendingSeekCompletion = nil
        if !isSeeking, let currentItem = slotA.player.currentItem, currentItem.status == .readyToPlay {
            let pausedTime = slotA.player.currentTime()
            if pausedTime.isValid && pausedTime.isNumeric {
                updateCurrentTime(time: pausedTime)
                
                // Align Slot B player accurately to the master paused frame
                if isLinked && slotB.url != nil && slotB.player.currentItem != nil {
                    let masterSecs = CMTimeGetSeconds(pausedTime)
                    let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                    let targetSecsB = max(0.0, masterSecs + offsetSecs)
                    let targetTimeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
                    self.slotB.currentTime = targetTimeB
                    self.isPauseAlignSeekPendingB = true
                    self.slotB.player.seek(to: targetTimeB, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.isPauseAlignSeekPendingB = false }
                        }
                    }
                }
            }
        }
    }
    
    /// How far ahead linked A/B playback is scheduled, so both players can start on the same host time.
    static let linkedStartLead = 0.03

    public func setPlaybackRate(_ newRate: Float) {
        guard hasTimeline || newRate == 0 else { return }
        stopSlowStep()
        cancelSlotBRelock()
        if rate != newRate { rate = newRate }
        if isPlaying != (newRate != 0.0) { isPlaying = (newRate != 0.0) }
        if isScrubbing { isScrubbing = false }
        
        if newRate == 0.0 {
            pause()
            return
        }
        
        slotA.player.automaticallyWaitsToMinimizeStalling = false
        slotB.player.automaticallyWaitsToMinimizeStalling = false
        
        if !isLinked || slotB.url == nil {
            slotA.player.playImmediately(atRate: newRate)
            updateShuttleText(for: newRate)
            return
        }
        
        let masterSecs = CMTimeGetSeconds(slotA.player.currentTime())
        let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
        let targetSecs = max(0.0, masterSecs + offsetSecs)
        let currSecsB = CMTimeGetSeconds(slotB.player.currentTime())
        let frameDur = 1.0 / max(1.0, slotB.fps)
        
        // Both start on one host time. Two `playImmediately` calls left B a fixed ~11 ms off A (measured, H.264 MP4s),
        // which the PLL never closed (inside its dead zone): B looked a frame late on many vsyncs.
        let startBothPlayers = { @MainActor [weak self] in
            guard let self = self, self.isPlaying, self.rate == newRate else { return }
            let hostClock = CMClockGetHostTimeClock()
            let startHost = CMTimeAdd(CMClockGetTime(hostClock), CMTime(seconds: Self.linkedStartLead, preferredTimescale: 1_000_000_000))
            self.slotB.player.setRate(newRate, time: .invalid, atHostTime: startHost)
            self.slotA.player.setRate(newRate, time: .invalid, atHostTime: startHost)
            self.relockHoldUntil = CACurrentMediaTime() + Self.linkedStartLead + 0.15
            self.updateShuttleText(for: newRate)
        }
        
        // A B seek still in flight (pause alignment, re-lock) would start B late, and B off by more than a quarter
        // frame would keep that offset: land it exactly first.
        if isSeekingB || isRelockingB || isPauseAlignSeekPendingB || abs(currSecsB - targetSecs) > frameDur * 0.25 {
            let targetTimeB = CMTime(seconds: targetSecs, preferredTimescale: 60000)
            seekSlotB(to: targetTimeB) {
                startBothPlayers()
            }
        } else {
            startBothPlayers()
        }
    }
    
    private func updateShuttleText(for newRate: Float) {
        let text: String
        if newRate == 0.0 {
            text = "PAUSE"
        } else if newRate > 0.0 {
            text = newRate == 1.0 ? "PLAY 1x" : "FWD \(Int(newRate))x"
        } else {
            text = newRate == -1.0 ? "REV 1x" : "REV \(Int(abs(newRate)))x"
        }
        if shuttleStateText != text { shuttleStateText = text }
    }
    
    // MARK: - Frame Stepping & Jumps
    
    public func stepFrame(forward: Bool) {
        stepFrames(count: 1, forward: forward)
    }
    
    public func stepFrames(count: Int, forward: Bool) {
        pause()
        guard slotA.player.currentItem != nil else { return }
        let currFrame = self.currentFrame
        let delta = forward ? count : -count
        let targetFrame = max(0, min(max(0, self.totalFrames - 1), currFrame + delta))
        guard targetFrame != currFrame else { return }
        
        self.currentFrame = targetFrame
        self.currentTimecode = TimecodeFormatter.format(frameIndex: targetFrame, fps: activeFps)
        let durSecs = CMTimeGetSeconds(duration)
        let fps = max(1.0, activeFps)
        let targetSecs = (Double(targetFrame) + 0.5) / fps
        if durSecs > 0 {
            self.currentProgress = min(1.0, max(0.0, targetSecs / durSecs))
        }
        seek(toFrame: targetFrame)
    }

    
    public func jumpToBeginning() {
        pause()
        self.currentFrame = 0
        self.currentTimecode = TimecodeFormatter.format(frameIndex: 0, fps: activeFps)
        self.currentProgress = 0.0
        seek(toFrame: 0)
    }
    
}
