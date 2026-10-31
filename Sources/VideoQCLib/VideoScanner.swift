import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    
    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    
    func reset() {
        lock.lock()
        flag = false
        lock.unlock()
    }
}

public actor VideoScanner {
    private let detector = EdgeDetector()
    private let cancellationState = CancellationState()
    
    public nonisolated var isCancelled: Bool {
        cancellationState.isCancelled || Task.isCancelled
    }
    
    public init() {}
    
    public nonisolated func cancel() {
        cancellationState.cancel()
    }
    
    public struct ScanProgress: Sendable {
        public let currentFileIndex: Int
        public let totalFiles: Int
        public let currentFileName: String
        public let currentFrame: Int
        public let totalFramesInFile: Int
        public let fps: Double
        public let flaggedVideosCount: Int
    }
    
    /// Finds all files the Player can open (video, image, audio) within a given directory
    public static func findMediaFiles(in directoryURL: URL, includeSubfolders: Bool = true) -> [URL] {
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: includeSubfolders ? [.skipsHiddenFiles, .skipsPackageDescendants]
                : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        
        var videoURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            if QCUtilities.isSupportedMedia(url: fileURL) {
                videoURLs.append(fileURL)
            }
        }
        
        return videoURLs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    
    /// Scans a batch of video files with bounded parallel hardware concurrency
    public func scanBatch(
        videoURLs: [URL],
        config: QCConfig,
        maxConcurrentScanners: Int = 2,
        progressHandler: @escaping @Sendable (ScanProgress) -> Void,
        onFileCompleted: (@Sendable (VideoQCResult) -> Void)? = nil
    ) async -> [VideoQCResult] {
        cancellationState.reset()
        
        guard !videoURLs.isEmpty else { return [] }
        
        let totalFiles = videoURLs.count
        let concurrency = max(1, min(maxConcurrentScanners, 4))
        
        // Use structured concurrency with bounded parallelism
        return await withTaskGroup(of: (Int, VideoQCResult).self) { group in
            var submitted = 0
            var results: [(Int, VideoQCResult)] = []
            results.reserveCapacity(totalFiles)
            
            // Seed initial worker pool
            let initialCount = min(concurrency, totalFiles)
            for _ in 0..<initialCount {
                let idx = submitted
                let url = videoURLs[idx]
                submitted += 1
                group.addTask {
                    let result = await self.scanSingleVideo(
                        url: url,
                        config: config,
                        fileIndex: idx + 1,
                        totalFiles: totalFiles,
                        flaggedSoFar: 0,
                        progressHandler: progressHandler
                    )
                    return (idx, result)
                }
            }
            
            var flaggedCount = 0
            
            // As each video finishes, submit the next one
            for await (idx, result) in group {
                // A file the scan was stopped in only counts when it already has findings (not as passed).
                if !result.stoppedEarly || result.isFlagged {
                    results.append((idx, result))
                    onFileCompleted?(result)
                }
                if result.isFlagged {
                    flaggedCount += 1
                }
                
                if submitted < totalFiles && !self.isCancelled && !Task.isCancelled {
                    let nextIdx = submitted
                    let nextURL = videoURLs[nextIdx]
                    let currentFlagged = flaggedCount
                    submitted += 1
                    group.addTask {
                        let res = await self.scanSingleVideo(
                            url: nextURL,
                            config: config,
                            fileIndex: nextIdx + 1,
                            totalFiles: totalFiles,
                            flaggedSoFar: currentFlagged,
                            progressHandler: progressHandler
                        )
                        return (nextIdx, res)
                    }
                }
            }
            
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
    /// Scans a single video file frame-by-frame using AVFoundation (nonisolated for parallel execution)
    public nonisolated func scanSingleVideo(
        url: URL,
        config: QCConfig,
        fileIndex: Int,
        totalFiles: Int,
        flaggedSoFar: Int,
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> VideoQCResult {
        let fileName = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        
        // Load video tracks and properties asynchronously
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let videoTrack = tracks.first else {
            // Stills and audio have no video track to check; a video file without one is broken.
            return VideoQCResult(
                fileURL: url,
                fileName: fileName,
                resolution: "Unknown",
                fps: 0,
                totalFrames: 0,
                durationSeconds: 0,
                errorFrames: [],
                readError: QCUtilities.mediaKind(of: url) == .video ? ProVideoFormats.openError(for: url) : nil
            )
        }
        
        let size = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let nominalFps = (try? await videoTrack.load(.nominalFrameRate)) ?? 25.0
        let fps = Double(nominalFps > 0 ? nominalFps : 25.0)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationSeconds = CMTimeGetSeconds(duration)
        let totalEstimatedFrames = Int(round(durationSeconds * fps))
        let resolutionStr = "\(Int(size.width))x\(Int(size.height))"
        
        // A long file is read as two segments at once: one decode stream leaves the hardware decoder half idle
        // (measured, M4 Max 1080p H.264: ~950 fps for one stream, ~1,780 for two). Each segment reads a couple of frames
        // past the split and keeps only its side of it, so every frame is checked exactly once.
        let frameDuration = 1 / fps
        let splitAt: Double? = durationSeconds >= Self.splitMinimumSeconds ? (durationSeconds / 2 / frameDuration).rounded() * frameDuration : nil
        let progress = ScanProgressState(flaggedSoFar: flaggedSoFar)
        let segments: [(range: CMTimeRange?, keep: Range<Double>)]
        if let splitAt {
            let overlap = 3 * frameDuration
            segments = [
                (CMTimeRange(start: .zero, end: CMTime(seconds: splitAt + overlap, preferredTimescale: 600_000)), -Double.infinity..<splitAt),
                (CMTimeRange(start: CMTime(seconds: max(0, splitAt - overlap), preferredTimescale: 600_000), end: .positiveInfinity), splitAt..<Double.infinity)
            ]
        } else {
            segments = [(nil, -Double.infinity..<Double.infinity)]
        }
        let reportProgress: @Sendable (Int, Bool) -> Void = { decoded, strong in
            guard let update = progress.record(decoded: decoded, strong: strong) else { return }
            progressHandler?(ScanProgress(currentFileIndex: fileIndex, totalFiles: totalFiles, currentFileName: fileName,
                                          currentFrame: update.frames, totalFramesInFile: max(totalEstimatedFrames, update.frames),
                                          fps: update.fps, flaggedVideosCount: update.flagged))
        }
        let detector = self.detector
        let cancellation = self.cancellationState
        let parts = await withTaskGroup(of: (Int, SegmentScan).self) { group in
            for (i, segment) in segments.enumerated() {
                group.addTask {
                    (i, await Self.scanSegment(url: url, range: segment.range, keep: segment.keep, detector: detector, config: config,
                                               cancellation: cancellation, report: reportProgress))
                }
            }
            var parts = Array(repeating: SegmentScan(), count: segments.count)
            for await (i, part) in group { parts[i] = part }
            return parts
        }
        let readError = parts.lazy.compactMap(\.error).first
        let stoppedEarly = readError == nil && parts.contains { !$0.finished }
        // Frame numbers count from the file's first frame (the first segment's first sample), like the Player.
        guard let firstPTS = parts[0].firstPTS else {
            var result = VideoQCResult(fileURL: url, fileName: fileName, resolution: resolutionStr, fps: fps,
                                       totalFrames: 0, durationSeconds: durationSeconds, errorFrames: [],
                                       readError: readError ?? (stoppedEarly ? nil : "No frames could be decoded"))
            result.stoppedEarly = stoppedEarly
            return result
        }
        var candidateFrames: [FrameError] = []
        var frameCount = 0
        for part in parts {
            frameCount += part.frameCount
            for hit in part.hits {
                let secs = hit.pts - firstPTS
                let frameIndex = secs.isFinite && secs >= 0 ? Self.frameIndex(seconds: secs, fps: fps) : hit.ordinal
                let oriented = transform.isIdentity ? hit.detections : hit.detections.map { $0.oriented(by: transform) }
                candidateFrames.append(FrameError(frameIndex: frameIndex, timecode: TimecodeFormatter.format(frameIndex: frameIndex, fps: fps),
                                                  detections: oriented))
            }
        }
        
        var result = VideoQCResult(
            fileURL: url,
            fileName: fileName,
            resolution: resolutionStr,
            fps: fps,
            totalFrames: frameCount,
            durationSeconds: durationSeconds,
            errorFrames: LineHysteresis.filter(candidateFrames, minRun: config.persistenceFrames),
            readError: readError
        )
        result.stoppedEarly = stoppedEarly
        return result
    }
    
    /// Frame number of a sample `seconds` after the first one: the nearest frame, as the Player shows it (it seeks to frame
    /// centres). On a 600 time base (QuickTime, iPhone) NTSC-rate timestamps sit up to half a tick early, so `floor` would
    /// land one frame low.
    static func frameIndex(seconds: Double, fps: Double) -> Int {
        Int((seconds * fps).rounded())
    }
    
    /// Files at least this long are split into two segments.
    static let splitMinimumSeconds: Double = 20
    
    struct SegmentScan: Sendable {
        struct Hit: Sendable {
            let pts: Double
            let ordinal: Int
            let detections: [LineDetection]
        }
        var hits: [Hit] = []
        var frameCount = 0
        var firstPTS: Double?
        /// The segment couldn't be opened or decoding failed before its end.
        var error: String?
        /// Decoding reached the end of the segment (false when the scan was stopped).
        var finished = false
    }
    
    /// Decodes one time range (the whole file when `range` is nil) and checks the frames whose timestamp is in `keep`.
    static func scanSegment(url: URL, range: CMTimeRange?, keep: Range<Double>, detector: EdgeDetector, config: QCConfig,
                            cancellation: CancellationState, report: @Sendable (Int, Bool) -> Void) async -> SegmentScan {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return SegmentScan(error: ProVideoFormats.openError(for: url)) }
        if let range { reader.timeRange = range }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            return SegmentScan(error: reader.error?.localizedDescription ?? "Couldn't start decoding")
        }
        
        var scan = SegmentScan()
        var pending = 0
        var pendingStrong = false
        var ordinal = 0
        while reader.status == .reading && !cancellation.isCancelled && !Task.isCancelled {
            var done = false
            autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { done = true; return }
                guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let secs = pts.isNumeric ? CMTimeGetSeconds(pts) : Double(ordinal)
                if scan.firstPTS == nil, pts.isNumeric { scan.firstPTS = secs }
                defer { ordinal += 1 }
                guard keep.contains(secs) else { return }
                scan.frameCount += 1
                pending += 1
                let detections = detector.scanPixelBuffer(image, config: config)
                if !detections.isEmpty {
                    scan.hits.append(SegmentScan.Hit(pts: secs, ordinal: ordinal, detections: detections))
                    pendingStrong = pendingStrong || detections.contains { !$0.isWeak }
                }
            }
            if done {
                scan.finished = true
                break
            }
            if pending >= 15 {
                report(pending, pendingStrong)
                pending = 0
                pendingStrong = false
            }
        }
        report(pending, pendingStrong)
        if reader.status == .reading { reader.cancelReading() }
        if reader.status == .failed {
            scan.error = "Decoding stopped early: \(reader.error?.localizedDescription ?? "unknown error")"
        }
        return scan
    }
}

/// Progress shared by a file's segments: frames done, speed and whether a strong line was seen; throttled to ~30 Hz.
final class ScanProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private let start = CFAbsoluteTimeGetCurrent()
    private var frames = 0
    private var strong = false
    private var lastSent: CFAbsoluteTime = 0
    private let flaggedSoFar: Int
    
    init(flaggedSoFar: Int) { self.flaggedSoFar = flaggedSoFar }
    
    func record(decoded: Int, strong seen: Bool) -> (frames: Int, fps: Double, flagged: Int)? {
        lock.lock()
        defer { lock.unlock() }
        frames += decoded
        strong = strong || seen
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSent >= 0.033 else { return nil }
        lastSent = now
        let elapsed = now - start
        return (frames, elapsed > 0 ? Double(frames) / elapsed : 0, flaggedSoFar + (strong ? 1 : 0))
    }
}

