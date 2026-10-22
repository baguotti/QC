/// Synthetic frames and cases shared by LineDetectorTests and scripts/LineFinderBench (no Testing import here).
import Foundation
import CoreVideo
@testable import VideoQCLib

typealias RGBColor = VideoQCLib.RGBColor

// MARK: - Synthetic frames

struct SyntheticFrame: Sendable {
    let width: Int
    let height: Int
    var pixels: [Double]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [Double](repeating: 0, count: width * height * 3)
    }

    subscript(x: Int, y: Int) -> (Double, Double, Double) {
        get {
            let i = (y * width + x) * 3
            return (pixels[i], pixels[i + 1], pixels[i + 2])
        }
        set {
            let i = (y * width + x) * 3
            pixels[i] = newValue.0
            pixels[i + 1] = newValue.1
            pixels[i + 2] = newValue.2
        }
    }

    mutating func fill(_ body: (Int, Int) -> (Double, Double, Double)) {
        for y in 0..<height {
            for x in 0..<width {
                self[x, y] = body(x, y)
            }
        }
    }

    mutating func blend(x: Int, y: Int, color: RGBColor, alpha: Double) {
        let p = self[x, y]
        self[x, y] = (
            alpha * Double(color.r) + (1 - alpha) * p.0,
            alpha * Double(color.g) + (1 - alpha) * p.1,
            alpha * Double(color.b) + (1 - alpha) * p.2
        )
    }

    /// Paints a line `thickness` px thick starting `depth` px in from `edge`, over the fraction `span` of the edge.
    mutating func drawEdgeLine(_ edge: EdgeLocation, depth: Int = 0, thickness: Int = 1, color: RGBColor, alpha: Double = 1, span: ClosedRange<Double> = 0...1) {
        let horizontal = edge == .top || edge == .bottom
        let length = horizontal ? width : height
        let from = Int(Double(length) * span.lowerBound)
        let to = Int(Double(length) * span.upperBound)
        for d in depth..<(depth + thickness) {
            for p in from..<to {
                switch edge {
                case .top: blend(x: p, y: d, color: color, alpha: alpha)
                case .bottom: blend(x: p, y: height - 1 - d, color: color, alpha: alpha)
                case .left: blend(x: d, y: p, color: color, alpha: alpha)
                case .right: blend(x: width - 1 - d, y: p, color: color, alpha: alpha)
                default: break
                }
            }
        }
    }

    mutating func addNoise(sigma: Double, seed: UInt64, rows: Range<Int>? = nil) {
        var rng = SplitMix64(seed: seed)
        for y in rows ?? 0..<height {
            for x in 0..<width {
                let p = self[x, y]
                self[x, y] = (p.0 + rng.gaussian() * sigma, p.1 + rng.gaussian() * sigma, p.2 + rng.gaussian() * sigma)
            }
        }
    }

    /// Simulates 4:2:0 chroma subsampling: luma kept per pixel, Cb/Cr averaged over 2x2 blocks (BT.709).
    mutating func subsampleChroma420() {
        func ycc(_ p: (Double, Double, Double)) -> (Double, Double, Double) {
            let y = 0.2126 * p.0 + 0.7152 * p.1 + 0.0722 * p.2
            return (y, (p.2 - y) / 1.8556, (p.0 - y) / 1.5748)
        }
        for by in stride(from: 0, to: height - 1, by: 2) {
            for bx in stride(from: 0, to: width - 1, by: 2) {
                let block = [(bx, by), (bx + 1, by), (bx, by + 1), (bx + 1, by + 1)]
                let converted = block.map { ycc(self[$0.0, $0.1]) }
                let cb = converted.map(\.1).reduce(0, +) / 4
                let cr = converted.map(\.2).reduce(0, +) / 4
                for (i, xy) in block.enumerated() {
                    let y = converted[i].0
                    let r = y + 1.5748 * cr
                    let b = y + 1.8556 * cb
                    let g = (y - 0.2126 * r - 0.0722 * b) / 0.7152
                    self[xy.0, xy.1] = (r, g, b)
                }
            }
        }
    }

    func makePixelBuffer(paddingRows: Int = 0, paddingColor: RGBColor? = nil) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height + paddingRows, kCVPixelFormatType_32BGRA, attrs, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
        for y in 0..<(height + paddingRows) {
            for x in 0..<width {
                let o = y * bpr + x * 4
                if y < height {
                    let p = self[x, y]
                    base[o] = clamp(p.2); base[o + 1] = clamp(p.1); base[o + 2] = clamp(p.0)
                } else {
                    let c = paddingColor ?? RGBColor(r: 0, g: 0, b: 0)
                    base[o] = c.b; base[o + 1] = c.g; base[o + 2] = c.r
                }
                base[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if paddingRows > 0 {
            let aperture: [CFString: Any] = [
                kCVImageBufferCleanApertureWidthKey: width,
                kCVImageBufferCleanApertureHeightKey: height,
                kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
                kCVImageBufferCleanApertureVerticalOffsetKey: -Double(paddingRows) / 2
            ]
            CVBufferSetAttachment(pb, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldPropagate)
        }
        return pb
    }
}

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * unit())
    }
}

