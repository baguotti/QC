import Foundation
import CoreVideo
import os
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
        // A language beside CLEAN asks for subtitles: CLEAN only rules out logos and titles there.
        #expect(subbed.nameMismatches(for: "SS27_TEASER_15s_16x9_EN_CLEAN_KL01002.mp4").isEmpty)
        #expect(titled.nameMismatches(for: "SS27_TEASER_15s_16x9_EN_CLEAN_KL01002.mp4") == ["Named CLEAN but shows text graphics"])
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

extension PictureTextTests {
    @Test("Timeline marks: a result's graphics by file, sorted; a clean result removes them") @MainActor
    func timelineMarks() {
        let url = URL(fileURLWithPath: "/tmp/marks/../marks/Spot.mov")
        PictureTextMarks.shared.set(PictureTextCheck(subtitlesLikely: false, graphics: [.init(text: "END", start: 9, end: 10),
                                                                                         .init(text: "TITLE", start: 1, end: 3)]), for: url)
        #expect(PictureTextMarks.shared.byURL[URL(fileURLWithPath: "/tmp/marks/Spot.mov")]?.map(\.text) == ["TITLE", "END"])
        PictureTextMarks.shared.set(PictureTextCheck(subtitlesLikely: false), for: url)
        #expect(PictureTextMarks.shared.byURL[URL(fileURLWithPath: "/tmp/marks/Spot.mov")] == nil)
    }
}

extension PictureTextTests {
    @Test("One subtitle line that comes back later is subtitles; a short tagline or a constant line isn't")
    func repeatedLine() {
        // As read from CK_HOME26_30sec_16x9_E3.0.mp4: the same line at 8.5–11 s and again at 20.5–23 s.
        let line = "I see subs here est test test"
        let times = [8.5, 9, 9.5, 10, 10.5, 11, 20.5, 21, 21.5, 22, 22.5, 23]
        let samples = times.map { S(time: $0, observations: [O(text: line, box: CGRect(x: 0.28, y: 0.1, width: 0.44, height: 0.044))]) }
        let r = PictureTextScanner.classify(samples)
        #expect(r.subtitlesLikely && r.graphics.isEmpty)
        let tagline = [0.0, 0.5, 1, 9, 9.5, 10].map { S(time: $0, observations: [Self.bottom("Just do it")]) }
        #expect(!PictureTextScanner.classify(tagline).subtitlesLikely)
        let constant = (0..<20).map { S(time: Double($0) * 0.5, observations: [Self.bottom("This line stays on screen throughout")]) }
        #expect(!PictureTextScanner.classify(constant).subtitlesLikely)
    }
}

extension PictureTextTests {
    static func card(_ text: String, x: CGFloat = 0.4, y: CGFloat = 0.5, height: CGFloat = 0.04) -> O {
        O(text: text, box: CGRect(x: x, y: y, width: 0.2, height: height))
    }

    @Test("Each appearance is its own graphic: a logo at the start and again at the end gives two markers")
    func appearances() {
        // As read from CK_HOME26_30sec_1x1_E3.0.mp4.
        let times = [0.0, 0.5, 1, 1.5, 2, 2.5, 28, 28.5, 29, 29.5, 30]
        let r = PictureTextScanner.classify(times.map { S(time: $0, observations: [Self.card("Calvin Klein")]) })
        #expect(r.graphics.map(\.start) == [0, 28] && r.graphicTexts == ["Calvin Klein"])
    }

