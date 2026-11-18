import Foundation
@preconcurrency import AVFoundation
import CoreVideo
import Testing
@testable import VideoQCLib

/// A smooth, detailed picture defined everywhere (a sum of waves), so any crop, shift or scale of it can be drawn
/// exactly: shot `seed`'s scene.
private struct Scene {
    let waves: [(kx: Double, ky: Double, phase: Double, amplitude: Double, speed: Double)]

    init(seed: Int) {
        var state = UInt64(seed &* 2_654_435_761 &+ 1)
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        waves = (0..<24).map { _ in
            let angle = next() * 2 * .pi
            // Low frequencies dominate, as in real pictures (amplitude ~ 1 / frequency).
            let frequency = 0.003 + next() * 0.06   // cycles per pixel at frame size 240
            // Half the waves drift on their own (things moving in the shot), so a frame isn't just its neighbour moved.
            return (cos(angle) * frequency * 2 * .pi, sin(angle) * frequency * 2 * .pi, next() * 2 * .pi, 0.01 / frequency,
                    next() < 0.5 ? 0 : 0.15 + next() * 0.3)
        }
    }

    /// Grey 0…1 at scene position (x, y) at time `t` (frames).
    func value(_ x: Double, _ y: Double, _ t: Double) -> Double {
        var v = 0.0
        var total = 0.0
        for w in waves { v += w.amplitude * sin(w.kx * x + w.ky * y + w.phase + w.speed * t); total += w.amplitude }
        return 0.5 + 0.45 * v / total
    }

    /// A `size` × `size` frame framed at `center` (scene coordinates) with `zoom` (above 1: tighter).
    func frame(size: Int, center: (Double, Double), zoom: Double = 1, t: Double = 0) -> [Float] {
        var out = [Float](repeating: 0, count: size * size)
        let half = Double(size - 1) / 2
        for y in 0..<size {
            for x in 0..<size {
                out[y * size + x] = Float(value(center.0 + (Double(x) - half) / zoom, center.1 + (Double(y) - half) / zoom, t))
            }
        }
        return out
    }
}

private enum CropClips {
    /// Writes grey frames as an H.264 QuickTime file at 25 fps.
    static func write(_ frames: [[Float]], size: Int, name: String, in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for (n, frame) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<size {
                for x in 0..<size {
                    let v = UInt8(max(0, min(255, frame[y * size + x] * 255)))
                    let p = base + y * row + x * 4
                    p[0] = v; p[1] = v; p[2] = v; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 25))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }
}

@Suite("Crop Match")
struct CropMatchTests {
    // MARK: Alignment

    /// Fingerprints of a scene panning one pixel a frame: frame k of shot `seed` starting at `from`.
    private func shot(_ seed: Int, frames: Range<Int>, size: Int = 64, shiftX: Double = 0, zoom: Double = 1, speed: Double = 1) -> [[Float]] {
        let scene = Scene(seed: seed)
        return frames.map { k in scene.frame(size: size, center: (200 + Double(k) * speed + shiftX, 200), zoom: zoom, t: Double(k)) }
    }

    @Test("Each cutdown frame is paired with its master frame, across cuts, trims, a retime and a shot not in the master")
    func alignment() {
        let masterFrames = shot(1, frames: 0..<20) + shot(2, frames: 0..<20) + shot(3, frames: 0..<20) + shot(4, frames: 0..<20)
        let master = Fingerprints(lumaFrames: masterFrames, width: 64, height: 64)
        // Shot 3 trimmed (frames 4…14), shot 9 (not in the master), shot 2 at double speed (frames 2, 4 … 16).
        let cutFrames = shot(3, frames: 4..<15) + shot(9, frames: 0..<8) + (1...8).map { shot(2, frames: ($0 * 2)..<($0 * 2 + 1))[0] }
        let cutdown = Fingerprints(lumaFrames: cutFrames, width: 64, height: 64)
        let path = CropMatcher.align(cutdown: cutdown, master: master)
        // Within 3 frames: fingerprints are blurred on purpose (they must survive reframes); measuring finds the exact frame.
        func near(_ found: ArraySlice<Int?>, _ expected: [Int]) -> Bool {
            zip(found, expected).allSatisfy { a, b in a.map { abs($0 - b) <= 3 } ?? false }
        }
        #expect(near(path[0..<11], Array(44..<55)), "\(path)")
        // The absent shot leaves the master; its last frames may be drawn into the next shot's start, which the
        // cutdown's own cut then splits off (runs under 3 frames are dropped).
        #expect(path[11..<17].allSatisfy { $0 == nil }, "\(path.map { $0.map(String.init) ?? "-" })")
        #expect(near(path[19..<27], (1...8).map { 20 + $0 * 2 }), "\(path)")

        let shots = CropMatcher.shots(from: path, cutdown: cutdown, master: master)
        #expect(shots.map(\.verdict) == [.same, .notInMaster, .same], "\(shots.map { "\($0.start)-\($0.end) \($0.verdict)" })")
        #expect(shots.count == 3 && shots[1].start == 11 && shots[1].end >= 16)
        #expect(shots[0].masterStart == 44 && shots[0].masterEnd == 54)
        #expect(shots[2].speed > 1.4, "speed \(shots[2].speed)")
    }

    @Test("A slightly reframed shot still pairs with its master shot")
    func alignmentSurvivesReframe() {
        let master = Fingerprints(lumaFrames: shot(1, frames: 0..<15) + shot(2, frames: 0..<15), width: 64, height: 64)
        let cutdown = Fingerprints(lumaFrames: shot(2, frames: 3..<12, shiftX: 3, zoom: 1.04), width: 64, height: 64)
        let path = CropMatcher.align(cutdown: cutdown, master: master)
        #expect(zip(path, 18..<27).allSatisfy { a, b in a.map { abs($0 - b) <= 3 } ?? false }, "\(path)")
    }

