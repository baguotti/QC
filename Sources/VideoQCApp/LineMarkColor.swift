import CoreGraphics
import simd

/// The Player's line-mark outline colour: the palette colour furthest from both the picture next to the line and the
/// line itself, so a red box never sits on red footage. Sampled from a 32 px copy of the paused frame.
enum LineMarkColor {
    static let side = 32
    /// In order of preference: red wins ties (it reads as "problem").
    static let palette: [SIMD3<Double>] = [
        SIMD3(1, 0.27, 0.23), SIMD3(1, 0.84, 0.04), SIMD3(0.2, 0.85, 1), SIMD3(1, 0.25, 0.85), SIMD3(1, 1, 1)
    ]

    /// The first palette colour clearly apart (≥ 0.45 in RGB) from every colour to avoid, else the one furthest away.
    static func pick(avoiding colours: [SIMD3<Double>]) -> SIMD3<Double> {
        let scored = palette.map { candidate in (candidate, colours.map { simd_distance(candidate, $0) }.min() ?? 1) }
        return scored.first { $0.1 >= 0.45 }?.0 ?? scored.max { $0.1 < $1.1 }!.0
    }

    /// RGBA bytes of the image scaled to `side` × `side`, row 0 at the top.
    static func thumbnail(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Mean colour (0…1) of the thumbnail inside `rect` (unit square, origin top-left), at least one pixel.
    static func average(_ thumbnail: [UInt8], in rect: CGRect) -> SIMD3<Double> {
        let n = Double(side)
        let x0 = max(0, min(side - 1, Int((rect.minX * n).rounded(.down)))), x1 = max(x0, min(side - 1, Int((rect.maxX * n).rounded(.up)) - 1))
        let y0 = max(0, min(side - 1, Int((rect.minY * n).rounded(.down)))), y1 = max(y0, min(side - 1, Int((rect.maxY * n).rounded(.up)) - 1))
        var sum = SIMD3<Double>(0, 0, 0)
        for y in y0...y1 {
            for x in x0...x1 {
                let i = (y * side + x) * 4
                sum += SIMD3(Double(thumbnail[i]), Double(thumbnail[i + 1]), Double(thumbnail[i + 2]))
            }
        }
        return sum / (255 * Double((x1 - x0 + 1) * (y1 - y0 + 1)))
    }
}