    @Test("A title card's words are one graphic; every card counts (no cap of five); fragments and transitions drop out")
    func cards() {
        // As read from the adidas MOVER SHAKER spot: an opening title, a product card, an end card.
        var samples: [S] = [1.0, 1.5, 2.0].map { S(time: $0, observations: [Self.card("GEN ZEN")]) }
        let product = ["MOVER", "SHAKER", "ADIDAS VIBES", "SMOKY", "VANILLA", "BOURBON", "SANDALWOOD"]
        samples += [3.0, 3.5, 4.0, 4.5, 5.0, 5.5].map { t in
            S(time: t, observations: product.enumerated().map { Self.card($1, y: 0.2 + CGFloat($0) * 0.08) })
        }
        samples.append(S(time: 6.0, observations: [Self.card("FRA"), Self.card("VIBES"), Self.card("OLLECTION")]))   // wipe
        samples += [6.5, 7.0, 7.5].map { S(time: $0, observations: [Self.card("ADIDAS VIBES"), Self.card("FRAGRANCE COLLECTION", y: 0.4)]) }
        let r = PictureTextScanner.classify(samples)
        #expect(r.graphics.map(\.start) == [1.0, 3.0, 6.0])   // the end card from the wipe that brings it in
        #expect(r.graphics[1].text.components(separatedBy: " · ").count == 6)   // six readings at most per card
        #expect(!r.graphicTexts.contains("FRA") && !r.graphicTexts.contains("VIBES") && !r.graphicTexts.contains("OLLECTION"))
        #expect(r.graphicTexts.contains("FRAGRANCE COLLECTION") && r.graphicTexts.contains("GEN ZEN"))
    }

    @Test("A sideways one-off misread at the edge isn't a graphic; a lone big end logo is")
    func sideways() {
        let edge = O(text: "io Klein", box: CGRect(x: 0, y: 0.1, width: 0.08, height: 0.26))
        #expect(!PictureTextScanner.classify([S(time: 12, observations: [edge])]).hasGraphics)
        let end = Self.card("BRAND", height: 0.08)
        #expect(PictureTextScanner.classify([S(time: 9.9, observations: [end])]).graphics.map(\.text) == ["BRAND"])
    }

    @Test("Misread copies of a name keep the fuller reading")
    func fullerReading() {
        let reads = ["JMMY CHOO", "JIMMY CHOO", "UMMY CHOO", "JIMMY CHOO"]
        let r = PictureTextScanner.classify(reads.enumerated().map { S(time: Double($0) * 0.5, observations: [Self.card($1)]) })
        #expect(r.graphicTexts == ["JIMMY CHOO"])
    }
}

extension PictureTextTests {
    @Test("A title typing itself out is one graphic with its full text")
    func typewriter() {
        let steps = ["BIG", "BIG BA", "BIG BANG", "BIG BANG EN", "BIG BANG ENERGY", "BIG BANG ENERGY"]
        let r = PictureTextScanner.classify(steps.enumerated().map { S(time: 0.5 + Double($0) * 0.5, observations: [Self.card($1)]) })
        #expect(r.graphics.count == 1 && r.graphics.first?.text == "BIG BANG ENERGY" && r.graphics.first?.start == 0.5)
    }

    @Test("A corner logo all through doesn't glue the titles together: each keeps its marker")
    func cornerBug() {
        let samples: [S] = (0..<60).map { i in
            let t = Double(i) * 0.5
            var o = [Self.card("BRAND", x: 0.85, y: 0.9, height: 0.03)]
            if (4...8).contains(t) { o.append(Self.card("FIRST TITLE")) }
            if (20...24).contains(t) { o.append(Self.card("SECOND TITLE")) }
            return S(time: t, observations: o)
        }
        let r = PictureTextScanner.classify(samples)
        #expect(r.graphics.map(\.start) == [0, 4, 20])
        #expect(r.graphics.map(\.text) == ["BRAND", "FIRST TITLE", "SECOND TITLE"])
    }

    @Test("Related readings: close matches and text inside text; short words don't count")
    func related() {
        #expect(PictureTextScanner.related("BIG BANG", "BIG BANG ENERGY"))
        #expect(PictureTextScanner.related("JMMY CHOO", "JIMMY CHOO"))
        #expect(!PictureTextScanner.related("SUMMER SALE", "SUMMER COLLECTION"))
        #expect(!PictureTextScanner.related("AB", "ABOUT US"))
    }

