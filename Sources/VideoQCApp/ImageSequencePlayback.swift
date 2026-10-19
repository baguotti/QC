import AVFoundation
import AppKit
import CoreImage
import ImageIO
import VideoQCLib

/// Plays an image sequence through the normal video pipeline (AVPlayer, video output, AVPlayerLayer, A/B sync).
/// The item is a 1-frame placeholder clip stretched to the sequence length; a custom compositor replaces every
/// frame with the decoded still for that time. Video files never go through here.
enum ImageSequencePlayback {
    /// Builds the item for `seq` at `fps`. `exposure` is read per rendered frame (the compositor applies EV itself,
    /// so the slot never gets the CIFilter exposure composition). The first call on a Mac writes the placeholder (~50 ms, off the main thread).
    @MainActor
    static func makeItem(for seq: ImageSequence, fps: Double, exposure: @escaping @Sendable () -> Double) async -> AVPlayerItem? {
        let firstURL = seq.firstURL
        let prepared = await Task.detached(priority: .userInitiated) { () -> (URL, CGSize)? in
            guard let url = PlaceholderClip.url(), let size = imageSize(firstURL) else { return nil }
            return (url, size)
        }.value
        guard let (placeholderURL, renderSize) = prepared else { return nil }
        let placeholder = AVURLAsset(url: placeholderURL)
        let composition = AVMutableComposition()
        let frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        let duration = CMTimeMultiply(frameDuration, multiplier: Int32(seq.length))
        guard let sourceTrack = try? await placeholder.loadTracks(withMediaType: .video).first,
              let sourceDuration = try? await sourceTrack.load(.timeRange).duration,
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let sourceRange = CMTimeRange(start: .zero, duration: sourceDuration)
        do {
            try track.insertTimeRange(sourceRange, of: sourceTrack, at: .zero)
        } catch {
            return nil
        }
        track.scaleTimeRange(sourceRange, toDuration: duration)
        
        let source = SequenceFrameSource(sequence: seq, fps: fps, renderSize: renderSize, exposure: exposure)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = SequenceCompositor.self
        videoComposition.frameDuration = frameDuration
        videoComposition.renderSize = renderSize
        videoComposition.instructions = [SequenceInstruction(timeRange: CMTimeRange(start: .zero, duration: duration), source: source)]
        
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        return item
    }
    
    nonisolated static func imageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Decodes one frame for screenshots / paused stills (display-ready: exposure applied by the caller).
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// A 16×16, one-second black H.264 clip, written once to Caches. It only gives the composition a real video track.
private enum PlaceholderClip {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: URL?

    static func url() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("QCpie", isDirectory: true)
        let url = dir.appendingPathComponent("sequence-placeholder-v1.mov")
        if FileManager.default.fileExists(atPath: url.path) {
            cached = url
            return url
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard write(to: url) else { return nil }
        cached = url
        return url
    }

    /// ~50 ms, once per Mac (the file persists in Caches).
    private static func write(to url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { usleep(1000) }
        adaptor.append(buffer, withPresentationTime: .zero)
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}

/// Decoded-frame cache with read-ahead. Decodes run on a concurrent background queue; the cache is bounded by memory.
final class SequenceFrameSource: @unchecked Sendable {
    let sequence: ImageSequence
    let fps: Double
    let renderSize: CGSize
    private let exposure: @Sendable () -> Double

    private let lock = NSLock()
    private var cache: [Int: CGImage] = [:]
    private var order: [Int] = []
    private var inFlight = Set<Int>()
    private var lastRequested = -1
    private let capacity: Int
    private let decodeQueue = DispatchQueue(label: "qcpie.sequence.decode", qos: .userInitiated, attributes: .concurrent)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let readAhead = 8

    init(sequence: ImageSequence, fps: Double, renderSize: CGSize, exposure: @escaping @Sendable () -> Double) {
        self.sequence = sequence
        self.fps = fps
        self.renderSize = renderSize
        self.exposure = exposure
        // ~256 MB of decoded frames (8–60 of them depending on resolution).
        let frameBytes = max(1, Int(renderSize.width * renderSize.height) * 4)
        capacity = min(60, max(8, 256_000_000 / frameBytes))
    }

