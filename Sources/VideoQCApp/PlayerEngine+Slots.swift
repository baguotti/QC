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
    // MARK: - Dual Slot Operations
    
    @MainActor
    private struct SlotSnapshot {
        let url: URL?
        let fileName: String
        let resolution: String
        let fps: Double
        let codec: String
        let duration: CMTime
        let videoSize: CGSize
        let totalFrames: Int
        let formattedFileSize: String
        let currentTime: CMTime
        let lastDecodedFrame: CGImage?
        let mediaKind: MediaKind
        let stillImage: CGImage?
        let sequence: ImageSequence?
        let loadedModificationDate: Date?
        let isRotated: Bool
        
        init(from slot: PlayerSlot) {
            self.url = slot.url
            self.fileName = slot.fileName
            self.resolution = slot.resolution
            self.fps = slot.fps
            self.codec = slot.codec
            self.duration = slot.duration
            self.videoSize = slot.videoSize
            self.totalFrames = slot.totalFrames
            self.formattedFileSize = slot.formattedFileSize
            self.currentTime = slot.player.currentTime()
            self.lastDecodedFrame = slot.lastDecodedFrame
            self.mediaKind = slot.mediaKind
            self.stillImage = slot.stillImage
            self.sequence = slot.sequence
            self.loadedModificationDate = slot.loadedModificationDate
            self.isRotated = slot.isRotated
        }
        
        func apply(to slot: PlayerSlot) {
            slot.url = url
            slot.fileName = fileName
            slot.resolution = resolution
            slot.fps = fps
            slot.codec = codec
            slot.duration = duration
            slot.videoSize = videoSize
            slot.totalFrames = totalFrames
            slot.formattedFileSize = formattedFileSize
            slot.lastDecodedFrame = lastDecodedFrame
            slot.mediaKind = mediaKind
            slot.stillImage = stillImage
            slot.sequence = sequence
            slot.loadedModificationDate = loadedModificationDate
            slot.isRotated = isRotated
        }
    }
    
    public func swapSlots() {
        guard slotA.url != nil || slotB.url != nil else { return }
        if isBlinkCompareB {
            isBlinkCompareB = false
        }
        let wasPlaying = self.isPlaying
        pause()
        // The range belongs to the clip leaving slot A; its item (and end time) is about to move to slot B.
        slotA.player.currentItem?.forwardPlaybackEndTime = .invalid
        inFrame = nil
        outFrame = nil
        
        let snapA = SlotSnapshot(from: slotA)
        let snapB = SlotSnapshot(from: slotB)
        let tempSlip = slotB.slipOffsetFrames
        
        // Detach both current items first to prevent NSInvalidArgumentException
        itemStatusCancellable?.cancel()
        itemStatusCancellable = nil
        itemPresentationSizeCancellable?.cancel()
        itemPresentationSizeCancellable = nil
        itemStatusCancellableB?.cancel()
        itemStatusCancellableB = nil
        itemPresentationSizeCancellableB?.cancel()
        itemPresentationSizeCancellableB = nil
        
        slotA.detachVideoOutput()
        slotB.detachVideoOutput()
        slotA.player.replaceCurrentItem(with: nil)
        slotB.player.replaceCurrentItem(with: nil)
        
        self.isSeeking = false
        self.pendingSeekTime = nil
        self.pendingSeekCompletion = nil
        self.pendingSeekTolerance = nil
        self.isSeekingB = false
        self.pendingSeekTimeB = nil
        self.pendingSeekCompletionB = nil
        
        snapB.apply(to: slotA)
        if let urlA = snapB.url, let itemA = makePlayerItem(url: urlA, for: slotA, startAt: snapB.currentTime) {
            slotA.player.seek(to: snapB.currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
            
            itemPresentationSizeCancellable = itemA.publisher(for: \.presentationSize)
                .receive(on: DispatchQueue.main)
                .filter { $0.width > 0 && $0.height > 0 }
                .first()
                .sink { [weak self] size in
                    guard let self = self, self.slotA.url == urlA else { return }
                    self.slotA.videoSize = size
                }
            
            itemStatusCancellable = itemA.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .filter { $0 == .readyToPlay }
                .first()
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    self.slotA.player.automaticallyWaitsToMinimizeStalling = false
                    self.slotA.player.preroll(atRate: 1.0) { _ in }
                }
        }
        
        self.objectWillChange.send()
        snapA.apply(to: slotB)
        slotB.slipOffsetFrames = -tempSlip
        slotBKeepsPosition = true
        if let urlB = snapA.url, let itemB = makePlayerItem(url: urlB, for: slotB, startAt: snapA.currentTime) {
            slotB.player.seek(to: snapA.currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
            
            itemPresentationSizeCancellableB = itemB.publisher(for: \.presentationSize)
                .receive(on: DispatchQueue.main)
                .filter { $0.width > 0 && $0.height > 0 }
                .first()
                .sink { [weak self] size in
                    guard let self = self, self.slotB.url == urlB else { return }
                    self.slotB.videoSize = size
                    self.enforceCompatibleCompareMode()
                }
            
            itemStatusCancellableB = itemB.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .filter { $0 == .readyToPlay }
                .first()
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    self.slotB.player.automaticallyWaitsToMinimizeStalling = false
                    self.slotB.player.preroll(atRate: 1.0) { _ in }
                }
        }
        
        if snapB.url == nil {
            Task { [slotA] in await slotA.frameExtractor.setURL(nil) }
        }
        refreshWaveform()
        if snapA.url == nil {
            Task { [slotB] in await slotB.frameExtractor.setURL(nil) }
        }
        
        self.duration = slotA.duration
        self.totalFrames = slotA.totalFrames
        if let url = slotA.url {
            self.activeMarkers = markersMap[url] ?? []
            self.durationTimecode = TimecodeFormatter.format(time: slotA.duration, fps: slotA.fps)
        } else {
            self.activeMarkers = []
            self.durationTimecode = "00:00:00:00"
        }
        
        if slotB.url == nil {
            compareMode = .single
        } else {
            enforceCompatibleCompareMode()
        }
        
        // The observer's rate is slot A's fps, and an image in A has none: rebuild it for the clip now in A.
        setupTimeObserver()
        updateCurrentTime(time: hasTimeline ? slotA.player.currentTime() : .zero)
        updateAudioVolumes()
        autoLoadSubtitles(for: slotA.url)
        autoLoadSubtitlesB(for: slotB.url)
        
        if wasPlaying {
            self.play()
        }
    }
    
    public func clearSlotB() {
        self.objectWillChange.send()
        slotB.player.pause()
        slotB.detachVideoOutput()
        slotB.player.replaceCurrentItem(with: nil)
        itemStatusCancellableB?.cancel()
        itemStatusCancellableB = nil
        itemPresentationSizeCancellableB?.cancel()
        itemPresentationSizeCancellableB = nil
        slotB.url = nil
        autoLoadSubtitlesB(for: nil)
        slotB.fileName = ""
        slotB.resolution = ""
        slotB.codec = ""
        slotB.duration = .zero
        slotB.totalFrames = 0
        slotB.formattedFileSize = "--"
        slotB.slipOffsetFrames = 0
        slotB.lastDecodedFrame = nil
        slotB.mediaKind = .video
        slotB.stillImage = nil
        slotB.sequence = nil
        slotB.sequenceSource = nil
        Task { [slotB] in
            await slotB.frameExtractor.setURL(nil)
        }
        isSeekingB = false
        pendingSeekTimeB = nil
        pendingSeekCompletionB = nil
        compareMode = .single
        audioSlot = .slotA
        isBlinkCompareB = false
        pendingAutoplayB = false
        updateAudioVolumes()
    }
    
    public func clearSlotA() {
        self.objectWillChange.send()
        stopSlowStep()
        slotA.player.pause()
        slotA.detachVideoOutput()
        slotA.player.replaceCurrentItem(with: nil)
        itemStatusCancellable?.cancel()
        itemStatusCancellable = nil
        itemPresentationSizeCancellable?.cancel()
        itemPresentationSizeCancellable = nil
        pendingAutoplay = false
        slotA.url = nil
        slotA.fileName = ""
        slotA.resolution = ""
        slotA.codec = ""
        slotA.duration = .zero
        slotA.totalFrames = 0
        slotA.formattedFileSize = "--"
        slotA.lastDecodedFrame = nil
        slotA.mediaKind = .video
        slotA.stillImage = nil
        slotA.sequence = nil
        slotA.sequenceSource = nil
        refreshWaveform()
        clearSubtitles()
        Task { [slotA] in
            await slotA.frameExtractor.setURL(nil)
        }
        activeMarkers = []
        durationTimecode = "00:00:00:00"
        currentTimecode = "00:00:00:00"
        isPlaying = false
        rate = 0.0
        updateAudioVolumes()
    }
    
    public func unload() {
        clearSlotA()
        clearSlotB()
    }
    
    public func cycleCompareMode() {
        guard slotB.url != nil else { return }
        if isBlinkCompareB {
            isBlinkCompareB = false
        }
        let validModes: [CompareMode] = hasMatchingAspectRatios
            ? CompareMode.allCases
            : CompareMode.allCases.filter { !$0.requiresMatchingAspect }
        if let idx = validModes.firstIndex(of: compareMode) {
            let nextIdx = (idx + 1) % validModes.count
            compareMode = validModes[nextIdx]
        } else {
            compareMode = validModes.first ?? .sideBySide
        }
    }
    
    public func syncSlotBToMaster() {
        guard slotB.url != nil, slotB.player.currentItem != nil else { return }
        let masterSecs = hasTimeline ? CMTimeGetSeconds(slotA.player.currentTime()) : 0
        let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
        let targetSecs = max(0.0, masterSecs + offsetSecs)
        if isLinkedPlaybackRunning {
            // B is kept in phase by the PLL while playing; a plain seek would leave it behind by the seek latency.
            let driftSecs = CMTimeGetSeconds(slotB.player.currentTime()) - targetSecs
            if !driftSecs.isFinite || abs(driftSecs) > 0.5 / max(1.0, slotB.fps) || slotB.player.rate == 0 {
                relockSlotB()
            }
            return
        }
        let targetTimeB = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        seekSlotB(to: targetTimeB)
    }

    /// Linked playback with the master actually running (the only state in which slot B is phase-locked).
    var isLinkedPlaybackRunning: Bool {
        isLinked && isPlaying && !isScrubbing && rate != 0 && slotA.player.rate != 0 && slotB.player.currentItem != nil
    }

    /// Hard re-sync of slot B during linked playback. An exact seek into long-GOP media takes ~100–200 ms, so
    /// seeking B to A's *current* time and restarting it left B several frames behind every time and the stall
    /// recovery re-seeked it several times a second (B stuttered at ~6 fps after TAB, fast-forward or pause/play).
    /// B instead seeks ahead of A and is started with `setRate(_:time:atHostTime:)` at the host time A reaches
    /// that position: one seek, landing in phase. The lead adapts to the measured seek latency.
    func relockSlotB() {
        guard !isRelockingB, !isSeekingB, isLinkedPlaybackRunning,
              let itemB = slotB.player.currentItem, itemB.status == .readyToPlay else { return }
        let secsA = CMTimeGetSeconds(slotA.player.currentTime())
        guard secsA.isFinite else { return }
        let playRate = rate
        let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
        let targetA = CMTime(seconds: secsA + relockLead * Double(playRate), preferredTimescale: 60000)
        let targetB = CMTime(seconds: max(0.0, CMTimeGetSeconds(targetA) + offsetSecs), preferredTimescale: 60000)
        let itemID = ObjectIdentifier(itemB)
        let generation = relockGeneration
        let seekStart = CACurrentMediaTime()

        isRelockingB = true
        relockHoldUntil = .greatestFiniteMagnitude
        lastRelockStart = seekStart
        slotB.player.pause()
        slotB.player.seek(to: targetB, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            let complete = { @MainActor in
                guard let self = self else { return }
                self.isRelockingB = false
                self.relockHoldUntil = 0
                guard finished, generation == self.relockGeneration, self.isLinkedPlaybackRunning, self.rate == playRate,
                      let currentB = self.slotB.player.currentItem, ObjectIdentifier(currentB) == itemID else { return }
                self.relockLead = min(1.0, max(0.15, (CACurrentMediaTime() - seekStart) * 1.5 + 0.05))
                self.slotB.player.automaticallyWaitsToMinimizeStalling = false
                let hostClock = CMClockGetHostTimeClock()
                // Host time at which A reaches targetA. If the seek overran the lead it is in the past and B starts
                // interpolated to A's current position, still in phase.
                guard let timebaseA = self.slotA.player.currentItem?.timebase else {
                    self.slotB.player.playImmediately(atRate: playRate)
                    return
                }
                let startHost = CMSyncConvertTime(targetA, from: timebaseA, to: hostClock)
                guard startHost.isValid else {
                    self.slotB.player.playImmediately(atRate: playRate)
                    return
                }
                self.slotB.player.setRate(playRate, time: targetB, atHostTime: startHost)
                let startsIn = max(0.0, CMTimeGetSeconds(CMTimeSubtract(startHost, CMClockGetTime(hostClock))))
                self.relockHoldUntil = CACurrentMediaTime() + startsIn + 0.15
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { complete() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { complete() } }
            }
        }
    }

    /// Explicit transport actions supersede an in-flight re-lock.
    func cancelSlotBRelock() {
        relockGeneration &+= 1
        relockHoldUntil = 0
    }
    
    func seekSlotB(to time: CMTime, tolerance: CMTime = .zero, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard slotB.url != nil, slotB.player.currentItem != nil else {
            completion?()
            return
        }
        if isSeekingB {
            pendingSeekTimeB = time
            // Kept, not replaced: a queued completion can be "start both players" (Play during a B seek).
            if let completion {
                let earlier = pendingSeekCompletionB
                pendingSeekCompletionB = { earlier?(); completion() }
            }
            return
        }
        isSeekingB = true
        slotB.player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            let runCompletion = { @MainActor in
                guard let self = self else { return }
                self.isSeekingB = false
                self.notifyFrameDecoded(.slotB, at: time)
                completion?()
                if !self.isPlaying && !self.isScrubbing {
                    self.notifySeekSettled()
                }
                if let nextB = self.pendingSeekTimeB {
                    let nextComp = self.pendingSeekCompletionB
                    self.pendingSeekTimeB = nil
                    self.pendingSeekCompletionB = nil
                    self.seekSlotB(to: nextB, tolerance: tolerance, completion: nextComp)
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    runCompletion()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        runCompletion()
                    }
                }
            }
        }
    }
    
}
