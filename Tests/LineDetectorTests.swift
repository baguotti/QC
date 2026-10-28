import Foundation
import CoreVideo
import Testing
@testable import VideoQCLib

extension LineCase: CustomTestStringConvertible {
    var testDescription: String { name }
}

// MARK: - Tests

@Suite("Line Finder synthetic detection")
struct LineDetectorTests {
    let detector = EdgeDetector()

    @Test("Detects tricky target lines", arguments: LineCase.positives)
    func positive(_ c: LineCase) {
        let detections = detector.scanPixelBuffer(c.frame().makePixelBuffer(), config: c.config)
        #expect(detections.contains { $0.edge == c.expectedEdge && !$0.isWeak }, "\(c.name): got \(Self.describe(detections))")
    }

    @Test("Leaves clean frames clean", arguments: LineCase.negatives)
    func negative(_ c: LineCase) {
        let detections = detector.scanPixelBuffer(c.frame().makePixelBuffer(), config: c.config)
        #expect(detections.allSatisfy { $0.isOffColor }, "\(c.name): got \(Self.describe(detections))")
    }

    @Test("Lines of another colour are reported as off-colour, not as the target", arguments: LineCase.offColor)
    func offColor(_ c: LineCase) {
        let detections = detector.scanPixelBuffer(c.frame().makePixelBuffer(), config: c.config)
        #expect(detections.contains { $0.edge == c.expectedEdge && $0.isOffColor && $0.isWeak }, "\(c.name): got \(Self.describe(detections))")
        #expect(!detections.contains { !$0.isOffColor }, "\(c.name): got \(Self.describe(detections))")
    }

    @Test("Old vs new detector on every case")
    func comparison() {
        let legacy = LegacyEdgeDetector()
        var report = ["case | expected | v1 | v2"]
        for c in LineCase.positives + LineCase.negatives {
            let buffer = c.frame().makePixelBuffer()
            let old = legacy.scanPixelBuffer(buffer, config: c.config).filter { !$0.isWeak }
            let new = detector.scanPixelBuffer(buffer, config: c.config).filter { !$0.isWeak }
            func verdict(_ d: [LineDetection]) -> String {
                if let edge = c.expectedEdge { return d.contains { $0.edge == edge } ? "hit" : "MISS" }
                return d.isEmpty ? "clean" : "FALSE FLAG"
            }
            report.append("\(c.name) | \(c.expectedEdge?.rawValue ?? "none") | \(verdict(old)) | \(verdict(new))")
        }
        print(report.joined(separator: "\n"))
    }

    @Test("Faint line is weak per frame and flagged only when it persists")
    func faintLinePersistence() {
        var f = Scenes.picture()
        f.drawEdgeLine(.bottom, thickness: 2, color: Scenes.green, alpha: 0.24)
        let detections = detector.scanPixelBuffer(f.makePixelBuffer(), config: LineCase.greenConfig)
        let bottom = detections.first { $0.edge == .bottom }
        #expect(bottom?.isWeak == true, "got \(Self.describe(detections))")

        guard let bottom else { return }
        func frames(_ indices: [Int]) -> [FrameError] {
            indices.map { FrameError(frameIndex: $0, timecode: "", detections: [bottom]) }
        }
        #expect(LineHysteresis.filter(frames(Array(0..<5)), minRun: 6).isEmpty)
        #expect(LineHysteresis.filter(frames(Array(10..<16)), minRun: 6).count == 6)
        #expect(LineHysteresis.filter(frames([0, 1, 2, 4, 5, 6, 7]), minRun: 6).isEmpty)

        let strong = LineDetection(edge: .top, thickness: 1, detectedColor: Scenes.green, spanRatio: 1, score: 1, isWeak: false)
        let single = LineHysteresis.filter([FrameError(frameIndex: 3, timecode: "", detections: [strong])], minRun: 6)
        #expect(single.count == 1)
    }

    @Test("Padding rows outside the clean aperture are ignored")
    func cleanAperture() {
        let padded = Scenes.picture().makePixelBuffer(paddingRows: 8, paddingColor: Scenes.green)
        #expect(detector.scanPixelBuffer(padded, config: LineCase.greenConfig).isEmpty)

        var f = Scenes.picture()
        f.drawEdgeLine(.bottom, color: Scenes.green)
        let lined = f.makePixelBuffer(paddingRows: 8, paddingColor: RGBColor(r: 128, g: 128, b: 128))
        #expect(detector.scanPixelBuffer(lined, config: LineCase.greenConfig).contains { $0.edge == .bottom })
    }

