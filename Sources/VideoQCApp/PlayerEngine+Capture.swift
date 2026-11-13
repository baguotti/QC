import Foundation
import os
@preconcurrency import AVFoundation
import Combine
import CoreMedia
import AppKit
import UniformTypeIdentifiers
@preconcurrency import VideoToolbox
import VideoQCLib

/// Marker and note navigation, still-frame capture and screenshot export.
extension PlayerEngine {
    // MARK: - Frame-Accurate Seeking & Scan Markers
    
    public func seek(toFrame requestedFrame: Int, completion: (@MainActor @Sendable () -> Void)? = nil) {
        // A remembered position or note can lie past the end of a clip re-exported shorter.
        let frameIndex = totalFrames > 0 ? min(max(0, requestedFrame), totalFrames - 1) : max(0, requestedFrame)
        let fps = max(1.0, activeFps)
        let durSecs = CMTimeGetSeconds(duration)
        // Center the timestamp squarely in the middle of the frame window (+0.5/fps)
        // to avoid leading-edge sample rounding or codec presentation timestamp (PTS) truncation
        let desiredSecs = (Double(frameIndex) + 0.5) / fps
        let targetSecs = durSecs > 0 ? min(max(0.0, desiredSecs), max(0.0, durSecs - 0.001)) : desiredSecs
        let targetTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        
        self.currentFrame = frameIndex
        self.currentTimecode = TimecodeFormatter.format(frameIndex: frameIndex, fps: activeFps)
        if durSecs > 0 {
            self.currentProgress = min(1.0, max(0.0, targetSecs / durSecs))
        }
        self.currentTime = targetTime
        self.slotA.currentTime = targetTime
        
        seek(toTime: targetTime, completion: completion)
    }
    
    // MARK: - Review Note Navigation
    
    public func jumpToPreviousNote() {
        guard !activeNotes.isEmpty else { return }
        let sorted = activeNotes.sorted { $0.frameIndex < $1.frameIndex }
        let cur = currentFrame
        if let prev = sorted.last(where: { $0.frameIndex < cur }) {
            pause()   // first: pausing re-reads the player's position, which would undo a seek still in flight
            seek(toFrame: prev.frameIndex)
        } else if let last = sorted.last {
            pause()   // first: pausing re-reads the player's position, which would undo a seek still in flight
            seek(toFrame: last.frameIndex)
        }
    }
    
    public func jumpToNextNote() {
        guard !activeNotes.isEmpty else { return }
        let sorted = activeNotes.sorted { $0.frameIndex < $1.frameIndex }
        let cur = currentFrame
        if let next = sorted.first(where: { $0.frameIndex > cur }) {
            pause()   // first: pausing re-reads the player's position, which would undo a seek still in flight
            seek(toFrame: next.frameIndex)
        } else if let first = sorted.first {
            pause()   // first: pausing re-reads the player's position, which would undo a seek still in flight
            seek(toFrame: first.frameIndex)
        }
    }
    
    public func setScanResults(_ results: [VideoQCResult]) {
        var map: [URL: [PlayerTimelineMarker]] = [:]
        var lines: [URL: LineMarkFrames] = [:]
        for res in results {
            var fileMarkers: [PlayerTimelineMarker] = []
            for seg in res.glitchSegments {
                let marker = PlayerTimelineMarker(
                    frameIndex: seg.startFrame,
                    timecode: seg.startTimecode,
                    edge: seg.edge,
                    colorHex: seg.detectedColor.hexString,
                    label: "\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX) @ \(seg.startTimecode)"
                )
                fileMarkers.append(marker)
            }
            map[res.fileURL.standardizedFileURL] = fileMarkers   // Player URLs are standardized
            let dims = res.resolution.split(separator: "x").compactMap { Double($0) }
            if dims.count == 2, !res.errorFrames.isEmpty {
                lines[res.fileURL.standardizedFileURL] = LineMarkFrames(
                    size: CGSize(width: dims[0], height: dims[1]),
                    frames: Dictionary(res.errorFrames.map { ($0.frameIndex, $0.detections) }, uniquingKeysWith: { a, _ in a }))
            }
        }
        self.lineMarks = lines
        self.markersMap = map
        if let active = activeURL {
            self.activeMarkers = map[active] ?? []
        }
    }
    
    // MARK: - Pixel-Perfect Still Frame Capture (For export)
    
