import Foundation
import os
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
import UniformTypeIdentifiers
@preconcurrency import VideoToolbox
import VideoQCLib

/// Time observers (incl. the linked A/B drift correction) and the J-K-L shuttle.
extension PlayerEngine {
    // MARK: - Time Observers
    
    func setupTimeObserver() {
        if let token = tokens.timeObserverToken, let player = tokens.player {
            player.removeTimeObserver(token)
            tokens.timeObserverToken = nil
            tokens.player = nil
        }
        // An image has no clock; an item-less AVPlayer still reports the previous file's time.
        guard hasTimeline else { return }
        let fps = max(1.0, activeFps)
        let interval = CMTime(seconds: 1.0 / fps, preferredTimescale: 60000)
        let token = slotA.player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self, !self.isScrubbing else { return }
                self.updateCurrentTime(time: time)
            }
        }
        tokens.timeObserverToken = token
        tokens.player = slotA.player
    }
    
    func updateCurrentTime(time: CMTime) {
        guard time.isValid && time.isNumeric else { return }
        let currSecs = CMTimeGetSeconds(time)
        guard currSecs.isFinite && !currSecs.isNaN else { return }
        
        self.currentTime = time
        self.slotA.currentTime = time
        let durSecs = CMTimeGetSeconds(duration)
        
        let newProgress: Double
        if durSecs > 0 && durSecs.isFinite && !durSecs.isNaN {
            newProgress = min(1.0, max(0.0, currSecs / durSecs))
        } else {
            newProgress = 0.0
        }
        if abs(newProgress - self.currentProgress) >= 0.0005 || !self.isPlaying {
            self.currentProgress = newProgress
        }
        
        let fps = max(1.0, activeFps)
        let calcVal = currSecs * fps + 1e-4
        let frameIdx: Int
        if calcVal.isFinite && !calcVal.isNaN {
            frameIdx = max(0, min(max(0, totalFrames - 1), Int(floor(calcVal))))
        } else {
            frameIdx = 0
        }
        if self.currentFrame != frameIdx {
            self.currentFrame = frameIdx
            self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIdx, fps: activeFps)
        }
        
        if slotB.url != nil && slotB.player.currentItem != nil {
            let timeB = slotB.player.currentTime()
            if self.isLinked {
                let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                let targetSecsB = max(0.0, currSecs + offsetSecs)
                self.slotB.currentTime = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
            } else if timeB.isValid && timeB.isNumeric {
                self.slotB.currentTime = timeB
            }
            
            // Continuous drift correction during linked playback:
            // High-precision Phase-Locked Loop (PLL) micro-rate adjustment with stall recovery.
            // Samples both players synchronously on the main thread to eliminate observer dispatch skew.
            // Suspended while B is being re-locked and until it has started in phase (see relockSlotB).
            if isLinkedPlaybackRunning && !self.isSeekingB && !self.isRelockingB && CACurrentMediaTime() >= self.relockHoldUntil {
                let liveA = slotA.player.currentTime()
                let liveB = slotB.player.currentTime()
                if liveA.isValid && liveA.isNumeric && liveB.isValid && liveB.isNumeric {
                    let liveSecsA = CMTimeGetSeconds(liveA)
                    let liveSecsB = CMTimeGetSeconds(liveB)
                    if liveSecsA.isFinite && !liveSecsA.isNaN && liveSecsB.isFinite && !liveSecsB.isNaN {
                        let fpsB = max(1.0, slotB.fps)
                        let frameDurB = 1.0 / fpsB
                        let offsetSecs = Double(slotB.slipOffsetFrames) / fpsB
                        let expectedSecsB = max(0.0, liveSecsA + offsetSecs)
                        let drift = liveSecsB - expectedSecsB
                        let baseRate = self.rate
                        
                        let durSecsB = CMTimeGetSeconds(slotB.duration)
                        let isAtEndB = (durSecsB > 0 && durSecsB.isFinite && liveSecsB >= durSecsB - 0.05)
                        
                        if !isAtEndB {
                            // Stall Recovery: slotB stopped moving or fell drastically behind (>3.5 frames of wall-clock
                            // lag). Re-locked in phase with a single seek, at most once per second so a decoder that
                            // can't keep up (fast-forward) never loops on seeks.
                            let isStalledB = slotB.player.rate == 0.0 || abs(drift) > frameDurB * 3.5 * max(1.0, Double(abs(baseRate)))
                            if isStalledB && CACurrentMediaTime() - self.lastRelockStart >= 1.0 {
                                self.relockSlotB()
                            } else if abs(drift) > frameDurB * 0.75 {
                                // Gentle micro-rate adjustment (±1.5%) with 0.25s rate-settle debounce
                                let now = Date()
                                if now.timeIntervalSince(self.lastDriftCorrectionTime) >= 0.25 {
                                    self.lastDriftCorrectionTime = now
                                    // Behind means further back along the direction of play (reverse: B later than A).
                                    let isBehind = (drift < 0) == (baseRate > 0)
                                    let correctionFactor: Float = isBehind ? 1.015 : 0.985
                                    let adjustedRate = baseRate * correctionFactor
                                    if abs(slotB.player.rate - adjustedRate) > 0.003 {
                                        slotB.player.rate = adjustedRate
                                    }
                                }
                            } else {
                                // In frame-accurate lockstep (within 3/4 frame): maintain exact base rate
                                if abs(slotB.player.rate - baseRate) > 0.001 {
                                    slotB.player.rate = baseRate
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Reverse playback loop handling (between In and Out when set). `isSeeking`: the observer keeps firing near In
        // until the wrap seek lands; one wrap only.
        if self.rate < 0, self.isLooping, !self.isSeeking, let range = loopRange,
           currSecs <= Double(range.start) / max(1, activeFps) + 0.05 {
            self.seek(toFrame: range.end) { [weak self] in
                guard let self = self else { return }
                self.setPlaybackRate(self.rate)
            }
        } else if self.rate < 0 && currSecs <= 0.05 && self.isLooping && durSecs > 0.5 {
            self.seek(toProgress: 0.999) { [weak self] in
                guard let self = self else { return }
                self.setPlaybackRate(self.rate)
            }
        }
    }
    
    /// An .srt attached in Specs to the clip on screen replaces the Player's subtitles.
    func setupSubtitleAttachmentObserver() {
        NotificationCenter.default.publisher(for: SubtitleAttachments.didChange)
            .sink { [weak self] notification in
                guard let self, let video = notification.object as? URL else { return }
                if QCUtilities.isSameURL(video, self.slotB.url) { self.autoLoadSubtitlesB(for: video) }
                guard QCUtilities.isSameURL(video, self.slotA.url),
                      SubtitleAttachments.manual(for: video).map({ !QCUtilities.isSameURL($0, self.subtitleSourceURL) }) ?? true
                else { return }
                self.autoLoadSubtitles(for: video)
            }
            .store(in: &cancellables)
    }
    
    func setupEndObserver() {
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let item = notification.object as? AVPlayerItem, item == self.slotA.player.currentItem {
                    self.handlePlaybackEnded()
                }
            }
            .store(in: &cancellables)
        // Playback that dies mid-clip (a network drive dropping, a file still being written running out of data) leaves
        // the player stopped: without this the engine stayed "playing" (display link ticking at 120 Hz, display kept
        // awake, uploads throttled, the transport showing PLAY).
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .merge(with: NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let item = notification.object as? AVPlayerItem, item == self.slotA.player.currentItem,
                      self.isPlaying, !self.isScrubbing, !self.isSlowStepping else { return }
                // A stall the player rides out (fast-forward through heavy media) isn't a stop.
                if notification.name == .AVPlayerItemPlaybackStalled, self.slotA.player.timeControlStatus == .playing { return }
                self.pause()
                if notification.name == .AVPlayerItemFailedToPlayToEndTime, let url = self.slotA.url {
                    // AVFoundation's own reason is technical ("Sample cursor was invalid…").
                    self.loadFailure = LoadFailure(message: "Playback of \(url.lastPathComponent) stopped: the file couldn't be "
                        + "read past here (still being written, damaged, or its drive disconnected)")
                }
            }
            .store(in: &cancellables)
    }
    
    private func handlePlaybackEnded() {
        if isLooping {
            let savedRate = self.rate
            let start = loopRange?.start ?? 0
            seek(toFrame: start) { [weak self] in
                guard let self = self else { return }
                let resumeRate = savedRate > 0 ? savedRate : 1.0
                self.setPlaybackRate(resumeRate)
            }
        } else {
            pause()
        }
    }
    
    // MARK: - J-K-L Shuttle Engine
    
    public func pressL() {
        guard slotA.player.currentItem != nil else { return }
        if isLooping, let outFrame, currentFrame > outFrame {
            seek(toFrame: inFrame ?? 0) { [weak self] in self?.pressL() }
            return
        }
        
        // At the end: restart from the top. Not for clips too short to leave the end zone (a 1-frame slate) or whose
        // duration hasn't loaded yet: from 0 they'd seek to 0 and land here again, forever.
        let durSecs = CMTimeGetSeconds(duration)
        let currSecs = CMTimeGetSeconds(currentTime)
        if durSecs.isFinite, durSecs > 0.1, currSecs > 0.05, currSecs >= durSecs - 0.05 {
            seek(toTime: .zero) { [weak self] in
                self?.pressL()
            }
            return
        }
        
        let nextRate: Float
        if rate < 1.0 {
            nextRate = 1.0
        } else if rate == 1.0 {
            nextRate = 2.0
        } else if rate == 2.0 {
            nextRate = 4.0
        } else if rate == 4.0 {
            nextRate = 8.0
        } else if rate == 8.0 {
            nextRate = 16.0
        } else {
            nextRate = 1.0
        }
        setPlaybackRate(nextRate)
    }
    
    public func pressK() {
        pause()
    }
    
    public func pressJ() {
        guard slotA.player.currentItem != nil else { return }
        
        if CMTimeGetSeconds(currentTime) <= 0.05 && isLooping && CMTimeGetSeconds(duration) > 0.5 {
            seek(toProgress: 0.999) { [weak self] in
                self?.pressJ()
            }
            return
        }
        
        let nextRate: Float
        if rate > -1.0 {
            nextRate = -1.0
        } else if rate == -1.0 {
            nextRate = -2.0
        } else if rate == -2.0 {
            nextRate = -4.0
        } else if rate == -4.0 {
            nextRate = -8.0
        } else if rate == -8.0 {
            nextRate = -16.0
        } else {
            nextRate = -1.0
        }
        setPlaybackRate(nextRate)
    }
    
}
