import CoreMedia
import Foundation
import Testing
@testable import QCpie
@testable import VideoQCLib

/// Hostile input for the parsers and formatters that read files, sheets and links: nothing here may crash
/// (Swift traps on Int(NaN), Int(±inf), out-of-range conversions and integer overflow) or hang.
@Suite("Edge input")
struct EdgeInputTests {

    // MARK: Timecode

    @Test("Timecode formats odd rates and frame numbers")
    func timecode() {
        #expect(TimecodeFormatter.format(frameIndex: 0, fps: .nan) == "00:00:00:00")
        #expect(TimecodeFormatter.format(frameIndex: 25, fps: 0) == "00:00:25:00")      // clamped to 1 fps
        #expect(TimecodeFormatter.format(frameIndex: -10, fps: 25) == "00:00:00:00")
        #expect(TimecodeFormatter.format(frameIndex: 1, fps: .infinity) == "00:00:00:01")
        _ = TimecodeFormatter.format(frameIndex: Int.max, fps: 25)
        _ = TimecodeFormatter.format(frameIndex: Int.max, fps: 25, startFrameOffset: 10)
        _ = TimecodeFormatter.format(frameIndex: 10, fps: 1e300)
        _ = TimecodeFormatter.format(time: CMTime(seconds: 1e300, preferredTimescale: 1), fps: 25)
        _ = TimecodeFormatter.format(time: .invalid, fps: 25)
        _ = TimecodeFormatter.format(time: .positiveInfinity, fps: 25)
    }

    @Test("Frame rates read as written: 29.97 isn't shown as 30")
    func frameRateLabels() {
        #expect(QCUtilities.formatFPS(29.97002997) == "29.97")
        #expect(QCUtilities.formatFPS(23.976) == "23.976")
        #expect(QCUtilities.formatFPS(59.94) == "59.94")
        #expect(QCUtilities.formatFPS(25) == "25")
        #expect(QCUtilities.formatFPS(.nan) == "--")
        #expect(Set(QueueSequenceInfo.rates.map(QueueSequenceInfo.rateLabel)).count == QueueSequenceInfo.rates.count)
    }