    @Test("Re-reading a file in Inspect drops its old Player markers") @MainActor
    func marksCleared() {
        let url = URL(fileURLWithPath: "/tmp/marks-cleared/Spot.mov")
        PictureTextMarks.shared.set(PictureTextCheck(subtitlesLikely: false, graphics: [.init(text: "T", start: 1, end: 2)]), for: url)
        PictureTextMarks.shared.clear([URL(fileURLWithPath: "/tmp/marks-cleared/../marks-cleared/Spot.mov")])
        #expect(PictureTextMarks.shared.byURL[url] == nil)
    }
}

extension PictureTextTests {
    @Test("Text building up on a card stays one graphic; a new card sharing one word is another")
    func buildUp() {
        let base = ["MOVER", "SHAKER", "ADIDAS VIBES"]
        var samples: [S] = [3.0, 3.5].map { S(time: $0, observations: base.map { Self.card($0) }) }
        samples += [4.0, 4.5, 5.0, 5.5].map { S(time: $0, observations: (base + ["SMOKY", "VANILLA", "BOURBON"]).map { Self.card($0) }) }
        samples += [6.0, 6.5, 7.0].map { S(time: $0, observations: [Self.card("ADIDAS VIBES"), Self.card("FRAGRANCE COLLECTION")]) }
        let r = PictureTextScanner.classify(samples)
        #expect(r.graphics.map(\.start) == [3.0, 6.0])
    }
}

extension PictureTextTests {
    @Test("Not a Graphic hides a text in every appearance, empties the CLEAN mismatch, and comes back on restore")
    func notAGraphic() {
        var check = PictureTextCheck(subtitlesLikely: false, graphics: [
            .init(text: "JIMMI · CHOC", start: 3, end: 4), .init(text: "SALE · JIMMI", start: 8, end: 9)])
        #expect(!check.nameMismatches(for: "Spot_CLEAN.mov").isEmpty)
        check.dismissed = PictureTextCheck.dismissKeys(for: check.allGraphics[0])
        #expect(check.graphics.map(\.text) == ["SALE"] && check.graphicTexts == ["SALE"])
        check.dismissed.insert(BurnedSubtitleReader.normalise("SALE"))
        #expect(check.graphics.isEmpty && check.isClean && check.nameMismatches(for: "Spot_CLEAN.mov").isEmpty)
        check.dismissed = []
        #expect(check.graphics.count == 2)
    }

    @Test("Subs label says how many different lines; classify counts them")
    func lineCount() {
        let samples = ["one line here", "a second line", "a third line now"].enumerated()
            .map { S(time: Double($0) * 0.5, observations: [Self.bottom($1)]) }
        let r = PictureTextScanner.classify(samples)
        #expect(r.subtitleLineCount == 3 && r.subsLabel == "LIKELY (3 lines)")
        #expect(PictureTextCheck(subtitlesLikely: false).subsLabel == "NONE")
    }

