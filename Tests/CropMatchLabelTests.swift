import Testing
@testable import QCpie

@Suite("Crop Match labels") @MainActor
struct CropMatchLabelTests {
    @Test("Version labels drop what all the names share, at a word boundary")
    func labels() {
        let labels = CropMatchReport.shortLabels(["Spot_16x9_15sec.mp4", "Spot_16x9_10sec.mp4", "Spot_16x9_06sec.mp4"])
        #expect(labels["Spot_16x9_15sec.mp4"] == "15sec")
        #expect(labels["Spot_16x9_06sec.mp4"] == "06sec")
        let odd = CropMatchReport.shortLabels(["Hero master v3.mov", "Hero cut 15 v3.mov"])
        #expect(odd["Hero master v3.mov"] == "master")
        #expect(odd["Hero cut 15 v3.mov"] == "cut 15")
    }
}