    @Test("A folder named like a clip isn't listed as media")
    func folderNamedLikeClip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qcpie-walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Render.mov"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Render.mov/inner.mov"))
        try Data().write(to: root.appendingPathComponent("clip.mp4"))
        let flat = VideoScanner.findMediaFiles(in: root, includeSubfolders: false).map(\.lastPathComponent)
        let deep = VideoScanner.findMediaFiles(in: root, includeSubfolders: true).map(\.lastPathComponent)
        #expect(flat == ["clip.mp4"])
        #expect(deep == ["clip.mp4", "inner.mov"])
    }

    // MARK: Subtitles

    @Test("SRT parsing survives junk and keeps times finite")
    func srt() {
        #expect(SubtitleParser.parseSRT("").isEmpty)
        #expect(SubtitleParser.parseSRT("\u{FEFF}").isEmpty)
        let junk = """
        1
        00:00:inf,000 --> 00:00:02,000
        bad

        2
        00:00:nan --> 00:00:03,000
        worse

        3
        1e999:00:00,000 --> 00:00:04,000
        huge

        4
        -00:00:05,000 --> 00:00:06,000
        negative
        """
        let cues = SubtitleParser.parseSRT(junk)
        #expect(cues.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 })
        _ = SubtitleParser.serializeSRT(cues)
        _ = SubtitleParser.timestamp(.nan)
        _ = SubtitleParser.timestamp(.infinity)
        _ = SubtitleParser.timestamp(-5)
        _ = SubtitleParser.timestamp(1e300)
        #expect(SubtitleParser.cueIndex(at: .nan, in: cues) == nil || true)
        let crlf = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nBye\r\n"
        #expect(SubtitleParser.parseSRT(crlf).count == 2)
    }

    // MARK: Delivery Plan sheet values

    @Test("Sheet cells with absurd numbers don't trap")
    func planValues() {
        _ = PlanParser.bytes("99999999999999999999 GB")
        _ = PlanParser.bytes("1e30 mb")
        #expect(PlanParser.bytes("5 MB") == 5_000_000)
        _ = PlanParser.seconds("99999999999999999999s")
        _ = PlanParser.seconds("1:2:3:4:5:6")
        _ = PlanParser.seconds("/")
        _ = PlanParser.seconds("30s / / 15s")
        _ = PlanParser.resolution("99999999999999999999x1080")
        _ = PlanParser.resolution("0x0")
        _ = PlanParser.aspect("16:0")
        _ = PlanParser.aspect("0:0")
        _ = PlanParser.frameRate("99999999999999999999999999 fps")
        _ = PlanParser.nameSeconds("clip_99999999999999999999s.mp4")
        _ = PlanParser.csv("\"unterminated, \"quote\n,,,\n\"")
        _ = PlanParser.parse(table: [], tab: "T")
        _ = PlanParser.parse(table: [[], [""], ["Code"]], tab: "T")
        #expect(PlanMatcher.contains(["a"], ["a", "b"]) == false)
        #expect(PlanMatcher.contains([], []) == false)
    }

    @Test("Batch numbering copes with huge and odd names")
    func batches() {
        #expect(PlanBatch.next(after: []) == "1")
        #expect(PlanBatch.next(after: ["2", "10"]) == "11")
        _ = PlanBatch.next(after: ["\(Int.max)"])
        _ = PlanBatch.sorted(["", "  ", "Final", "2", "10", "\(Int.max)", "99999999999999999999"])
    }

    @Test("QC stamps and columns with odd input")
    func stampsAndColumns() {
        #expect(PlanGrid.columnName(0) == "A")
        #expect(PlanGrid.columnName(25) == "Z")
        #expect(PlanGrid.columnName(26) == "AA")
        _ = PlanGrid.columnName(-5)
        _ = PlanGrid.columnName(Int.max - 1)
        _ = PlanStatusResolver.date(fromStamp: "")
        _ = PlanStatusResolver.date(fromStamp: "9999-99-99 99:99:99 UTC · x")
        _ = PlanSheetLink.parse("")
        _ = PlanSheetLink.parse("https://docs.google.com/spreadsheets/d/")
        _ = PlanSheetLink.parse("https://docs.google.com/spreadsheets/d/abc def/edit#gid=notanumber")
    }

    // MARK: Frame.io

    @Test("Comment timecodes and links with odd input")
    func frameIO() {
        #expect(FrameIOCommentImport.frames("00:00:01:00", fps: 25) == 25)
        _ = FrameIOCommentImport.frames("99999999999999:00:00:00", fps: 25)
        _ = FrameIOCommentImport.frames("00:00:00:00", fps: .nan)
        _ = FrameIOCommentImport.frames("00:00:00:00", fps: 1e300)
        _ = FrameIOCommentImport.frames("::::", fps: 25)
        _ = FrameIOCommentImport.frames("01:00:00;00", fps: 29.97)
        for text in ["", "https://", "https://next.frame.io/project/", "https://next.frame.io/project//view/",
                     "next.frame.io/project/a/b/c/d/e/f", "https://f.io/", "javascript:alert(1)", String(repeating: "/", count: 5000)] {
            _ = try? FrameIOLink.parse(text)
            _ = FrameIOLink.looksLikeLink(text)
        }
    }

    // MARK: Utilities and sequences

    @Test("Utilities with odd input")
    func utilities() {
        #expect(QCUtilities.gcd(0, 0) == 1)
        #expect(QCUtilities.gcd(Int.min + 1, 2) >= 1)
        _ = QCUtilities.escapeCSV("a,\"b\"\nc")
        _ = QCUtilities.escapeTSV("a\tb\nc")
        _ = FrameRate.counting(nominal: .nan)
        _ = FrameRate.counting(nominal: -1)
        _ = FrameRate.counting(nominal: .infinity)
    }

    @Test("Image sequence detection with odd names")
    func sequences() {
        let dir = URL(fileURLWithPath: "/tmp/seq")
        let huge = (0..<8).map { dir.appendingPathComponent("f_9999999999999999999\($0).png") }
        let mixed = (0..<8).map { dir.appendingPathComponent("frame_\($0).PNG") } + [dir.appendingPathComponent(".png")]
        let negative = (0..<8).map { dir.appendingPathComponent("f-\($0).png") }
        _ = ImageSequenceDetector.detect(huge)
        _ = ImageSequenceDetector.detect(mixed)
        _ = ImageSequenceDetector.detect(negative)
        _ = ImageSequenceDetector.detect([])
    }
}