    @Test("Edges follow the track's preferred transform")
    func rotation() {
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        #expect(EdgeLocation.top.oriented(by: portrait) == .right)
        #expect(EdgeLocation.right.oriented(by: portrait) == .bottom)
        #expect(EdgeLocation.bottom.oriented(by: portrait) == .left)
        #expect(EdgeLocation.left.oriented(by: portrait) == .top)
        #expect(EdgeLocation.splitHorizontal.oriented(by: portrait) == .splitVertical)

        let upsideDown = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        #expect(EdgeLocation.top.oriented(by: upsideDown) == .bottom)
        #expect(EdgeLocation.left.oriented(by: upsideDown) == .right)
        #expect(EdgeLocation.top.oriented(by: .identity) == .top)
    }

    @Test("Seam positions follow the track's preferred transform")
    func seamPositionRotation() {
        let green = RGBColor(r: 0, g: 255, b: 0)
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let seam = LineDetection(edge: .splitHorizontal, thickness: 2, detectedColor: green, spanRatio: 1, position: 100)
            .oriented(by: portrait)
        #expect(seam.edge == .splitVertical)
        #expect(seam.position == 978)   // rows 100–101 show as columns 979 and 978

        let mirrored = LineDetection(edge: .splitVertical, thickness: 1, detectedColor: green, spanRatio: 1, position: 300)
            .oriented(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1920, ty: 0))
        #expect(mirrored.edge == .splitVertical)
        #expect(mirrored.position == 1619)

        let insideBar = LineDetection(edge: .top, thickness: 1, detectedColor: green, spanRatio: 1, position: 140).oriented(by: portrait)
        #expect(insideBar.edge == .right)
        #expect(insideBar.position == 140)
    }

    @Test("Any-colour mode finds an untargeted line and ignores clean pictures")
    func anyColour() {
        let config = QCConfig(targetHex: "#00FF00", anyColor: true)
        var f = Scenes.picture()
        f.drawEdgeLine(.right, thickness: 2, color: RGBColor(r: 255, g: 140, b: 0))
        #expect(detector.scanPixelBuffer(f.makePixelBuffer(), config: config).contains { $0.edge == .right })
        #expect(detector.scanPixelBuffer(Scenes.picture().makePixelBuffer(), config: config).isEmpty)
    }

    @Test("Frame numbers match the Player on a 600 time base (NTSC rates)")
    func frameNumbersOn600TimeBase() {
        for rate in [30000.0 / 1001, 24000.0 / 1001, 60000.0 / 1001] {
            let fps = Double(Float(rate))
            let wrong = (0..<40_000).filter { n in
                let pts = (Double(n) * 600 / rate).rounded() / 600
                return VideoScanner.frameIndex(seconds: pts, fps: fps) != n
            }
            #expect(wrong.isEmpty, "\(rate) fps: first wrong frame \(wrong.first ?? -1)")
        }
    }

    @Test("Two seams in the same frames stay two segments")
    func twoSeams() {
        var f = Scenes.picture()
        for y in 0..<Scenes.height { for x in [150, 330] { f[x, y] = (0, 255, 0) } }
        let config = QCConfig(targetHex: "#00FF00", scanFullScreen: true)
        let detections = detector.scanPixelBuffer(f.makePixelBuffer(), config: config)
        #expect(detections.filter { $0.edge == .splitVertical }.count == 2, "got \(Self.describe(detections))")
        let frames = (0..<3).map { FrameError(frameIndex: $0, timecode: "", detections: detections) }
        let result = VideoQCResult(fileURL: URL(fileURLWithPath: "/seams.mov"), fileName: "seams.mov", resolution: "", fps: 25,
                                   totalFrames: 3, durationSeconds: 0.12, errorFrames: frames)
        #expect(result.glitchSegments.map(\.position) == [150, 330])
        #expect(result.glitchSegments.allSatisfy { $0.frameCount == 3 })
    }

    static func describe(_ detections: [LineDetection]) -> String {
        detections.map { "\($0.edge.rawValue) t=\($0.thickness) α=\(String(format: "%.2f", $0.score))\($0.isWeak ? " weak" : "") span=\(String(format: "%.2f", $0.spanRatio))" }.joined(separator: ", ")
    }
}
