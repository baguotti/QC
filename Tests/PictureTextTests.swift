import Foundation
import Testing
@testable import VideoQCLib
@testable import QCpie

@Suite("Inspect: subs and graphics in the picture", .serialized)
struct PictureTextTests {
    typealias O = PictureTextScanner.Observation
    typealias S = PictureTextScanner.Sample

    static func bottom(_ text: String) -> O { O(text: text, box: CGRect(x: 0.3, y: 0.08, width: 0.4, height: 0.05)) }
    static func centre(_ text: String, height: CGFloat = 0.06) -> O { O(text: text, box: CGRect(x: 0.35, y: 0.47, width: 0.3, height: height)) }

    @Test("Changing lower-centre text is subtitles; the rest is graphics")
    func subtitlesAndGraphics() {
        let samples = [S(time: 0, observations: [Self.centre("BRAND")]),
                       S(time: 0.5, observations: [Self.centre("BRAND"), Self.bottom("When I was a child")]),
                       S(time: 1, observations: [Self.bottom("When I was a child")]),
                       S(time: 1.5, observations: [Self.bottom("we had a neighbour")]),
                       S(time: 2, observations: [Self.bottom("his mother was ill")])]
        let r = PictureTextScanner.classify(samples)
        #expect(r.subtitlesLikely && !r.isClean)
        #expect(r.graphics.map(\.text) == ["BRAND"] && r.graphics[0].start == 0 && r.graphics[0].end == 1)
        #expect(r.subtitleExamples.first?.text == "When I was a child")
    }

    @Test("One constant line at the bottom (a tagline) is a graphic, not subtitles")
    func constantBottomLine() {
        let samples = (0..<6).map { S(time: Double($0) * 0.5, observations: [Self.bottom("www.brand.com")]) }
        let r = PictureTextScanner.classify(samples)
        #expect(!r.subtitlesLikely && r.graphics.map(\.text) == ["www.brand.com"])
    }

    @Test("Lower-third name supers off-centre aren't subtitles")
    func lowerThirds() {
        let left = { (t: String) in O(text: t, box: CGRect(x: 0.05, y: 0.1, width: 0.25, height: 0.04)) }
        let samples = [S(time: 0, observations: [left("Jane Doe")]), S(time: 0.5, observations: [left("Jane Doe")]),
                       S(time: 1, observations: [left("John Roe")]), S(time: 1.5, observations: [left("John Roe")])]
        let r = PictureTextScanner.classify(samples)
        #expect(!r.subtitlesLikely && r.graphics.count == 2)
    }

    @Test("Small or one-sample text is ignored unless it's big (a short end logo)")
    func filters() {
        let tiny = O(text: "small print", box: CGRect(x: 0.4, y: 0.5, width: 0.1, height: 0.01))
        let flash = Self.centre("flash", height: 0.03)
        let endLogo = Self.centre("LOGO", height: 0.08)
        let r = PictureTextScanner.classify([S(time: 0, observations: [tiny, tiny]), S(time: 0.5, observations: [tiny]),
                                             S(time: 3, observations: [flash]), S(time: 5.9, observations: [endLogo])])
        #expect(r.graphics.map(\.text) == ["LOGO"])
        #expect(PictureTextScanner.classify([]).isClean)
    }

    @Test("File names: CLEAN / TITLED / SUBS promises and mismatches")
    func names() {
        #expect(PictureTextCheck.promises(inName: "CK_FA26_HOME_30Sec_16x9_E6.0_CLEAN.mp4") == [.clean])
        #expect(PictureTextCheck.promises(inName: "PEARL 26_SOCIAL_3_9x16_logo.mp4") == [.titled])
        #expect(PictureTextCheck.promises(inName: "Spot_FR_SUBS_v2.mov") == [.subtitled])
        #expect(PictureTextCheck.promises(inName: "Cleaning_Products_30s.mov").isEmpty)   // CLEANING isn't CLEAN
        let titled = PictureTextCheck(subtitlesLikely: false, graphics: [.init(text: "BRAND", start: 0, end: 1)])
        let clean = PictureTextCheck(subtitlesLikely: false)
        let subbed = PictureTextCheck(subtitlesLikely: true)
        #expect(titled.nameMismatches(for: "x_CLEAN.mov") == ["Named CLEAN but shows text graphics"])
        #expect(subbed.nameMismatches(for: "x_CLEAN.mov") == ["Named CLEAN but shows subtitles"])
        #expect(clean.nameMismatches(for: "x_CLEAN.mov").isEmpty)
        #expect(clean.nameMismatches(for: "x_TITLED.mov").count == 1 && clean.nameMismatches(for: "x_SUBS.mov").count == 1)
        #expect(clean.nameMismatches(for: "x_16x9.mov").isEmpty)
        #expect(PictureTextCheck.unreadable.nameMismatches(for: "x_CLEAN.mov").isEmpty && !PictureTextCheck.unreadable.isClean)
    }

