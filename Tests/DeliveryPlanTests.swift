import Foundation
import Testing
@testable import QCpie

@Suite("Delivery Plan")
struct DeliveryPlanTests {
    // Shaped like the real sheet: a title row, quoted line breaks, a section row, a subtotal row, sizes holding codecs.
    static let csv = """
    "1100 - PROJECT","","","","","","","","","","","","","",""
    "N.","File Name","Length","Channel","Placement","Resolution","Aspect ratio","Logos ","Graphics","CTA","Subs","Translations","Sound","Files size","Frame rate"
    "","2. Teaser 15s + GIF","","","","","","","","","","","","",""
    "2","TEASER_15s","15s","Organic Social","IG/FB/YT","1920x1080","16x9","Yes","Yes","No","Yes EN","No","Yes","mp4",""
    "2","TEASER_15s","15s","Organic Social","IG/FB/YT","1920x1080","16x9","No","Yes","No","Yes EN","No","Yes","mp4",""
    "2","TEASER_15s","15s","KLP","Social","1080x1080","9x16","No","No","No","No","En","Yes","prores",""
    "4","HERO_6s","10s","Karl.com","PDP","
    2040x2400","17x20
    Desktop & Mobile ","No","Yes","No","No","EN","Yes","Max 20mb",""
    "","","","","","","","","","","","","","15",""
    "","TEASER_GIF","gif","Newsletter","Newsletter","1200 x 1500","4x5","No","No","No","No","No","No","Max 5mb",""
    """

    static var rows: [PlanRow] {
        var rows = PlanParser.rows(csv: csv, tab: "Edits")
        PlanParser.flagDuplicates(&rows)
        return rows
    }

    @Test("Header, sections, subtotals and messy cells")
    func parsing() {
        let rows = Self.rows
        #expect(rows.count == 5)
        #expect(rows.allSatisfy { $0.section == "2. Teaser 15s + GIF" })
        let hero = rows[3]
        #expect(hero.width == 2040 && hero.height == 2400)
        #expect(hero.value(.aspect) == "17x20 Desktop & Mobile")
        #expect(hero.maxBytes == 20_000_000)
        #expect(hero.issues.contains { $0.contains("name says 6s") })
        #expect(rows[0].format == .mp4)
        #expect(rows[2].format == .prores)
        #expect(rows[2].issues.contains { $0.contains("1080×1080 isn't 9x16") })
        #expect(rows[4].format == .gif && rows[4].width == 1200 && rows[4].seconds == nil)
        // Same name and specs but a different Logos value: different rows, not duplicates.
        #expect(rows[0].id != rows[1].id)
        #expect(rows[0].issues.isEmpty && rows[1].issues.isEmpty)
    }

