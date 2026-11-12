import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

@Suite("Delivery Plan: picture and sound against the row")
struct DeliveryPlanContentTests {
    /// One row with these Logos / Graphics / CTA / Subs / Sound values.
    static func row(logos: String = "", graphics: String = "", cta: String = "", subs: String = "", sound: String = "") -> PlanRow {
        let table = [["Code", "File Name", "Logos", "Graphics", "CTA", "Subs", "Sound"],
                     ["KL01001", "SS27_TEASER_15s_16x9_EN", logos, graphics, cta, subs, sound]]
        return PlanParser.parse(table: table, tab: "Plan").rows[0]
    }

    static func picture(subtitles: Bool = false, lines: Int = 0, language: String? = nil,
                        graphics: [PictureTextCheck.Sighting] = []) -> PlanContent {
        PlanContent(duration: 15, picture: .init(subtitles: subtitles, lowerLines: lines, language: language, graphics: graphics))
    }

    static let logo = PictureTextCheck.Sighting(text: "KARL LAGERFELD", start: 0, end: 15)

    static func areas(_ row: PlanRow, _ content: PlanContent) -> [PlanContentFlag.Area] {
        PlanContentCheck.flags(row, content).map(\.area)
    }

    @Test("Logos: asked for and missing, at the wrong time, or there when the row rules out all text")
    func logos() {
        #expect(Self.areas(Self.row(logos: "Yes"), Self.picture()) == [.graphics])
        #expect(Self.areas(Self.row(logos: "Yes"), Self.picture(graphics: [Self.logo])).isEmpty)
        // "first 2s": text that starts at 5 s isn't it.
        let late = PictureTextCheck.Sighting(text: "KARL LAGERFELD", start: 5, end: 7)
        #expect(Self.areas(Self.row(logos: "Yes - first 2s"), Self.picture(graphics: [late])) == [.graphics])
        #expect(Self.areas(Self.row(logos: "Yes - first 2s"), Self.picture(graphics: [Self.logo])).isEmpty)
        // Intro and outro: one at the start only misses the end.
        let intro = PictureTextCheck.Sighting(text: "KLP", start: 0, end: 2)
        let flags = PlanContentCheck.flags(Self.row(logos: "Intro:KLP Logo\nOutro: KLP Logo"), Self.picture(graphics: [intro]))
        #expect(flags.count == 1 && flags[0].text.contains("at the end"))
        let outro = PictureTextCheck.Sighting(text: "KLP", start: 13, end: 15)
        #expect(Self.areas(Self.row(logos: "Intro:KLP Logo\nOutro: KLP Logo"), Self.picture(graphics: [intro, outro])).isEmpty)
        // No logo: flagged only when Graphics says no too (titles are text on screen as well).
        #expect(Self.areas(Self.row(logos: "No", graphics: "No"), Self.picture(graphics: [Self.logo])) == [.graphics])
        #expect(Self.areas(Self.row(logos: "No", graphics: "Yes"), Self.picture(graphics: [Self.logo])).isEmpty)
        #expect(Self.areas(Self.row(logos: "No", graphics: "No", cta: "Yes"), Self.picture(graphics: [Self.logo])).isEmpty)
        // Unclear wording says nothing.
        #expect(Self.areas(Self.row(logos: "tbc", graphics: "tbc"), Self.picture()).isEmpty)
        #expect(Self.areas(Self.row(), Self.picture(graphics: [Self.logo])).isEmpty)
    }