    func frameIndex(at time: CMTime) -> Int {
        let secs = CMTimeGetSeconds(time)
        guard secs.isFinite else { return 0 }
        return min(max(0, Int(floor(secs * fps + 1e-4))), sequence.length - 1)
    }

    /// The decoded frame (nil for a gap in the numbering). Blocks only on a cache miss.
    func image(at index: Int) -> CGImage? {
        lock.lock()
        let cached = cache[index]
        let previous = lastRequested
        lastRequested = index
        lock.unlock()
        prefetch(after: index, forward: index >= previous)
        if let cached { return cached }
        guard let url = sequence.url(forFrame: index), let image = ImageSequencePlayback.decode(url) else { return nil }
        store(image, at: index)
        return image
    }

    private func prefetch(after index: Int, forward: Bool) {
        let step = forward ? 1 : -1
        var targets: [Int] = []
        lock.lock()
        for offset in 1...Self.readAhead {
            let i = index + offset * step
            guard i >= 0, i < sequence.length, cache[i] == nil, !inFlight.contains(i) else { continue }
            inFlight.insert(i)
            targets.append(i)
        }
        lock.unlock()
        for i in targets {
            decodeQueue.async { [weak self] in
                guard let self else { return }
                let image = self.sequence.url(forFrame: i).flatMap(ImageSequencePlayback.decode)
                self.lock.lock()
                self.inFlight.remove(i)
                self.lock.unlock()
                if let image { self.store(image, at: i) }
            }
        }
    }

    private func store(_ image: CGImage, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        if cache[index] == nil { order.append(index) }
        cache[index] = image
        // Evict the frames farthest from the playhead.
        while order.count > capacity {
            let anchor = lastRequested
            guard let farthest = order.enumerated().max(by: { abs($0.element - anchor) < abs($1.element - anchor) }) else { break }
            cache.removeValue(forKey: farthest.element)
            order.remove(at: farthest.offset)
        }
    }

    /// Draws frame `index` into `buffer`: the still scaled to the render size, exposure applied, or a dark red
    /// "MISSING FRAME" card where the numbering has a gap.
    func render(_ index: Int, into buffer: CVPixelBuffer) {
        let image = image(at: index)
        let ev = exposure()
        if let image, abs(ev) >= 0.001 {
            let scaled = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: renderSize.width / CGFloat(image.width),
                                                                                   y: renderSize.height / CGFloat(image.height)))
            ciContext.render(scaled.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev]), to: buffer)
            return
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let rect = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        if let image {
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            return
        }
        drawMissingCard(index, in: context)
    }
    
    /// The frame as shown while paused (decoded still, or the missing-frame card); exposure is applied by the caller.
    func displayImage(at index: Int) -> CGImage? {
        if let image = image(at: index) { return image }
        guard let context = CGContext(data: nil, width: Int(renderSize.width), height: Int(renderSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        drawMissingCard(index, in: context)
        return context.makeImage()
    }
    
    private func drawMissingCard(_ index: Int, in context: CGContext) {
        let rect = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        context.setFillColor(CGColor(red: 0.28, green: 0.04, blue: 0.05, alpha: 1))
        context.fill(rect)
        let label = "MISSING FRAME \(sequence.firstNumber + index)" as NSString
        let fontSize = max(14, rect.height * 0.05)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor(white: 1, alpha: 0.85)
        ]
        let size = label.size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        label.draw(at: CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class SequenceInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]? = nil
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let source: SequenceFrameSource

    init(timeRange: CMTimeRange, source: SequenceFrameSource) {
        self.timeRange = timeRange
        self.source = source
    }
}

final class SequenceCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
    ]
    let sourcePixelBufferAttributes: [String: any Sendable]? = SequenceCompositor.pixelAttributes
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = SequenceCompositor.pixelAttributes
    private let renderQueue = DispatchQueue(label: "qcpie.sequence.render", qos: .userInteractive)

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            guard let instruction = request.videoCompositionInstruction as? SequenceInstruction,
                  let buffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "QCpie.ImageSequence", code: -1))
                return
            }
            let source = instruction.source
            source.render(source.frameIndex(at: request.compositionTime), into: buffer)
            request.finish(withComposedVideoFrame: buffer)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