enum Scenes {
    static let width = 480
    static let height = 270

    static let green = RGBColor(r: 0, g: 255, b: 0)
    static let black = RGBColor(r: 0, g: 0, b: 0)
    static let white = RGBColor(r: 255, g: 255, b: 255)

    /// Textured mid-tone picture: smooth colour fields plus fine detail, no dominant hue.
    static func picture(seed: UInt64 = 1, width: Int = width, height: Int = height) -> SyntheticFrame {
        var f = SyntheticFrame(width: width, height: height)
        let s = Double(seed)
        f.fill { x, y in
            let fx = Double(x), fy = Double(y)
            return (
                125 + 55 * sin(fx / 37 + s) + 25 * sin(fy / 23 + 2 * s) + 10 * sin((fx + fy) / 5),
                115 + 45 * sin(fx / 29 + fy / 41 + s) + 15 * cos(fy / 13),
                120 + 50 * cos(fx / 53 - fy / 31 + s) + 12 * sin(fx / 7)
            )
        }
        f.addNoise(sigma: 4, seed: seed &* 31)
        return f
    }

    static func darkPicture(seed: UInt64 = 2) -> SyntheticFrame {
        var f = SyntheticFrame(width: width, height: height)
        f.fill { x, y in
            let v = 34 + 9 * sin(Double(x) / 31) + 6 * cos(Double(y) / 17)
            return (v + 3, v, v + 5)
        }
        f.addNoise(sigma: 2, seed: seed)
        return f
    }

    /// Strongly textured greens (leaves): high per-pixel variance around a green hue.
    static func paintFoliage(_ f: inout SyntheticFrame, rows: Range<Int>, columns: Range<Int>, seed: UInt64 = 3) {
        var rng = SplitMix64(seed: seed)
        for y in rows {
            for x in columns {
                let leaf = 0.5 + 0.5 * sin(Double(x) / 3.1 + Double(y) / 4.7) * cos(Double(y) / 2.3)
                let n = rng.gaussian()
                f[x, y] = (30 + 30 * leaf + 10 * n, 95 + 110 * leaf + 18 * n, 25 + 25 * leaf + 8 * n)
            }
        }
    }

    /// The O&O defect: a 1 px darker grey column (#918D8B) at the left of a light neutral picture (#D0CCCA).
    static func greyColumnOnLightPicture() -> SyntheticFrame {
        var f = SyntheticFrame(width: width, height: height)
        f.fill { x, y in
            let v = 4 * sin(Double(x) / 19) + 3 * cos(Double(y) / 11)
            return (208 + v, 204 + v, 202 + v)
        }
        f.addNoise(sigma: 2, seed: 9)
        f.drawEdgeLine(.left, color: RGBColor(r: 145, g: 141, b: 139))
        return f
    }

    static func solid(_ c: RGBColor) -> SyntheticFrame {
        var f = SyntheticFrame(width: width, height: height)
        f.fill { _, _ in (Double(c.r), Double(c.g), Double(c.b)) }
        return f
    }
}

// MARK: - Cases

struct LineCase: Sendable {
    let name: String
    let config: QCConfig
    let expectedEdge: EdgeLocation?
    let frame: @Sendable () -> SyntheticFrame


