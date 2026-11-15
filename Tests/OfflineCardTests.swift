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

    @Test("Red with something bright on it is a candidate (flat or a gradient); plain red isn't; flatness is measured")
    func signature() {
        #expect(look(shaded: false, ink: true).isOffline)
        #expect(look(shaded: true, ink: true).isOffline)
        #expect(!look(shaded: false, ink: false).isOffline)
        #expect(look(shaded: false, ink: true).redFlatShare > look(shaded: true, ink: true).redFlatShare)
    }

    @Test("The words decide: offline text confirms, other text is a title card, no text needs a flat, still picture")
    func verdict() {
        #expect(FrameCheckAnalyzer.offlineDetail(text: "Media offline Média hors ligne", isStill: false, isFlat: false) != nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: "MEDIA OFFLINE", isStill: true, isFlat: false) != nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: "WINTER SALE 50% OFF", isStill: true, isFlat: true) == nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: nil, isStill: true, isFlat: true) != nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: "!", isStill: true, isFlat: true) != nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: nil, isStill: false, isFlat: true) == nil)
        #expect(FrameCheckAnalyzer.offlineDetail(text: nil, isStill: true, isFlat: false) == nil)
    }

    @Test("A run stands still when its frames barely change")
    func still() {
        let run = FrameCheckAnalyzer.offlineRuns([FrameLook](repeating: FrameLook(luma: 45, spread: 0, redShare: 0.9), count: 10), fps: 25)[0]
        #expect(FrameCheckAnalyzer.isStill(run, metrics: [StutterFrameMetrics](repeating: .init(motion: 0.1, blendRatio: nil), count: 10)))
        #expect(!FrameCheckAnalyzer.isStill(run, metrics: [StutterFrameMetrics](repeating: .init(motion: 6, blendRatio: nil), count: 10)))
    }

    @Test("Stray frames: another picture inside a steady shot; not a flash on the same picture, a new shot, or a wild picture")
    func stray() {
        func flagged(_ s: StrayFrames) -> Bool {
            var m = [StutterFrameMetrics](repeating: .init(motion: 1, blendRatio: nil), count: 20)
            m[10].stray = s
            return !FrameCheckAnalyzer.strayFrames(m, fps: 25).isEmpty
        }
        #expect(flagged(StrayFrames(count: 1, continuity: 1, expected: 1, likeness: 0.39)))       // offline card in a slow shot
        #expect(flagged(StrayFrames(count: 2, continuity: 0.85, expected: 0.9, likeness: 0.1)))
        #expect(!flagged(StrayFrames(count: 1, continuity: 1, expected: 1, likeness: 0.9)))       // camera flash
        #expect(!flagged(StrayFrames(count: 2, continuity: 0.57, expected: 1, likeness: -0.05)))  // light leak into a new shot
        #expect(!flagged(StrayFrames(count: 3, continuity: 0.8, expected: -0.28, likeness: 0.19)))   // spinning shot
        #expect(!flagged(StrayFrames(count: 4, continuity: 1, expected: 1, likeness: 0)))         // too long at 25 fps
        #expect(!flagged(StrayFrames(count: 1, continuity: 0.58, expected: 0.65, likeness: 0.08, lead: 0.65)))   // shake transition's smear
    }

    @Test("Held pictures are found by their unchanged frames, longest first")
    func held() {
        var m = [StutterFrameMetrics](repeating: .init(motion: 5, blendRatio: nil), count: 100)
        for i in 21..<30 { m[i].motion = 0 }
        for i in 61..<90 { m[i].motion = 0.1 }
        m[50].motion = 0   // one repeated frame is no hold
        let runs = FrameCheckAnalyzer.heldRuns(m, fps: 25)
        #expect(runs.map(\.start) == [60, 20])
        #expect(runs.map(\.count) == [30, 10])
    }
}