    // MARK: Framing

    @Test("Framing is measured to a fraction of a pixel and a tenth of a percent", arguments: [
        (0.0, 0.0, 1.0), (6.0, -3.0, 1.0), (-2.4, 1.3, 1.0), (0.0, 0.0, 1.03), (4.0, 2.0, 0.97), (-10.0, 7.5, 1.05)
    ])
    func framing(dx: Double, dy: Double, zoom: Double) throws {
        let size = 192
        let scene = Scene(seed: 7)
        let master = scene.frame(size: size, center: (300, 300))
        let cutdown = scene.frame(size: size, center: (300 + dx, 300 + dy), zoom: zoom)
        let framing = try #require(CropAligner.measure(cutdown: cutdown, master: master, width: size, height: size))
        #expect(abs(framing.dx - dx) < 0.25, "dx \(framing.dx) vs \(dx)")
        #expect(abs(framing.dy - dy) < 0.25, "dy \(framing.dy) vs \(dy)")
        #expect(abs(framing.scale - zoom) < 0.002, "scale \(framing.scale) vs \(zoom)")
        #expect(framing.isReframed(width: size, sourceScale: 1) == (dx != 0 || dy != 0 || zoom != 1))
    }

    @Test("A plain picture is too plain to measure, not a match")
    func plain() throws {
        let flat = [Float](repeating: 0.4, count: 96 * 96)
        let framing = try #require(CropAligner.measure(cutdown: flat, master: flat, width: 96, height: 96))
        #expect(framing.tooPlain)
    }

    // MARK: End to end

    @Test("A reframed shot and a 2× punch-in are found and measured; a shot framed as the master passes; a new shot is reported")
    func endToEnd() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let size = 240
        func frames(_ seed: Int, _ range: Range<Int>, shiftX: Double = 0, zoom: Double = 1) -> [[Float]] {
            let scene = Scene(seed: seed)
            return range.map { scene.frame(size: size, center: (400 + Double($0) * 2 + shiftX, 400), zoom: zoom, t: Double($0)) }
        }
        let master = try await CropClips.write(frames(1, 0..<20) + frames(2, 0..<20) + frames(3, 0..<20), size: size,
                                               name: "Spot_30s.mov", in: folder)
        // Shot 3 as the master; shot 1 moved 8 px right and 2 % tighter; then a shot that isn't in the master.
        // …and shot 2 punched in 2× (beyond what the frame-wide fingerprints pair: the zoomed search finds it).
        let cutdown = try await CropClips.write(frames(3, 4..<16) + frames(1, 3..<15, shiftX: 8, zoom: 1.02) + frames(5, 0..<10)
                                                + frames(2, 4..<16, zoom: 2), size: size, name: "Spot_15s.mov", in: folder)
        // The master is found by itself (the longest video).
        let batch = await CropMatcher().run(files: [cutdown, master]) { _ in }
        let run = try #require(batch.runs.first)
        #expect(run.master == master)
        let result = try #require(run.results.first)
        #expect(result.readError == nil)
        #expect(result.shots.map(\.verdict) == [.same, .reframed, .notInMaster, .reframed], "\(result.shots.map { "\($0.start)-\($0.end) \($0.verdict) \($0.shift) \($0.scale) \($0.likeness)" })")
        let reframed = result.shots[1]
        #expect(abs(reframed.shift.x - 8) < 1, "shift \(reframed.shift)")
        #expect(abs(reframed.shift.y) < 1)
        #expect(abs(reframed.scale - 1.02) < 0.004, "scale \(reframed.scale)")
        #expect(abs((result.shots[0].masterStart ?? 0) - 44) <= 3)
        if result.shots.count == 4 {
            #expect(abs(result.shots[3].scale - 2) < 0.01, "punch-in scale \(result.shots[3].scale)")
            #expect(hypot(result.shots[3].shift.x, result.shots[3].shift.y) < 1)
        }
        // The exact frame pair, found by measuring: cutdown 12 + k shows master 3 + k of shot 1.
        if let c = reframed.measuredCutdownFrame, let m = reframed.measuredMasterFrame { #expect(m - c == 3 - 12) }
    }
}

@Suite("Crop Match report")
struct CropMatchReportTests {
    @Test("Editor values and the crop's rectangle on the master come from the measured scale and shift")
    func editValues() {
        // The samples' 106.5 % / position 1021 × 540 shot, as measured.
        var shot = CropMatchShot(id: 0, start: 0, end: 9, masterStart: 0, masterEnd: 9, likeness: 1, verdict: .reframed)
        shot.scale = 1.0668
        shot.shift = CGPoint(x: -56.9, y: -0.2)
        let size = CGSize(width: 1920, height: 1080)
        let values = shot.editValues(masterSize: size)
        #expect(abs(values.scale - 106.68) < 0.01)
        #expect(abs(values.x - 1020.7) < 0.1 && abs(values.y - 540.2) < 0.1)
        let rect = shot.cropRect(masterSize: size)
        #expect(abs(rect.width - 1 / 1.0668) < 1e-6)
        #expect(abs(rect.midX - (0.5 - 56.9 / 1920)) < 1e-6)
        // Framed as the master: the whole frame, at 100 % and the centre.
        let same = CropMatchShot(id: 1, start: 0, end: 9, masterStart: 0, masterEnd: 9, likeness: 1, verdict: .same)
        #expect(same.cropRect(masterSize: size) == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(same.editValues(masterSize: size) == (100, 960, 540))
    }
}