    /// Returns the frame as displayed, i.e. with the current exposure applied exactly once.
    /// `applyingExposure: false` returns the decoded pixels as they are (missed-line reports), or nil when only
    /// exposure-adjusted pixels are available; the cached `lastDecodedFrame` is only updated for display-ready frames.
    public func captureCurrentFrame(for slot: SlotTarget = .slotA, at time: CMTime? = nil, applyingExposure: Bool = true) async -> CGImage? {
        let currentSlot = (slot == .slotA) ? slotA : slotB
        // The video output and the viewport's cached frame already carry the exposure: only usable as originals at EV 0.
        let exposureFreeFallbacks = applyingExposure || exposureEV == 0
        func cachedFrame() -> CGImage? { exposureFreeFallbacks ? currentSlot.lastDecodedFrame : nil }
        guard let url = currentSlot.url else { return cachedFrame() }
        guard currentSlot.mediaKind == .video else { return currentSlot.stillImage }
        
        let targetTime: CMTime
        if let explicitTime = time, explicitTime.isValid, explicitTime.isNumeric {
            targetTime = explicitTime
        } else {
            if slot == .slotA {
                targetTime = (currentSlot.currentTime.isValid && currentSlot.currentTime.isNumeric) ? currentSlot.currentTime : currentSlot.player.currentTime()
            } else {
                if isLinked {
                    let timeA = (slotA.currentTime.isValid && slotA.currentTime.isNumeric) ? slotA.currentTime : slotA.player.currentTime()
                    let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                    let masterSecs = CMTimeGetSeconds(timeA)
                    let targetSecsB = max(0.0, (masterSecs.isFinite && !masterSecs.isNaN ? masterSecs : 0.0) + offsetSecs)
                    targetTime = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
                } else {
                    targetTime = (currentSlot.currentTime.isValid && currentSlot.currentTime.isNumeric) ? currentSlot.currentTime : currentSlot.player.currentTime()
                }
            }
        }
        
        guard targetTime.isValid && targetTime.isNumeric else { return cachedFrame() }
        let fps = max(1.0, currentSlot.fps)
        let rawSecs = CMTimeGetSeconds(targetTime)
        guard rawSecs.isFinite && !rawSecs.isNaN else { return cachedFrame() }
        
        // Snap to exact frame-center PTS so AVAssetImageGenerator zero tolerance lands squarely inside target frame
        let frameIdx = max(0, Int(floor(rawSecs * fps + 1e-4)))
        let targetSecs = (Double(frameIdx) + 0.5) / fps
        let centerTime = CMTime(seconds: targetSecs, preferredTimescale: 60000)
        
        // Sequences: the exact frame from the sequence's cache (decoded on a miss, reads ahead for stepping).
        if let seq = currentSlot.sequence {
            guard let source = currentSlot.sequenceSource else { return cachedFrame() }
            let index = min(frameIdx, seq.length - 1)
            guard let decoded = await Task.detached(priority: .userInitiated, operation: { source.displayImage(at: index) }).value else {
                return cachedFrame()
            }
            // Another file was loaded while decoding: never hand back (or cache) the old file's frame.
            guard currentSlot.url == url else { return nil }
            guard applyingExposure else { return decoded }
            let image = ExposureAdjuster.shared.applyExposure(to: decoded, ev: exposureEV)
            currentSlot.lastDecodedFrame = image
            return image
        }
        
        // 1. Try frame extractor (decodes without the exposure composition, so apply it here)
        let extracted = await currentSlot.frameExtractor.capture(at: centerTime, fallbackURL: url)
        guard currentSlot.url == url else { return nil }
        if let extracted {
            guard applyingExposure else { return extracted }
            let image = ExposureAdjuster.shared.applyExposure(to: extracted, ev: exposureEV)
            currentSlot.lastDecodedFrame = image
            return image
        }
        
        // 2. Try video output pixel buffer (already composited with exposure)
        if exposureFreeFallbacks, let output = currentSlot.videoOutput {
            var displayTime = CMTime.zero
            var pb = output.copyPixelBuffer(forItemTime: centerTime, itemTimeForDisplay: &displayTime)
            if pb == nil {
                pb = output.copyPixelBuffer(forItemTime: currentSlot.player.currentTime(), itemTimeForDisplay: &displayTime)
            }
            if let pb = pb {
                var cg: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
                if let cg = cg {
                    currentSlot.lastDecodedFrame = cg
                    return cg
                }
            }
        }
        
        // 3. Fallback to cached frame from viewport
        return cachedFrame()
    }
    
