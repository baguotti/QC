import Foundation
import Testing
@testable import VideoQCLib

/// Files macOS can't open, read for their specs by the bundled ffprobe (Inspect only).
@Suite("FFprobe specs")
struct FFprobeTests {
    private func probe(_ json: String) -> FFprobe.Probe { FFprobe.parse(Data(json.utf8))! }

    private func video(_ extra: String = "", codec: String = "vp9", w: Int = 1280, h: Int = 720,
                       avg: String = "25/1", r: String = "25/1") -> String {
        """
        {"index": 0, "codec_type": "video", "codec_name": "\(codec)", "profile": "0", "width": \(w), "height": \(h),
         "avg_frame_rate": "\(avg)", "r_frame_rate": "\(r)", "disposition": {"attached_pic": 0} \(extra)}
        """
    }

    private func packets(_ times: [Double], stream: Int = 0) -> String {
        times.map { #"{"stream_index": \#(stream), "pts_time": "\#(String(format: "%.6f", $0))"}"# }.joined(separator: ",")
    }

    private func json(streams: [String], packets: String = "", duration: String = "2.000000", format: String = "matroska,webm") -> String {
        #"{"packets": [\#(packets)], "streams": [\#(streams.joined(separator: ","))], "format": {"format_name": "\#(format)", "duration": "\#(duration)"}}"#
    }

    private let url = URL(fileURLWithPath: "/d/Spot_30s.webm")

    // MARK: Frame rate

    @Test func headerRateWinsWhenPacketsAgree() {
        // MKV rounds timestamps to the millisecond: 29.4–30.3 between packets, 30 on average.
        let times = (0..<150).map { (Double($0) / 30 * 1000).rounded() / 1000 }
        let p = probe(json(streams: [video(avg: "30/1", r: "30/1")], packets: packets(times.shuffled())))
        #expect(p.frameRate.fps == 30)
        #expect(!p.frameRate.isVariable)
    }

    @Test func packetsWinOverAWrongHeader() {
        // WebM written at a variable rate says 60; DV says 60000.
        let at20 = (0..<100).map { Double($0) / 20 }
        #expect(probe(json(streams: [video(avg: "60/1", r: "60/1")], packets: packets(at20))).frameRate.fps == 20)
        let at25 = (0..<125).map { Double($0) / 25 }
        #expect(probe(json(streams: [video(codec: "dvvideo", avg: "60000/1", r: "60000/1")], packets: packets(at25))).frameRate.fps == 25)
        // 23.976 measured lands on the standard rate.
        let ntsc = (0..<120).map { Double($0) * 1001 / 24000 }
        #expect(probe(json(streams: [video(avg: "0/0", r: "0/0")], packets: packets(ntsc))).frameRate.fps == 24000.0 / 1001)
    }

    @Test func fieldCodedInterlacedKeepsTheHeaderRate() {
        let fields = (0..<250).map { Double($0) / 50 }
        let p = probe(json(streams: [video(#", "field_order": "tt""#, codec: "h264")], packets: packets(fields), format: "mpegts"))
        #expect(p.frameRate.fps == 25)
    }

    @Test func fewPacketsUseTheHeaderAndNothingFallsBackTo25() {
        #expect(probe(json(streams: [video(avg: "24/1")], packets: packets([0, 1.0 / 24, 2.0 / 24]))).frameRate.fps == 24)
        #expect(probe(json(streams: [video(avg: "0/0", r: "0/0")])).frameRate.fps == 25)
    }

    @Test func irregularPacketsAreVariable() {
        var t = 0.0
        let times = (0..<120).map { i -> Double in defer { t += i % 3 == 0 ? 1.0 / 60 : 1.0 / 20 }; return t }
        #expect(probe(json(streams: [video(avg: "1000/1", r: "1000/1")], packets: packets(times))).frameRate.isVariable)
    }

    @Test func packetsOfOtherStreamsAreIgnored() {
        let audio = #"{"index": 1, "codec_type": "audio", "codec_name": "opus", "sample_rate": "48000", "channels": 2}"#
        let all = packets((0..<50).map { Double($0) / 25 }) + "," + packets((0..<500).map { Double($0) / 250 }, stream: 1)
        let p = probe(json(streams: [video(), audio], packets: all))
        #expect(p.videoPacketTimes.count == 50)
        #expect(p.frameRate.fps == 25)
    }

    // MARK: Mapping

    @Test func webmMapsToSpecsOnly() {
        let audio = #"{"index": 1, "codec_type": "audio", "codec_name": "opus", "sample_rate": "48000", "channels": 2, "bit_rate": "128000"}"#
        let a = DeliverablesInspector.asset(from: probe(json(streams: [video(), audio], duration: "30.000000")), url: url, fileSize: 3_750_000)
        #expect(a.resolutionString == "1280 x 720")
        #expect(a.aspectRatioString == "16:9")
        #expect(a.fps == 25)
        #expect(a.totalFrames == 750)
        #expect(a.timecode == "00:00:30:00")
        #expect(a.videoCodec == "VP9")
        #expect(a.audioCodec == "Opus")
        #expect(a.audioConfig == "Opus • 128 kbps • 48kHz • Stereo (2ch)")
        #expect(a.overallBitsPerSecond == 1_000_000)
        #expect(a.container == "WEBM")
        #expect(a.specsOnlyReason == "macOS can't play VP9 in WEBM")
        #expect(!a.validation.isDurationMismatch)   // named 30s, is 30 s
    }

    @Test func quarterTurnSwapsTheSize() {
        let rotated = video(#", "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}]"#, codec: "h264", w: 1920, h: 1080)
        let a = DeliverablesInspector.asset(from: probe(json(streams: [rotated])), url: url, fileSize: 1)
        #expect(a.resolutionString == "1080 x 1920")
        #expect(a.aspectRatioString == "9:16")
    }

    @Test func audioOnlyIgnoresCoverArtAndNamesTheContainer() {
        let cover = video(#", "disposition": {"attached_pic": 1}"#, codec: "mjpeg", w: 600, h: 600)
            .replacingOccurrences(of: #", "disposition": {"attached_pic": 0} "#, with: "")
        let flac = #"{"index": 1, "codec_type": "audio", "codec_name": "flac", "sample_rate": "44100", "channels": 1}"#
        let a = DeliverablesInspector.asset(from: probe(json(streams: [cover, flac])), url: URL(fileURLWithPath: "/d/a.mka"), fileSize: 1)
        #expect(a.videoCodec == "NONE")
        #expect(a.fps == 0)
        #expect(a.timecode == "00:00:02:00")   // counted at 25, as for audio macOS reads
        #expect(a.specsOnlyReason == "macOS can't play FLAC in MKA")
    }

    @Test func subtitlesCaptionsTracksAndPCM() {
        let v = video(#", "closed_captions": 1"#, codec: "mpeg2video", w: 1920, h: 1080)
        let pcm1 = #"{"index": 1, "codec_type": "audio", "codec_name": "pcm_s24le", "sample_rate": "48000", "channels": 1, "bits_per_raw_sample": "24"}"#
        let pcm2 = pcm1.replacingOccurrences(of: #""index": 1"#, with: #""index": 2"#)
        let eng = #"{"index": 3, "codec_type": "subtitle", "codec_name": "subrip", "tags": {"language": "eng"}}"#
        let und = #"{"index": 4, "codec_type": "subtitle", "codec_name": "subrip", "tags": {"language": "und"}}"#
        let a = DeliverablesInspector.asset(from: probe(json(streams: [v, pcm1, pcm2, eng, und], format: "mpegts")),
                                            url: URL(fileURLWithPath: "/d/a.ts"), fileSize: 1)
        #expect(a.videoCodec == "MPEG-2")
        #expect(a.audioConfig == "PCM (24-bit) • 1152 kbps • 48kHz • Mono (1ch) • 2 tracks")
        #expect(a.subtitlesInfo == "SUB (ENG) + CC (608/708)")
        #expect(a.hasSubtitles)
    }

    @Test func durationFromStreamsAndProVideoFormatsReason() {
        let v = video(#", "duration": "12.500000""#, codec: "prores")
        let p = probe(json(streams: [v], duration: "N/A", format: "mxf"))
        #expect(p.bestDuration == 12.5)
        let a = DeliverablesInspector.asset(from: p, url: URL(fileURLWithPath: "/d/a.mxf"), fileSize: 1, needsProVideoFormats: true)
        #expect(a.specsOnlyReason == "Install Apple Pro Video Formats to play it")
    }

    @Test func variableRateIsNoted() {
        var t = 0.0
        let times = (0..<120).map { i -> Double in defer { t += i % 3 == 0 ? 1.0 / 60 : 1.0 / 20 }; return t }
        let a = DeliverablesInspector.asset(from: probe(json(streams: [video()], packets: packets(times))), url: url, fileSize: 1)
        #expect(a.specsOnlyReason?.hasSuffix("variable frame rate") == true)
    }

    @Test func damagedOrEmptyOutputIsNoProbe() {
        #expect(FFprobe.parse(Data("not json".utf8)) == nil)
        let empty = probe("{}")
        #expect(empty.video == nil && empty.audio.isEmpty)
    }

    @Test func damagedNumbersAndMissingTimesDontTrapOrSkew() {
        let v = video(#", "bit_rate": "1e30", "duration": "N/A""#, codec: "h264", w: 1920, h: 1080)
        let audio = #"{"index": 1, "codec_type": "audio", "codec_name": "aac", "sample_rate": "9e99", "channels": -2}"#
        let times = packets((0..<50).map { Double($0) / 25 }) + #",{"stream_index": 0, "pts_time": "N/A"}"#
        let p = probe(json(streams: [v, audio], packets: times))
        #expect(p.video?.bitRate == 0)
        #expect(p.audio.first?.sampleRate == 0 && p.audio.first?.channels == 0)
        #expect(p.videoPacketTimes.count == 50)
        #expect(p.frameRate.fps == 25)
    }

    @Test func cutOffWhenThePacketsStopEarly() {
        #expect(DeliverablesInspector.cutOffDetail(lastPacket: 19.96, start: 0, duration: 20) == nil)
        #expect(DeliverablesInspector.cutOffDetail(lastPacket: 3, start: 0, duration: 20)?.hasPrefix(DeliverablesInspector.cutOffPrefix) == true)
        // Absolute times (MPEG-TS starts at 1.4 s).
        #expect(DeliverablesInspector.cutOffDetail(lastPacket: 3.4, start: 1.43, duration: 2.02) == nil)
        #expect(DeliverablesInspector.cutOffDetail(lastPacket: 0.2, start: 0, duration: 2.0) != nil)
    }

    @Test func nativeContainersMacOSCantOpenAreDamagedNotSpecsOnly() async {
        // A MOV macOS can't open has a broken header: Unreadable, never "macOS can't play H.264 in MOV".
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).mov")
        try? Data(repeating: 1, count: 2048).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(await DeliverablesInspector.probedAsset(junk) == nil)
        #expect(DeliverablesInspector.nativeContainers.isSuperset(of: ["mov", "mp4", "wav"]))
    }

    @Test func reasonDoesntRepeatAContainerNamedLikeItsCodec() {
        let wmv = video(codec: "wmv2")
        let a = DeliverablesInspector.asset(from: probe(json(streams: [wmv], format: "asf")), url: URL(fileURLWithPath: "/d/a.wmv"), fileSize: 1)
        #expect(a.specsOnlyReason == "macOS can't play WMV")
    }

    // MARK: Names

    @Test func codecNames() {
        #expect(CodecNames.ffmpegVideo("prores", profile: "HQ") == "ProRes 422 HQ")
        #expect(CodecNames.ffmpegVideo("prores", profile: "XQ") == "ProRes 4444 XQ")
        #expect(CodecNames.ffmpegVideo("dnxhd", profile: "DNXHR HQX") == "DNxHR HQX")
        #expect(CodecNames.ffmpegVideo("dnxhd", profile: "DNXHD") == "DNxHD")
        #expect(CodecNames.ffmpegVideo("somethingnew", profile: "") == "SOMETHINGNEW")
        #expect(CodecNames.ffmpegAudio("pcm_s16be", bits: 0) == "PCM (16-bit)")
        #expect(CodecNames.ffmpegAudio("pcm_f32le", bits: 32) == "PCM (32-bit float)")
        #expect(CodecNames.ffmpegAudio("eac3", bits: 0) == "E-AC-3")
    }

    // MARK: Running

    @Test func aStalledProbeIsKilledAndAFailedOneIsNil() async {
        let start = ContinuousClock.now
        #expect(await FFprobe.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: .milliseconds(300)) == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(await FFprobe.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: []) == nil)
        #expect(await FFprobe.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["{}"]) == Data("{}\n".utf8))
    }

    @Test func finishedRunsDontHoldDescriptors() async {
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        let before = openDescriptors()
        for _ in 0..<200 { _ = await FFprobe.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["{}"]) }
        try? await Task.sleep(for: .milliseconds(200))
        // The timeout timer used to keep each run's process and pipe for 20 s: 200 runs held 200+ descriptors. Loose
        // bound: other suites run in parallel and open files too.
        let grown = openDescriptors() - before
        #expect(grown < 100, "\(grown) more descriptors open")
    }

    @Test func inputGoesThroughTheFileProtocol() {
        #expect(FFprobe.input(URL(fileURLWithPath: "/V/a b: c%03d?.webm")) == "file:/V/a b: c%03d?.webm")
    }

    /// Real files, where the bundled ffprobe is built and FFmpeg can make them (skipped on CI).
    @Test func realWebMAndMKV() async throws {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FFprobe.isAvailable, FileManager.default.isExecutableFile(atPath: ffmpeg) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ffprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let webm = dir.appendingPathComponent("clip_2s.webm")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: ffmpeg)
        make.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=2", "-f", "lavfi", "-i", "sine=d=2",
                          "-c:v", "libvpx-vp9", "-c:a", "libopus", "-shortest", webm.path]
        try make.run()
        make.waitUntilExit()
        guard make.terminationStatus == 0 else { return }
        let a = try #require(await DeliverablesInspector.inspectFile(url: webm))
        #expect(a.isSpecsOnly)
        #expect(a.resolutionString == "640 x 360")
        #expect(a.fps == 25)
        #expect(a.videoCodec == "VP9")
        #expect(a.audioCodec == "Opus")
        #expect(abs(a.durationSeconds - 2) < 0.1)
        // Cut off after its header (a copy still running): the full duration, but the data stops early.
        let long = dir.appendingPathComponent("long.mkv")
        let makeLong = Process()
        makeLong.executableURL = URL(fileURLWithPath: ffmpeg)
        makeLong.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=12", "-c:v", "libx264", long.path]
        try makeLong.run()
        makeLong.waitUntilExit()
        let full = try #require(await DeliverablesInspector.inspectFile(url: long))
        #expect(!full.validation.isCutOff)
        let cut = dir.appendingPathComponent("cut.mkv")
        try Data(try Data(contentsOf: long).prefix(120_000)).write(to: cut)
        let partial = try #require(await DeliverablesInspector.inspectFile(url: cut))
        #expect(partial.isSpecsOnly)
        #expect(partial.validation.isCutOff)
        // A damaged file: neither reader opens it.
        let junk = dir.appendingPathComponent("junk.mkv")
        try Data(repeating: 7, count: 4096).write(to: junk)
        let bad = try #require(await DeliverablesInspector.inspectFile(url: junk))
        #expect(bad.videoCodec == DeliverablesInspector.unreadableCodec)
        #expect(!bad.isSpecsOnly)
    }
}