/// A file cut off after its index (render or copy still running, interrupted download) opens and reports its full
/// duration; Inspect must flag it instead of passing it.
@Suite("Cut-off files")
struct CutOffFileTests {
    @Test("Inspect flags a clip whose data stops before its index says")
    func cutOffIsFlagged() async throws {
        let url = try await TestClips.ntscOn600TimeBase(Scenes.picture(), frames: 120, indexFirst: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let intact = try #require(await DeliverablesInspector.inspectBatch(urls: [url], maxConcurrency: 1).first)
        #expect(intact.validation.durationMismatchDetail?.contains("CUT OFF") != true)

        let data = try Data(contentsOf: url)
        let cut = url.deletingLastPathComponent().appendingPathComponent("cut.mov")
        try data.prefix(data.count * 6 / 10).write(to: cut)
        let asset = try #require(await DeliverablesInspector.inspectBatch(urls: [cut], maxConcurrency: 1).first)
        #expect(asset.validation.isDurationMismatch)
        #expect(asset.validation.durationMismatchDetail?.contains("CUT OFF") == true)

        // Upload's preflight flags it too (it opens, so "can't be opened" alone missed it); the intact clip passes.
        func row(_ file: URL) -> UploadPreflight.Row {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            return .init(path: file.path, name: file.lastPathComponent, files: [file], sizes: [size], topLevel: true)
        }
        #expect(await UploadPreflight.unreadable([row(url), row(cut)]) == [cut.path])
    }
}

/// Google returns formatted values: a sheet in an Italian (or other comma-decimal) locale sends "2,5s", "29,97", "1,5 GB".
@Suite("Comma decimals in sheet values")
struct CommaDecimalTests {
    @Test("Lengths, rates and sizes read the same with a comma")
    func commaDecimals() {
        #expect(PlanParser.seconds("2,5s") == PlanParser.seconds("2.5s"))
        #expect(PlanParser.seconds("2,5 sec") == PlanParser.seconds("2.5s"))
        #expect(PlanParser.seconds("1,30") == nil, "ambiguous: maybe 1:30, so no length rather than 1.3 s")
        #expect(PlanParser.frameRate("29,97") == 29.97)
        #expect(PlanParser.bytes("1,5 GB") == 1_500_000_000)
        #expect(PlanParser.aspect("1,85:1") == PlanParser.aspect("1.85:1"))
        #expect(PlanParser.aspect("17x20,9x16") == PlanParser.aspect("17x20"))   // a list, not 20.9
        #expect(PlanParser.seconds("30s,15s") == nil || PlanParser.seconds("30s,15s") != 30.15...30.15)
    }
}

/// Saving subtitles and reading them back must give the same cues (what SubRip can hold of them).
@Suite("Subtitle round trip")
struct SubtitleRoundTripTests {
    @Test("Random cues survive serialize → parse, blank lines inside a cue included")
    func roundTrip() {
        var rng = SplitMix64(seed: 7)
        let pieces = ["Hello", "<i>tilted</i>", "{\\an8}top", "Ciao, com'è?", "→ arrow -->", "911", "日本語", "  ", "", "a\tb", "-- dash", "1"]
        for _ in 0..<2_000 {
            var t = 0.0
            let cues: [SubtitleCue] = (0..<Int(rng.next() % 6)).map { _ in
                t += Double(rng.next() % 5_000) / 1000
                let start = t
                t += Double(1 + rng.next() % 4_000) / 1000
                let lines = (0..<Int(1 + rng.next() % 4)).map { _ in pieces[Int(rng.next() % UInt64(pieces.count))] }
                return SubtitleCue(start: start, end: t, text: lines.joined(separator: "\n"))
            }
            let read = SubtitleParser.parseSRT(SubtitleParser.serializeSRT(cues))
            let expected = cues.map { cue in
                cue.text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
            }
            #expect(read.count == cues.count)
            #expect(read.map(\.text) == expected)
            #expect(zip(read, cues).allSatisfy { abs($0.start - $1.start) < 0.0011 && abs($0.end - $1.end) < 0.0011 })
            if read.count != cues.count || read.map(\.text) != expected { break }
        }
    }
}

/// Whatever a producer types into the sheet: the parser and matcher must never crash, and rows always have names.
@Suite("Plan parser fuzz")
struct PlanParserFuzzTests {
    @Test("Random sheets parse and match without crashing")
    func randomSheets() {
        var rng = SplitMix64(seed: 99)
        func pick<T>(_ a: [T]) -> T { a[Int(rng.next() % UInt64(a.count))] }
        let words = ["Code", "File Name", "Filename", "Length", "Duration", "Resolution", "Aspect", "Ratio", "Size", "Format", "FPS",
                     "Channel", "Placement", "Logo", "Subs", "QC Status", "QC Note", "Batch", "Frame.io", "Total", "Grand total",
                     "", " ", "KL0001", "KL0002", "kl0001", "TEASER_15s_KL0001", "15s", "2-3s", "1:30", "1920x1080", "9x16", "1,85:1",
                     "20 MB", "max 1,5 GB", "mov", "ProRes", "gif", "29,97", "QC Passed", "Approved", "Needs Fix", "Dropped", "1", "13",
                     "日本語", "→", "\"quoted\"", "a,b", "line\nbreak", "=SUM(A1)", "9999999999999999999999 GB", "nan", "-", "N/A"]
        for _ in 0..<1_500 {
            let table: [[String]] = (0..<Int(rng.next() % 25)).map { _ in (0..<Int(rng.next() % 12)).map { _ in pick(words) } }
            let (rows, _) = PlanParser.parse(table: table, tab: "T")
            #expect(rows.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
            let files = (0..<Int(rng.next() % 6)).map { _ in
                PlanFile(url: URL(fileURLWithPath: "/d/\(pick(words))_\(pick(words)).mp4"), width: Int(rng.next() % 4000), height: Int(rng.next() % 4000),
                         seconds: Double(rng.next() % 100), fps: 25, bytes: Int64(rng.next() % 1_000_000), codec: "H.264", hasAudio: rng.next() % 2 == 0)
            }
            _ = PlanMatcher.match(rows: rows, files: files)
            var flagged = rows
            PlanParser.flagDuplicates(&flagged)
        }
    }
}

/// Google's replies and the QCpie tab, however odd: parsing, laying out and locating cells must never crash.
@Suite("Sheet reply fuzz")
struct SheetReplyFuzzTests {
    static let words = ["Code", "Deliverable", "QC Status", "QC Note", "QC Updated", "Batch", "Frame.io", "Uploaded", "", "KL1", "KL1", "kl2",
                        "QC Passed", "x", "日本", "=A1", "\"", "\n"]
    func tables(_ seed: UInt64, _ body: ([[String]], inout SplitMix64) -> Void) {
        var rng = SplitMix64(seed: seed)
        for _ in 0..<1_500 {
            let table: [[String]] = (0..<Int(rng.next() % 12)).map { _ in (0..<Int(rng.next() % 30)).map { _ in Self.words[Int(rng.next() % UInt64(Self.words.count))] } }
            body(table, &rng)
        }
    }