    @Test("Inspect: Not a Graphic is saved per file, applied to the row and its markers; the chips filter and count") @MainActor
    func inspectState() {
        let state = SpecsState()
        let url = URL(fileURLWithPath: "/tmp/notagraphic-\(UUID().uuidString)/Spot_CLEAN.mov")
        func asset(_ name: String, _ check: PictureTextCheck?) -> DeliverableAsset {
            var a = DeliverableAsset(fileURL: url.deletingLastPathComponent().appendingPathComponent(name), fileName: name, fileSizeBytes: 1,
                                     formattedFileSize: "1 B", width: 1920, height: 1080, resolutionString: "1920x1080", aspectRatioString: "16:9",
                                     durationSeconds: 10, formattedDuration: "10s", totalFrames: 250, timecode: "00:00:10:00", fps: 25,
                                     videoCodec: "H.264", audioConfig: "NONE", container: "MOV")
            a.pictureText = check
            return a
        }
        let logo = PictureTextCheck.Sighting(text: "BRAND", start: 1, end: 2)
        state.deliverableAssets = [asset("Spot_CLEAN.mov", PictureTextCheck(subtitlesLikely: false, graphics: [logo])),
                                   asset("Spot_SUBS.mov", PictureTextCheck(subtitlesLikely: true, subtitleLineCount: 4)),
                                   asset("Other.mov", PictureTextCheck(subtitlesLikely: false)),
                                   asset("Unchecked.mov", nil)]
        #expect(state.pictureTextCounts[.all] == 3 && state.pictureTextCounts[.mismatch] == 1 && state.pictureTextCounts[.subs] == 1)
        state.pictureTextFilter = .mismatch
        #expect(state.displayedAssets(filter: "", mask: MediaKindFilter.all).map(\.fileName) == ["Spot_CLEAN.mov"])
        state.dismissGraphic(logo, in: url)
        defer { state.restoreDismissedGraphics(in: url) }
        #expect(state.dismissedGraphics(for: url) == ["brand"])
        #expect(state.deliverableAssets[0].pictureText?.isClean == true && !state.deliverableAssets[0].hasAnyNameMismatch)
        #expect(state.pictureTextCounts[.clean] == 2 && state.pictureTextCounts[.mismatch] == nil)
        #expect(PictureTextMarks.shared.byURL[url.standardizedFileURL] == nil)
        state.restoreDismissedGraphics(in: url)
        #expect(state.deliverableAssets[0].hasAnyNameMismatch && PictureTextMarks.shared.byURL[url.standardizedFileURL]?.count == 1)
        state.pictureTextFilter = .all
    }
}

extension PictureTextTests {
    @Test("Not a Graphic still hides a misread that comes back slightly different")
    func fuzzyDismissal() {
        var check = PictureTextCheck(subtitlesLikely: false, graphics: [.init(text: "JIMMI CHOO", start: 3, end: 4)])
        check.dismissed = ["jimmi choc"]
        #expect(check.graphics.isEmpty)
        check.dismissed = ["something else"]
        #expect(check.graphics.count == 1)
    }

    @Test("Chips: a chip left on with no checked files hides nothing; a dismissed row mismatch isn't a Name Mismatch") @MainActor
    func chipEdges() {
        let state = SpecsState()
        let folder = URL(fileURLWithPath: "/tmp/chips-\(UUID().uuidString)")
        func asset(_ name: String, _ check: PictureTextCheck?) -> DeliverableAsset {
            var a = DeliverableAsset(fileURL: folder.appendingPathComponent(name), fileName: name, fileSizeBytes: 1, formattedFileSize: "1 B",
                                     width: 1920, height: 1080, resolutionString: "1920x1080", aspectRatioString: "16:9", durationSeconds: 10,
                                     formattedDuration: "10s", totalFrames: 250, timecode: "00:00:10:00", fps: 25, videoCodec: "H.264",
                                     audioConfig: "NONE", container: "MOV")
            a.pictureText = check
            return a
        }
        state.deliverableAssets = [asset("A_CLEAN.mov", PictureTextCheck(subtitlesLikely: false, graphics: [.init(text: "BRAND", start: 1, end: 2)]))]
        state.pictureTextFilter = .mismatch
        #expect(state.displayedAssets(filter: "", mask: MediaKindFilter.all).count == 1)
        state.toggleDismissMismatch(for: state.deliverableAssets[0].fileURL)
        #expect(state.displayedAssets(filter: "", mask: MediaKindFilter.all).isEmpty && state.pictureTextCounts[.mismatch] == nil)
        state.toggleDismissMismatch(for: state.deliverableAssets[0].fileURL)
        // The list replaced by files never checked: the chips go, and so does their filter's effect.
        state.deliverableAssets = [asset("New.mov", nil), asset("Other.mov", nil)]
        #expect(state.displayedAssets(filter: "", mask: MediaKindFilter.all).count == 2)
        state.pictureTextFilter = .all
    }
}