    // MARK: - Pixel-Perfect Frame & Compare Screenshot Export
    
    /// Captures the current visible frame or dual-slot A/B composition for screenshot export.
    /// Pure master frames with zero UI elements, timecode HUDs, or media info labels.
    public func captureCompositedScreenshotImage() async -> CGImage? {
        let isABActive = slotB.url != nil && (compareMode != .single || isBlinkCompareB)
        
        // 1. Blink compare: user is viewing 100% Slot B directly
        if isBlinkCompareB && slotB.url != nil {
            let timeA = (slotA.currentTime.isValid && slotA.currentTime.isNumeric) ? slotA.currentTime : slotA.player.currentTime()
            let timeB: CMTime
            if isLinked {
                let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
                let masterSecs = CMTimeGetSeconds(timeA)
                let targetSecsB = max(0.0, (masterSecs.isFinite && !masterSecs.isNaN ? masterSecs : 0.0) + offsetSecs)
                timeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
            } else {
                timeB = (slotB.currentTime.isValid && slotB.currentTime.isNumeric) ? slotB.currentTime : slotB.player.currentTime()
            }
            guard let rawImage = await captureCurrentFrame(for: .slotB, at: timeB) ?? slotB.lastDecodedFrame else { return nil }
            return rawImage
        }
        
        // 2. Single slot capture
        if !isABActive || compareMode == .single {
            let targetSlot: SlotTarget = (activeTarget == .slotB && slotB.url != nil) ? .slotB : .slotA
            let rawImage = await captureCurrentFrame(for: targetSlot) ?? ((targetSlot == .slotB) ? slotB.lastDecodedFrame : slotA.lastDecodedFrame)
            guard let img = rawImage else { return nil }
            return img
        }
        
        // 3. Dual slot A/B compositing
        let timeA = (slotA.currentTime.isValid && slotA.currentTime.isNumeric) ? slotA.currentTime : slotA.player.currentTime()
        let timeB: CMTime
        if isLinked {
            let offsetSecs = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
            let masterSecs = CMTimeGetSeconds(timeA)
            let targetSecsB = max(0.0, (masterSecs.isFinite && !masterSecs.isNaN ? masterSecs : 0.0) + offsetSecs)
            timeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
        } else {
            timeB = (slotB.currentTime.isValid && slotB.currentTime.isNumeric) ? slotB.currentTime : slotB.player.currentTime()
        }
        
        async let frameA = captureCurrentFrame(for: .slotA, at: timeA)
        async let frameB = captureCurrentFrame(for: .slotB, at: timeB)
        var (rawA, rawB) = await (frameA, frameB)
        
        if rawA == nil { rawA = slotA.lastDecodedFrame }
        if rawB == nil { rawB = slotB.lastDecodedFrame }
        
        guard let imgA = rawA else {
            return rawB
        }
        guard let imgB = rawB else {
            return imgA
        }
        
        // Captured frames are display-ready (exposure already applied once).
        let expA = imgA
        let expB = imgB
        
        let colorSpace = expA.colorSpace ?? expB.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        // A's colour space can't always back an 8-bit RGBA canvas (a greyscale still, some HDR spaces): fall back to sRGB
        // rather than returning A alone.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        func canvas(_ width: Int, _ height: Int) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo)
                ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: bitmapInfo)
        }
        
        switch compareMode {
        case .single:
            return expA
            
        case .splitVertical:
            let outW = max(expA.width, expB.width)
            let outH = max(expA.height, expB.height)
            guard let ctx = canvas(outW, outH) else {
                return expA
            }
            // Base: Slot B across entire frame
            ctx.draw(expB, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            
            // Left portion: Slot A
            let splitPos = max(0.0, min(1.0, splitPosition))
            let splitX = round(CGFloat(outW) * splitPos)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: splitX, height: CGFloat(outH)))
            ctx.draw(expA, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.restoreGState()
            
            // Cyan split wipe line at divider position
            let lineWidth = max(2.0, round(CGFloat(outW) / 960.0))
            let dividerRect = CGRect(x: splitX - (lineWidth / 2.0), y: 0, width: lineWidth, height: CGFloat(outH))
            ctx.setFillColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9)
            ctx.fill(dividerRect)
            
            return ctx.makeImage() ?? expA
            
        case .splitHorizontal:
            let outW = max(expA.width, expB.width)
            let outH = max(expA.height, expB.height)
            guard let ctx = canvas(outW, outH) else {
                return expA
            }
            // Base: Slot B across entire frame (bottom)
            ctx.draw(expB, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            
            // Top portion: Slot A (in CGContext, y=0 is bottom, top is splitY to outH)
            let splitPos = max(0.0, min(1.0, splitPosition))
            let splitY = round(CGFloat(outH) * splitPos)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: splitY, width: CGFloat(outW), height: CGFloat(outH) - splitY))
            ctx.draw(expA, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.restoreGState()
            
            // Cyan split wipe line at divider position
            let lineHeight = max(2.0, round(CGFloat(outH) / 540.0))
            let dividerRect = CGRect(x: 0, y: splitY - (lineHeight / 2.0), width: CGFloat(outW), height: lineHeight)
            ctx.setFillColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9)
            ctx.fill(dividerRect)
            
            return ctx.makeImage() ?? expA
            
        case .sideBySide:
            let outW = expA.width + expB.width
            let outH = max(expA.height, expB.height)
            guard let ctx = canvas(outW, outH) else {
                return expA
            }
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
            
            let rectA = CGRect(x: 0, y: (outH - expA.height) / 2, width: expA.width, height: expA.height)
            let rectB = CGRect(x: expA.width, y: (outH - expB.height) / 2, width: expB.width, height: expB.height)
            ctx.draw(expA, in: rectA)
            ctx.draw(expB, in: rectB)
            
            return ctx.makeImage() ?? expA
            
        case .sideBySideVertical:
            let outW = max(expA.width, expB.width)
            let outH = expA.height + expB.height
            guard let ctx = canvas(outW, outH) else {
                return expA
            }
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
            
            // In CGContext, y=0 is bottom (Slot B) and top is Slot A
            let rectB = CGRect(x: (outW - expB.width) / 2, y: 0, width: expB.width, height: expB.height)
            let rectA = CGRect(x: (outW - expA.width) / 2, y: expB.height, width: expA.width, height: expA.height)
            ctx.draw(expB, in: rectB)
            ctx.draw(expA, in: rectA)
            
            return ctx.makeImage() ?? expA
            
        case .difference:
            let outW = max(expA.width, expB.width)
            let outH = max(expA.height, expB.height)
            guard let ctx = canvas(outW, outH) else {
                return expA
            }
            ctx.draw(expA, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.setBlendMode(.difference)
            ctx.draw(expB, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.setBlendMode(.normal)
            
            return ctx.makeImage() ?? expA
            
        case .overlay:
            let outW = max(expA.width, expB.width)
            let outH = max(expA.height, expB.height)
            guard let ctx = canvas(outW, outH) else {
                return expA
            }
            ctx.draw(expA, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            ctx.setAlpha(0.5)
            ctx.draw(expB, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            
            return ctx.makeImage() ?? expA
        }
    }
    
    /// Encodes a CGImage to the specified preset format and compression.
    public func encodeScreenshot(image: CGImage, preset: ScreenshotPreset) throws -> Data {
        switch preset {
        case .jpgMedium:
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.70]) else {
                throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to JPG Medium."])
            }
            return data
            
        case .jpgHigh:
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else {
                throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to JPG High."])
            }
            return data
            
        case .pngHigh:
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let data = bitmapRep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to PNG High."])
            }
            return data
            
        case .pngMedium:
            // PNG Medium: 100% source resolution with 24-bit RGB and SUB compression filter for lower bitrate
            let w = image.width
            let h = image.height
            let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let ctx24 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx24.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let img24 = ctx24.makeImage() {
                    let mutableData = NSMutableData()
                    if let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.png" as CFString, 1, nil) {
                        let options: [CFString: Any] = [
                            kCGImagePropertyPNGDictionary: [
                                kCGImagePropertyPNGCompressionFilter: 0x10
                            ]
                        ]
                        CGImageDestinationAddImage(dest, img24, options as CFDictionary)
                        if CGImageDestinationFinalize(dest) {
                            return mutableData as Data
                        }
                    }
                }
            }
            let bitmapRep = NSBitmapImageRep(cgImage: image)
            guard let data = bitmapRep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "PlayerEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image to PNG Medium."])
            }
            return data
        }
    }
}
