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
}
