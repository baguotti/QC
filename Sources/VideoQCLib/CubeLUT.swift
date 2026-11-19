import Foundation
import CoreImage

/// A 3D LUT read from an Adobe / Resolve `.cube` file, ready for `CIColorCubeWithColorSpace`.
public struct CubeLUT: Sendable, Equatable {
    public let name: String
    public let size: Int
    /// RGBA Float32 values, red fastest (the `.cube` order, and Core Image's).
    public let data: Data

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notThreeD
        case noSize
        case hasShaper
        case badSize(Int)
        case unsupportedDomain
        case wrongCount(expected: Int, found: Int)
        case badLine(Int)

        public var description: String {
            switch self {
            case .notThreeD: return "Only 3D LUTs are supported (LUT_3D_SIZE)."
            case .noSize: return "No LUT_3D_SIZE line: this isn't a 3D .cube LUT."
            case .hasShaper: return "LUTs with a 1D shaper before the 3D table aren't supported: export the 3D LUT alone."
            case .badSize(let n): return "LUT_3D_SIZE \(n) is out of range (2–128)."
            case .unsupportedDomain: return "Only a 0–1 input range is supported (DOMAIN_MIN / DOMAIN_MAX)."
            case .wrongCount(let expected, let found): return "Expected \(expected) entries, found \(found)."
            case .badLine(let n): return "Line \(n) isn't three numbers."
            }
        }
    }

    public init(name: String, size: Int, data: Data) {
        self.name = name
        self.size = size
        self.data = data
    }

    public static func read(_ url: URL) throws -> CubeLUT {
        try parse(try Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    /// Parses bytes rather than lines of a `String`: a 65³ LUT is 275k lines.
    public static func parse(_ bytes: Data, name: String) throws -> CubeLUT {
        var size = 0
        var values: [Float] = []
        var lineNumber = 0
        var sawOneD = false
        var domainOK = true

        try bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buf = raw.bindMemory(to: UInt8.self)
            let n = buf.count
            // A UTF-8 byte-order mark (some Windows tools write one) isn't part of the first line.
            var i = n >= 3 && buf[0] == 0xEF && buf[1] == 0xBB && buf[2] == 0xBF ? 3 : 0
            while i < n {
                var end = i
                while end < n, buf[end] != 0x0A, buf[end] != 0x0D { end += 1 }
                lineNumber += 1
                defer {
                    i = end
                    if i < n, buf[i] == 0x0D { i += 1 }
                    if i < n, buf[i] == 0x0A { i += 1 }
                }
                var start = i
                while start < end, buf[start] == 0x20 || buf[start] == 0x09 { start += 1 }
                guard start < end, buf[start] != 0x23 else { continue }   // blank or '#'
                let first = buf[start]
                let isNumber = (first >= 0x30 && first <= 0x39) || first == 0x2D || first == 0x2B || first == 0x2E
                if !isNumber {
                    let line = String(decoding: UnsafeBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
                    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    switch parts.first.map({ $0.uppercased() }) {   // keywords are upper case by the spec; some tools don't
                    case "LUT_3D_SIZE":
                        guard parts.count >= 2, let s = Int(parts[1]) else { throw ReadError.badLine(lineNumber) }
                        guard (2...128).contains(s) else { throw ReadError.badSize(s) }
                        size = s
                        values.reserveCapacity(s * s * s * 3)
                    case "LUT_1D_SIZE":
                        sawOneD = true
                    case "DOMAIN_MIN":
                        domainOK = domainOK && parts.dropFirst().allSatisfy { Double($0) == 0 }
                    case "DOMAIN_MAX":
                        domainOK = domainOK && parts.dropFirst().allSatisfy { Double($0) == 1 }
                    default:
                        break   // TITLE, LUT_3D_INPUT_RANGE and other keywords
                    }
                    continue
                }
                var count = 0
                var p = start
                while p < end, count < 3 {
                    while p < end, buf[p] == 0x20 || buf[p] == 0x09 { p += 1 }
                    guard p < end else { break }
                    var q = p
                    while q < end, buf[q] != 0x20, buf[q] != 0x09 { q += 1 }
                    let token = String(decoding: UnsafeBufferPointer(rebasing: buf[p..<q]), as: UTF8.self)
                    guard let v = Float(token) else { throw ReadError.badLine(lineNumber) }
                    values.append(v)
                    count += 1
                    p = q
                }
                guard count == 3 else { throw ReadError.badLine(lineNumber) }
            }
        }
        guard size > 0 else { throw sawOneD ? ReadError.notThreeD : ReadError.noSize }
        guard !sawOneD else { throw ReadError.hasShaper }
        guard domainOK else { throw ReadError.unsupportedDomain }
        let expected = size * size * size
        guard values.count == expected * 3 else { throw ReadError.wrongCount(expected: expected, found: values.count / 3) }

        var rgba = [Float](repeating: 1, count: expected * 4)
        for e in 0..<expected {
            rgba[e * 4] = values[e * 3]
            rgba[e * 4 + 1] = values[e * 3 + 1]
            rgba[e * 4 + 2] = values[e * 3 + 2]
        }
        return CubeLUT(name: name, size: size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// For pictures without a colour space: video untagged is Rec. 709.
    static let fallbackSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
}

extension CIImage {
    /// The picture through `lut`, looked up on the file's own code values: Core Image converts its linear working
    /// values back to the image's colour space (the one it decoded from), so the cube sees what a grading app sees.
    /// Converting to a different 709 (`itur_709`) instead read CoreMedia's 709 values ~20 code values too bright.
    public func applyingLUT(_ lut: CubeLUT) -> CIImage {
        applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": lut.size,
            "inputCubeData": lut.data,
            "inputColorSpace": colorSpace ?? CubeLUT.fallbackSpace,
        ])
    }
}