    static let greenConfig = QCConfig(targetHex: "#00FF00", tolerance: 0.25)
    static let blackConfig = QCConfig(targetHex: "#000000", tolerance: 0.03)
    static let whiteConfig = QCConfig(targetHex: "#FFFFFF", tolerance: 0.03)

    static let positives: [LineCase] = [
        LineCase(name: "1 px line at bottom edge", config: greenConfig, expectedEdge: .bottom) {
            var f = Scenes.picture()
            f.drawEdgeLine(.bottom, color: Scenes.green)
            return f
        },
        LineCase(name: "line 1 px in, outer column half-blended", config: greenConfig, expectedEdge: .left) {
            var f = Scenes.picture()
            f.drawEdgeLine(.left, depth: 1, color: Scenes.green)
            f.drawEdgeLine(.left, depth: 0, color: Scenes.green, alpha: 0.5)
            return f
        },
        LineCase(name: "line 1 px in, outer row untouched", config: greenConfig, expectedEdge: .top) {
            var f = Scenes.picture()
            f.drawEdgeLine(.top, depth: 1, thickness: 2, color: Scenes.green)
            return f
        },
        LineCase(name: "50% blended line", config: greenConfig, expectedEdge: .top) {
            var f = Scenes.picture()
            f.drawEdgeLine(.top, thickness: 2, color: Scenes.green, alpha: 0.5)
            return f
        },
        LineCase(name: "30% blended line", config: greenConfig, expectedEdge: .right) {
            var f = Scenes.picture()
            f.drawEdgeLine(.right, color: Scenes.green, alpha: 0.3)
            return f
        },
        LineCase(name: "partial span (40%)", config: greenConfig, expectedEdge: .bottom) {
            var f = Scenes.picture()
            f.drawEdgeLine(.bottom, thickness: 2, color: Scenes.green, span: 0.3...0.7)
            return f
        },
        LineCase(name: "noisy / compressed line", config: greenConfig, expectedEdge: .bottom) {
            var f = Scenes.picture()
            f.drawEdgeLine(.bottom, thickness: 2, color: Scenes.green, alpha: 0.85)
            f.addNoise(sigma: 22, seed: 11, rows: (Scenes.height - 2)..<Scenes.height)
            f.addNoise(sigma: 6, seed: 12)
            return f
        },
        LineCase(name: "4:2:0 chroma blur", config: greenConfig, expectedEdge: .bottom) {
            var f = Scenes.picture()
            f.drawEdgeLine(.bottom, color: Scenes.green)
            f.subsampleChroma420()
            return f
        },
        LineCase(name: "black line on dark scene", config: blackConfig, expectedEdge: .left) {
            var f = Scenes.darkPicture()
            f.drawEdgeLine(.left, thickness: 2, color: Scenes.black, alpha: 0.7)
            return f
        },
        LineCase(name: "green line next to green content", config: greenConfig, expectedEdge: .bottom) {
            var f = Scenes.picture()
            Scenes.paintFoliage(&f, rows: (Scenes.height - 60)..<Scenes.height, columns: 0..<(Scenes.width * 2 / 5))
            f.drawEdgeLine(.bottom, color: Scenes.green, alpha: 0.6)
            return f
        },
        LineCase(name: "internal split line", config: QCConfig(targetHex: "#00FF00", tolerance: 0.25, scanFullScreen: true), expectedEdge: .splitVertical) {
            let left = Scenes.picture(seed: 1)
            let right = Scenes.picture(seed: 7)
            var f = left
            let mid = Scenes.width / 2
            for y in 0..<Scenes.height {
                for x in mid..<Scenes.width { f[x, y] = right[x, y] }
                for x in (mid - 1)...mid { f.blend(x: x, y: y, color: Scenes.green, alpha: 0.6) }
            }
            return f
        },
        LineCase(name: "horizontal split, 1 px, 35% blended", config: QCConfig(targetHex: "#00FF00", tolerance: 0.25, scanFullScreen: true), expectedEdge: .splitHorizontal) {
            let top = Scenes.picture(seed: 3)
            let bottom = Scenes.picture(seed: 11)
            var f = top
            let mid = Scenes.height / 2
            for y in mid..<Scenes.height { for x in 0..<Scenes.width { f[x, y] = bottom[x, y] } }
            for x in 0..<Scenes.width { f.blend(x: x, y: mid, color: Scenes.green, alpha: 0.35) }
            return f
        },
        LineCase(name: "partial vertical split (40% of height)", config: QCConfig(targetHex: "#00FF00", tolerance: 0.25, scanFullScreen: true), expectedEdge: .splitVertical) {
            var f = Scenes.picture(seed: 5)
            let mid = Scenes.width / 3
            for y in Int(Double(Scenes.height) * 0.3)..<Int(Double(Scenes.height) * 0.7) { f[mid, y] = (0, 255, 0) }
            return f
        },
        LineCase(name: "line at the picture edge inside a letterbox", config: greenConfig, expectedEdge: .top) {
            var f = Scenes.picture()
            for y in 0..<40 { for x in 0..<Scenes.width { f[x, y] = (0, 0, 0); f[x, Scenes.height - 1 - y] = (0, 0, 0) } }
            for x in 0..<Scenes.width { f[x, 40] = (0, 255, 0) }
            return f
        },
    ]

