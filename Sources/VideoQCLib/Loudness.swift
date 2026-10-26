import Foundation
import Accelerate
import CoreAudio
import AudioToolbox
import CoreMedia

/// ITU-R BS.1770-4 / EBU Tech 3341–3342 measurement of one audio track.
public struct LoudnessMeasurement: Sendable, Equatable {
    /// Gated programme loudness (LUFS); nil when nothing is above the −70 LUFS gate (silent).
    public let integrated: Double?
    /// 4× oversampled true peak (dBTP).
    public let truePeak: Double
    /// Loudness range (LU); nil for clips shorter than one 3 s window.
    public let range: Double?
    /// Loudest 3 s window (LUFS); nil for clips shorter than 3 s.
    public let maxShortTerm: Double?
    /// Channel problems: silent channel, out of phase, dual mono.
    public let channelNotes: [String]

    public var isSilent: Bool { integrated == nil || truePeak < -60 }

    public var summary: String {
        guard let integrated else { return "Silent" }
        return String(format: "%.1f LUFS · %.1f dBTP", integrated, truePeak)
    }

    public var detail: String {
        var lines = [
            "Integrated: " + (integrated.map { String(format: "%.1f LUFS", $0) } ?? "silent"),
            "True peak: " + (truePeak.isFinite ? String(format: "%.1f dBTP", truePeak) : "–"),
            "Loudness range: " + (range.map { String(format: "%.1f LU", $0) } ?? "–"),
            "Max short-term: " + (maxShortTerm.map { String(format: "%.1f LUFS", $0) } ?? "–")
        ]
        lines += channelNotes
        return lines.joined(separator: "\n")
    }
}

public struct LoudnessTarget: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let integrated: Double
    public let tolerance: Double
    public let maxTruePeak: Double

    public static let presets: [LoudnessTarget] = [
        LoudnessTarget(id: "r128", name: "EBU R128", integrated: -23, tolerance: 1, maxTruePeak: -1),
        LoudnessTarget(id: "a85", name: "ATSC A/85", integrated: -24, tolerance: 2, maxTruePeak: -2),
        LoudnessTarget(id: "streaming", name: "Streaming / Social", integrated: -14, tolerance: 1, maxTruePeak: -1),
        LoudnessTarget(id: "apple", name: "Apple", integrated: -16, tolerance: 1, maxTruePeak: -1)
    ]

    public static let presetKey = "prefLoudnessTarget"
    public static let customIntegratedKey = "prefLoudnessCustomLUFS"
    public static let customToleranceKey = "prefLoudnessCustomTolerance"
    public static let customTruePeakKey = "prefLoudnessCustomTruePeak"

    public static func custom(integrated: Double, tolerance: Double, maxTruePeak: Double) -> LoudnessTarget {
        LoudnessTarget(id: "custom", name: "Custom", integrated: integrated, tolerance: tolerance, maxTruePeak: maxTruePeak)
    }

    public static func resolve(id: String, customIntegrated: Double, customTolerance: Double, customTruePeak: Double) -> LoudnessTarget {
        if id == "custom" { return custom(integrated: customIntegrated, tolerance: customTolerance, maxTruePeak: customTruePeak) }
        return presets.first { $0.id == id } ?? presets[0]
    }

    public static var current: LoudnessTarget {
        let d = UserDefaults.standard
        return resolve(id: d.string(forKey: presetKey) ?? "r128",
                       customIntegrated: d.object(forKey: customIntegratedKey) as? Double ?? -23,
                       customTolerance: d.object(forKey: customToleranceKey) as? Double ?? 1,
                       customTruePeak: d.object(forKey: customTruePeakKey) as? Double ?? -1)
    }

    /// "−23 LUFS ±1 · −1 dBTP"
    public var spec: String {
        String(format: "%g LUFS ±%g · %g dBTP", integrated, tolerance, maxTruePeak)
    }

    public enum Verdict: String, Sendable { case pass = "PASS", warn = "WARN", fail = "FAIL" }

    /// Fail outside the tolerance or over the true-peak ceiling; warn within 0.5 dB of either edge or on a channel problem.
    public func evaluate(_ m: LoudnessMeasurement) -> (verdict: Verdict, issues: [String]) {
        guard let lufs = m.integrated else { return (.fail, ["Silent"]) }
        var verdict = Verdict.pass
        var issues: [String] = []
        let delta = lufs - integrated
        if abs(delta) > tolerance + 0.05 {
            verdict = .fail
            issues.append(String(format: "%@ by %.1f LU", delta > 0 ? "Too loud" : "Too quiet", abs(delta)))
        } else if abs(delta) > tolerance - min(0.5, tolerance / 2) {
            verdict = .warn
            issues.append(String(format: "Near limit (%+.1f LU)", delta))
        }
        if m.truePeak > maxTruePeak + 0.05 {
            verdict = .fail
            issues.append(String(format: "True peak %.1f dBTP over %g", m.truePeak, maxTruePeak))
        } else if m.truePeak > maxTruePeak - 0.5, verdict == .pass {
            verdict = .warn
            issues.append(String(format: "True peak near limit (%.1f dBTP)", m.truePeak))
        }
        if !m.channelNotes.isEmpty, verdict == .pass { verdict = .warn }
        issues += m.channelNotes
        return (verdict, issues)
    }
}

