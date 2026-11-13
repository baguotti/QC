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
}