    @Test("Generated clips: subtitles, a centre title, a clean picture, an unreadable file")
    func endToEnd() async throws {
        let subs = try BurnedSubtitleTests.makeClip([(from: 0, to: 30, text: "The first line of dialogue"),
                                                     (from: 30, to: 60, text: "and then another one follows"),
                                                     (from: 60, to: 90, text: "and a third to be sure")], frames: 100)
        var style = BurnedSubtitleTests.Style(); style.fontSize = 60; style.top = true
        let titled = try BurnedSubtitleTests.makeClip([(from: 20, to: 80, text: "BIG TITLE")], frames: 100, style: style)
        let clean = try BurnedSubtitleTests.makeClip([], frames: 60)
        defer { [subs, titled, clean].forEach { try? FileManager.default.removeItem(at: $0) } }
        let s = await PictureTextScanner.check(subs)
        #expect(s.subtitlesLikely && s.graphics.isEmpty)
        let t = await PictureTextScanner.check(titled)
        #expect(!t.subtitlesLikely && t.graphics.map(\.text) == ["BIG TITLE"])
        #expect((t.graphics.first?.start ?? 9) <= 1.0)
        #expect(await PictureTextScanner.check(clean).isClean)
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-video-\(UUID().uuidString).mov")
        try Data("nope".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        #expect(await PictureTextScanner.check(bogus).isUnreadable)
    }

    @Test("A batch reports every file once and stops when cancelled")
    func batch() async throws {
        let a = try BurnedSubtitleTests.makeClip([], frames: 30), b = try BurnedSubtitleTests.makeClip([], frames: 30)
        let c = try BurnedSubtitleTests.makeClip([], frames: 30)
        defer { [a, b, c].forEach { try? FileManager.default.removeItem(at: $0) } }
        let seen = Seen()
        await PictureTextScanner.checkBatch(urls: [a, b, c], isCancelled: { false }) { url, _, done in seen.add(url, done) }
        #expect(seen.urls == Set([a, b, c]) && seen.maxDone == 3)
        let none = Seen()
        await PictureTextScanner.checkBatch(urls: [a, b, c], isCancelled: { true }) { url, _, done in none.add(url, done) }
        #expect(none.urls.isEmpty)
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls = Set<URL>()
        private(set) var maxDone = 0
        func add(_ url: URL, _ done: Int) { lock.withLock { urls.insert(url); maxDone = max(maxDone, done) } }
    }
}

extension PictureTextTests {
    @Test("Names: NO_LOGO / NO TEXT / NO_SUBS are negations; more subtitle words; contradictory names say nothing")
    func negations() {
        #expect(PictureTextCheck.promises(inName: "SPOT_30s_NO_LOGO.mov").isEmpty)
        #expect(PictureTextCheck.promises(inName: "SPOT_30s_NO_TEXT.mov") == [.clean])
        #expect(PictureTextCheck.promises(inName: "SPOT NO SUBS 16x9.mp4").isEmpty)
        #expect(PictureTextCheck.promises(inName: "Spot_EN_SUBTITLES.mov") == [.subtitled])
        #expect(PictureTextCheck.promises(inName: "Spot_FR_SUB.mov") == [.subtitled])
        #expect(PictureTextCheck.promises(inName: "Spot_CLEAN_SUBS.mov").isEmpty)
        #expect(PictureTextCheck.promises(inName: "Spot_TITLED_SUBS.mov") == [.titled, .subtitled])
        #expect(PictureTextCheck.promises(inName: "Subway_Ad.mov").isEmpty)
        let logo = PictureTextCheck(subtitlesLikely: false, graphics: [.init(text: "BRAND", start: 0, end: 1)])
        #expect(logo.nameMismatches(for: "SPOT_NO_LOGO.mov").isEmpty)   // only text-free promises are checked
        #expect(PictureTextCheck.unavailable.nameMismatches(for: "x_CLEAN.mp3").isEmpty && !PictureTextCheck.unavailable.isClean)
    }

