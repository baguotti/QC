import Foundation

extension FFprobe.Probe {
    /// The video's frame rate as frames are counted, and whether it varies. Container headers are often wrong (WebM
    /// written at a variable rate says 60, DV 60000, MKV rounds timestamps to the millisecond), so the rate comes from
    /// the first seconds' packet times when the header disagrees, except field-coded interlaced video, whose packets
    /// are fields (twice the frame rate).
    public var frameRate: (fps: Double, isVariable: Bool) {
        guard let video else { return (0, false) }
        let header = [video.avgFrameRate, video.realFrameRate].first { $0 >= 1 && $0 <= 1000 } ?? 0
        let times = Array(Set(videoPacketTimes)).sorted()
        var measured = 0.0, isVariable = false
        if times.count >= 10, let first = times.first, let last = times.last, last > first {
            measured = Double(times.count - 1) / (last - first)
            let deltas = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
            let low = deltas[deltas.count / 10], high = deltas[deltas.count * 9 / 10]
            isVariable = low > 0 && high / low > 1.5
        }
        // Within 3%: packet times are rounded (MKV to the millisecond) and AVI repeats some; a wrong header is off by
        // far more (60 for 20, 60000 for 25).
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) / b < 0.03 }
        let interlaced = ["tt", "bb", "tb", "bt"].contains(video.fieldOrder)
        let fps: Double
        if measured <= 0 || measured > 1000 {
            fps = header > 0 ? header : 25
        } else if header > 0 && (close(measured, header) || (interlaced && close(measured, header * 2))) {
            fps = header
        } else {
            fps = measured
        }
        return (FrameRate.nearestStandard(fps, within: 0.005) ?? fps, isVariable)
    }

    /// Seconds: the container's, else the longest stream's (MKV often has no stream durations).
    public var bestDuration: Double {
        if duration > 0 { return duration }
        return streams.map(\.duration).max() ?? 0
    }
}

extension DeliverablesInspector {
    /// A file macOS couldn't open, read by the bundled ffprobe: its specs, marked specs-only. Nil when ffprobe isn't
    /// there or can't read it either (then it's unreadable: damaged, empty or still being written).
    public static func probedAsset(_ url: URL) async -> DeliverableAsset? {
        let needsProVideoFormats = ProVideoFormats.needsInstall(for: url)
        // macOS opens these containers whatever codec is inside (it only fails to decode it): failing to open one means
        // it's damaged or still being written, and must stay Unreadable, not "macOS can't play H.264 in MOV".
        guard needsProVideoFormats || !nativeContainers.contains(url.pathExtension.lowercased()),
              let probe = await FFprobe.probe(url) else { return nil }
        var probed = asset(from: probe, url: url, fileSize: QCUtilities.fileSize(of: url) ?? 0,
                           needsProVideoFormats: needsProVideoFormats, created: fileCreationDate(url))
        // Cut off after its header (copy or download still running): the header gives the full duration, the packets
        // stop early. Flagged like a file macOS reads (`presentFraction`).
        let duration = probe.bestDuration
        if duration > 0.5 {
            let end = probe.startTime + duration
            // Clips shorter than the first run's packet window were read to their end already: no second run.
            let readWhole = probe.video != nil && duration < Double(FFprobe.packetSeconds) - 0.5
            let lastPacket = readWhole ? probe.videoPacketTimes.max() : await FFprobe.lastPacketTime(url, from: end - 2, video: probe.video != nil)
            // No answer (ffprobe failed or timed out) isn't proof of anything: not flagged.
            if let last = lastPacket,
               let detail = cutOffDetail(lastPacket: last, start: probe.startTime, duration: duration) {
                probed = probed.withValidation(cutOff: detail)
            }
        }
        return probed
    }

    /// "CUT OFF: …" when the last packet starts well before the end the header gives (2 s, less for short files: the
    /// last packet starts a frame or an audio block before the end), else nil.
    static func cutOffDetail(lastPacket: Double, start: Double, duration: Double) -> String? {
        let reached = lastPacket - start
        guard reached < duration - min(2, max(0.5, duration * 0.1)) else { return nil }
        let share = max(0, reached) / duration
        return "\(cutOffPrefix): the data stops at \(share < 0.01 ? "under 1%" : "\(Int(share * 100))%") of its \(String(format: "%.0f", duration)) s (still being written, or damaged)"
    }

    static let nativeContainers: Set<String> = ["mov", "mp4", "m4v", "m4a", "3gp", "wav", "aif", "aiff", "caf", "mp3", "aac"]

