import Foundation
import Testing
@testable import QCpie

@Suite("Subtitle attachments: many files at once", .serialized)
struct SubtitleAttachmentBatchTests {
    @Test("resolveAll finds what resolve finds: sidecars, language suffixes, loose names, manual attachments") @MainActor
    func batchMatchesSingle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srt-batch-\(UUID().uuidString)")
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["A.mov", "B.mp4", "Clip 4 - Hero.mov", "D.mov", "E.mov"]
        for name in names { try Data().write(to: folder.appendingPathComponent(name)) }
        for srt in ["a.srt", "B.en.srt", "Clip 4 | Hero.srt"] { try Data().write(to: folder.appendingPathComponent(srt)) }
        let attached = other.appendingPathComponent("for-e.srt")
        try Data().write(to: attached)
        let e = folder.appendingPathComponent("E.mov")
        SubtitleAttachments.setManual(attached, for: e)
        defer { SubtitleAttachments.setManual(nil, for: e) }
        let videos = names.map { folder.appendingPathComponent($0) }
        let batch = SubtitleAttachments.resolveAll(videos)
        for video in videos {
            #expect(batch[video.standardizedFileURL]?.standardizedFileURL == SubtitleAttachments.resolve(for: video)?.standardizedFileURL,
                    "\(video.lastPathComponent)")
        }
        #expect(batch.count == 4 && batch[folder.appendingPathComponent("D.mov").standardizedFileURL] == nil)
    }

    // `Spot.v2.srt` belongs to `Spot.v2.mov`, not `Spot.mov`; `Spot.en.srt` is Spot's English subtitles.
    @Test func anotherClipsSubtitlesAreNotALanguageSuffix() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("srt-suffix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["Spot.mov", "Spot.v2.mov", "Spot.v2.srt", "Promo.mov", "Promo.final.mov", "Promo.final.srt", "Cut.mov", "Cut.pt-BR.srt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        #expect(SubtitleAttachments.sidecar(for: folder.appendingPathComponent("Spot.mov")) == nil)
        #expect(SubtitleAttachments.sidecar(for: folder.appendingPathComponent("Spot.v2.mov"))?.lastPathComponent == "Spot.v2.srt")
        #expect(SubtitleAttachments.sidecar(for: folder.appendingPathComponent("Promo.mov")) == nil)
        #expect(SubtitleAttachments.sidecar(for: folder.appendingPathComponent("Cut.mov"))?.lastPathComponent == "Cut.pt-BR.srt")
    }
}