    @Test("Portrait social captions sit higher and still count; a credits roll isn't subtitles")
    func portraitAndCredits() {
        let high = { (t: String) in O(text: t, box: CGRect(x: 0.2, y: 0.36, width: 0.6, height: 0.03)) }
        let captions = [S(time: 0, observations: [high("so today we try")]), S(time: 0.5, observations: [high("the new collection")]),
                        S(time: 1, observations: [high("and it is great")])]
        #expect(PictureTextScanner.classify(captions, aspect: 9.0 / 16.0).subtitlesLikely)
        #expect(!PictureTextScanner.classify(captions, aspect: 16.0 / 9.0).subtitlesLikely)
        let roll = (0..<8).map { i in
            S(time: Double(i) * 0.5, observations: (0..<5).map { j in
                O(text: "Credit \(i * 5 + j) Name Surname", box: CGRect(x: 0.35, y: 0.05 + Double(j) * 0.06, width: 0.3, height: 0.04))
            })
        }
        let credits = PictureTextScanner.classify(roll)
        #expect(!credits.subtitlesLikely && credits.hasGraphics)
    }

    @Test("Generated: audio-only, a still, a folder are unavailable; a cut-short video is unreadable")
    func unavailableAndCutShort() async throws {
        let clip = try BurnedSubtitleTests.makeClip([(from: 0, to: 250, text: "Long subtitle")], frames: 250)
        defer { try? FileManager.default.removeItem(at: clip) }
        let data = try Data(contentsOf: clip)
        let cut = FileManager.default.temporaryDirectory.appendingPathComponent("cut-\(UUID().uuidString).mov")
        // Keep the header and the start: a .mov from AVAssetWriter has its index at the end, so cut the middle out.
        try data.write(to: cut)
        defer { try? FileManager.default.removeItem(at: cut) }
        let handle = try FileHandle(forWritingTo: cut)
        try handle.seek(toOffset: UInt64(data.count / 3))
        try handle.write(contentsOf: Data(repeating: 0, count: data.count / 3))
        try handle.close()
        let damaged = await PictureTextScanner.check(cut)
        #expect(damaged.isUnreadable || damaged.subtitlesLikely == false && !damaged.isClean, "\(damaged)")
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }
        #expect(await PictureTextScanner.check(png).isUnavailable)
        #expect(await PictureTextScanner.check(FileManager.default.temporaryDirectory).isUnavailable)
        #expect(await PictureTextScanner.check(URL(fileURLWithPath: "/nonexistent/x.mov")).isUnreadable)
    }
}

extension PictureTextTests {
    @Test("A picture-text mismatch counts as the row's mismatch and reaches the export notes")
    func rowMismatchAndExport() {
        var asset = DeliverableAsset(fileURL: URL(fileURLWithPath: "/tmp/Spot_CLEAN.mov"), fileName: "Spot_CLEAN.mov", fileSizeBytes: 1,
                                     formattedFileSize: "1 B", width: 1920, height: 1080, resolutionString: "1920x1080",
                                     aspectRatioString: "16:9", durationSeconds: 10, formattedDuration: "10s", totalFrames: 250,
                                     timecode: "00:00:10:00", fps: 25, videoCodec: "H.264", audioConfig: "NONE", container: "MOV")
        #expect(!asset.hasAnyNameMismatch && asset.notesWithPictureText == asset.validation.summaryString)
        asset.pictureText = PictureTextCheck(subtitlesLikely: false, graphics: [.init(text: "BRAND", start: 8, end: 10)])
        #expect(asset.hasAnyNameMismatch && asset.notesWithPictureText == "Named CLEAN but shows text graphics")
        let csv = DeliverablesInspector.generateManifestCSV(assets: [asset])
        #expect(csv.contains("MISMATCH FLAGGED") && csv.contains("TEXT: BRAND (MISMATCH: Named CLEAN but shows text graphics)"))
        asset.pictureText = PictureTextCheck(subtitlesLikely: false)
        #expect(!asset.hasAnyNameMismatch && DeliverablesInspector.generateManifestCSV(assets: [asset]).contains("CLEAN"))
    }
}

extension PictureTextTests {
    @Test("Logo text on a product (narrow, tall boxes) in a 9x16 social isn't subtitles")
    func productText() {
        // Read from PEARL 26_SOCIAL_4_9x16_Logo.mp4: the logo printed on the shoe, seen as tall narrow boxes.
        let tall = { (t: String, x: Double) in O(text: t, box: CGRect(x: x - 0.03, y: 0.40, width: 0.06, height: 0.08)) }
        let samples = [S(time: 0.5, observations: [tall("JIMMY CHOO", 0.57), tall("NOGNO1", 0.56)]),
                       S(time: 1, observations: [tall("JMMY", 0.63), tall("CHOO", 0.59), tall("LONDON", 0.60)]),
                       S(time: 4, observations: [tall("JIMMY CHOO", 0.45), tall("LONDON", 0.44)]),
                       S(time: 5, observations: [tall("JMMY CHOO", 0.54), tall("NOGNO1", 0.52)])]
        #expect(!PictureTextScanner.classify(samples, aspect: 9.0 / 16.0).subtitlesLikely)
    }
}