    @Test("Values")
    func values() {
        #expect(PlanParser.seconds("2-3s") == 2...3)
        #expect(PlanParser.seconds("1:30") == 90...90)
        #expect(PlanParser.seconds("1m30s") == 90...90)
        #expect(PlanParser.seconds("gif") == nil)
        #expect(PlanParser.aspect("6:7 (mobile)").map { abs($0 - 6.0 / 7) < 1e-9 } == true)
        #expect(PlanParser.bytes("500KB") == 500_000)
        #expect(PlanSheetLink.parse("https://docs.google.com/spreadsheets/d/17U4hbVN1_eeFHFoTtTswt6kRfRCz-uKy6-2VyvWKNGM/edit#gid=1810111647")
                == PlanSheetLink(sheetID: "17U4hbVN1_eeFHFoTtTswt6kRfRCz-uKy6-2VyvWKNGM", gid: "1810111647"))
        #expect(PlanSheetLink.parse("not a link") == nil)
    }

    @Test("Tabs from the htmlview page")
    func htmlView() {
        let html = #"<title>1100 - Deliverables - Google Sheets</title> items.push({name: "Placement", pageUrl: "https:\/\/x", gid: "1810111647"}); items.push({name: "Edits \"v2\"", pageUrl: "https:\/\/y", gid: "1049261921"});"#
        let (title, tabs) = PublicSheetSource.parseHTMLView(html)
        #expect(title == "1100 - Deliverables")
        #expect(tabs == [PlanTab(gid: "1810111647", name: "Placement"), PlanTab(gid: "1049261921", name: "Edits \"v2\"")])
    }

    private func file(_ name: String, _ w: Int, _ h: Int, seconds: Double = 15, bytes: Int64 = 1_000_000,
                      codec: String = "H.264", audio: Bool = true) -> PlanFile {
        PlanFile(url: URL(fileURLWithPath: "/d/" + name), width: w, height: h, seconds: seconds, fps: 25, bytes: bytes,
                 codec: codec, hasAudio: audio)
    }

    @Test("Files go to the row they name; logo hints and specs decide between look-alike rows")
    func matching() {
        let rows = Self.rows
        let match = PlanMatcher.match(rows: rows, files: [
            file("TEASER_15s_16x9_LOGO.mp4", 1920, 1080),
            file("TEASER_15s_16x9_CLEAN.mp4", 1920, 1080),
            file("TEASER_15s_1x1.mov", 1080, 1080, codec: "Apple ProRes 422"),
            file("HERO_6s_PDP.mp4", 2040, 2400, seconds: 10, bytes: 24_000_000),
            file("SOMETHING_ELSE.mp4", 1920, 1080),
        ])
        #expect(match.result(rows[0]).files.map(\.lastPathComponent) == ["TEASER_15s_16x9_LOGO.mp4"])
        #expect(match.result(rows[0]).status == .delivered)
        #expect(match.result(rows[1]).files.map(\.lastPathComponent) == ["TEASER_15s_16x9_CLEAN.mp4"])
        #expect(match.result(rows[2]).status == .delivered)
        #expect(match.result(rows[3]).status == .wrongSpec)
        #expect(match.result(rows[3]).problems.contains { $0.contains("max 20 MB") })
        #expect(match.result(rows[4]).status == .missing)
        #expect(match.extras.map(\.lastPathComponent) == ["SOMETHING_ELSE.mp4"])
    }

    @Test("Look-alike rows without hints are matched by order and flagged; wrong specs are named")
    func ambiguity() {
        let rows = Self.rows
        let match = PlanMatcher.match(rows: rows, files: [
            file("TEASER_15s_a.mp4", 1920, 1080),
            file("TEASER_15s_b.mp4", 1920, 1080, audio: false),
        ])
        let first = match.result(rows[0]), second = match.result(rows[1])
        #expect(first.files.count == 1 && second.files.count == 1)
        #expect([first.status, second.status].contains(.check) || [first.status, second.status].contains(.wrongSpec))
        // The silent file fits neither row as well as the other one: it goes second and says why.
        #expect(second.problems.contains("No audio, expected sound") || first.problems.contains("No audio, expected sound"))
    }

    @Test("A file name with a token-prefix of a row name doesn't match it")
    func tokens() {
        #expect(PlanMatcher.contains(PlanMatcher.tokens("HERO VIDEO_30s_16x9"), PlanMatcher.tokens("HERO VIDEO_30s")))
        #expect(!PlanMatcher.contains(PlanMatcher.tokens("HERO VIDEO_30s_16x9"), PlanMatcher.tokens("HERO VIDEO_30")))
    }
}

extension DeliveryPlanTests {
    @Test("A file that fits perfectly gets its row even when a wrong file sorts first; aspect hints in names count")
    func perfectFitsFirst() {
        let rows = Self.rows
        let match = PlanMatcher.match(rows: rows, files: [
            PlanFile(url: URL(fileURLWithPath: "/d/TEASER_15s_9x16_LOGO.mp4"), width: 1080, height: 1350, seconds: 15, fps: 25,
                     bytes: 1, codec: "H.264", hasAudio: true),
            PlanFile(url: URL(fileURLWithPath: "/d/TEASER_15s_16x9_LOGO.mp4"), width: 1920, height: 1080, seconds: 15, fps: 25,
                     bytes: 1, codec: "H.264", hasAudio: true),
        ])
        #expect(match.result(rows[0]).files.map(\.lastPathComponent) == ["TEASER_15s_16x9_LOGO.mp4"])
        #expect(match.result(rows[0]).status == .delivered)
        // No 9x16 row in this sheet: the wrong file is listed as an extra, naming its closest row.
        #expect(match.extras.map(\.lastPathComponent) == ["TEASER_15s_9x16_LOGO.mp4"])
        #expect(match.extraNotes.values.first?.contains("row 4") == true)
    }
}
