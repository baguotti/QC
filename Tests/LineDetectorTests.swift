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
        #expect(detections.allSatisfy(\.isOffColor), "\(c.name): got \(Self.describe(detections))")
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

    @Test("Any-colour mode finds an untargeted line and ignores clean pictures")
    func anyColour() {
        let config = QCConfig(targetHex: "#00FF00", anyColor: true)
        var f = Scenes.picture()
        f.drawEdgeLine(.right, thickness: 2, color: RGBColor(r: 255, g: 140, b: 0))
        #expect(detector.scanPixelBuffer(f.makePixelBuffer(), config: config).contains { $0.edge == .right })
        #expect(detector.scanPixelBuffer(Scenes.picture().makePixelBuffer(), config: config).isEmpty)
    }

    static func describe(_ detections: [LineDetection]) -> String {
        detections.map { "\($0.edge.rawValue) t=\($0.thickness) α=\(String(format: "%.2f", $0.score))\($0.isWeak ? " weak" : "") span=\(String(format: "%.2f", $0.spanRatio))" }.joined(separator: ", ")
    }
}
