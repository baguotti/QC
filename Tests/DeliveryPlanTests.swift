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

extension DeliveryPlanTests {
    // Shaped like `htmlview/sheet?headers=true&gid=` output.
    static let html = #"""
    <style>.ritz .waffle .s0{background-color:#bdbdbd;text-align:left;font-weight:bold;color:#000000;font-size:8pt;white-space:normal;}.ritz .waffle .s1{border-bottom:2px SOLID #999999;background-color:#f3f3f3;text-align:right;text-decoration:line-through;color:#1155cc;white-space:nowrap;vertical-align:middle;}</style>
    <table class="waffle"><thead><tr><th class="row-header freezebar-vertical-handle"></th><th id="9C0" style="width:49px;">A</th><th id="9C1" style="width:360px;">B</th><th id="9C2" style="width:97px;">C</th></tr></thead><tbody>
    <tr style="height: 31px"><th id="9R0" style="height: 31px;"><div>1</div></th><td class="s0">Code</td><td class="s0">File Name</td><td class="s0">Length</td></tr>
    <tr><th style="height:3px;" class="freezebar-cell freezebar-horizontal-handle"></th><td class="freezebar-cell"></td><td class="freezebar-cell"></td><td class="freezebar-cell"></td></tr>
    <tr style="height: 40px"><th id="9R1" style="height: 40px;"><div>2</div></th><td class="s1" colspan="2" rowspan="2">Karl.com &amp; <a href="x">Top</a><br>Banner</td><td class="s1">30s</td></tr>
    <tr style="height: 21px"><th id="9R2" style="height: 21px;"><div>3</div></th><td>&lt;6s&#39;</td></tr>
    </tbody></table>
    """#

    @Test("The sheet's HTML view: widths, frozen rows, styles, merges, text")
    func gridHTML() throws {
        let grid = try #require(PlanGrid.parseHTML(Self.html))
        #expect(grid.columnWidths == [49, 360, 97])
        #expect(grid.frozenRows == 1)
        #expect(grid.rows.map(\.line) == [1, 2, 3])
        #expect(grid.rows[1].height == 40)
        let merged = grid.rows[1].cells[0]
        #expect(merged.span == 2 && merged.rowSpan == 2 && merged.text == "Karl.com & Top\nBanner")
        #expect(grid.rows[1].cells[1].column == 2)
        // Row 3's only cell sits right of the rowspan.
        #expect(grid.rows[2].cells.map(\.column) == [2])
        #expect(grid.rows[2].cells[0].text == "<6s'")
        let header = grid.styles[grid.rows[0].cells[0].style]
        #expect(header.background == 0xBDBDBD && header.bold && header.wrap && header.fontSize == 8)
        let body = grid.styles[merged.style]
        #expect(body.align == .right && body.valign == .middle && body.strike && !body.wrap && body.color == 0x1155CC)
        #expect(body.bottom == PlanGridBorder(width: 2, color: 0x999999))
        #expect(PlanGrid.parseHTML("<html>Sign in</html>") == nil)
        #expect(PlanGrid.columnName(0) == "A" && PlanGrid.columnName(25) == "Z" && PlanGrid.columnName(26) == "AA")
    }

    @Test("Without the HTML, the CSV gives the same rows unformatted, header frozen")
    func gridCSV() {
        let grid = PlanGrid.fromCSV(Self.csv)
        #expect(grid.rows.count == PlanParser.csv(Self.csv).count)
        #expect(grid.frozenRows == 2)
        #expect(!grid.formatted)
    }
}

extension DeliveryPlanTests {
    @Test("Totals aren't deliverables; with a Code column, rows without a code are headings")
    func totalsAndCodes() {
        let csv = """
        "Code","N.","File Name","Length","Resolution"
        "KL0001","2","TEASER_15s_KL0001","15s","1920x1080"
        "","","Total","","13"
        "","","10. SNAPSHOTS OF PARIS","15s",""
        "KL0002","","PARIS_15s_KL0002","15s","1080x1920"
        "","","Grand total","","1075"
        """
        let rows = PlanParser.rows(csv: csv, tab: "Edits")
        #expect(rows.map(\.name) == ["TEASER_15s_KL0001", "PARIS_15s_KL0002"])
        #expect(rows[1].section == "10. SNAPSHOTS OF PARIS")
        #expect(rows[0].id != rows[1].id)
        let noCodes = PlanParser.rows(csv: "\"File Name\",\"Length\",\"Resolution\"\n\"A_15s\",\"15s\",\"1x1\"\n\"Grand Total\",\"\",\"5\"", tab: "T")
        #expect(noCodes.map(\.name) == ["A_15s"])
    }
}

extension DeliveryPlanTests {
    static let coded = """
    "Code","File Name","Length","Resolution","Aspect ratio"
    "KL0001","TEASER_15s_KL0001","15s","1920x1080","16x9"
    "KL0002","TEASER_15s_KL0002","15s","1080x1920","9x16"
    "KL0003","HERO_6s_KL0003","6s","1080x1080","1x1"
    """

    @Test("Coded names: files without the code still match by name; a code on the wrong file is called out")
    func codes() {
        let rows = PlanParser.rows(csv: Self.coded, tab: "P")
        func f(_ name: String, _ w: Int, _ h: Int, _ s: Double) -> PlanFile {
            PlanFile(url: URL(fileURLWithPath: "/d/\(name).mp4"), width: w, height: h, seconds: s, fps: 25, bytes: 1, codec: "H.264", hasAudio: true)
        }
        let match = PlanMatcher.match(rows: rows, files: [f("TEASER_15s_9x16", 1080, 1920, 15), f("TEASER_15s_KL0003", 1920, 1080, 15)])
        #expect(match.result(rows[1]).files.map(\.lastPathComponent) == ["TEASER_15s_9x16.mp4"])
        let wrong = match.result(rows[2])
        #expect(wrong.status == .wrongSpec)
        #expect(wrong.problems.contains { $0.contains("doesn't match KL0003's row") && $0.contains("rows 2, 3") })
    }
}

extension DeliveryPlanTests {
    @Test("Edits: script holds the key, links parse, pending text lays over the grid")
    func editing() throws {
        let script = AppsScriptWriter.script(token: "abc123")
        #expect(script.contains("const TOKEN = 'abc123';"))
        try script.write(toFile: NSTemporaryDirectory() + "qcpie-plan-script.js", atomically: true, encoding: .utf8)
        #expect(AppsScriptWriter.parseURL("https://script.google.com/macros/s/AKfy123/exec") != nil)
        #expect(AppsScriptWriter.parseURL("https://script.google.com/a/macros/wildislandfilms.com/s/AKfy/exec") != nil)
        #expect(AppsScriptWriter.parseURL("https://docs.google.com/spreadsheets/d/x") == nil)
        let grid = try #require(PlanGrid.parseHTML(Self.html))
        #expect(grid.text(line: 2, column: 1) == "Karl.com & Top\nBanner")   // inside the merge
        let edited = grid.applying([DeliveryPlanStore.CellKey(line: 2, column: 2): "20s"])
        #expect(edited.text(line: 2, column: 2) == "20s" && grid.text(line: 2, column: 2) == "30s")
        #expect(PlanGrid.normalized(" Karl.com\nTop  Banner ") == "Karl.com Top Banner")
    }
}

extension DeliveryPlanTests {
    @Test("One state per row: manual status wins, a newer file sends it back to To QC, flags explain")
    func states() throws {
        let set = try #require(PlanStatusResolver.date(fromStamp: "2026-11-04 14:00:00 · Ric"))
        func r(_ m: PlanStatus, files: Bool = true, qc: String = "", updated: String = "", dates: [Date] = []) -> PlanRowState {
            PlanStatusResolver.resolve(match: m, hasFiles: files, qc: qc, updated: updated, fileDates: dates)
        }
        #expect(r(.missing, files: false).state == .missing)
        #expect(r(.delivered).state == .toQC)
        #expect(r(.wrongSpec).state == .wrongSpec && r(.check).state == .check)
        #expect(r(.delivered, qc: "QC Passed", updated: "2026-11-04 14:00:00 · Ric", dates: [set.addingTimeInterval(-60)]).state == .passed)
        let newer = r(.delivered, qc: "QC Passed", updated: "2026-11-04 14:00:00 · Ric", dates: [set.addingTimeInterval(600)])
        #expect(newer.state == .toQC && newer.flags.first?.contains("New file since") == true)
        #expect(r(.delivered, qc: "Needs Fix", updated: "2026-11-04 14:00:00", dates: [set.addingTimeInterval(600)]).state == .toQC)
        #expect(r(.missing, files: false, qc: "Delivered").flags.first?.contains("No file") == true)
        #expect(r(.missing, files: false, qc: "Dropped").state == .dropped)
        #expect(PlanQCStatus.parse("qc passed ✓") == .passed && PlanQCStatus.parse("Approved") == .approved && PlanQCStatus.parse("x") == nil)
        // Old stamps (no "UTC") are local; new ones are UTC, so time zones agree.
        let stamp = PlanStatusResolver.stamp(set, by: "Ric")
        #expect(stamp.hasSuffix(" UTC · Ric") && PlanStatusResolver.date(fromStamp: stamp) == set)
        #expect(PlanStatusResolver.date(fromStamp: "2026-11-04 13:00:00 UTC · Sheets")
                == ISO8601DateFormatter().date(from: "2026-11-04T13:00:00Z"))
    }

    @Test("QC columns are read but never make a row changed or re-run matching")
    func qcColumns() {
        let csv = """
        "Code","File Name","Length","Resolution","QC Status","QC Note","QC Updated"
        "KL0001","A_15s_KL0001","15s","1920x1080","QC Passed","ok","2026-11-04 14:00:00 · Ric"
        """
        let rows = PlanParser.rows(csv: csv, tab: "T")
        #expect(rows[0].value(.qcStatus) == "QC Passed" && rows[0].value(.qcNote) == "ok")
        #expect(rows[0].content["qcStatus"] == nil)
        let plain = PlanParser.rows(csv: csv.replacingOccurrences(of: "QC Passed", with: "Needs Fix"), tab: "T")
        #expect(plain[0].matchSignature == rows[0].matchSignature && plain[0] != rows[0])
    }
}

extension DeliveryPlanTests {
    @Test("A row with specs but no code yet is still a deliverable; a lone title is a heading")
    func uncodedRows() {
        let csv = """
        "Code","File Name","Length","Resolution"
        "KL0001","A_15s_KL0001","15s","1920x1080"
        "","NEW SECTION","15s",""
        "","B_15s","15s","1080x1920"
        """
        let rows = PlanParser.rows(csv: csv, tab: "T")
        #expect(rows.map(\.name) == ["A_15s_KL0001", "B_15s"])
        #expect(rows[1].section == "NEW SECTION" && rows[1].code == nil)
    }

    @Test("Batches sort naturally and are never part of matching or changes")
    func batches() {
        #expect(PlanBatch.sorted(["2", "1.10", "1", "10", "1.2", "Final", " 1 "]) == ["1", "1.2", "1.10", "2", "10", "Final"])
        #expect(PlanBatch.title("1.1") == "Batch 1.1" && PlanBatch.title("Final") == "Final")
        #expect(PlanBatch.next(after: ["1", "2"]) == "3" && PlanBatch.next(after: []) == "1")
        #expect(PlanField.detect("Batch") == .batch && PlanField.batch.isTracking && !PlanField.batch.isQC)
        let a = PlanParser.rows(csv: "Code,File Name,Resolution,Length,Batch\nKL0001,A_KL0001,1920x1080,15s,1\n", tab: "T")
        let b = PlanParser.rows(csv: "Code,File Name,Resolution,Length,Batch\nKL0001,A_KL0001,1920x1080,15s,2\n", tab: "T")
        #expect(a[0].value(.batch) == "1" && a[0].id == b[0].id)
        #expect(a[0].matchSignature == b[0].matchSignature && a[0].content == b[0].content)
    }

    @Test("Frame.io and Uploaded columns are QCpie's own, never part of matching")
    func frameioColumns() {
        #expect(PlanField.detect("Frame.io") == .frameio && PlanField.detect("Uploaded") == .uploaded)
        #expect(PlanField.frameio.isTracking && PlanField.uploaded.isTracking)
        let csv = "Code,File Name,Resolution,Length,Frame.io\nKL0001,A_KL0001,1920x1080,15s,"
        let a = PlanParser.rows(csv: csv + "\n", tab: "T"), b = PlanParser.rows(csv: csv + "https://next.frame.io/project/p/view/x\n", tab: "T")
        #expect(b[0].value(.frameio) == "https://next.frame.io/project/p/view/x" && a[0].matchSignature == b[0].matchSignature)
        #expect(DeliveryPlanStore.uploadStamp(Date(timeIntervalSince1970: 0)) == "1970-01-01 00:00 UTC")
    }

    @Test("Upload state: stamps parse and filters pass the right rows")
    func uploadState() {
        #expect(PlanUpload.date("2026-11-05 10:42 UTC") == Date(timeIntervalSince1970: 1_793_875_320))
        #expect(PlanUpload.date("2026-11-05 10:42:00 UTC") != nil && PlanUpload.date("yesterday") == nil)
        func row(_ upload: PlanUpload) -> PlanRowState { PlanRowState(state: .toQC, upload: upload, mismatches: upload == .stale ? [.differs] : []) }
        #expect(row(.uploaded).passes(1) && row(.stale).passes(1) && !row(.none).passes(1))
        #expect(row(.none).passes(0) && !row(.uploaded).passes(0))
        #expect(row(.stale).passes(2) && !row(.uploaded).passes(2))
    }
}

@Test func mismatchFilters() {
    let differs = PlanRowState(state: .toQC, upload: .stale, mismatches: [.differs, .early])
    #expect(differs.passes(1) && !differs.passes(0))
    #expect(differs.passes(PlanMismatch.differs.rawValue) && differs.passes(PlanMismatch.early.rawValue))
    #expect(!differs.passes(PlanMismatch.noLocalFile.rawValue))
    let notUploaded = PlanRowState(state: .passed, mismatches: [.notUploaded])
    #expect(notUploaded.passes(0) && notUploaded.passes(PlanMismatch.notUploaded.rawValue))
    // Files: "here, not in the plan" passes only files without a row; row kinds need a row.
    let extra = PlanFileInfo(code: "", line: 0, rowID: nil, state: nil)
    #expect(extra.passes(PlanMismatch.localExtra.rawValue) && !extra.passes(0) && !extra.passes(PlanMismatch.differs.rawValue))
    let file = PlanFileInfo(code: "KL1", line: 3, rowID: "r", state: .toQC, upload: .stale, mismatches: [.differs])
    #expect(file.passes(PlanMismatch.differs.rawValue) && file.passes(1) && !file.passes(PlanMismatch.localExtra.rawValue))
    #expect(PlanMismatch.filterTitle(0) == "Not on Frame.io" && PlanMismatch.filterTitle(6) == PlanMismatch.frameioExtra.title)
}

@Test func frameIOIDsMatchLinks() {
    #expect(DeliveryPlanStore.frameIOID("https://next.frame.io/project/p1/view/ABC-1?share=x") == "abc-1")
    #expect(DeliveryPlanStore.frameIOID("https://next.frame.io/project/p1/view/abc/") == "abc")
    #expect(DeliveryPlanStore.frameIOID("") == nil)
    // A stack is linked when a row links it or its current version.
    let stack = DeliveryPlanStore.ListedFile(name: "A.mp4", url: "https://next.frame.io/project/p/view/s1", size: 10, head: "v9")
    #expect(stack.isLinked(in: ["v9"]) && stack.isLinked(in: ["s1"]) && !stack.isLinked(in: ["v8"]))
    // Saved before heads were recorded: still decodes.
    let old = try? JSONDecoder().decode(DeliveryPlanStore.ListedFile.self, from: Data(#"{"name":"a","url":"u/x","size":1}"#.utf8))
    #expect(old?.head == nil && old?.ids == ["x"])
}
