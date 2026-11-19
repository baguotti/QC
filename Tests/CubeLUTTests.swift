import CoreImage
import Foundation
import Testing
@testable import VideoQCLib

@Suite("Cube LUTs")
struct CubeLUTTests {
    private func floats(_ lut: CubeLUT) -> [Float] {
        lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    @Test func readsTitleCommentsAndCRLF() throws {
        let text = "# made by hand\r\nTITLE \"Test\"\r\nLUT_3D_SIZE 2\r\nDOMAIN_MIN 0 0 0\r\nDOMAIN_MAX 1 1 1\r\n\r\n"
            + "0 0 0\r\n1 0 0\r\n0 1 0\r\n1 1 0\r\n0 0 1\r\n1 0 1\r\n0 1 1\r\n1 1 1.0e0\r\n"
        let lut = try CubeLUT.parse(Data(text.utf8), name: "Test")
        #expect(lut.size == 2)
        let v = floats(lut)
        #expect(v.count == 32)
        #expect(Array(v[4..<8]) == [1, 0, 0, 1])   // red fastest, alpha 1
        #expect(Array(v[28..<32]) == [1, 1, 1, 1])
    }

    @Test func rejectsWhatItCannotShow() {
        #expect(throws: CubeLUT.ReadError.notThreeD) { try CubeLUT.parse(Data("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n".utf8), name: "x") }
        #expect(throws: CubeLUT.ReadError.wrongCount(expected: 8, found: 1)) { try CubeLUT.parse(Data("LUT_3D_SIZE 2\n0 0 0\n".utf8), name: "x") }
        #expect(throws: CubeLUT.ReadError.badLine(2)) { try CubeLUT.parse(Data("LUT_3D_SIZE 2\n0 0\n".utf8), name: "x") }
        #expect(throws: CubeLUT.ReadError.unsupportedDomain) {
            try CubeLUT.parse(Data(("LUT_3D_SIZE 2\nDOMAIN_MAX 2 2 2\n" + String(repeating: "0 0 0\n", count: 8)).utf8), name: "x")
        }
    }

    /// Files from other tools: a byte-order mark, lower-case keywords; a 1D shaper or no size says why.
    @Test func readsOtherToolsFilesAndExplainsTheRest() throws {
        let body = String(repeating: "0 0 0\n", count: 8)
        #expect(try CubeLUT.parse(Data(("\u{FEFF}LUT_3D_SIZE 2\n" + body).utf8), name: "x").size == 2)
        #expect(try CubeLUT.parse(Data(("lut_3d_size 2\n" + body).utf8), name: "x").size == 2)
        #expect(throws: CubeLUT.ReadError.hasShaper) {
            try CubeLUT.parse(Data(("LUT_1D_SIZE 2\n0 0 0\n1 1 1\nLUT_3D_SIZE 2\n" + body).utf8), name: "x")
        }
        #expect(throws: CubeLUT.ReadError.noSize) { try CubeLUT.parse(Data(body.utf8), name: "x") }
    }

    /// Every LUT shipped in the app reads (a broken one would only show up on users' Macs).
    @Test func everyBundledLUTReads() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/LUTs")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "cube" }
        #expect(files.count >= 2)
        for file in files { #expect(throws: Never.self) { _ = try CubeLUT.read(file) } }
    }

    /// The LUT bundled with the app parses whole (32³, ARRI LogC to Rec. 709: black stays black, white stays white).
    @Test func bundledLUTParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/LUTs/ALEXA_Default_LogC2Rec709.cube")
        let lut = try CubeLUT.read(url)
        #expect(lut.size == 32)
        #expect(lut.name == "ALEXA_Default_LogC2Rec709")
        let v = floats(lut)
        #expect(Array(v[0..<3]) == [0, 0, 0])
        #expect(Array(v[(v.count - 4)..<(v.count - 1)]) == [1, 1, 1])
    }

    /// The cube is looked up on the picture's own code values: a 709-tagged pixel comes out as the table says,
    /// not as Core Image's linear working values would index it.
    @Test func looksUpTheImagesOwnCodeValues() throws {
        // An inverting LUT: out = 1 - in, so 0.25 must read 0.75 in the same colour space.
        var text = "LUT_3D_SIZE 2\n"
        for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
        let lut = try CubeLUT.parse(Data(text.utf8), name: "invert")
        let space = try #require(CGColorSpace(name: CGColorSpace.itur_709))
        let pixel = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(CIContext().createCGImage(pixel, from: pixel.extent, format: .RGBAf, colorSpace: space))
        let out = CIImage(cgImage: image).applyingLUT(lut)
        var rgba = [Float](repeating: 0, count: 4)
        CIContext().render(out, toBitmap: &rgba, rowBytes: 16, bounds: out.extent, format: .RGBAf, colorSpace: space)
        #expect(abs(rgba[0] - 0.75) < 0.01)
    }
}