extension PictureTextTests {
    /// Sorting by Subs / Text on Screen once re-parsed names and re-filtered dismissals in every comparison: 13 s for
    /// 1,000 files (debug build). Now ~20 ms; the limits leave room for a slow machine.
    @Test("1,000 checked files: sorting, chip counts and export stay fast") @MainActor
    func largeList() {
        let state = SpecsState()
        state.deliverableAssets = (0..<1000).map { i in
            let name = "Spot_\(i)_\(i % 3 == 0 ? "CLEAN" : "TITLED")_16x9.mov"
            var a = DeliverableAsset(fileURL: URL(fileURLWithPath: "/tmp/p/\(name)"), fileName: name, fileSizeBytes: 1, formattedFileSize: "1 B",
                                     width: 1920, height: 1080, resolutionString: "1920x1080", aspectRatioString: "16:9", durationSeconds: 30,
                                     formattedDuration: "30s", totalFrames: 750, timecode: "00:00:30:00", fps: 25, videoCodec: "H.264",
                                     audioConfig: "NONE", container: "MOV")
            let g = (0..<(i % 6)).map { PictureTextCheck.Sighting(text: "TITLE \(i) PART \($0) · BRAND NAME · LINE \($0)", start: Double($0) * 3, end: Double($0) * 3 + 2) }
            a.pictureText = PictureTextCheck(subtitlesLikely: i % 4 == 0, subtitleLineCount: 5, graphics: g,
                                             dismissed: i % 2 == 0 ? ["brand name", "misread one", "another"] : [])
            return a
        }
        let previous = state.specsSortColumnRaw
        defer { state.specsSortColumnRaw = previous }
        var t0 = CFAbsoluteTimeGetCurrent()
        state.specsSortColumnRaw = SpecsSortColumn.graphics.rawValue
        let sorted = state.sortDeliverableAssets(state.deliverableAssets)
        #expect(CFAbsoluteTimeGetCurrent() - t0 < 0.5)
        #expect(sorted.first?.hasPictureTextMismatch == true)
        t0 = CFAbsoluteTimeGetCurrent()
        _ = state.pictureTextCounts
        #expect(CFAbsoluteTimeGetCurrent() - t0 < 0.2)
        t0 = CFAbsoluteTimeGetCurrent()
        _ = DeliverablesInspector.generateManifestCSV(assets: state.deliverableAssets)
        #expect(CFAbsoluteTimeGetCurrent() - t0 < 0.5)
    }

