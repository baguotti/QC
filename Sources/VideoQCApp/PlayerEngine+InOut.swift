import Foundation
import os
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
import UniformTypeIdentifiers
@preconcurrency import VideoToolbox
import VideoQCLib

extension PlayerEngine {
    // MARK: - In / Out

    public func markIn() {
        guard hasTimeline else { return }
        inFrame = currentFrame
        if let outFrame, outFrame <= currentFrame { self.outFrame = nil }
        applyInOutRange()
    }

    public func markOut() {
        guard hasTimeline else { return }
        outFrame = currentFrame
        if let inFrame, inFrame >= currentFrame { self.inFrame = nil }
        applyInOutRange()
    }

    public func clearInOut() {
        inFrame = nil
        outFrame = nil
        applyInOutRange()
    }

    /// ⇧I / ⇧O: the In or Out point, or the first / last frame when it isn't set.
    public func goToIn() {
        guard let inFrame else { return jumpToBeginning() }
        jump(to: inFrame)
    }

    public func goToOut() {
        guard let outFrame else { return jumpToEnd() }
        jump(to: outFrame)
    }

    /// Paused jump with the clock updated at once (like Home / End).
    private func jump(to frame: Int) {
        pause()
        currentFrame = frame
        currentTimecode = TimecodeFormatter.format(frameIndex: frame, fps: activeFps)
        let durSecs = CMTimeGetSeconds(duration)
        if durSecs > 0 { currentProgress = min(1, max(0, (Double(frame) + 0.5) / max(1, activeFps) / durSecs)) }
        seek(toFrame: frame)
    }

    func applyInOutRange() {
        guard let item = slotA.player.currentItem else { return }
        guard isLooping, let outFrame else {
            item.forwardPlaybackEndTime = .invalid
            return
        }
        item.forwardPlaybackEndTime = CMTime(seconds: Double(outFrame + 1) / max(1, activeFps), preferredTimescale: 60000)
    }

    /// Frames looped between with loop on: In (or the first frame) to Out (or the last); nil without In / Out.
    var loopRange: (start: Int, end: Int)? {
        guard inFrame != nil || outFrame != nil else { return nil }
        return (inFrame ?? 0, outFrame ?? max(0, totalFrames - 1))
    }

    /// The In–Out range of slot A's file as a time range (whole clip ends where a point isn't set).
    public var inOutTimeRange: CMTimeRange? {
        guard inFrame != nil || outFrame != nil else { return nil }
        let fps = max(1, activeFps)
        let start = CMTime(seconds: Double(inFrame ?? 0) / fps, preferredTimescale: 60000)
        let end = outFrame.map { CMTime(seconds: Double($0 + 1) / fps, preferredTimescale: 60000) } ?? duration
        return CMTimeRange(start: start, end: end)
    }

    public func jumpToEnd() {
        pause()
        let lastFrame = max(0, totalFrames - 1)
        self.currentFrame = lastFrame
        self.currentTimecode = TimecodeFormatter.format(frameIndex: lastFrame, fps: activeFps)
        self.currentProgress = 1.0
        seek(toFrame: lastFrame)
    }
    
}
