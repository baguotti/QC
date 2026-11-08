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
    // MARK: - Asset Loading
    
    public func loadVideo(url: URL, into target: SlotTarget = .slotA, initialSeekFrame: Int? = nil, autoplay: Bool = false, forceAutoplay: Bool = false) {
        let shouldAutoplay = forceAutoplay || (autoplay && isAutoplayEnabled)
        ProVideoFormatsPrompt.showIfNeeded(for: url)
        if target == .slotA || slotA.url == nil {
            loadVideoIntoSlotA(url: url, initialSeekFrame: initialSeekFrame, autoplay: shouldAutoplay)
        } else {
            loadVideoIntoSlotB(url: url, autoplay: shouldAutoplay)
        }
    }
    
    private func loadVideoIntoSlotA(url: URL, initialSeekFrame: Int? = nil, autoplay: Bool = false) {
        let stdURL = url.standardizedFileURL
        self.activeMarkers = markersMap[stdURL] ?? markersMap[url] ?? []
        
        let modified = Self.modificationDate(of: stdURL)
        if let currentA = slotA.url, currentA.standardizedFileURL.path == stdURL.path, slotA.loadedModificationDate == modified {
            if let frame = initialSeekFrame {
                seek(toFrame: frame)
            } else if autoplay {
                seek(toTime: .zero) { [weak self] in
                    self?.play()
                }
            }
            return
        }
        
        // Resume where you left off: remember the clip being left, pick up the new one's last frame (not when
        // autoplaying from the start or jumping to a frame).
        let resume = UserPreferences.resumePosition
        if resume, let previous = slotA.url, hasTimeline {
            let frame = currentFrame
            UserPreferences.saveFrame(frame > 0 && frame < totalFrames - 1 ? frame : nil, for: previous)
        }
        self.pendingInitialSeekFrame = initialSeekFrame ?? (resume && !autoplay ? UserPreferences.savedFrame(for: stdURL) : nil)
        self.pendingAutoplay = autoplay
        self.pendingAutoplayB = false
        pause()
        
        self.objectWillChange.send()
        switch UserPreferences.defaultZoom {
        case "100":
            isFitZoom = false
            zoomScale = 1
        case "fit":
            isFitZoom = true
        default:
            break
        }
        slotA.url = stdURL
        slotA.loadedModificationDate = modified
        slotA.isRotated = false
        slotA.fileName = stdURL.lastPathComponent
        slotA.formattedFileSize = "--"
        autoLoadSubtitles(for: stdURL)
        self.activeNotes = []
        self.activeNotesURL = nil
        self.currentTime = .zero
        self.currentFrame = 0
        self.currentProgress = 0.0
        self.currentTimecode = "00:00:00:00"
        self.inFrame = nil
        self.outFrame = nil
        self.panOffset = .zero
        self.isScrubbing = false
        self.wasPlayingBeforeScrub = false
        self.isSeeking = false
        self.pendingSeekTime = nil
        self.pendingSeekTolerance = nil
        self.pendingSeekCompletion = nil
        
        slotA.sequence = ImageSequenceStore.shared.sequence(for: stdURL)
        slotA.mediaKind = slotA.sequence != nil ? .video : (QCUtilities.mediaKind(of: url) ?? .video)
        slotA.stillImage = nil
        refreshWaveform()
        if !hasTimeline {
            setupTimeObserver()
        }
        itemPresentationSizeCancellable = nil
        itemStatusCancellable = nil
        if let seq = slotA.sequence { slotA.fileName = seq.displayName }
        let item = makePlayerItem(url: url, for: slotA)
        Task {
            await extractMetadata(url: url, asset: item?.asset as? AVURLAsset, for: .slotA)
        }
        updateAudioVolumes()
        if let item {
            observeItem(item, for: .slotA)
        }
    }

    private func reportLoadFailure(_ url: URL, error: Error?) {
        let reason = ProVideoFormats.needsInstall(for: url)
            ? "it needs Apple Pro Video Formats"
            : (error as NSError?)?.localizedFailureReason ?? "it may still be rendering or copying, or be damaged"
        loadFailure = LoadFailure(message: "Can't play \(url.lastPathComponent): \(reason)")
    }

    /// Read from disk each time (URL resource values are cached per URL and would hide a re-export).
    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Load-time observers: the presentation size, and preroll / autoplay (slot B also re-syncs to A) once ready.
    private func observeItem(_ item: AVPlayerItem, for target: SlotTarget) {
        let slot = (target == .slotA) ? slotA : slotB
        let url = slot.url
        let sizeSink = item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .filter { $0.width > 0 && $0.height > 0 }
            .first()
            .sink { [weak self] size in
                guard let self = self, slot.url == url else { return }
                slot.videoSize = size
                if target == .slotB { self.enforceCompatibleCompareMode() }
            }
        let statusSink = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .filter { $0 != .unknown }
            .first()
            .sink { [weak self] status in
                guard let self = self else { return }
                guard status == .readyToPlay else {
                    if slot.url == url, let url { self.reportLoadFailure(url, error: item.error) }
                    return
                }
                slot.player.automaticallyWaitsToMinimizeStalling = false
                slot.player.preroll(atRate: 1.0) { _ in }
                if target == .slotB, !self.slotBKeepsPosition { self.syncSlotBToMaster() }
                // A replaced item for the same clip (sequence rate change) keeps the In–Out loop.
                if target == .slotA { self.applyInOutRange() }
                let autoplay = (target == .slotA) ? self.pendingAutoplay : self.pendingAutoplayB
                if autoplay {
                    if target == .slotA { self.pendingAutoplay = false } else { self.pendingAutoplayB = false }
                    self.seek(toTime: .zero) { [weak self] in
                        self?.play()
                    }
                }
            }
        if target == .slotA {
            itemPresentationSizeCancellable = sizeSink
            itemStatusCancellable = statusSink
        } else {
            itemPresentationSizeCancellableB = sizeSink
            itemStatusCancellableB = statusSink
        }
    }
    
    /// Builds an image sequence's item off the main thread, then installs it like a freshly loaded video.
    private func installSequenceItem(_ seq: ImageSequence, for target: SlotTarget, startAt: CMTime? = nil) async {
        let slot = (target == .slotA) ? slotA : slotB
        let box = exposureBox
        guard let item = await ImageSequencePlayback.makeItem(for: seq, fps: ImageSequenceStore.shared.fps(for: seq), exposure: { box.value }),
              slot.sequence == seq else { return }
        slot.sequenceSource = (item.videoComposition?.instructions.first as? SequenceInstruction)?.source
        slot.attachVideoOutput(to: item)
        slot.player.replaceCurrentItem(with: item)
        slot.player.automaticallyWaitsToMinimizeStalling = false
        // Swapping slots keeps each clip's position: the sequence's item only exists now.
        if let startAt, startAt.isNumeric {
            if target == .slotA { seek(toTime: startAt) } else { seekSlotB(to: startAt) }
        }
        observeItem(item, for: target)
        await extractMetadata(url: seq.firstURL, asset: item.asset, for: target)
    }
    
    /// Images get no item (no player, no timeline); audio plays without video output, frame extractor or exposure.
    func makePlayerItem(url: URL, for slot: PlayerSlot, startAt: CMTime? = nil) -> AVPlayerItem? {
        slot.detachVideoOutput()
        let isVideo = slot.mediaKind == .video && slot.sequence == nil
        Task { [slot] in
            await slot.frameExtractor.setURL(isVideo ? url : nil)
        }
        slot.sequenceSource = nil
        if let seq = slot.sequence {
            slot.player.replaceCurrentItem(with: nil)
            let target: SlotTarget = (slot === slotA) ? .slotA : .slotB
            Task { await installSequenceItem(seq, for: target, startAt: startAt) }
            return nil
        }
        guard slot.mediaKind != .image else {
            slot.player.replaceCurrentItem(with: nil)
            return nil
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        if isVideo {
            slot.attachVideoOutput(to: item)
        }
        slot.player.replaceCurrentItem(with: item)
        slot.player.automaticallyWaitsToMinimizeStalling = false
        installExposureComposition(for: slot)
        return item
    }
    
    private func loadVideoIntoSlotB(url: URL, autoplay: Bool = false) {
        let stdURL = url.standardizedFileURL
        let wasInABMode = (slotB.url != nil)
        let modified = Self.modificationDate(of: stdURL)
        if let currentB = slotB.url, currentB.standardizedFileURL.path == stdURL.path, slotB.loadedModificationDate == modified {
            if autoplay {
                seek(toTime: .zero) { [weak self] in
                    self?.play()
                }
            }
            return
        }
        
        self.pendingAutoplayB = autoplay
        self.pendingAutoplay = false
        self.slotBKeepsPosition = false
        pause()
        
        isSeekingB = false
        pendingSeekTimeB = nil
        pendingSeekCompletionB = nil
        
        if !wasInABMode {
            self.compareMode = UserPreferences.defaultCompare
            self.isBlinkCompareB = false
        }
        
        self.objectWillChange.send()
        slotB.url = stdURL
        slotB.loadedModificationDate = modified
        slotB.isRotated = false
        slotB.fileName = stdURL.lastPathComponent
        slotB.formattedFileSize = "--"
        slotB.slipOffsetFrames = 0
        autoLoadSubtitlesB(for: stdURL)
        if activeTarget == .slotB {
            self.activeNotes = []
            self.activeNotesURL = nil
        }
        
        slotB.sequence = ImageSequenceStore.shared.sequence(for: stdURL)
        slotB.mediaKind = slotB.sequence != nil ? .video : (QCUtilities.mediaKind(of: stdURL) ?? .video)
        slotB.stillImage = nil
        itemPresentationSizeCancellableB = nil
        itemStatusCancellableB = nil
        if let seq = slotB.sequence { slotB.fileName = seq.displayName }
        let item = makePlayerItem(url: stdURL, for: slotB)
        Task {
            await extractMetadata(url: stdURL, asset: item?.asset as? AVURLAsset, for: .slotB)
        }
        enforceCompatibleCompareMode()
        updateAudioVolumes()
        if let item {
            observeItem(item, for: .slotB)
        }
    }
    
    /// `asset` is nil for images (no player item); for a sequence it is the composition built by `installSequenceItem`.
    private func extractMetadata(url fileURL: URL, asset: AVAsset?, for target: SlotTarget) async {
        let slot = (target == .slotA) ? slotA : slotB
        let sequence = slot.sequence
        // A sequence's item is built asynchronously; its metadata comes from `installSequenceItem`.
        if sequence != nil && asset == nil { return }
        var kind = slot.mediaKind
        let fileSizeText = await Task.detached(priority: .utility) { PlayerSlot.fileSizeText(for: fileURL) }.value
        do {
            var dur = CMTime.zero
            var tracks: [AVAssetTrack] = []
            var detectedFps: Double = 25.0
            var resStr = "--"
            var codecStr = "--"
            var detectedSize = CGSize(width: 1920, height: 1080)
            var still: CGImage? = nil
            
            if let asset, let sequence {
                dur = try await asset.load(.duration)
                detectedFps = ImageSequenceStore.shared.fps(for: sequence)
                if let size = await Task.detached(priority: .userInitiated, operation: { ImageSequencePlayback.imageSize(sequence.firstURL) }).value {
                    detectedSize = size
                    resStr = "\(Int(size.width))x\(Int(size.height))"
                }
                codecStr = "\(sequence.ext.uppercased()) SEQ" + (sequence.missingCount > 0 ? " · \(sequence.missingCount) MISSING" : "")
            } else if let asset {
                dur = try await asset.load(.duration)
                tracks = try await asset.loadTracks(withMediaType: .video)
                // An .mp4 / .mov holding only sound (music, podcast exports): played as audio, with the info card.
                if kind == .video, tracks.isEmpty, !(try await asset.loadTracks(withMediaType: .audio)).isEmpty {
                    kind = .audio
                }
            } else {
                guard let decoded = await Task.detached(priority: .userInitiated, operation: { MediaStills.decodeImage(at: fileURL) }).value else {
                    Log.player.error("Could not decode image \(fileURL.path)")
                    return
                }
                still = decoded.image
                detectedSize = CGSize(width: decoded.image.width, height: decoded.image.height)
                resStr = "\(decoded.image.width)x\(decoded.image.height)"
                codecStr = decoded.format
            }
            if kind == .audio, let asset {
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let info = await DeliverablesInspector.extractAudioInfo(tracks: audioTracks)
                codecStr = info.codec
                detectedSize = MediaStills.audioCardSize
                let details = [info.fullDesc, TimecodeFormatter.format(time: dur, fps: detectedFps), fileSizeText]
                still = MediaStills.audioCard(fileName: fileURL.lastPathComponent, details: details)
            }
            // A newer load replaced this file while its metadata was loading.
            guard slot.url?.path == fileURL.standardizedFileURL.path, slot.sequence == sequence else { return }
            if kind != slot.mediaKind {
                slot.mediaKind = kind
                slot.detachVideoOutput()
                Task { [slot] in await slot.frameExtractor.setURL(nil) }
            }
            slot.stillImage = still
            
            if kind == .video, let vTrack = tracks.first {
                let naturalSize = try await vTrack.load(.naturalSize)
                let transform = try await vTrack.load(.preferredTransform)
                if !transform.isIdentity, slot.url?.path == fileURL.standardizedFileURL.path {
                    slot.isRotated = true
                    installExposureComposition(for: slot)
                    refreshPausedFramesForExposure()
                }
                let transformedSize = naturalSize.applying(transform)
                // A damaged header can carry NaN or absurd sizes: Int() traps on those (Inspect guards the same way).
                func pixels(_ v: CGFloat) -> Int { v.isFinite && abs(v) < 1_000_000 ? Int(abs(v)) : 0 }
                let w = pixels(transformedSize.width)
                let h = pixels(transformedSize.height)
                resStr = "\(w)x\(h)"
                detectedSize = CGSize(width: max(1, w), height: max(1, h))
                
                let nominalRate = try await vTrack.load(.nominalFrameRate)
                let minFrameDur = try? await vTrack.load(.minFrameDuration)
                // Frame math clamps rates to ≥ 1 fps throughout: a slower clip is counted at 1 fps (frames shown twice).
                detectedFps = max(1, resolveAccurateFramerate(nominal: nominalRate, minFrameDuration: minFrameDur))
                
                let descriptions = try await vTrack.load(.formatDescriptions)
                if let firstDesc = descriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(firstDesc)
                    codecStr = fourCCToString(subType)
                }
            }
            
            // Checked again: the track loads above suspend, and a newer file must not get this one's fps / duration.
            guard slot.url?.path == fileURL.standardizedFileURL.path, slot.sequence == sequence else { return }
            let durSecs = CMTimeGetSeconds(dur)
            let roundedFps = max(1.0, detectedFps)
            let totFrames: Int
            if durSecs.isFinite && !durSecs.isNaN && roundedFps.isFinite && !roundedFps.isNaN {
                totFrames = max(0, Int(round(durSecs * roundedFps)))
            } else {
                totFrames = 0
            }
            
            if target == .slotA {
                self.slotA.duration = dur
                self.slotA.fps = detectedFps
                self.slotA.resolution = resStr
                self.slotA.codec = codecStr
                self.slotA.videoSize = detectedSize
                self.slotA.totalFrames = totFrames
                self.slotA.formattedFileSize = fileSizeText
                
                self.duration = dur
                self.totalFrames = totFrames
                self.durationTimecode = TimecodeFormatter.format(time: dur, fps: detectedFps)
                self.setupTimeObserver()
                
                if let frame = self.pendingInitialSeekFrame {
                    self.pendingInitialSeekFrame = nil
                    self.seek(toFrame: frame)
                }
                if !self.isPlaying {
                    // From the frame number: `currentTime` is a frame centre, which `format(time:)` rounds up a frame.
                    self.currentTimecode = TimecodeFormatter.format(frameIndex: self.currentFrame, fps: detectedFps)
                }
                self.enforceCompatibleCompareMode()
            } else {
                self.objectWillChange.send()
                self.slotB.duration = dur
                self.slotB.fps = detectedFps
                self.slotB.resolution = resStr
                self.slotB.codec = codecStr
                self.slotB.videoSize = detectedSize
                self.slotB.totalFrames = totFrames
                self.slotB.formattedFileSize = fileSizeText
                if !self.slotBKeepsPosition { self.syncSlotBToMaster() }
                self.enforceCompatibleCompareMode()
            }
        } catch {
            Log.player.error("Reading \(target == .slotA ? "A" : "B") metadata failed: \(fileURL.path)", error)
        }
    }
    
    private func fourCCToString(_ fourCC: FourCharCode) -> String {
        let raw = QCUtilities.fourCCToString(fourCC)
        switch raw.lowercased() {
        case "ap4h": return "ProRes 4444"
        case "apch": return "ProRes 422HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422LT"
        case "apco": return "ProRes 422Proxy"
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        default: return raw.uppercased()
        }
    }
    
    private func resolveAccurateFramerate(nominal: Float, minFrameDuration: CMTime?) -> Double {
        var rawFps = Double(nominal)
        if let minDur = minFrameDuration, minDur.isValid && minDur.seconds > 0 {
            let minFps = 1.0 / minDur.seconds
            // Variable frame rate (phone clips, screen recordings): one short frame interval makes the minimum duration
            // tiny (measured: a 30 fps clip with one 1.7 ms gap read 600 fps), so the average rate is the clip's rate.
            if nominal > 0, abs(minFps - Double(nominal)) / Double(nominal) > 0.01 {
                return FrameRate.counting(nominal: Double(nominal))
            }
            rawFps = minFps
        }
        // Slideshows and timelapses can run at 1 fps or slower: only a missing rate falls back to 25.
        guard rawFps.isFinite, rawFps > 0.01 else { return 25.0 }
        
        // Snap to standard broadcast framerates with high precision to eliminate fractional drift
        if abs(rawFps - (24000.0 / 1001.0)) < 0.005 || abs(Double(nominal) - 23.976) < 0.005 { return 24000.0 / 1001.0 }
        if abs(rawFps - 24.0) < 0.005 || abs(Double(nominal) - 24.0) < 0.005 { return 24.0 }
        if abs(rawFps - 25.0) < 0.005 || abs(Double(nominal) - 25.0) < 0.005 { return 25.0 }
        if abs(rawFps - (30000.0 / 1001.0)) < 0.005 || abs(Double(nominal) - 29.97) < 0.005 { return 30000.0 / 1001.0 }
        if abs(rawFps - 30.0) < 0.005 || abs(Double(nominal) - 30.0) < 0.005 { return 30.0 }
        if abs(rawFps - (48000.0 / 1001.0)) < 0.005 { return 48000.0 / 1001.0 }
        if abs(rawFps - 48.0) < 0.005 { return 48.0 }
        if abs(rawFps - 50.0) < 0.005 { return 50.0 }
        if abs(rawFps - (60000.0 / 1001.0)) < 0.005 || abs(Double(nominal) - 59.94) < 0.005 { return 60000.0 / 1001.0 }
        if abs(rawFps - 60.0) < 0.005 || abs(Double(nominal) - 60.0) < 0.005 { return 60.0 }
        
        return rawFps
    }
    
}
