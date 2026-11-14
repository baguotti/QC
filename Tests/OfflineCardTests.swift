import Testing
@testable import VideoQCLib

@Suite("Media Offline cards")
struct OfflineCardTests {
    /// 64 × 36 luma, 32 × 18 CbCr: a red field (optionally shaded), with a bright block when `ink` is set.
    private func look(shaded: Bool, ink: Bool) -> FrameLook {
        let w = 64, h = 36
        var luma = [UInt8](repeating: 45, count: w * h)
        var chroma = [UInt8](repeating: 0, count: (w / 2) * (h / 2) * 2)
        for y in 0..<h / 2 {
            for x in 0..<w / 2 {
                let shade = shaded ? x : 0
                chroma[(y * (w / 2) + x) * 2] = 110
                chroma[(y * (w / 2) + x) * 2 + 1] = UInt8(190 + shade)
                if shaded { for dy in 0..<2 { for dx in 0..<2 { luma[(2 * y + dy) * w + 2 * x + dx] = UInt8(30 + shade * 2) } } }
            }
        }
        if ink { for y in 10..<16 { for x in 10..<40 { luma[y * w + x] = 235 } } }
        return FrameLook.measure(luma: luma, chroma: chroma, width: w, height: h)
    }

    @Test("A flat red field with something bright on it looks like a card; shaded or plain red doesn't")
    func signature() {
        #expect(look(shaded: false, ink: true).isOffline)
        #expect(!look(shaded: true, ink: true).isOffline)
        #expect(!look(shaded: false, ink: false).isOffline)
    }

    @Test("The words decide: offline text confirms, other text is a title card, no text needs a still picture")
    func verdict() {
        #expect(FrameCheckAnalyzer.offlineDetail(text: "Media offline Média hors ligne", isStill: false) != nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: "MEDIA OFFLINE", isStill: true) != nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: "WINTER SALE 50% OFF", isStill: true) == nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: nil, isStill: true) != nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: "!", isStill: true) != nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: nil, isStill: false) == nil)
    }

    @Test("A run stands still when its frames barely change")
    func still() {
        let run = FrameCheckAnalyzer.offlineRuns([FrameLook](repeating: FrameLook(luma: 45, spread: 0, redShare: 0.9), count: 10), fps: 25)[0]
        #expect(FrameCheckAnalyzer.isStill(run, metrics: [StutterFrameMetrics](repeating: .init(motion: 0.1, blendRatio: nil), count: 10)))
        #expect(!FrameCheckAnalyzer.isStill(run, metrics: [StutterFrameMetrics](repeating: .init(motion: 6, blendRatio: nil), count: 10)))
    }
}
