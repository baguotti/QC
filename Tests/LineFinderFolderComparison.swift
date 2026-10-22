import Foundation
@preconcurrency import AVFoundation
import Testing
@testable import VideoQCLib

/// Scans a real folder with the v1 and v2 detectors and prints the flagged segments side by side.
/// LINEFINDER_COMPARE_DIR=/path/to/deliverables [LINEFINDER_TARGET=#00FF00] swift test --filter LineFinderFolderComparison
@Suite("Line Finder real-folder comparison")
struct LineFinderFolderComparison {
    static let environment = ProcessInfo.processInfo.environment
    static let folder = environment["LINEFINDER_COMPARE_DIR"]

    @Test(.enabled(if: folder != nil))
    func compareFolder() async {
        let target = Self.environment["LINEFINDER_TARGET"] ?? "#00FF00"
        let isBlackOrWhite = QCConfig(targetHex: target).isBlackDetection || QCConfig(targetHex: target).isWhiteDetection
        let config = QCConfig(targetHex: target, tolerance: isBlackOrWhite ? 0.03 : 0.25)
        let videos = VideoScanner.findMediaFiles(in: URL(fileURLWithPath: Self.folder!)).filter { QCUtilities.mediaKind(of: $0) == .video }

        var lines = ["file | v1 segments | v2 segments"]
        for (index, url) in videos.enumerated() {
            let v1 = await Self.legacySegments(url: url, config: config)
            let v2 = await VideoScanner().scanSingleVideo(url: url, config: config, fileIndex: index + 1, totalFiles: videos.count, flaggedSoFar: 0).glitchSegments
            lines.append("\(url.lastPathComponent) | \(v1.count) | \(v2.count)")
            for (label, segments) in [("v1", v1), ("v2", v2)] {
                for s in segments {
                    lines.append("    \(label) \(s.edge.rawValue) \(s.startTimecode)–\(s.endTimecode) (\(s.frameCount) f, \(s.avgThickness) px, \(s.detectedColor.hexString))")
                }
            }
        }
        print(lines.joined(separator: "\n"))
    }

    /// The v1 pipeline: every frame judged alone, full buffer, no orientation.
    static func legacySegments(url: URL, config: QCConfig) async -> [GlitchSegment] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let nominalFps = (try? await track.load(.nominalFrameRate)) ?? 25
        let fps = Double(nominalFps > 0 ? nominalFps : 25)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return [] }

        let detector = LegacyEdgeDetector()
        var frames: [FrameError] = []
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                let detections = detector.scanPixelBuffer(buffer, config: config)
                if !detections.isEmpty {
                    frames.append(FrameError(frameIndex: index, timecode: TimecodeFormatter.format(frameIndex: index, fps: fps), detections: detections))
                }
            }
            index += 1
        }
        return VideoQCResult(fileURL: url, fileName: url.lastPathComponent, resolution: "", fps: fps, totalFrames: index, durationSeconds: 0, errorFrames: frames).glitchSegments
    }
}