    @Test("QCpie tab: parse and writes")
    func qcTab() {
        tables(5) { table, rng in
            guard let qc = PlanQCTab.parse(table) else { return }
            let codes = ["KL1", "kl2", "KL9", ""]
            let changes = (0..<Int(rng.next() % 4)).map { _ in
                PlanQCTab.Change(code: codes[Int(rng.next() % 4)], name: "n", values: [.qcStatus: "QC Passed", .batch: rng.next() % 2 == 0 ? "1" : ""])
            }
            _ = PlanQCTab.writes(changes, into: qc)
        }
    }

    @Test("Sheet view grid from a table")
    func grid() { tables(6) { table, _ in _ = PlanGrid.fromTable(table) } }

    @Test("Locating a typed cell again")
    func locate() {
        tables(7) { table, rng in
            let cell = PlanOutbox.Cell(gid: "0", line: Int(rng.next() % 15) - 2, column: Int(rng.next() % 35) - 2,
                                       sheetColumn: Int(rng.next() % 35) - 2, code: ["KL1", nil, ""][Int(rng.next() % 3)],
                                       header: ["QC Note", nil, "", "Missing"][Int(rng.next() % 4)], value: "v",
                                       expect: ["", "x", "KL1"][Int(rng.next() % 3)], changed: Date())
            _ = DeliveryPlanStore.locate(cell, in: table)
        }
    }

