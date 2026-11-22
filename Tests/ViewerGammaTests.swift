import Foundation
import CoreImage
import Testing
@testable import VideoQCLib

// Broadcast viewer gamma: light shown = code value ^ 2.4 (Premiere Pro / Resolve), not macOS's Rec.709 reading.
@Suite("Viewer gamma")
struct ViewerGammaTests {
    private let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    /// A grey pixel with code value `v` in `space`, as linear light after `transform`.
    private func light(_ v: Double, in space: CGColorSpace, _ transform: (CIImage) -> CIImage) -> Double {
        let byte = UInt8((v * 255).rounded())
        var pixel: [UInt8] = [byte, byte, byte, 255]
        let provider = CGDataProvider(data: Data(pixel) as CFData)!
        let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        pixel = []
        var out = [Float](repeating: 0, count: 4)
        context.render(transform(CIImage(cgImage: image)), toBitmap: &out, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linear)
        return Double(out[1])
    }

    @Test func broadcastShowsCodeValuesToThePower2_4() {
        let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
        for v in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let code = (v * 255).rounded() / 255
            let shown = light(v, in: rec709) { $0.applyingDisplayGamma(2.4, source: rec709) }
            #expect(abs(shown - pow(code, 2.4)) < 0.004, "code \(code): shown \(shown), expected \(pow(code, 2.4))")
        }
    }

    @Test func hdrAndOffAreUnchanged() {
        let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
        #expect(light(0.5, in: pq) { $0.applyingDisplayGamma(2.4, source: pq) } == light(0.5, in: pq) { $0 })
        #expect(light(0.5, in: rec709) { $0.applyingDisplayGamma(0, source: rec709) } == light(0.5, in: rec709) { $0 })
    }
}