    /// A 4:2:0 frame of mid grey with a white block at `block` (pixel rect), or none.
    static func frame(width: Int = 1920, height: Int = 1080, block: CGRect? = nil) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        let b = buffer!
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        for y in 0..<height {
            for x in 0..<width { base[y * stride + x] = block?.contains(CGPoint(x: x, y: y)) == true ? 235 : 120 }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    @Test("Same picture: an identical frame matches; a changed subtitle-sized word doesn't")
    func sameFrame() throws {
        let plain = try #require(PictureTextScanner.lumaGrid(Self.frame()))
        #expect(PictureTextScanner.sameFrame(plain, try #require(PictureTextScanner.lumaGrid(Self.frame()))))
        // One letter's stroke of a 1080p subtitle: 6 × 40 px.
        let letter = try #require(PictureTextScanner.lumaGrid(Self.frame(block: CGRect(x: 900, y: 950, width: 6, height: 40))))
        #expect(!PictureTextScanner.sameFrame(plain, letter))
        #expect(plain.count == 48 * 27)
    }

    @Test("Helpers: as many as the memory allows")
    func helperCount() {
        let gb: UInt64 = 1_073_741_824
        #expect(PictureTextWorkers.recommendedCount(memory: 8 * gb) == 0)
        #expect(PictureTextWorkers.recommendedCount(memory: 16 * gb) == 2)
        #expect(PictureTextWorkers.recommendedCount(memory: 36 * gb) == 4)
        #expect(PictureTextWorkers.recommendedCount(memory: 96 * gb) == 4)
    }

    @Test("Helper protocol: a paused helper holds its file, resumes, and stops when its input closes", .timeLimit(.minutes(1)))
    func helperProtocol() async throws {
        let clip = try BurnedSubtitleTests.makeClip([(from: 0, to: 30, text: "The first line of dialogue")], frames: 60)
        defer { try? FileManager.default.removeItem(at: clip) }
        let toWorker = Pipe(), fromWorker = Pipe()
        let served = Task { await PictureTextWorkers.serve(input: toWorker.fileHandleForReading, output: fromWorker.fileHandleForWriting) }
        func send(_ m: PictureTextWorkers.Message) throws { try toWorker.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(m) + [10]) }
        let lines = AsyncStream<PictureTextWorkers.Message> { out in
            Thread {
                PictureTextWorkers.forEachLine(of: fromWorker.fileHandleForReading) { line in
                    if let m = try? JSONDecoder().decode(PictureTextWorkers.Message.self, from: line) { out.yield(m) }
                }
                out.finish()
            }.start()
        }
        try send(.init(pause: true))
        try send(.init(file: clip.path))
        let arrived = OSAllocatedUnfairLock(initialState: false)
        let first = Task { () -> PictureTextWorkers.Message? in
            for await m in lines where m.reading != nil { arrived.withLock { $0 = true }; return m }
            return nil
        }
        try await Task.sleep(for: .seconds(1.5))
        #expect(!arrived.withLock { $0 })   // held while paused (the clip reads in well under a second)
        try send(.init(pause: false))
        let reading = try #require(await first.value?.reading)
        #expect(PictureTextScanner.check(from: reading) == (await PictureTextScanner.check(clip)))
        try toWorker.fileHandleForWriting.close()
        await served.value
        try fromWorker.fileHandleForWriting.close()
    }

    @Test("Helper processes give the same results as reading in the app; a helper that can't start falls back", .timeLimit(.minutes(1)))
    func helperProcesses() async throws {
        let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/QCpie")
        let subs = try BurnedSubtitleTests.makeClip([(from: 0, to: 30, text: "The first line of dialogue"),
                                                     (from: 30, to: 60, text: "and then another one follows"),
                                                     (from: 60, to: 90, text: "and a third to be sure")], frames: 100)
        var style = BurnedSubtitleTests.Style(); style.fontSize = 60; style.top = true
        let titled = try BurnedSubtitleTests.makeClip([(from: 20, to: 80, text: "BIG TITLE")], frames: 100, style: style)
        let clean = try BurnedSubtitleTests.makeClip([], frames: 60), clean2 = try BurnedSubtitleTests.makeClip([], frames: 40)
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-video-\(UUID().uuidString).mov")
        try Data("nope".utf8).write(to: bogus)
        let urls = [subs, titled, clean, clean2, bogus, subs, titled]
        defer { [subs, titled, clean, clean2, bogus].forEach { try? FileManager.default.removeItem(at: $0) } }
        var expected: [URL: PictureTextCheck] = [:]
        for url in urls { expected[url] = await PictureTextScanner.check(url) }
        for executable in [binary, URL(fileURLWithPath: "/nonexistent/QCpie")] where FileManager.default.isExecutableFile(atPath: binary.path) {
            let got = OSAllocatedUnfairLock(initialState: [(URL, PictureTextCheck)]())
            await PictureTextScanner.checkBatch(urls: urls, workers: .init(executable: executable, count: 4) { false },
                                                isCancelled: { false }) { url, result, _ in got.withLock { $0.append((url, result)) } }
            let results = got.withLock { $0 }
            #expect(results.count == urls.count)
            for (url, result) in results { #expect(result == expected[url], "\(url.lastPathComponent) via \(executable.path)") }
        }
    }
}