    /// Pure: the asset for `probe` (tested with saved ffprobe output).
    public static func asset(from probe: FFprobe.Probe, url: URL, fileSize: Int64, needsProVideoFormats: Bool = false,
                             created: Date? = nil) -> DeliverableAsset {
        let video = probe.video
        // 1. Picture: pixel size as stored, turned for a quarter-turn display matrix (phones), as AVFoundation does.
        var width = 0, height = 0
        if let video {
            let turned = Int((abs(video.rotation).truncatingRemainder(dividingBy: 180)).rounded()) == 90
            width = turned ? video.height : video.width
            height = turned ? video.width : video.height
        }
        let resolutionString = video == nil ? "--" : "\(width) x \(height)"
        // The shape it's shown in: DV PAL is 720 x 576 of 16:15 pixels, 4:3 on screen (5:4 from the stored size).
        let aspectRatioString = video.map { v in
            let turned = Int((abs(v.rotation).truncatingRemainder(dividingBy: 180)).rounded()) == 90
            return displayAspect(width: width, height: height, pixelAspect: turned ? 1 / v.pixelAspect : v.pixelAspect)
        } ?? "--"

        // 2. Rate and duration (audio-only: fps 0, timecode counted at 25), as for files macOS reads.
        let rate = probe.frameRate
        let fps = video == nil ? 0 : rate.fps
        let durationSeconds = probe.bestDuration
        let timecodeFPS = fps > 0 ? fps : 25.0
        let totalFrames = Int(max(0.0, min(Double(Int.max - 1), round(durationSeconds * timecodeFPS))))

        // 3. Codecs.
        let videoCodec = video.map { CodecNames.ffmpegVideo($0.codec, profile: $0.profile) } ?? "NONE"
        let audioStreams = probe.audio
        var audioInfo: (codec: String, bitrate: String, subDetail: String, fullDesc: String) = ("NONE", "--", "", "NONE")
        if let audio = audioStreams.first {
            let codec = CodecNames.ffmpegAudio(audio.codec, bits: audio.bitsPerSample)
            var kbps = audio.bitRate > 0 ? Int((Double(audio.bitRate) / 1000).rounded()) : 0
            if kbps == 0, audio.codec.hasPrefix("pcm_"), audio.sampleRate > 0, audio.channels > 0 {
                kbps = Int((Double(audio.sampleRate * audio.channels * (audio.bitsPerSample > 0 ? audio.bitsPerSample : 16)) / 1000).rounded())
            }
            audioInfo = audioSummary(codec: codec, sampleRate: audio.sampleRate, channels: audio.channels,
                                     trackCount: audioStreams.count, bitrateKbps: kbps)
        }

        // 4. Subtitle streams (MKV, TS) and captions carried in the video.
        var subs: [String] = []
        let subtitleStreams = probe.streams.filter { $0.type == "subtitle" }
        if !subtitleStreams.isEmpty {
            let languages = subtitleStreams.map(\.language).filter { !$0.isEmpty }.map { $0.uppercased() }
            subs.append(languages.isEmpty ? (subtitleStreams.count > 1 ? "\(subtitleStreams.count) SUBS" : "SUBTITLE")
                                          : "SUB (\(languages.joined(separator: ",")))")
        }
        if video?.hasClosedCaptions == true { subs.append("CC (608/708)") }

        let validation = validateFilename(fileName: url.lastPathComponent, durationSeconds: durationSeconds,
                                          aspectRatio: aspectRatioString, width: width, height: height,
                                          hasAudioTrack: !audioStreams.isEmpty)
        var asset = DeliverableAsset(
            fileURL: url, fileName: url.lastPathComponent, fileSizeBytes: fileSize, formattedFileSize: formatFileSize(bytes: fileSize),
            width: width, height: height, resolutionString: resolutionString, aspectRatioString: aspectRatioString,
            durationSeconds: durationSeconds, formattedDuration: String(format: "%.2fs", durationSeconds),
            totalFrames: totalFrames, timecode: TimecodeFormatter.format(frameIndex: totalFrames, fps: timecodeFPS), fps: fps,
            videoCodec: videoCodec, audioCodec: audioInfo.codec, audioBitrate: audioInfo.bitrate,
            audioFormatDetail: audioInfo.subDetail, audioConfig: audioInfo.fullDesc,
            audioLevelString: audioStreams.isEmpty ? "NO AUDIO" : "--",
            container: url.pathExtension.uppercased(),
            creationDate: created, formattedCreationDate: created.map { creationDateFormatter.string(from: $0) } ?? "--",
            hasSubtitles: !subs.isEmpty, subtitlesInfo: subs.isEmpty ? "NONE" : subs.joined(separator: " + "),
            validation: validation)
        // The codec and the container: either can be what macOS lacks (FLAC plays, FLAC in MKA doesn't).
        let what = video == nil ? audioInfo.codec : videoCodec
        let ext = url.pathExtension.uppercased()
        var reason = needsProVideoFormats ? "Install Apple Pro Video Formats to play it"
            : "macOS can't play \(what)\(ext.isEmpty || what.uppercased() == ext ? "" : " in \(ext)")"
        if rate.isVariable && video != nil { reason += " • variable frame rate" }
        asset.specsOnlyReason = reason
        return asset
    }
}
