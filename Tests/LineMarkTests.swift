import Foundation
import Testing
import VideoQCLib
@testable import QCpie

/// Player line marks: Line Check's detections mapped onto the paused frame (layer origin bottom-left).
@Suite struct LineMarkTests {
    let picture = CGSize(width: 1920, height: 1080)
    let bounds = CGRect(x: 0, y: 0, width: 960, height: 540)
    func line(_ edge: EdgeLocation, _ thickness: Int, at position: Int? = nil) -> LineDetection {
        LineDetection(edge: edge, thickness: thickness, detectedColor: RGBColor(r: 0, g: 255, b: 0), spanRatio: 1, position: position)
    }

    @Test func edgesAndSeamsLandWhereTheLineIs() {
        let rects = PlayerContainerNSView.lineMarkRects(
            [line(.top, 4), line(.bottom, 2, at: 140), line(.right, 6), line(.splitVertical, 2, at: 960)],
            picture: picture, shown: picture, in: bounds, zoom: 1)
        // Unpadded: half size (960/1920), padded 2 pt each side.
        #expect(rects[0] == CGRect(x: 0, y: 540 - 2, width: 960, height: 2).insetBy(dx: -2, dy: -2))
        #expect(rects[1] == CGRect(x: 0, y: 70, width: 960, height: 1).insetBy(dx: -2, dy: -2))   // inside a 140 px bar
        #expect(rects[2] == CGRect(x: 960 - 3, y: 0, width: 3, height: 540).insetBy(dx: -2, dy: -2))
        #expect(rects[3] == CGRect(x: 480, y: 0, width: 1, height: 540).insetBy(dx: -2, dy: -2))
    }

    @Test func rotatedClipUsesOnScreenOrientation() {
        // Portrait on screen, landscape buffer: the seam column is measured across the 1080 px width.
        let tall = CGRect(x: 0, y: 0, width: 540, height: 960)
        let rects = PlayerContainerNSView.lineMarkRects([line(.splitVertical, 2, at: 540)], picture: picture,
                                                    shown: CGSize(width: 1080, height: 1920), in: tall, zoom: 2)
        #expect(rects[0] == CGRect(x: 270, y: 0, width: 1, height: 960).insetBy(dx: -1, dy: -1))
    }

    @Test func outlineColourAvoidsThePictureAndTheLine() {
        let red = SIMD3<Double>(0.9, 0.2, 0.2), green = SIMD3<Double>(0, 1, 0), grey = SIMD3<Double>(0.4, 0.4, 0.4)
        #expect(LineMarkColor.pick(avoiding: [green, grey]) == LineMarkColor.palette[0])   // red by default
        #expect(LineMarkColor.pick(avoiding: [green, red]) != LineMarkColor.palette[0])    // never red on red
        #expect(LineMarkColor.pick(avoiding: [SIMD3(1, 1, 1), SIMD3(1, 1, 1)]) != SIMD3(1, 1, 1))
    }

    @Test func averageReadsTheRegion() {
        var thumb = [UInt8](repeating: 0, count: LineMarkColor.side * LineMarkColor.side * 4)
        for i in stride(from: 0, to: LineMarkColor.side * 4, by: 4) { thumb[i] = 255 }   // top row red
        #expect(LineMarkColor.average(thumb, in: CGRect(x: 0, y: 0, width: 1, height: 0.02)) == SIMD3(1, 0, 0))
        #expect(LineMarkColor.average(thumb, in: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)) == SIMD3(0, 0, 0))
    }
}
