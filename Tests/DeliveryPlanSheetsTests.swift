import Foundation
import Testing
@testable import QCpie

// The Delivery Plan through the Sheets API: the Sheet view's layout, the QCpie tab, the outbox and cell writes.
// Nothing here reaches Google (`StubSheets` answers instead).

@Suite("Delivery Plan · Sheets API")
struct DeliveryPlanSheetsTests {
    // A 3×3 tab: column B hidden, A2:A3 merged, row 1 frozen and bold on grey, C2 right-aligned blue with a border.
    static let layout = #"""
    {"sheets":[{"properties":{"gridProperties":{"frozenRowCount":1}},
      "merges":[{"startRowIndex":1,"endRowIndex":3,"startColumnIndex":0,"endColumnIndex":1}],
      "data":[{"rowMetadata":[{"pixelSize":31},{"pixelSize":40},{"pixelSize":21}],
               "columnMetadata":[{"pixelSize":49},{"pixelSize":80,"hiddenByUser":true},{"pixelSize":97}],
               "rowData":[
                 {"values":[{"effectiveFormat":{"backgroundColor":{"red":0.7411765,"green":0.7411765,"blue":0.7411765},"textFormat":{"bold":true,"fontSize":8}}},{},{"effectiveFormat":{"textFormat":{"bold":true}}}]},
                 {"values":[{"effectiveFormat":{"wrapStrategy":"WRAP","verticalAlignment":"MIDDLE"}},{},{"effectiveFormat":{"horizontalAlignment":"RIGHT","textFormat":{"foregroundColor":{"red":0.06666667,"green":0.33333334,"blue":0.8},"strikethrough":true},"borders":{"bottom":{"style":"SOLID_MEDIUM","color":{"red":0.6,"green":0.6,"blue":0.6}}}}}]},
                 {"values":[{},{},{}]}]}]}]}
    """#
    static let table = [["Code", "Hidden", "Length"], ["Karl.com\nTop", "x", "30s"], ["", "y", "15"]]

    @Test("Layout: hidden columns out, merges, frozen rows, formats; values fill it")
    func layoutGrid() throws {
        let grid = try #require(PlanGrid.fromSheets(layout: Data(Self.layout.utf8), table: Self.table))
        #expect(grid.columnWidths == [49, 97])
        #expect(grid.sheetColumns == [0, 2])
        #expect(grid.frozenRows == 1 && grid.formatted)
        #expect(grid.rows.map(\.line) == [1, 2, 3] && grid.rows[1].height == 40)
        let merged = grid.rows[1].cells[0]
        #expect(merged.span == 1 && merged.rowSpan == 2 && merged.text == "Karl.com\nTop")
        #expect(grid.rows[2].cells.map(\.column) == [1])   // A3 is under the merge
        let header = grid.styles[grid.rows[0].cells[0].style]
        #expect(header.background == 0xBDBDBD && header.bold && header.fontSize == 8)
        let body = grid.styles[grid.rows[1].cells[1].style]
        #expect(body.align == .right && body.strike && body.color == 0x1155CC && body.bottom == PlanGridBorder(width: 2, color: 0x999999))
        #expect(grid.styles[merged.style].wrap && grid.styles[merged.style].valign == .middle)
        // A number without its own alignment sits right, as in Sheets.
        #expect(grid.styles[grid.rows[2].cells[0].style].align == .right)

        var newer = Self.table
        newer[1][2] = "20s"
        #expect(grid.fits(newer))
        #expect(grid.withTexts(newer).text(line: 2, column: 1) == "20s")
        // A row added: the layout doesn't fit (read it again) but still shows what it has cells for.
        let grown = newer + [["KL9", "", "6s"]]
        #expect(!grid.fits(grown))
        #expect(grid.withTexts(grown).text(line: 2, column: 1) == "20s")
        #expect(PlanGrid.fromSheets(layout: Data("{}".utf8), table: Self.table) == nil)
    }

    @Test("Changed rows get their formats read again (conditional colours follow the values)")
    func rowFormats() throws {
        let grid = try #require(PlanGrid.fromSheets(layout: Data(Self.layout.utf8), table: Self.table))
        var newer = Self.table
        newer[2][2] = "16"
        #expect(PlanGrid.changedLines(Self.table, newer) == [3...3])
        #expect(PlanGrid.changedLines([["a"], ["b"], ["c"], ["d"]], [["x"], ["y"], ["c"], ["z"]]) == [1...2, 4...4])
        // Row 3 turned green by a rule: only its cells change style.
        let reply = #"{"sheets":[{"data":[{"startRow":2,"rowData":[{"values":[{},{},{"effectiveFormat":{"backgroundColor":{"red":0,"green":1,"blue":0}}}]}]}]}]}"#
        let patched = grid.withTexts(newer).patchingFormats(Data(reply.utf8))
        #expect(patched.styles[patched.rows[2].cells[0].style].background == 0x00FF00)
        #expect(patched.rows[0].cells.map(\.style) == grid.rows[0].cells.map(\.style))
        #expect(patched.rows[1].cells.map(\.style) == grid.rows[1].cells.map(\.style))
    }

    @Test("Dropdowns: lists by column, ranges to read")
    func validations() {
        let json = #"{"sheets":[{"data":[{"rowData":[{"values":[{},{"dataValidation":{"condition":{"type":"ONE_OF_LIST","values":[{"userEnteredValue":"Yes"},{"userEnteredValue":" No "}]}}},{"dataValidation":{"condition":{"type":"ONE_OF_RANGE","values":[{"userEnteredValue":"=Lists!A1:A5"}]}}}]}]}]}]}"#
        let (lists, ranges) = DeliveryPlanStore.parseValidations(Data(json.utf8))
        #expect(lists == [1: ["Yes", "No"]])
        #expect(ranges.map(\.column) == [2] && ranges.map(\.range) == ["Lists!A1:A5"])
    }
}

extension DeliveryPlanSheetsTests {
    static let qcValues = [
        ["Code", "Deliverable", "QC Status", "QC Note", "QC Updated", "Batch", "Frame.io", "Uploaded"],
        ["KL0001", "TEASER", "QC Passed", "", "2026-11-04 14:00:00 UTC · Ric", "2", "", ""],
        ["kl0002", "HERO", "", "fix logo", "", "", "", ""],
        ["KL0001", "TEASER", "", "", "", "", "https://next.frame.io/project/p/view/f1", ""],
    ]

    @Test("QCpie tab: values by code (duplicates merged), writes in place, new codes appended, missing columns added")
    func qcTab() throws {
        let table = try #require(PlanQCTab.parse(Self.qcValues))
        #expect(table.lines["kl0001"] == [2, 4] && table.lines["kl0002"] == [3])
        #expect(table.values["kl0001"]?[.qcStatus] == "QC Passed")
        #expect(table.values["kl0001"]?[.frameio] == "https://next.frame.io/project/p/view/f1")
        #expect(PlanQCTab.parse([["Name"], ["x"]]) == nil)

        let writes = PlanQCTab.writes([
            .init(code: "KL0002", name: "HERO", values: [.qcStatus: "Needs Fix", .qcUpdated: "2026-11-06 10:00:00 UTC · Ric"]),
            .init(code: "KL0001", name: "TEASER", values: [.batch: "3"]),
            .init(code: "KL0009", name: "NEW", values: [.frameio: "https://x/view/9"]),
        ], into: table)
        let ranges = Dictionary(uniqueKeysWithValues: writes.updates.map { ($0.range, $0.values[0][0]) })
        #expect(ranges["'QCpie'!C3"] == "Needs Fix" && ranges["'QCpie'!E3"] == "2026-11-06 10:00:00 UTC · Ric")
        #expect(ranges["'QCpie'!F2"] == "3" && ranges["'QCpie'!F4"] == "3")   // every line of a duplicated code
        #expect(writes.appends == [["KL0009", "NEW", "", "", "", "", "https://x/view/9", ""]])

        // A tab missing the Batch column: its header is added after the last column.
        let narrow = try #require(PlanQCTab.parse([["Code", "QC Status"], ["KL1", ""]]))
        let added = PlanQCTab.writes([.init(code: "KL1", name: "", values: [.batch: "1"])], into: narrow)
        #expect(added.updates.map(\.range) == ["'QCpie'!C1", "'QCpie'!C2"] && added.updates[0].values == [["Batch"]])
    }

    @Test("Moving to the QCpie tab: newest stamp wins, the outbox wins over both, QC columns become lookups")
    func qcTabSetUp() throws {
        let placement = [
            ["Code", "File Name", "Length", "QC Status", "QC Updated", "Batch"],
            ["KL1", "TEASER_KL1", "15s", "Needs Fix", "2026-11-01 10:00:00 UTC · A", ""],
            ["KL2", "HERO_KL2", "6s", "", "", "2"],
        ]
        let edits = [
            ["Title"],
            ["Code", "File Name", "Length", "QC Status", "QC Updated"],
            ["KL1", "TEASER_KL1", "15s", "QC Passed", "2026-11-03 10:00:00 UTC · B"],
        ]
        let tabs = [SheetsAPI.Tab(gid: "11", title: "Placement", hidden: false), SheetsAPI.Tab(gid: "22", title: "Edits", hidden: false)]
        let plan = DeliveryPlanStore.qcTabPlan(tabs: tabs, tables: [placement, edits],
                                               pending: [.init(code: "KL2", name: "HERO_KL2", values: [.qcNote: "logo"])])
        #expect(plan.rows == [
            ["KL1", "TEASER_KL1", "QC Passed", "", "2026-11-03 10:00:00 UTC · B", "", "", ""],
            ["KL2", "HERO_KL2", "", "logo", "", "2", "", ""],
        ])
        #expect(plan.lookups.map { "\($0.title):\($0.field.rawValue):\($0.column):\($0.firstRow)" }
                == ["Placement:qcStatus:3:2", "Placement:qcUpdated:4:2", "Placement:batch:5:2", "Edits:qcStatus:3:3", "Edits:qcUpdated:4:3"])
        #expect(PlanQCTab.formula(.qcStatus, codeColumn: 0, firstRow: 3)
                == #"=ARRAYFORMULA(IF(LEN(A3:A), IFERROR(VLOOKUP(A3:A&"", 'QCpie'!$A:$Z, MATCH("QC Status", 'QCpie'!$1:$1, 0), FALSE)&"", ""), ""))"#)

        let requests = DeliveryPlanStore.qcTabRequests(plan, sheetID: 77)
        // addSheet, values, bold header, dropdown, then a lookup and a warning per column: one atomic batch.
        #expect(requests.count == 4 + 2 * plan.lookups.count)
        #expect(requests.first?["addSheet"] != nil)
        let body = try JSONSerialization.data(withJSONObject: ["requests": requests])
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#""stringValue":"2026-11-03 10:00:00 UTC · B""#) && text.contains(#""warningOnly":true"#))
    }
}

extension DeliveryPlanSheetsTests {
    @Test("Outbox: shown until a read after the write; a change made while sending is sent again")
    func outbox() {
        var box = PlanOutbox()
        let t0 = Date(timeIntervalSince1970: 1000)
        box.set(code: "KL1", name: "A", [.qcStatus: "QC Passed"], quiet: false, at: t0)
        box.set(code: "kl1", name: "A", [.qcNote: "ok"], quiet: true, at: t0.addingTimeInterval(1))
        #expect(box.records.count == 1 && box.overlay["kl1"] == [.qcStatus: "QC Passed", .qcNote: "ok"])
        #expect(box.records["kl1"]?.quiet == false)   // one loud edit makes the record loud
        box.set(code: "KL2", name: "B", [.batch: "2"], quiet: true, at: t0)

        // Sent at t0+2; KL2 changes again during the send.
        box.set(code: "KL2", name: "B", [.batch: "3"], quiet: true, at: t0.addingTimeInterval(3))
        box.written(codes: ["KL1", "KL2"], cells: [], sentAt: t0.addingTimeInterval(2), at: t0.addingTimeInterval(4))
        #expect(box.unsent.records.map(\.code) == ["KL2"])
        // A read that started before the write came back: KL1 stays laid over.
        let early = box.settle(readStart: t0.addingTimeInterval(3))
        #expect(!early)
        #expect(box.overlay["kl1"] != nil)
        let late = box.settle(readStart: t0.addingTimeInterval(5))
        #expect(late)
        #expect(box.overlay["kl1"] == nil && box.overlay["kl2"] == [.batch: "3"])

        let cell = PlanOutbox.Cell(gid: "1", line: 2, column: 1, sheetColumn: 2, code: "KL1", header: "Length", value: "20s", expect: "15s", changed: t0)
        box.add(cell)
        box.add(PlanOutbox.Cell(gid: "1", line: 2, column: 1, sheetColumn: 2, code: "KL1", header: "Length", value: "25s", expect: "15s", changed: t0))
        #expect(box.cells.count == 1 && box.cellOverlay(gid: "1") == [DeliveryPlanStore.CellKey(line: 2, column: 1): "25s"])
        // Refused for good: dropped, but a record already written stays until a read shows it.
        box.set(code: "KL4", name: "D", [.qcNote: "n"], quiet: true, at: t0)
        box.written(codes: ["KL4"], cells: [], sentAt: t0.addingTimeInterval(1), at: t0.addingTimeInterval(2))
        box.drop(codes: ["KL2", "KL4"], cells: Set(box.cells.map(\.id)), sentAt: t0.addingTimeInterval(10))
        #expect(box.records.keys.sorted() == ["kl4"] && box.cells.isEmpty)
        box.settle(readStart: t0.addingTimeInterval(3))
        #expect(box.isEmpty)
        // Saved and read back.
        box.set(code: "KL3", name: "C", [.frameio: "u"], quiet: true, at: t0)
        let decoded = try? JSONDecoder().decode(PlanOutbox.self, from: JSONEncoder().encode(box))
        #expect(decoded == box)
    }

    @Test("Typed cells are found again by code and header, and refused when the sheet changed them")
    func locateCells() {
        let table = [["Code", "File Name", "Length"], ["KL2", "B", "6s"], ["KL1", "A", "15s"]]
        func cell(line: Int, column: Int, code: String?, header: String?, expect: String) -> PlanOutbox.Cell {
            PlanOutbox.Cell(gid: "1", line: line, column: column, sheetColumn: column, code: code, header: header, value: "x", expect: expect, changed: Date())
        }
        // Sorted since: KL1 moved from line 2 to line 3.
        if case .success(let (r, c)) = DeliveryPlanStore.locate(cell(line: 2, column: 2, code: "KL1", header: "Length", expect: "15s"), in: table) {
            #expect(r == 2 && c == 2)
        } else { Issue.record("not found") }
        // A column inserted before Length: found by header.
        let moved = [["Code", "File Name", "Note", "Length"], ["KL1", "A", "", "15s"]]
        if case .success(let (_, c)) = DeliveryPlanStore.locate(cell(line: 2, column: 2, code: "KL1", header: "length", expect: "15s"), in: moved) {
            #expect(c == 3)
        } else { Issue.record("not found") }
        // Two columns with the same header: the one typed in stays.
        let twice = [["Code", "Notes", "Notes"], ["KL1", "", ""]]
        if case .success(let (_, c)) = DeliveryPlanStore.locate(cell(line: 2, column: 2, code: "KL1", header: "Notes", expect: ""), in: twice) {
            #expect(c == 2)
        } else { Issue.record("not found") }
        if case .failure(let refusal) = DeliveryPlanStore.locate(cell(line: 3, column: 2, code: "KL1", header: "Length", expect: "10s"), in: table) {
            #expect(refusal.message.contains("now “15s”"))
        } else { Issue.record("should refuse") }
        if case .failure(let refusal) = DeliveryPlanStore.locate(cell(line: 2, column: 2, code: "KL7", header: nil, expect: ""), in: table) {
            #expect(refusal.message.contains("KL7"))
        } else { Issue.record("should refuse") }
    }
}

extension DeliveryPlanSheetsTests {
    @Test("Sign-in: the id token's email, the redirect from the client id")
    func auth() {
        let payload = GoogleAuth.base64URL(Data(#"{"email":"ric@wildislandfilms.com","sub":"1"}"#.utf8))
        #expect(GoogleAuth.email(fromIDToken: "h.\(payload).s") == "ric@wildislandfilms.com")
        #expect(GoogleAuth.email(fromIDToken: "nonsense") == nil)
    }

    @Test("Sheets API: a refused token is refreshed once; 403, 404 and 429 are told apart; + in ranges is encoded")
    func api() async throws {
        StubSheets.reset()
        let auth = GoogleAuth(session: StubSheets.session, tokens: .init(access: "old", refresh: nil, expires: .distantFuture))
        let api = SheetsAPI(auth: auth, session: StubSheets.session)
        StubSheets.respond = { request in
            #expect(request.url?.absoluteString.contains("%2B") == true)   // "A+B" tab name
            return (200, #"{"valueRanges":[{"values":[["Code"],["KL1"]]}]}"#)
        }
        let data = try await api.values("sheet", ranges: ["'A+B'"])
        #expect(try SheetsAPI.tables(data) == [[["Code"], ["KL1"]]])

        StubSheets.respond = { _ in (403, #"{"error":{"message":"The caller does not have permission"}}"#) }
        await #expect(throws: SheetsAPI.Failure.noAccess("The caller does not have permission")) { try await api.metadata("sheet") }
        StubSheets.respond = { _ in (404, "{}") }
        await #expect(throws: SheetsAPI.Failure.notFound) { try await api.metadata("sheet") }
        StubSheets.respond = { _ in (429, "{}") }
        do { _ = try await api.metadata("sheet"); Issue.record("should throw") } catch let failure as SheetsAPI.Failure {
            #expect(failure.isTransient)
        }
        // 401 with no refresh token: signed out, after exactly one try.
        StubSheets.respond = { _ in (401, "{}") }
        await #expect(throws: GoogleAuth.Failure.self) { try await api.metadata("sheet") }
    }
}

/// Answers Sheets API requests in tests.
final class StubSheets: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest) -> (Int, String) = { _ in (200, "{}") }
    static func reset() { respond = { _ in (200, "{}") } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSheets.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension DeliveryPlanSheetsTests {
    @Test("Summary: states, batches, Frame.io as the filters count them, newest reviews once per code")
    func summary() {
        let csv = """
        "Code","File Name","Channel"
        "KL1","A_KL1","Web"
        "KL2","B_KL2","Social"
        "KL3","C_KL3","Social"
        "KL1","A_KL1","Web"
        """
        let rows = PlanParser.rows(csv: csv, tab: "P")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let states: [PlanState] = [.approved, .missing, .dropped, .approved]
        let stamps = [PlanStatusResolver.stamp(now.addingTimeInterval(-60), by: "Ric"), "", "",
                      PlanStatusResolver.stamp(now.addingTimeInterval(-60), by: "Ric")]
        let index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
        let summary = PlanSummary.build(
            rows: rows, batchNames: ["1"],
            state: { r in var s = PlanRowState(state: states[index[r.id]!]); if index[r.id]! == 2 { s.upload = .uploaded }; return s },
            batch: { index[$0.id]! == 0 ? "1" : "" },
            status: { index[$0.id]! == 0 || index[$0.id]! == 3 ? "Approved" : "" },
            updated: { stamps[index[$0.id]!] }, now: now)
        #expect(summary.total == 4 && summary.done == 2 && summary.dropped == 1 && summary.live == 3)
        #expect(summary.batches.map(\.name) == ["1", ""] && summary.batches[0].done == 1)
        #expect(summary.channels.map(\.name) == ["Social", "Web"])
        // Dropped rows count too: the Frame.io filter shows them.
        #expect(summary.uploads.on == 1 && summary.uploads.none == 3)
        // KL1 is listed twice: one review.
        #expect(summary.recent.map(\.code) == ["KL1"] && summary.reviewedToday == 1 && summary.recent[0].who == "Ric")
    }
}

extension DeliveryPlanSheetsTests {
    @Test("Health: the badge names the most pressing problem first")
    func health() {
        var h = PlanHealth()
        #expect(h.status(signedIn: false, hasQCTab: true).text == "Signed out")
        #expect(h.status(signedIn: true, hasQCTab: true) == (.good, "Synced"))
        #expect(h.status(signedIn: true, hasQCTab: false).text == "No QCpie tab")
        h.waiting = 3
        #expect(h.status(signedIn: true, hasQCTab: true) == (.busy, "Saving 3"))
        h.retrying = true; h.writeError = "offline"
        #expect(h.status(signedIn: true, hasQCTab: true) == (.warning, "3 waiting"))
        h.canWrite = false
        #expect(h.status(signedIn: true, hasQCTab: true).text == "View only")
        h.readError = "403"
        #expect(h.status(signedIn: true, hasQCTab: true) == (.problem, "Can't read"))
    }
}

extension DeliveryPlanSheetsTests {
    @Test("Frame.io folder: titled by project and folders, account and workspace left out")
    func frameIORootTitle() {
        let path: [FrameIOBrowser.Crumb] = [
            .init(level: .account, id: "a", title: "Studio", folderID: nil),
            .init(level: .workspace, id: "w", title: "Clients", folderID: nil),
            .init(level: .project, id: "p", title: "KARL SS27", folderID: "root"),
            .init(level: .folder, id: "f", title: "Deliveries", folderID: nil),
        ]
        #expect(DeliveryPlanStore.rootTitle(path) == "KARL SS27 › Deliveries")
        #expect(PlanFrameIORootSheet.scanText(.scanning(20)) == "Reading… 20 folders")
    }
}
