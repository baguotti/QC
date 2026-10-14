import Foundation
@preconcurrency import AVFoundation

/// Peak overview of an audio file for the timeline: `bins` values in 0...1 (max |sample| per bin, mono downmix).
public enum AudioWaveform {
    /// Decodes the whole file at a low sample rate; call off the main thread. Returns nil on failure or cancellation.
    public static func peaks(url: URL, bins: Int = 1200) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0, bins > 0 else { return nil }

        // 8 kHz mono is plenty for a few pixels per bin and keeps hour-long files to a few seconds of work.
        let sampleRate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ])
        guard let reader = try? AVAssetReader(asset: asset), reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let samplesPerBin = max(1.0, seconds * sampleRate / Double(bins))
        var peaks = [Float](repeating: 0, count: bins)
        var sampleIndex = 0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>? = nil
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                for i in 0..<count {
                    let bin = min(bins - 1, Int(Double(sampleIndex + i) / samplesPerBin))
                    let value = abs(samples[i])
                    if value > peaks[bin] { peaks[bin] = value }
                }
            }
            sampleIndex += count
        }
        guard reader.status == .completed else { return nil }
        return peaks.map { min(1, $0) }
    }
}
