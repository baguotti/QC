import AVFoundation
import Foundation
import Testing
import VideoQCLib

@Suite("Split-mono loudness")
struct SplitMonoLoudnessTests {
    @Test("L and R on two mono tracks measure like the same audio on one stereo track")
    func splitMonoMatchesStereo() async throws {
        let stereo = try await Self.writeTone(channelsPerTrack: [2])
        let split = try await Self.writeTone(channelsPerTrack: [1, 1])
        defer { try? FileManager.default.removeItem(at: stereo); try? FileManager.default.removeItem(at: split) }

        let a = try #require(await DeliverablesInspector.extractAudioLevels(for: stereo).loudness?.integrated)
        let b = try #require(await DeliverablesInspector.extractAudioLevels(for: split).loudness?.integrated)
        #expect(abs(a - b) < 0.2, "stereo \(a) LUFS vs split mono \(b) LUFS")
    }

    /// 5 s of a 1 kHz tone at −20 dBFS on every channel, 48 kHz, one audio track per entry.
    static func writeTone(channelsPerTrack: [Int]) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splitmono-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let rate = 48_000.0
        let inputs = channelsPerTrack.map { channels -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            return input
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let chunk = 4_800
        let amplitude = Float(pow(10, -20.0 / 20))
        for (input, channels) in zip(inputs, channelsPerTrack) {
            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                                   mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                                   mBitsPerChannel: 32, mReserved: 0)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                           magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            for start in stride(from: 0, to: Int(rate) * 5, by: chunk) {
                var samples = [Float](repeating: 0, count: chunk * channels)
                for i in 0..<chunk {
                    let v = amplitude * Float(sin(2 * Double.pi * 1000 * Double(start + i) / rate))
                    for c in 0..<channels { samples[i * channels + c] = v }
                }
                var block: CMBlockBuffer?
                let bytes = samples.count * 4
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                   blockBufferOut: &block)
                samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                                                            offsetIntoDestination: 0, dataLength: bytes) }
                var buffer: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                                     sampleCount: chunk,
                                                                     presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                                                                     packetDescriptions: nil, sampleBufferOut: &buffer)
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                input.append(buffer!)
            }
            input.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}