/// Streaming BS.1770-4 meter: feed interleaved Float32 buffers, then `finish()`.
/// K-weighting via vDSP biquads, 100 ms sub-blocks (400 ms momentary, 3 s short-term), 4× polyphase true peak.
struct LoudnessMeter {
    let channels: Int
    private let weights: [Double]
    private let names: [String]
    /// Channels that may be silent without a note (LFE).
    private let mayBeSilent: Set<Int>
    private let subBlockLength: Int
    private var biquad: vDSP_biquad_Setup
    private var biquadDelays: [[Float]]
    private var subBlockFill = 0
    private var subBlockSums: [Double]
    private var subBlockEnergies: [Double] = []
    private var momentary: [Double] = []
    private var shortTerm: [Double] = []
    private var peak: Float = 0
    private var history: [[Float]]
    private var channelEnergy: [Double]
    private var crossLR: Double = 0
    private var left: [Float] = []
    private var deinterleaved: [Float] = []
    private var filtered: [Float] = []
    private var upsampled: [Float] = []

    private static let tapsPerPhase = 12
    /// BS.1770-4 Annex 2 interpolator (48 taps, 4 phases), each phase reversed so vDSP_conv applies it as a convolution.
    private static let phaseFilters: [[Float]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
         0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
         0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
         0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
         0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750]
    ].map { $0.reversed() }

    /// `labels`: the track's channel labels (from its channel layout) when known; 5.1 without labels is taken as
    /// SMPTE order (L R C LFE Ls Rs).
    init?(channels: Int, sampleRate: Double, labels: [AudioChannelLabel]? = nil) {
        guard channels > 0, sampleRate >= 8000 else { return nil }
        self.channels = channels
        let labels = labels?.count == channels ? labels! : (channels == 6 ? [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround] : [])
        // BS.1770 channel weights: LFE excluded, surrounds +1.5 dB.
        let surrounds: Set<AudioChannelLabel> = [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
                                                 kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                                                 kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
                                                 kAudioChannelLabel_CenterSurround]
        let lfe: Set<AudioChannelLabel> = [kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2]
        weights = (0..<channels).map { c in
            guard c < labels.count else { return 1 }
            return lfe.contains(labels[c]) ? 0 : (surrounds.contains(labels[c]) ? 1.41 : 1)
        }
        mayBeSilent = Set((0..<channels).filter { c in c < labels.count && lfe.contains(labels[c]) })
        names = (0..<channels).map { c in
            if channels == 2 { return c == 0 ? "Left" : "Right" }
            if c < labels.count, let name = Self.labelNames[labels[c]] { return name }
            return "Ch \(c + 1)"
        }
        subBlockLength = max(1, Int((sampleRate / 10).rounded()))

        // K-weighting (high shelf + RLB high-pass) for any sample rate, as in libebur128.
        var k = tan(.pi * 1681.974450955533 / sampleRate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        k = tan(.pi * 38.13547087602444 / sampleRate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let highPass = [1.0, -2.0, 1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        guard let setup = vDSP_biquad_CreateSetup(shelf + highPass, 2) else { return nil }
        biquad = setup
        biquadDelays = Array(repeating: Array(repeating: 0, count: 6), count: channels)
        subBlockSums = Array(repeating: 0, count: channels)
        history = Array(repeating: Array(repeating: 0, count: Self.tapsPerPhase - 1), count: channels)
        channelEnergy = Array(repeating: 0, count: channels)
    }

    private static let labelNames: [AudioChannelLabel: String] = [
        kAudioChannelLabel_Left: "L", kAudioChannelLabel_Right: "R", kAudioChannelLabel_Center: "C",
        kAudioChannelLabel_LFEScreen: "LFE", kAudioChannelLabel_LeftSurround: "Ls", kAudioChannelLabel_RightSurround: "Rs",
        kAudioChannelLabel_RearSurroundLeft: "Lrs", kAudioChannelLabel_RearSurroundRight: "Rrs"
    ]

    /// Channel labels of a decoded LPCM format, expanding layout tags and bitmaps; nil when unlabelled.
    static func channelLabels(_ format: CMAudioFormatDescription) -> [AudioChannelLabel]? {
        var size = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &size), size > 0 else { return nil }
        var expanded = layout
        var owned: UnsafeMutableRawPointer? = nil
        defer { owned?.deallocate() }
        if layout.pointee.mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions {
            let specifier = layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
                ? kAudioFormatProperty_ChannelLayoutForBitmap : kAudioFormatProperty_ChannelLayoutForTag
            var input: UInt32 = specifier == kAudioFormatProperty_ChannelLayoutForBitmap
                ? layout.pointee.mChannelBitmap.rawValue : layout.pointee.mChannelLayoutTag
            var outSize: UInt32 = 0
            guard AudioFormatGetPropertyInfo(specifier, 4, &input, &outSize) == noErr, outSize > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(outSize), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            owned = raw
            guard AudioFormatGetProperty(specifier, 4, &input, &outSize, raw) == noErr else { return nil }
            expanded = UnsafePointer(raw.assumingMemoryBound(to: AudioChannelLayout.self))
        }
        let count = Int(expanded.pointee.mNumberChannelDescriptions)
        guard count > 0 else { return nil }
        let descriptions = (UnsafeRawPointer(expanded) + MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
            .assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { descriptions[$0].mChannelLabel }
    }

    func destroy() { vDSP_biquad_DestroySetup(biquad) }

    mutating func process(_ samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let hist = Self.tapsPerPhase - 1
        if deinterleaved.count < frames + hist {
            deinterleaved = Array(repeating: 0, count: frames + hist)
            filtered = Array(repeating: 0, count: frames)
            upsampled = Array(repeating: 0, count: frames)
        }
        if channels == 2, left.count < frames { left = Array(repeating: 0, count: frames) }
        var channelBlockSums = Array(repeating: [Double](), count: channels)
        for c in 0..<channels {
            deinterleaved.withUnsafeMutableBufferPointer { d in
                for i in 0..<hist { d[i] = history[c][i] }
                for i in 0..<frames { d[hist + i] = samples[i * channels + c] }
                let x = d.baseAddress! + hist

                var m: Float = 0
                vDSP_maxmgv(x, 1, &m, vDSP_Length(frames))
                peak = max(peak, m)
                var e: Float = 0
                vDSP_svesq(x, 1, &e, vDSP_Length(frames))
                channelEnergy[c] += Double(e)
                if channels == 2 {
                    if c == 0 {
                        left.withUnsafeMutableBufferPointer { l in l.baseAddress!.update(from: x, count: frames) }
                    } else {
                        var dot: Float = 0
                        vDSP_dotpr(left, 1, x, 1, &dot, vDSP_Length(frames))
                        crossLR += Double(dot)
                    }
                }

                // True peak: each phase of the 4× interpolator over [history + buffer].
                upsampled.withUnsafeMutableBufferPointer { u in
                    for phase in Self.phaseFilters {
                        phase.withUnsafeBufferPointer { f in
                            vDSP_conv(d.baseAddress!, 1, f.baseAddress!, 1, u.baseAddress!, 1, vDSP_Length(frames), vDSP_Length(Self.tapsPerPhase))
                        }
                        var tp: Float = 0
                        vDSP_maxmgv(u.baseAddress!, 1, &tp, vDSP_Length(frames))
                        peak = max(peak, tp)
                    }
                }
                for i in 0..<hist { history[c][i] = d[frames + i] }

                filtered.withUnsafeMutableBufferPointer { y in
                    biquadDelays[c].withUnsafeMutableBufferPointer { delay in
                        vDSP_biquad(biquad, delay.baseAddress!, x, 1, y.baseAddress!, 1, vDSP_Length(frames))
                    }
                    // Split into sub-block segments aligned with the running fill.
                    var offset = 0
                    var fill = subBlockFill
                    while offset < frames {
                        let n = min(subBlockLength - fill, frames - offset)
                        var s: Float = 0
                        vDSP_svesq(y.baseAddress! + offset, 1, &s, vDSP_Length(n))
                        channelBlockSums[c].append(Double(s))
                        offset += n
                        fill = (fill + n) % subBlockLength
                    }
                }
            }
        }

        var offset = 0
        var segment = 0
        while offset < frames {
            let n = min(subBlockLength - subBlockFill, frames - offset)
            for c in 0..<channels { subBlockSums[c] += channelBlockSums[c][segment] }
            subBlockFill += n
            offset += n
            segment += 1
            if subBlockFill == subBlockLength { closeSubBlock() }
        }
    }

    private mutating func closeSubBlock() {
        var energy = 0.0
        for c in 0..<channels { energy += weights[c] * subBlockSums[c] / Double(subBlockLength) }
        subBlockEnergies.append(energy)
        subBlockSums = Array(repeating: 0, count: channels)
        subBlockFill = 0
        let n = subBlockEnergies.count
        if n >= 4 { momentary.append(subBlockEnergies[(n - 4)...].reduce(0, +) / 4) }
        if n >= 30 { shortTerm.append(subBlockEnergies[(n - 30)...].reduce(0, +) / 30) }
    }

    private static func lufs(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
    private static let absoluteGate = pow(10, (-70 + 0.691) / 10)

    func finish() -> LoudnessMeasurement {
        // A clip shorter than one 400 ms block is measured as a single block of everything decoded.
        var blocks = momentary
        if blocks.isEmpty {
            let count = subBlockEnergies.count * subBlockLength + subBlockFill
            var energy = subBlockEnergies.reduce(0, +) * Double(subBlockLength)
            for c in 0..<channels { energy += weights[c] * subBlockSums[c] }
            if count > 0 { blocks = [energy / Double(count)] }
        }
        let gated = blocks.filter { $0 > Self.absoluteGate }
        var integrated: Double? = nil
        if !gated.isEmpty {
            let relativeGate = gated.reduce(0, +) / Double(gated.count) * pow(10, -10.0 / 10)
            let kept = gated.filter { $0 > relativeGate }
            integrated = Self.lufs(kept.reduce(0, +) / Double(kept.count))
        }

        var range: Double? = nil
        let stGated = shortTerm.filter { $0 > Self.absoluteGate }
        if !stGated.isEmpty {
            let relativeGate = stGated.reduce(0, +) / Double(stGated.count) * pow(10, -20.0 / 10)
            let sorted = stGated.filter { $0 > relativeGate }.map(Self.lufs).sorted()
            if !sorted.isEmpty {
                let at = { (p: Double) in sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
                range = at(0.95) - at(0.10)
            }
        }

        return LoudnessMeasurement(
            integrated: integrated,
            truePeak: peak > 0 ? Double(20 * log10(peak)) : -.infinity,
            range: range,
            maxShortTerm: shortTerm.max().flatMap { $0 > 0 ? Self.lufs($0) : nil },
            channelNotes: channelNotes()
        )
    }

    private func channelNotes() -> [String] {
        let frames = Double(max(1, subBlockEnergies.count * subBlockLength + subBlockFill))
        let level = channelEnergy.map { 10 * log10(max($0 / frames, 1e-20)) }
        guard let loudest = level.max(), loudest > -50 else { return [] }
        var notes: [String] = []
        for c in 0..<channels where level[c] < -70 && !mayBeSilent.contains(c) {
            notes.append("\(names[c]) channel silent")
        }
        if channels == 2, notes.isEmpty {
            let l = channelEnergy[0], r = channelEnergy[1]
            let difference = max(0, l + r - 2 * crossLR) / (l + r)
            let correlation = crossLR / sqrt(l * r)
            if difference < 1e-5 {
                notes.append("Dual mono (L = R)")
            } else if correlation < -0.5 {
                notes.append(String(format: "Out of phase (correlation %.2f)", correlation))
            }
        }
        return notes
    }
}
