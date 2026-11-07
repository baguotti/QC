import Foundation
import AVFoundation
import Testing
@testable import QCpie

// Thumbnails decode in parallel: a Line Check frame asked for while a hover skims the same file must still be the exact
// frame (skim and poster requests use keyframe tolerance). Uses a local `_TEST` clip; skipped without it.
@Suite("Thumbnail provider")
struct ThumbnailProviderTests {
    @Test func exactFramesStayExactWhileSkimming() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("_TEST")
        let file = root.appendingPathComponent("LNEH_ROUGHCUT_24fps_E1.4.mp4")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let size = CGSize(width: 320, height: 180)
        func bytes(_ i: CGImage) -> Data { (i.dataProvider?.data as Data?) ?? Data() }
        let ref = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        ref.appliesPreferredTrackTransform = true; ref.maximumSize = size
        ref.requestedTimeToleranceBefore = .zero; ref.requestedTimeToleranceAfter = .zero
        let provider = GlitchThumbnailProvider()
        var mismatches = 0
        let frames = [13, 37, 61, 90, 117, 140]
        let results = await withTaskGroup(of: (Int, CGImage?).self) { g in
            for i in 0..<30 { g.addTask { (-1, await provider.getThumbnail(for: file, frameIndex: i * 5 + 1, fps: 24, targetSize: size, fast: true, cache: false)) } }
            for f in frames { g.addTask { (f, await provider.getThumbnail(for: file, frameIndex: f, fps: 24, targetSize: size)) } }
            var out: [(Int, CGImage?)] = []
            for await r in g where r.0 >= 0 { out.append(r) }
            return out
        }
        for (f, img) in results {
            let expected = try ref.copyCGImage(at: CMTime(seconds: (Double(f) + 0.5) / 24, preferredTimescale: 60000), actualTime: nil)
            if img.map(bytes) != bytes(expected) { mismatches += 1 }
        }
        print("checked", results.count, "mismatches", mismatches)
        #expect(mismatches == 0)
    }
}