    static let negatives: [LineCase] = [
        LineCase(name: "letterboxed picture, green target", config: greenConfig, expectedEdge: nil) {
            var f = Scenes.picture()
            for y in 0..<40 { for x in 0..<Scenes.width { f[x, y] = (0, 0, 0); f[x, Scenes.height - 1 - y] = (0, 0, 0) } }
            return f
        },
        LineCase(name: "grey column under green target", config: greenConfig, expectedEdge: nil) {
            Scenes.greyColumnOnLightPicture()
        },
        LineCase(name: "green line under white target", config: whiteConfig, expectedEdge: nil) {
            var f = Scenes.picture()
            f.drawEdgeLine(.left, color: Scenes.green)
            return f
        },
        LineCase(name: "clean textured picture", config: greenConfig, expectedEdge: nil) {
            Scenes.picture()
        },
        LineCase(name: "foliage touching the edge", config: greenConfig, expectedEdge: nil) {
            var f = Scenes.picture()
            Scenes.paintFoliage(&f, rows: (Scenes.height - 80)..<Scenes.height, columns: 0..<Scenes.width)
            Scenes.paintFoliage(&f, rows: 0..<Scenes.height, columns: 0..<60, seed: 9)
            return f
        },
        LineCase(name: "letterbox bars thicker than edge depth", config: blackConfig, expectedEdge: nil) {
            var f = Scenes.picture()
            for y in Array(0..<40) + Array((Scenes.height - 40)..<Scenes.height) {
                for x in 0..<Scenes.width { f[x, y] = (0, 0, 0) }
            }
            return f
        },
        LineCase(name: "sky gradient", config: whiteConfig, expectedEdge: nil) {
            var f = Scenes.picture()
            for y in 0..<(Scenes.height / 2) {
                for x in 0..<Scenes.width {
                    let t = Double(y) / Double(Scenes.height / 2)
                    f[x, y] = (246 - 70 * t, 249 - 50 * t, 253 - 20 * t)
                }
            }
            f.addNoise(sigma: 1.5, seed: 5, rows: 0..<(Scenes.height / 2))
            return f
        },
        LineCase(name: "sky gradient (green target)", config: greenConfig, expectedEdge: nil) {
            var f = Scenes.picture()
            for y in 0..<(Scenes.height / 2) {
                for x in 0..<Scenes.width {
                    let t = Double(y) / Double(Scenes.height / 2)
                    f[x, y] = (90 + 80 * t, 170 + 40 * t, 230 - 10 * t)
                }
            }
            return f
        },
        LineCase(name: "full black frame", config: blackConfig, expectedEdge: nil) { Scenes.solid(Scenes.black) },
        LineCase(name: "full white frame", config: whiteConfig, expectedEdge: nil) { Scenes.solid(Scenes.white) },
        LineCase(name: "full green frame", config: greenConfig, expectedEdge: nil) { Scenes.solid(Scenes.green) },
        LineCase(name: "dark scene with no line", config: blackConfig, expectedEdge: nil) { Scenes.darkPicture() }
    ]
}


extension LineCase {
    /// Lines of another colour: no target detection, but an off-colour one on this edge.
    static let offColor: [LineCase] = [
        LineCase(name: "grey column under green target", config: greenConfig, expectedEdge: .left) {
            Scenes.greyColumnOnLightPicture()
        },
    ]
}