    @Test("Subtitles: missing, unexpected, or in another language; one line in a short clip isn't missing")
    func subtitles() {
        #expect(Self.areas(Self.row(subs: "Yes - FR"), Self.picture()) == [.subtitles])
        #expect(Self.areas(Self.row(subs: "Yes - FR"), Self.picture(lines: 1)).isEmpty)
        #expect(Self.areas(Self.row(subs: "Yes - FR"), Self.picture(subtitles: true, lines: 3, language: "fr")).isEmpty)
        let wrong = PlanContentCheck.flags(Self.row(subs: "Yes - FR"), Self.picture(subtitles: true, lines: 3, language: "en"))
        #expect(wrong.count == 1 && wrong[0].text.contains("French") && wrong[0].text.contains("English"))
        #expect(Self.areas(Self.row(subs: "Yes - ENG"), Self.picture(subtitles: true, lines: 3, language: "en")).isEmpty)
        #expect(Self.areas(Self.row(subs: "Yes EN/FR"), Self.picture(subtitles: true, lines: 3, language: "de")).isEmpty)   // two: not checked
        #expect(Self.areas(Self.row(subs: "Yes"), Self.picture(subtitles: true, lines: 3, language: nil)).isEmpty)
        #expect(Self.areas(Self.row(subs: "No"), Self.picture(subtitles: true, lines: 3)) == [.subtitles])
        #expect(Self.areas(Self.row(subs: "No"), Self.picture(lines: 1)).isEmpty)
    }

    @Test("Sound: silent when asked for, audible when the row says none; nothing before Check Loudness")
    func sound() {
        #expect(Self.areas(Self.row(sound: "Yes"), PlanContent(duration: 15, silent: true)) == [.sound])
        #expect(Self.areas(Self.row(sound: "Yes"), PlanContent(duration: 15, silent: false, loudness: -23)).isEmpty)
        let loud = PlanContentCheck.flags(Self.row(sound: "No"), PlanContent(duration: 15, silent: false, loudness: -23))
        #expect(loud.count == 1 && loud[0].text.contains("-23.0 LUFS"))
        #expect(Self.areas(Self.row(sound: "No"), PlanContent(duration: 15, silent: true)).isEmpty)
        #expect(Self.areas(Self.row(sound: "Yes"), PlanContent(duration: 15)).isEmpty)
    }

    @Test("Fast enough for every plan update: 2,000 checked files")
    func speed() {
        let rows = [Self.row(logos: "Yes - first 2s", subs: "Yes - FR", sound: "Yes"), Self.row(logos: "No", graphics: "No", subs: "No", sound: "No")]
        var content = Self.picture(subtitles: true, lines: 3, language: "fr", graphics: [Self.logo])
        content.silent = false
        // This thread's CPU time, not the clock: the suite runs beside the video-reading tests.
        func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
        let t0 = cpu()
        var count = 0
        for i in 0..<2_000 { count += PlanContentCheck.flags(rows[i % 2], content).count }
        #expect(count == 3_000)   // the second row, 1,000 times: text on screen, subtitles and sound where it says none
        #expect(cpu() - t0 < 0.1)
    }

    @Test("Plan wording")
    func wording() {
        #expect(PlanContentCheck.firstSeconds("yes - first 2s") == 2)
        #expect(PlanContentCheck.firstSeconds("yes, first 1.5 sec") == 1.5)
        #expect(PlanContentCheck.firstSeconds("yes") == nil)
        #expect(PlanContentCheck.language(in: "Yes - ENG")?.name == "English")
        #expect(PlanContentCheck.language(in: "Yes EN")?.name == "English")
        #expect(PlanContentCheck.language(in: "Yes EN/FR") == nil)
        #expect(PlanContentCheck.isNo("No") && PlanContentCheck.isNo("none") && PlanContentCheck.isNo("No.") && PlanContentCheck.isNo("No logo"))
        #expect(!PlanContentCheck.isNo("Not sure") && !PlanContentCheck.isNo("Yes") && !PlanContentCheck.isNo("No VO"))
        // "No logo" doesn't ask for one; "No VO" isn't "no sound".
        #expect(Self.areas(Self.row(logos: "No logo"), Self.picture()).isEmpty)
        #expect(Self.areas(Self.row(sound: "No VO"), PlanContent(duration: 15, silent: false, loudness: -20)).isEmpty)
    }

    @Test("Subtitle language read from the lines")
    func language() {
        #expect(PictureTextScanner.language(of: ["On s'est rencontrés à Paris, l'été où il pleuvait.", "Chaque look raconte une histoire.",
                                                 "La lumière change tout."]) == "fr")
        #expect(PictureTextScanner.language(of: ["We met in Paris, the summer it rained.", "Every look tells a story."]) == "en")
    }
}