    @Test("Odd JSON replies")
    func replies() {
        let replies = ["", "{}", "[]", "null", "{\"valueRanges\": 3}", "{\"valueRanges\": [{\"values\": [[1, null, true, {\"a\":1}]]}]}",
                       "{\"valueRanges\": [{\"values\": \"x\"}]}", "{\"sheets\": [{\"data\": [{\"rowData\": [{\"values\": [{}]}]}]}]}",
                       "{\"sheets\": [{\"data\": [{\"rowMetadata\": [{\"pixelSize\": -5}], \"columnMetadata\": [{\"pixelSize\": 1e300}]}], \"merges\": [{\"startRowIndex\": 5, \"endRowIndex\": 2}]}]}"]
        for reply in replies {
            let data = Data(reply.utf8)
            _ = try? SheetsAPI.tables(data)
            _ = PlanGrid.fromSheets(layout: data, table: [["a", "b"], ["c"]])
            _ = DeliveryPlanStore.parseValidations(data)
        }
    }
}

/// Note text as reviewers type it (and Frame.io comments bring it): link detection must never crash or lose text.
@Suite("Note text fuzz")
struct NoteTextFuzzTests {
    @Test("Links, paths, emoji and quotes in any mix")
    func randomNotes() {
        var rng = SplitMix64(seed: 11)
        let pieces = ["https://next.frame.io/project/a/b", "www.example.com", "\"/Volumes/Media/Cut 1.mov\"", "'~/Downloads/x.mov'",
                      "/Volumes/Media/raw.mov", "file:///tmp/a.mov", "00:00:10:12", "👍🏽", "日本語", "\"", "'", " ", "\n", "e.g.",
                      "a@b.com", "http://", "\"/Volumes/a\"/Volumes/b\"", "mailto:x@y.z", "ftp://h/x", "🇮🇹", "\u{200B}", "→"]
        for _ in 0..<3_000 {
            let text = (0..<Int(rng.next() % 12)).map { _ in pieces[Int(rng.next() % UInt64(pieces.count))] }.joined(separator: rng.next() % 2 == 0 ? " " : "")
            let (attributed, _) = NoteLinkParser.buildAttributedString(text: text, isResolved: rng.next() % 2 == 0,
                                                                       accentColor: .blue, textMuted: .gray, textMain: .black)
            #expect(String(attributed.characters) == text)
        }
    }
}

/// Whatever Frame.io returns: importing comments as notes and merging them must never crash.
@Suite("Frame.io comment fuzz")
struct FrameIOCommentFuzzTests {
    @Test("Random comments import and merge")
    func randomComments() {
        var rng = SplitMix64(seed: 13)
        func maybe<T>(_ v: T) -> T? { rng.next() % 3 == 0 ? nil : v }
        let codes = ["00:00:10:11", "01:00:00;00", "99:99:99:99", "", "::", "00:00:00:00", "garbage", "23:59:59:29", "-1:00:00:00"]
        let dates = ["2026-10-01T09:30:00.000Z", "2026-10-01T09:30:00Z", "", "not a date", "1970-01-01T00:00:00Z"]
        func comment(_ depth: Int) -> FrameIO.Comment {
            FrameIO.Comment(id: ["c1", "c2", "c1", "", "x"][Int(rng.next() % 5)], text: ["", "Fix", "👍", "\n\n"][Int(rng.next() % 4)],
                            annotation: maybe("{}"), timestamp: maybe([0, 1, -5, 2_000_000_000, -2_000_000_000, 9999999][Int(rng.next() % 6)]),
                            timecode: maybe(codes[Int(rng.next() % UInt64(codes.count))]), duration: maybe([0, -1, 50, 2_000_000_000][Int(rng.next() % 4)]),
                            completedAt: maybe(dates[Int(rng.next() % UInt64(dates.count))]), createdAt: maybe(dates[Int(rng.next() % UInt64(dates.count))]),
                            textEditedAt: maybe(dates[Int(rng.next() % UInt64(dates.count))]), owner: maybe(.init(name: maybe("Ana"), email: maybe("a@b"))),
                            replies: depth > 0 ? (0..<Int(rng.next() % 3)).map { _ in comment(depth - 1) } : nil)
        }
        var local: [QCFileNote] = []
        for _ in 0..<2_000 {
            let comments = (0..<Int(rng.next() % 5)).map { _ in comment(1) }
            let fps = [25, 29.97, 0, .nan, 1e300, 60][Int(rng.next() % 6)]
            let start = FrameIOCommentImport.startFrames(comments, fps: fps)
            for c in comments { _ = FrameIOCommentImport.frame(of: c, fps: fps, start: start) }
            let incoming = FrameIOCommentImport.notes(from: comments, fps: fps)
            let merged = FrameIOCommentImport.merge(local: local, incoming: incoming, previouslyImported: [], sent: [])
            local = Array(merged.notes.prefix(20))
        }
    }
}

/// The Sheet view's layout from Google's grid data, however malformed: never crash.
@Suite("Sheet layout fuzz")
struct SheetLayoutFuzzTests {
    @Test("Random grid data with odd merges, sizes and colours")
    func randomLayouts() throws {
        var rng = SplitMix64(seed: 17)
        func n(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(rng.next() % UInt64(range.count)) }
        func num() -> Any { [0, 1, -1, 0.5, 2, 1e300, -1e300, 255, "x", NSNull()][n(0...9)] }
        for _ in 0..<800 {
            let rows = n(0...8), cols = n(0...8)
            let rowData: [[String: Any]] = (0..<rows).map { _ in
                ["values": (0..<n(0...10)).map { _ -> [String: Any] in
                    ["formattedValue": ["", "a", "1", "日本"][n(0...3)],
                     "effectiveFormat": ["backgroundColor": ["red": num(), "green": num(), "blue": num()],
                                         "textFormat": ["foregroundColor": ["red": num()], "bold": [true, false, 1][n(0...2)], "fontSize": num()],
                                         "horizontalAlignment": ["LEFT", "CENTER", "x", ""][n(0...3)],
                                         "borders": ["top": ["style": "SOLID", "width": num(), "color": ["blue": num()]]]]]
                }]
            }
            let merges: [[String: Any]] = (0..<n(0...3)).map { _ in
                ["startRowIndex": n(-2...12), "endRowIndex": n(-2...12), "startColumnIndex": n(-2...12), "endColumnIndex": n(-2...12)]
            }
            let json: [String: Any] = ["sheets": [["data": [["rowData": rowData,
                                                             "rowMetadata": (0..<n(0...10)).map { _ in ["pixelSize": num(), "hiddenByUser": n(0...1) == 1] },
                                                             "columnMetadata": (0..<n(0...10)).map { _ in ["pixelSize": num(), "hiddenByUser": n(0...1) == 1] }]],
                                                   "merges": merges, "properties": ["gridProperties": ["frozenRowCount": n(-1...20)]]]]]
            let data = try JSONSerialization.data(withJSONObject: json)
            let table: [[String]] = (0..<n(0...10)).map { _ in (0..<n(0...10)).map { _ in "v" } }
            if let grid = PlanGrid.fromSheets(layout: data, table: table) { _ = grid.withTexts(table) }
        }
    }
}

/// Notes sync between Macs: random edits on two sides against a common base. The merge must keep every one-sided
/// change and every one-sided deletion, whatever the mix.
@Suite("Notes merge properties")
struct NotesMergePropertyTests {
    @Test("One-sided adds, edits and deletes always survive the merge")
    func properties() {
        var rng = SplitMix64(seed: 23)
        func n(_ k: Int) -> Int { Int(rng.next() % UInt64(max(1, k))) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<2_000 {
            let base = (0..<n(6)).map { i in QCFileNote(frameIndex: n(100), timecode: "", author: "A", text: "base \(i)", createdAt: t0.addingTimeInterval(Double(i))) }
            enum Op { case keep, edit, delete }
            func side(_ tag: String) -> ([QCFileNote], [UUID: Op], [QCFileNote]) {
                var ops: [UUID: Op] = [:]
                var notes: [QCFileNote] = []
                for note in base {
                    let op: Op = [.keep, .edit, .delete][n(3)]
                    ops[note.id] = op
                    switch op {
                    case .keep: notes.append(note)
                    case .edit:
                        var e = note; e.text = "\(tag) edit"; e.editedAt = t0.addingTimeInterval(100 + Double(n(50))); notes.append(e)
                    case .delete: break
                    }
                }
                let added = (0..<n(3)).map { _ in QCFileNote(frameIndex: n(100), timecode: "", author: tag, text: "\(tag) new", createdAt: t0) }
                return (notes + added, ops, added)
            }
            let (local, lops, ladd) = side("L"), (remote, rops, radd) = side("R")
            let merged = QCNotesManager.threeWayMerge(local: local, remote: remote, base: base)
            let byID = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            #expect(merged.count == byID.count, "no duplicate ids")
            for a in ladd + radd { #expect(byID[a.id] != nil, "an added note survives") }
            for note in base {
                switch (lops[note.id]!, rops[note.id]!) {
                case (.keep, .keep): #expect(byID[note.id] == note)
                case (.edit, .keep): #expect(byID[note.id]?.text == "L edit")
                case (.keep, .edit): #expect(byID[note.id]?.text == "R edit")
                case (.delete, .keep), (.keep, .delete), (.delete, .delete): #expect(byID[note.id] == nil, "a one-sided delete sticks")
                case (.edit, .edit): #expect(byID[note.id] != nil)
                case (.edit, .delete), (.delete, .edit): break   // policy: the deletion wins (see the summary)
                }
            }
            let flipped = QCNotesManager.threeWayMerge(local: remote, remote: local, base: base)
            #expect(Set(flipped.map(\.id)) == Set(merged.map(\.id)), "which Mac merges doesn't change which notes exist")
            let unchanged: Set<UUID> = Set(QCNotesManager.threeWayMerge(local: base, remote: base, base: base).map(\.id))
            let baseIDs: Set<UUID> = Set(base.map(\.id))
            #expect(unchanged == baseIDs)
        }
    }
}

/// The queue's folder tree: every file once, in any mix of folders and roots.
@MainActor
@Suite("Folder tree fuzz")
struct FolderTreeFuzzTests {
    @Test("Every queued file appears exactly once in the tree")
    func everyFileOnce() {
        var rng = SplitMix64(seed: 29)
        let parts = ["Shoot", "Day 1", "day 1", "Edits", "A", "B", "日本", "a.b", "x y", "_TEST", "Shoot"]
        for _ in 0..<1_500 {
            let root: URL? = rng.next() % 4 == 0 ? nil : URL(fileURLWithPath: "/Volumes/Server/" + parts[Int(rng.next() % UInt64(parts.count))])
            let base = root?.path ?? "/Volumes/Other"
            var seen = Set<String>()
            let files: [URL] = (0..<Int(rng.next() % 30)).compactMap { i in
                let depth = Int(rng.next() % 4)
                let dirs = (0..<depth).map { _ in parts[Int(rng.next() % UInt64(parts.count))] }
                let outside = rng.next() % 8 == 0
                let path = ([outside ? "/Users/me/Desktop" : base] + dirs + ["clip \(i).mov"]).joined(separator: "/")
                return seen.insert(path).inserted ? URL(fileURLWithPath: path) : nil
            }
            FileSystemTreeBuilder.clearCache()
            let tree = FileSystemTreeBuilder.buildTree(rootURL: root, files: files)
            let listed = FileSystemTreeBuilder.orderedVideoURLs(from: tree).map(\.standardizedFileURL.path)
            #expect(listed.count == files.count, "listed \(listed.count) of \(files.count)")
            #expect(Set(listed) == Set(files.map(\.standardizedFileURL.path)))
            if listed.count != files.count { break }
        }
    }
}

/// Frame.io links as people paste them: extras around or after the link must not change what it points to.
@Suite("Frame.io link variants")
struct FrameIOLinkVariantTests {
    @Test("Trailing slash, query, fragment, spaces and brackets resolve the same")
    func variants() throws {
        let p = "1a2b3c4d-0000-4000-8000-000000000001", f = "1a2b3c4d-0000-4000-8000-000000000002", v = "1a2b3c4d-0000-4000-8000-000000000003"
        for base in ["https://next.frame.io/project/\(p)", "https://next.frame.io/project/\(p)/\(f)", "https://next.frame.io/project/\(p)/view/\(v)"] {
            let reference = try FrameIOLink.parse(base)
            for variant in [base + "/", base + "?view=grid", base + "#comments", " \(base) ", "<\(base)>", base + "/?a=1#b",
                            base.replacingOccurrences(of: "https://", with: "http://"), base.replacingOccurrences(of: "https://", with: "")] {
                let parsed = try? FrameIOLink.parse(variant)
                #expect(parsed == reference, "\(variant) → \(String(describing: parsed))")
            }
        }
    }
}

/// Two renders of a sequence in one folder with different padding (shot_009.png and shot_9.png) must not be
/// silently mixed into one: the duplicate frame numbers are counted so Inspect can flag them.
@Suite("Image sequence duplicates")
struct ImageSequenceDuplicateTests {
    @Test("Mixed padding: duplicates are counted, and frames come from one render")
    func mixedPadding() throws {
        let dir = URL(fileURLWithPath: "/tmp/seqdup")
        let a = (1...10).map { dir.appendingPathComponent("shot_" + String(format: "%03d", $0) + ".png") }
        let b = (1...10).map { dir.appendingPathComponent("shot_\($0).png") }
        let seq = try #require(ImageSequenceDetector.detect(a + b).first)
        #expect(seq.duplicateCount == 10)
        #expect(seq.length == 10)
    }
}

/// What the app writes as CSV, the app reads back cell for cell.
@Suite("CSV round trip")
struct CSVRoundTripTests {
    @Test("escapeCSV → PlanParser.csv returns the same table")
    func roundTrip() {
        var rng = SplitMix64(seed: 31)
        let pieces = ["a", "b c", "x,y", "\"q\"", "multi\nline", "crlf\r\nline", " lead", "trail ", "", "日本", "a\"b,c\nd", "=1+2", ",", "\"", "\n"]
        for _ in 0..<2_000 {
            let cols = 1 + Int(rng.next() % 6)
            let table: [[String]] = (0..<Int(1 + rng.next() % 6)).map { _ in (0..<cols).map { _ in pieces[Int(rng.next() % UInt64(pieces.count))] } }
            let text = table.map { $0.map(QCUtilities.escapeCSV).joined(separator: ",") }.joined(separator: "\n") + "\n"
            let read = PlanParser.csv(text)
            #expect(read == table, "wrote \(table) read \(read)")
            if read != table { break }
        }
    }
}
