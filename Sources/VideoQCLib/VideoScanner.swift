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
        cancellationState.isCancelled
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
    
    /// Finds all video files within a given directory
    public static func findVideoFiles(in directoryURL: URL) -> [URL] {
        let fileManager = FileManager.default
        let supportedExtensions = ["mp4", "mov", "m4v", "mkv", "avi", "prores"]
        
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        
        var videoURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
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
        progressHandler: @escaping @Sendable (ScanProgress) -> Void
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
            
            // As each video finishes, submit the next one
            for await (idx, result) in group {
                results.append((idx, result))
                
                if submitted < totalFiles && !self.isCancelled {
                    let nextIdx = submitted
                    let nextURL = videoURLs[nextIdx]
                    submitted += 1
                    group.addTask {
                        let res = await self.scanSingleVideo(
                            url: nextURL,
                            config: config,
                            fileIndex: nextIdx + 1,
                            totalFiles: totalFiles,
                            flaggedSoFar: 0,
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
            return VideoQCResult(
                fileURL: url,
                fileName: fileName,
                resolution: "Unknown",
                fps: 0,
                totalFrames: 0,
                durationSeconds: 0,
                errorFrames: []
            )
        }
        
        let size = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let nominalFps = (try? await videoTrack.load(.nominalFrameRate)) ?? 25.0
        let fps = Double(nominalFps > 0 ? nominalFps : 25.0)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationSeconds = CMTimeGetSeconds(duration)
        let totalEstimatedFrames = Int(round(durationSeconds * fps))
        let resolutionStr = "\(Int(size.width))x\(Int(size.height))"
        
        // Setup AVAssetReader
        guard let reader = try? AVAssetReader(asset: asset) else {
            return VideoQCResult(
                fileURL: url,
                fileName: fileName,
                resolution: resolutionStr,
                fps: fps,
                totalFrames: totalEstimatedFrames,
                durationSeconds: durationSeconds,
                errorFrames: []
            )
        }
        
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        
        guard reader.startReading() else {
            return VideoQCResult(
                fileURL: url,
                fileName: fileName,
                resolution: resolutionStr,
                fps: fps,
                totalFrames: totalEstimatedFrames,
                durationSeconds: durationSeconds,
                errorFrames: []
            )
        }
        
        var errorFrames: [FrameError] = []
        var frameCount = 0
        let startTime = CFAbsoluteTimeGetCurrent()
        
        while reader.status == .reading && !isCancelled {
            var shouldBreak = false
            
            autoreleasepool {
                guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                    shouldBreak = true
                    return
                }
                
                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let detections = detector.scanPixelBuffer(imageBuffer, config: config)
                    if !detections.isEmpty {
                        let timecode = TimecodeFormatter.format(frameIndex: frameCount, fps: fps)
                        errorFrames.append(FrameError(frameIndex: frameCount, timecode: timecode, detections: detections))
                    }
                }
            }
            
            if shouldBreak {
                break
            }
            
            frameCount += 1
            
            // Send periodic progress update (every 10 frames or at key intervals)
            if frameCount % 15 == 0 || frameCount == totalEstimatedFrames {
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let currentFps = elapsed > 0 ? Double(frameCount) / elapsed : fps
                
                let progress = ScanProgress(
                    currentFileIndex: fileIndex,
                    totalFiles: totalFiles,
                    currentFileName: fileName,
                    currentFrame: frameCount,
                    totalFramesInFile: max(totalEstimatedFrames, frameCount),
                    fps: currentFps,
                    flaggedVideosCount: flaggedSoFar + (errorFrames.isEmpty ? 0 : 1)
                )
                progressHandler?(progress)
            }
        }
        
        if reader.status == .reading {
            reader.cancelReading()
        }
        
        return VideoQCResult(
            fileURL: url,
            fileName: fileName,
            resolution: resolutionStr,
            fps: fps,
            totalFrames: frameCount,
            durationSeconds: durationSeconds,
            errorFrames: errorFrames
        )
    }
}
