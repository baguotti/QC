import Foundation
@preconcurrency import AVFoundation
import CoreVideo
@testable import VideoQCLib

/// Short H.264 QuickTime clips written on the fly for scanner tests.
enum TestClips {
    /// `frames` copies of `frame` at 29.97 fps on a 600 time base (QuickTime, iPhone), where NTSC-rate timestamps are
    /// rounded to the tick. Returns the file in a fresh temporary folder; the caller removes `url.deletingLastPathComponent()`.
    static func ntscOn600TimeBase(_ frame: SyntheticFrame, frames: Int) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip.mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: frame.width,
            AVVideoHeightKey: frame.height
        ])
        input.mediaTimeScale = 600
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let buffer = frame.makePixelBuffer()
        let rate = 30000.0 / 1001
        for n in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let ticks = (Double(n) * 600 / rate).rounded()
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(ticks), timescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }
}
