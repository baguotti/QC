import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

public actor VideoScanner {
    private let detector = EdgeDetector()
    private var isCancelled = false
    
    public init() {}
    
    public func cancel() {
        isCancelled = true
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
    
    /// Scans a batch of video files
    public func scanBatch(
        videoURLs: [URL],
        config: QCConfig,
        progressHandler: @escaping @Sendable (ScanProgress) -> Void
    ) async -> [VideoQCResult] {
        isCancelled = false
        var results: [VideoQCResult] = []
        var flaggedCount = 0
        let totalFiles = videoURLs.count
        
        for (index, videoURL) in videoURLs.enumerated() {
            if isCancelled { break }
            
            let fileIndex = index + 1
            let result = await scanSingleVideo(
                url: videoURL,
                config: config,
                fileIndex: fileIndex,
                totalFiles: totalFiles,
                flaggedSoFar: flaggedCount,
                progressHandler: progressHandler
            )
            
            results.append(result)
            if result.isFlagged {
                flaggedCount += 1
            }
        }
        
        return results
    }
    
    /// Scans a single video file frame-by-frame using AVFoundation
    public func scanSingleVideo(
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
