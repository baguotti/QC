import AVFoundation
import Testing
@testable import QCpie

@Suite("In / Out export") struct InOutExporterTests {
    // A WAV cut stays a WAV with its PCM (not PCM inside an .m4a).
    @Test func wavStaysWav() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 3)!
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
        }
        let target = dir.appendingPathComponent("cut.wav")
        let reencoded = try await InOutExporter.export(source: source, range: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600),
                                                                          duration: CMTime(seconds: 1, preferredTimescale: 600)), to: target)
        #expect(!reencoded)
        let cut = try AVAudioFile(forReading: target)
        #expect(abs(Double(cut.length) / cut.fileFormat.sampleRate - 1) < 0.05)
        #expect(cut.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatLinearPCM)
    }
}
