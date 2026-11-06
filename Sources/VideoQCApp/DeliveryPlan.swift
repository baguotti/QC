import Foundation
import VideoQCLib

// Delivery Plan: a Google Sheet listing every deliverable (one row per file), read as CSV and matched against the
// files the Inspect tab has measured. Pure model: parsing, cleaning, matching. Fetching and state live in
// `DeliveryPlanStore`, the UI in `DeliveryPlanPanel`.

/// A Google Sheets link: the spreadsheet id and, when the link points at a tab, its gid.
struct PlanSheetLink: Codable, Equatable, Sendable {
    let sheetID: String
    var gid: String?

    /// `…/spreadsheets/d/<id>/edit#gid=<gid>`, `…?gid=`, or a bare id.
    static func parse(_ text: String) -> PlanSheetLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let gid = trimmed.range(of: #"[#?&]gid=(\d+)"#, options: .regularExpression)
            .map { String(trimmed[$0].drop { $0 != "=" }.dropFirst()) }
        if let range = trimmed.range(of: #"/spreadsheets/d/([A-Za-z0-9_-]{20,})"#, options: .regularExpression) {
            let id = trimmed[range].components(separatedBy: "/").last ?? ""
            return PlanSheetLink(sheetID: id, gid: gid)
        }
        if trimmed.range(of: #"^[A-Za-z0-9_-]{30,}$"#, options: .regularExpression) != nil {
            return PlanSheetLink(sheetID: trimmed, gid: nil)
        }
        return nil
    }

    var webURL: URL { URL(string: "https://docs.google.com/spreadsheets/d/\(sheetID)/edit")! }
    /// The sheet opened on one row.
    func webURL(tab gid: String, line: Int) -> URL {
        URL(string: "https://docs.google.com/spreadsheets/d/\(sheetID)/edit#gid=\(gid)&range=A\(line)")!
    }
}

struct PlanTab: Codable, Equatable, Sendable, Identifiable, Hashable {
    let gid: String
    var name: String
    var id: String { gid }
}

/// The columns the plan understands, recognised by their header text (position and order don't matter).
enum PlanField: String, CaseIterable, Codable, Sendable {
    case id, number, name, length, channel, placement, resolution, aspect, logos, graphics, cta, subs, translations,
         sound, maxSize, frameRate, format, qcStatus, qcNote, qcUpdated, batch, frameio, uploaded

    /// QCpie's own columns (written by it, never part of a row's identity or "changed" highlights).
    var isQC: Bool { self == .qcStatus || self == .qcNote || self == .qcUpdated }
    /// Columns QCpie writes (QC columns and Batch): never part of a row's identity, matching or "changed" highlights.
    var isTracking: Bool { isQC || self == .batch || self == .frameio || self == .uploaded }

    var title: String {
        switch self {
        case .id: return "ID"
        case .number: return "N."
        case .name: return "File Name"
        case .length: return "Length"
        case .channel: return "Channel"
        case .placement: return "Placement"
        case .resolution: return "Resolution"
        case .aspect: return "Aspect Ratio"
        case .logos: return "Logos"
        case .graphics: return "Graphics"
        case .cta: return "CTA"
        case .subs: return "Subs"
        case .translations: return "Translations"
        case .sound: return "Sound"
        case .maxSize: return "File Size"
        case .frameRate: return "Frame Rate"
        case .format: return "Format"
        case .qcStatus: return "QC Status"
        case .qcNote: return "QC Note"
        case .qcUpdated: return "QC Updated"
        case .batch: return "Batch"
        case .frameio: return "Frame.io"
        case .uploaded: return "Uploaded"
        }
    }

    /// The field a header names, or nil.
    static func detect(_ header: String) -> PlanField? {
        let h = header.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !h.isEmpty else { return nil }
        switch h {
        case "id", "deliverable id", "delivery id", "ref", "code", "unique id": return .id
        case "n.", "n", "no", "no.", "#", "nr", "nr.", "asset", "asset n.", "asset no": return .number
        case "name", "title", "deliverable": return .name
        case "cta": return .cta
        case "qc status": return .qcStatus
        case "qc note", "qc notes": return .qcNote
        case "qc updated": return .qcUpdated
        case "batch", "batches", "delivery batch": return .batch
        case "frame.io", "frameio", "frame io", "frame.io link": return .frameio
        case "uploaded", "upload date", "uploaded on": return .uploaded
        default: break
        }
        if h.contains("file name") || h.contains("filename") || h.contains("file title") { return .name }
        if h.contains("frame rate") || h.contains("framerate") || h == "fps" { return .frameRate }
        if h.contains("aspect") { return .aspect }
        if h.contains("resolution") || h.contains("dimension") || h == "res" { return .resolution }
        if h.contains("size") { return .maxSize }
        if h.contains("length") || h.contains("duration") { return .length }
        if h.contains("channel") { return .channel }
        if h.contains("placement") { return .placement }
        if h.contains("logo") { return .logos }
        if h.contains("graphic") { return .graphics }
        if h.hasPrefix("sub") { return .subs }
        if h.contains("translat") || h.contains("language") { return .translations }
        if h.contains("sound") || h.contains("audio") { return .sound }
        if h.contains("format") || h.contains("codec") || h.contains("file type") || h == "type" || h.contains("container") { return .format }
        return nil
    }
}

enum PlanFormat: String, Sendable, Equatable {
    case mp4, mov, prores, gif

    var title: String { self == .prores ? "ProRes" : rawValue.uppercased() }

    /// "mp4", "H.264", "ProRes 422", "gif", "MOV"…
    static func detect(_ text: String) -> PlanFormat? {
        let t = text.lowercased()
        if t.contains("prores") { return .prores }
        if t.contains("gif") { return .gif }
        if t.contains("mp4") || t.contains("h264") || t.contains("h.264") || t.contains("h265") || t.contains("hevc") { return .mp4 }
        if t.contains("mov") || t.contains("quicktime") { return .mov }
        return nil
    }
}

/// One deliverable: a data row of the sheet, cleaned up.
struct PlanRow: Identifiable, Sendable, Equatable {
    /// Stable across refreshes: the ID column when there is one, else the row's defining values (+ occurrence).
    let id: String
    let tab: String
    /// 1-based row in the sheet.
    let line: Int
    let section: String?
    /// Cleaned text per recognised column (whitespace collapsed).
    let values: [PlanField: String]
    let width: Int?
    let height: Int?
    /// Width ÷ height from the aspect column.
    let aspect: Double?
    let seconds: ClosedRange<Double>?
    let maxBytes: Int64?
    let format: PlanFormat?
    let fps: Double?
    /// Contradictions inside the sheet (resolution vs aspect, name vs length…).
    var issues: [String]

    /// Every value, lower-cased, for the filter field (built once with the row, not per keystroke).
    let searchText: String

    var name: String { values[.name] ?? "" }
    var number: String { values[.number] ?? "" }
    func value(_ field: PlanField) -> String { values[field] ?? "" }
    /// Every recognised value, for change detection.
    var content: [String: String] {
        Dictionary(uniqueKeysWithValues: values.filter { !$0.key.isTracking }.map { ($0.key.rawValue, $0.value) })
    }
    /// What matching depends on (QC columns excluded).
    var matchSignature: [String: String] { content.merging(["#id": id], uniquingKeysWith: { a, _ in a }) }
    /// The code (ID column), if the sheet has one.
    var code: String? { values[.id] }

    /// The row with QCpie's columns taken from the QCpie tab (`values`; a field it lacks is cleared).
    func withTracking(_ tracked: [PlanField: String]) -> PlanRow {
        var merged = values.filter { !$0.key.isTracking }
        for (field, value) in tracked where field.isTracking && !value.isEmpty { merged[field] = value }
        guard merged != values else { return self }
        return PlanRow(id: id, tab: tab, line: line, section: section, values: merged, width: width, height: height,
                       aspect: aspect, seconds: seconds, maxBytes: maxBytes, format: format, fps: fps, issues: issues,
                       searchText: merged.values.joined(separator: " ").lowercased())
    }
}

// MARK: - Parsing

enum PlanParser {
    /// RFC 4180 CSV: quoted fields may hold commas, quotes ("") and line breaks.
    static func csv(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\r": break
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func clean(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The header row (the first of the top 15 naming a file-name column and at least two other known columns) and
    /// the column of each field (the first column naming it wins).
    static func header(_ rows: [[String]]) -> (index: Int, columns: [PlanField: Int])? {
        for (index, row) in rows.prefix(15).enumerated() {
            var columns: [PlanField: Int] = [:]
            for (column, text) in row.enumerated() {
                if let field = PlanField.detect(text), columns[field] == nil { columns[field] = column }
            }
            if columns[.name] != nil, columns.count >= 3 { return (index, columns) }
        }
        return nil
    }

    /// The rows of one tab. Blank rows and rows without a file name (subtotals) are skipped; a row whose only text
    /// is in one cell is a section title for the rows under it (unless it's a number: a subtotal).
    static func rows(csv text: String, tab: String) -> [PlanRow] { parse(csv: text, tab: tab).rows }

    /// Rows and the header (index, columns) from one CSV parse (the store needs both on every read).
    static func parse(csv text: String, tab: String) -> (rows: [PlanRow], header: (index: Int, columns: [PlanField: Int])?) {
        parse(table: csv(text), tab: tab)
    }

    /// Rows and the header from a tab's values (Sheets API: rows of formatted strings).
    static func parse(table: [[String]], tab: String) -> (rows: [PlanRow], header: (index: Int, columns: [PlanField: Int])?) {
        guard let found = header(table) else { return ([], nil) }
        let (headerIndex, columns) = found
        return (buildRows(table, headerIndex: headerIndex, columns: columns, tab: tab), found)
    }

    private static func buildRows(_ table: [[String]], headerIndex: Int, columns: [PlanField: Int], tab: String) -> [PlanRow] {
        var result: [PlanRow] = []
        var section: String? = nil
        var seen: [String: Int] = [:]
        for index in table.indices where index > headerIndex {
            let cells = table[index].map(clean)
            let filled = cells.enumerated().filter { !$0.element.isEmpty }
            if filled.isEmpty { continue }
            if filled.count == 1 {
                // A lone number is a subtotal ("15" under a block), not a section title.
                if Double(filled[0].element) == nil { section = filled[0].element }
                continue
            }
            var values: [PlanField: String] = [:]
            for (field, column) in columns where column < cells.count && !cells[column].isEmpty {
                values[field] = cells[column]
            }
            guard let name = values[.name], !name.isEmpty else { continue }
            // Totals ("Total", "Grand total" + a count) aren't deliverables. With an ID column, a row without an ID
            // is a heading or a total: text makes it the section title.
            if isTotal(name) { continue }
            // With an ID column, a row without an ID is a heading, unless it has specs: then it's a deliverable that
            // hasn't been given its code yet (it must still show, as Missing at least).
            if columns[.id] != nil, values[.id] == nil,
               values[.resolution] == nil, values[.aspect] == nil, values[.maxSize] == nil, values[.format] == nil {
                if Double(name) == nil { section = name }
                continue
            }
            let row = build(values: values, tab: tab, line: index + 1, section: section, seen: &seen)
            result.append(row)
        }
        return result
    }

    static func isTotal(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return ["total", "totals", "grand total", "subtotal", "sub total", "sub-total", "tot", "tot."].contains(n)
    }

    private static func build(values: [PlanField: String], tab: String, line: Int, section: String?,
                              seen: inout [String: Int]) -> PlanRow {
        let size = resolution(values[.resolution] ?? "")
        let ratio = aspect(values[.aspect] ?? "")
        let length = seconds(values[.length] ?? "")
        // "mp4" / "prores" sometimes sit in the size column; "gif" in the length column or the name.
        let format = values[.format].flatMap(PlanFormat.detect)
            ?? values[.maxSize].flatMap(PlanFormat.detect)
            ?? values[.length].flatMap { PlanFormat.detect($0) == .gif ? .gif : nil }
            ?? (values[.name]?.lowercased().hasSuffix("gif") == true ? .gif : nil)
        let fps = values[.frameRate].flatMap(frameRate)
        let maxBytes = values[.maxSize].flatMap(bytes)

        var issues: [String] = []
        if let text = values[.resolution], size == nil { issues.append("Can't read the resolution “\(text)”.") }
        if let size, let ratio, abs(Double(size.0) / Double(size.1) - ratio) / ratio > 0.02 {
            issues.append("\(size.0)×\(size.1) isn't \(values[.aspect] ?? "")")
        }
        if let named = nameSeconds(values[.name] ?? ""), let length, !length.contains(named) {
            issues.append("The name says \(format0(named))s, Length says \(values[.length] ?? "")")
        }

        let identity: String
        if let id = values[.id], !id.isEmpty {
            identity = "id:" + id.lowercased()
        } else {
            let key = [tab, values[.name], values[.channel], values[.placement], values[.resolution], values[.aspect],
                       values[.logos], values[.subs], values[.translations], format?.rawValue]
                .map { ($0 ?? "").lowercased() }.joined(separator: "|")
            identity = key
        }
        let occurrence = seen[identity, default: 0]
        seen[identity] = occurrence + 1
        return PlanRow(id: occurrence == 0 ? identity : "\(identity)#\(occurrence)", tab: tab, line: line, section: section,
                       values: values, width: size?.0, height: size?.1, aspect: ratio, seconds: length,
                       maxBytes: maxBytes, format: format, fps: fps, issues: issues,
                       searchText: values.values.joined(separator: " ").lowercased())
    }

    /// "1920x1080", "1200 x 1500", "1080×1920".
    static func resolution(_ text: String) -> (Int, Int)? {
        guard let range = text.range(of: #"(\d{2,5})\s*[xX×]\s*(\d{2,5})"#, options: .regularExpression) else { return nil }
        let parts = text[range].components(separatedBy: CharacterSet(charactersIn: "xX× ")).compactMap { Int($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : nil
    }

    /// "16x9", "6:7 (mobile)", "17x20 Desktop & Mobile", "2.39:1" → width ÷ height.
    static func aspect(_ text: String) -> Double? {
        guard let range = text.range(of: #"(\d+(?:\.\d+)?)\s*[xX×:/]\s*(\d+(?:\.\d+)?)"#, options: .regularExpression) else { return nil }
        let parts = text[range].components(separatedBy: CharacterSet(charactersIn: "xX×:/ ")).compactMap { Double($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? parts[0] / parts[1] : nil
    }

    /// "30s", "15 sec", "2-3s", "1:30", "1m30s", "0:00:15:00"? (timecodes are read as h:m:s) → seconds.
    static func seconds(_ text: String) -> ClosedRange<Double>? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        // "30s / 15s": either length is fine.
        if t.contains("/") {
            let parts = t.components(separatedBy: "/").compactMap { seconds($0) }
            guard !parts.isEmpty else { return nil }
            return parts.map(\.lowerBound).min()!...parts.map(\.upperBound).max()!
        }
        if let range = t.range(of: #"^(\d+(?:\.\d+)?)[-–](\d+(?:\.\d+)?)s"#, options: .regularExpression) {
            let parts = t[range].dropLast().components(separatedBy: CharacterSet(charactersIn: "-–")).compactMap(Double.init)
            if parts.count == 2, parts[0] <= parts[1] { return parts[0]...parts[1] }
        }
        if let range = t.range(of: #"^(\d+)m(\d+(?:\.\d+)?)s?$"#, options: .regularExpression) {
            let parts = t[range].components(separatedBy: CharacterSet(charactersIn: "ms")).compactMap(Double.init)
            if parts.count == 2 { let s = parts[0] * 60 + parts[1]; return s...s }
        }
        if t.range(of: #"^\d+(:\d{1,2}){1,2}$"#, options: .regularExpression) != nil {
            let s = t.components(separatedBy: ":").compactMap(Double.init).reduce(0) { $0 * 60 + $1 }
            return s...s
        }
        if let range = t.range(of: #"^(\d+(?:\.\d+)?)(s|sec|secs|seconds|\")?$"#, options: .regularExpression) {
            let digits = t[range].prefix { $0.isNumber || $0 == "." }
            if let s = Double(digits) { return s...s }
        }
        return nil
    }

    /// The duration a file name ends with: "…_HERO VIDEO_30s" → 30.
    static func nameSeconds(_ name: String) -> Double? {
        guard let range = name.range(of: #"(?:^|[_\s-])(\d{1,3})s$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Double(name[range].filter(\.isNumber))
    }

    static func frameRate(_ text: String) -> Double? {
        guard let range = text.range(of: #"\d+(?:[.,]\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[range].replacingOccurrences(of: ",", with: "."))
    }

    /// "Max 20mb", "5 MB", "500KB", "1.5 GB" (decimal units: the strict reading of a platform limit).
    static func bytes(_ text: String) -> Int64? {
        let t = text.lowercased()
        guard let range = t.range(of: #"(\d+(?:[.,]\d+)?)\s*(kb|mb|gb)"#, options: .regularExpression) else { return nil }
        let match = t[range]
        guard let value = Double(match.prefix { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit: Double = match.hasSuffix("kb") ? 1e3 : match.hasSuffix("gb") ? 1e9 : 1e6
        return Int64(value * unit)
    }

    /// Rows with the same identity and the same values: flagged on the later ones.
    static func flagDuplicates(_ rows: inout [PlanRow]) {
        var first: [String: Int] = [:]
        for index in rows.indices {
            let base = rows[index].id.components(separatedBy: "#").first ?? rows[index].id
            if let earlier = first[base] {
                if rows[earlier].values == rows[index].values {
                    rows[index].issues.append("Same as row \(rows[earlier].line) in \(rows[earlier].tab)")
                }
            } else {
                first[base] = index
            }
        }
    }
}

func format0(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
}

// MARK: - Matching

/// What the matcher needs from a measured file (an Inspect asset).
struct PlanFile: Sendable, Equatable {
    let url: URL
    let width: Int
    let height: Int
    let seconds: Double
    let fps: Double
    let bytes: Int64
    let codec: String
    let hasAudio: Bool
    /// Modification date (a file newer than its row's QC status is a new version).
    var modified: Date? = nil

    init(url: URL, width: Int, height: Int, seconds: Double, fps: Double, bytes: Int64, codec: String, hasAudio: Bool,
         modified: Date? = nil) {
        self.url = url; self.width = width; self.height = height; self.seconds = seconds
        self.fps = fps; self.bytes = bytes; self.codec = codec; self.hasAudio = hasAudio; self.modified = modified
    }

    init(_ asset: DeliverableAsset) {
        self.init(url: asset.fileURL, width: asset.width, height: asset.height, seconds: asset.durationSeconds,
                  fps: asset.fps, bytes: asset.fileSizeBytes, codec: asset.videoCodec, hasAudio: asset.hasAudio)
    }

    var ext: String { url.pathExtension.lowercased() }
}

enum PlanStatus: Int, Sendable, CaseIterable {
    /// No file yet.
    case missing
    /// A file whose specs all match.
    case delivered
    /// A file with a spec that doesn't match the row.
    case wrongSpec
    /// Matched, but by order among rows that look the same, or two files for one row: needs a look.
    case check

    var title: String {
        switch self {
        case .missing: return "Missing"
        case .delivered: return "Found"
        case .wrongSpec: return "Wrong Spec"
        case .check: return "Check"
        }
    }
}

struct PlanRowResult: Sendable, Equatable {
    var status: PlanStatus = .missing
    var files: [URL] = []
    var problems: [String] = []
}

struct PlanMatch: Sendable, Equatable {
    var rows: [String: PlanRowResult] = [:]
    /// Files no row names, or whose rows already have a matching file.
    var extras: [URL] = []
    /// Why a named file is an extra.
    var extraNotes: [URL: String] = [:]

    static let empty = PlanMatch()

    func result(_ row: PlanRow) -> PlanRowResult { rows[row.id] ?? PlanRowResult() }
}

enum PlanMatcher {
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Whether `needle` appears in `haystack` as consecutive tokens.
    static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// How a file differs from a row (empty: matches). Only what the row states is checked.
    static func problems(_ row: PlanRow, _ file: PlanFile) -> [String] {
        var problems: [String] = []
        if let w = row.width, let h = row.height, file.width > 0, (file.width, file.height) != (w, h) {
            problems.append("\(file.width)×\(file.height), expected \(w)×\(h)")
        }
        if let range = row.seconds, file.seconds > 0, !(range.lowerBound - 0.5...range.upperBound + 0.5).contains(file.seconds) {
            let expected = range.lowerBound == range.upperBound ? "\(format0(range.lowerBound))s" : "\(format0(range.lowerBound))–\(format0(range.upperBound))s"
            problems.append("Runs \(String(format: "%.2f", file.seconds))s, expected \(expected)")
        }
        if let fps = row.fps, file.fps > 0, abs(fps - file.fps) > 0.01 {
            problems.append("\(String(format: "%.3g", file.fps)) fps, expected \(format0(fps))")
        }
        if let max = row.maxBytes, file.bytes > max {
            problems.append("\(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .decimal)), max \(ByteCountFormatter.string(fromByteCount: max, countStyle: .decimal))")
        }
        if let format = row.format {
            let ok: Bool
            switch format {
            case .mp4: ok = file.ext == "mp4" || file.ext == "m4v"
            case .mov: ok = file.ext == "mov"
            case .gif: ok = file.ext == "gif"
            case .prores: ok = file.codec.lowercased().contains("prores")
            }
            if !ok { problems.append(format == .prores ? "\(file.codec.isEmpty ? file.ext.uppercased() : file.codec), expected ProRes" : ".\(file.ext), expected \(format.title)") }
        }
        if wantsSound(row), !file.hasAudio, file.ext != "gif" { problems.append("No audio, expected sound") }
        return problems
    }

    static func wantsSound(_ row: PlanRow) -> Bool {
        let t = row.value(.sound).lowercased()
        return t.hasPrefix("yes") || t == "y" || t == "audio" || t.hasPrefix("music")
    }

    /// Logo / clean hints in a file name, scored against the row's Logos column (+1 agrees, −1 contradicts).
    static func logoScore(_ row: PlanRow, _ fileTokens: [String]) -> Int {
        let wants = row.value(.logos).lowercased()
        guard wants.hasPrefix("yes") || wants.hasPrefix("no") else { return 0 }
        let clean = fileTokens.contains { ["clean", "nologo", "nologos", "textless", "unbranded"].contains($0) }
            || contains(fileTokens, ["no", "logo"]) || contains(fileTokens, ["no", "logos"])
        let logo = !clean && fileTokens.contains { ["logo", "logos", "branded"].contains($0) }
        if !clean && !logo { return 0 }
        return (wants.hasPrefix("yes") == logo) ? 1 : -1
    }

    /// An aspect or size in a file name ("9x16", "1080x1920"), scored against the row's (+1 agrees, −1 contradicts).
    static func aspectScore(_ row: PlanRow, _ fileTokens: [String]) -> Int {
        let rowRatio = row.width.flatMap { w in row.height.map { Double(w) / Double($0) } } ?? row.aspect
        guard let rowRatio else { return 0 }
        for token in fileTokens where token.contains("x") {
            if let ratio = PlanParser.aspect(token) { return abs(ratio - rowRatio) / rowRatio < 0.02 ? 1 : -1 }
        }
        return 0
    }

    /// Each file goes to the row it names (the longest row name inside the file name, or the row's ID), preferring
    /// rows whose specs it meets, then name hints (logo / clean, aspect), then rows not yet taken (in sheet order).
    /// Files that fit a row perfectly are placed first, so a wrong file can't take the row a right one needs.
    static func match(rows: [PlanRow], files: [PlanFile]) -> PlanMatch {
        var match = PlanMatch()
        let rowTokens = rows.map { tokens($0.name) }
        let idTokens = rows.map { $0.values[.id].map(tokens) ?? [] }
        // Rows by their whole name (tokens joined): a file looks up each run of its own tokens, longest first, so
        // 1,100 files × 1,100 rows costs a few hundred dictionary lookups per file.
        var byID: [String: [Int]] = [:]
        var multiTokenIDs: [Int] = []
        for (index, id) in idTokens.enumerated() where !id.isEmpty {
            if id.count == 1 { byID[id[0], default: []].append(index) } else { multiTokenIDs.append(index) }
        }
        var byName: [String: [Int]] = [:]
        for (index, t) in rowTokens.enumerated() where !t.isEmpty {
            byName[t.joined(separator: " "), default: []].append(index)
            // Names that carry their ID ("…_15s_KL0001") also match files named without it.
            let id = idTokens[index]
            if !id.isEmpty, t.count > id.count, Array(t.suffix(id.count)) == id {
                byName[t.dropLast(id.count).joined(separator: " "), default: []].append(index)
            }
        }
        var taken: [Int: [URL]] = [:]
        var notes: [Int: [String]] = [:]
        var specProblems: [Int: [(url: URL, problems: [String])]] = [:]
        var alternatives: [Int: [Int]] = [:]
        var perfect: Set<Int> = []

        typealias Scored = (index: Int, problems: [String], hint: Int)
        var plans: [(file: PlanFile, scored: [Scored])] = []
        /// Files whose ID points at a row their name doesn't match: a wrong code, or a misnamed file.
        var idNameNotes: [URL: String] = [:]
        func rowsNamed(in ft: [String]) -> [Int] {
            for length in stride(from: ft.count, through: 1, by: -1) {
                var hits: [Int] = []
                for start in 0...(ft.count - length) { hits += byName[ft[start..<(start + length)].joined(separator: " ")] ?? [] }
                if !hits.isEmpty { return Array(Set(hits)).sorted() }
            }
            return []
        }
        for file in files.sorted(by: { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }) {
            let ft = tokens(file.url.deletingPathExtension().lastPathComponent)
            // An ID in the name decides alone.
            // Codes are one word: a dictionary lookup per file token, not a scan of every row (that was 1.1 M
            // comparisons for 1,075 files, ~8 s on a MacBook Air's efficiency cores).
            var candidates = Array(Set(ft.flatMap { byID[$0] ?? [] })).sorted()
            if !multiTokenIDs.isEmpty {
                candidates += multiTokenIDs.filter { contains(ft, idTokens[$0]) }
            }
            if candidates.isEmpty {
                candidates = rowsNamed(in: ft)
            } else if candidates.count == 1 {
                let index = candidates[0]
                let id = idTokens[index]
                var name = rowTokens[index]
                if name.count > id.count, Array(name.suffix(id.count)) == id { name.removeLast(id.count) }
                if !name.isEmpty, !contains(ft, name) {
                    let withoutID = ft.filter { !id.contains($0) }
                    let named = rowsNamed(in: withoutID).filter { $0 != index }.prefix(3).map { "\(rows[$0].line)" }
                    let code = rows[index].values[.id] ?? ""
                    idNameNotes[file.url] = "The file name doesn't match \(code)'s row" +
                        (named.isEmpty ? "" : " (the name looks like row\(named.count == 1 ? "" : "s") \(named.joined(separator: ", ")))") +
                        ": check the code."
                }
            }
            guard !candidates.isEmpty else { match.extras.append(file.url); continue }
            plans.append((file, candidates.map { ($0, problems(rows[$0], file), logoScore(rows[$0], ft) + aspectScore(rows[$0], ft)) }))
        }
        // Perfect fits first (stable: name order within each group).
        let ordered = plans.enumerated().sorted { a, b in
            let pa = a.element.scored.map(\.problems.count).min() ?? 0, pb = b.element.scored.map(\.problems.count).min() ?? 0
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)

        for (file, scored) in ordered {
            let fewest = scored.map(\.problems.count).min() ?? 0
            let fit = scored.filter { $0.problems.count == fewest }
            let bestHint = fit.map(\.hint).max() ?? 0
            let best = fit.filter { $0.hint == bestHint }
            let free = best.filter { taken[$0.index] == nil }
            // Its rows already hold files that fit them: this one belongs to none of them.
            if free.isEmpty, fewest > 0, best.allSatisfy({ perfect.contains($0.index) }) {
                match.extras.append(file.url)
                match.extraNotes[file.url] = "Closest: row \(rows[best[0].index].line), which already has a matching file. \(best[0].problems.joined(separator: "; "))."
                continue
            }
            let pick = free.first ?? best[0]
            if pick.problems.isEmpty { perfect.insert(pick.index) }
            taken[pick.index, default: []].append(file.url)
            if let note = idNameNotes[file.url] { notes[pick.index, default: []].append(note) }
            alternatives[pick.index, default: []] += best.map(\.index).filter { $0 != pick.index }
            specProblems[pick.index, default: []].append((file.url, pick.problems))
        }

        // Still ambiguous only if a look-alike row ended up without a file (else the other file settled it).
        for (index, others) in alternatives {
            let open = Array(Set(others.filter { taken[$0] == nil })).sorted().prefix(3).map { "\(rows[$0].line)" }
            guard !open.isEmpty else { continue }
            notes[index, default: []].append("Could also be row\(open.count == 1 ? "" : "s") \(open.joined(separator: ", ")): the file name doesn't tell them apart.")
        }

        for (index, urls) in taken {
            let perFile = specProblems[index] ?? []
            var problems = perFile.flatMap { entry in
                urls.count > 1 ? entry.problems.map { "\(entry.url.lastPathComponent): \($0)" } : entry.problems
            }
            let specsWrong = !problems.isEmpty
            if urls.count > 1 { problems.append("\(urls.count) files for this row.") }
            problems += notes[index] ?? []
            let status: PlanStatus = specsWrong ? .wrongSpec : (urls.count > 1 || notes[index] != nil) ? .check : .delivered
            match.rows[rows[index].id] = PlanRowResult(status: status, files: urls, problems: problems)
        }
        match.extras.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return match
    }
}


// MARK: - QC status

/// Statuses people set (the sheet's QC Status column, a dropdown). Everything else is worked out from the files.
enum PlanQCStatus: String, CaseIterable, Sendable, Codable {
    case needsFix, passed, approved, delivered, onHold, dropped

    var title: String {
        switch self {
        case .needsFix: return "Needs Fix"
        case .passed: return "QC Passed"
        case .approved: return "Approved"
        case .delivered: return "Delivered"
        case .onHold: return "On Hold"
        case .dropped: return "Dropped"
        }
    }

    /// The sheet's text, leniently ("passed", "QC passed", "approved ✓"…).
    static func parse(_ text: String) -> PlanQCStatus? {
        let t = text.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains("fix") { return .needsFix }
        if t.contains("pass") { return .passed }
        if t.contains("approv") { return .approved }
        if t.contains("deliver") { return .delivered }
        if t.contains("hold") { return .onHold }
        if t.contains("drop") || t.contains("cancel") || t.contains("omit") { return .dropped }
        return nil
    }

    var state: PlanState {
        switch self {
        case .needsFix: return .needsFix
        case .passed: return .passed
        case .approved: return .approved
        case .delivered: return .delivered
        case .onHold: return .onHold
        case .dropped: return .dropped
        }
    }

    /// ⌥1…⌥6.
    var shortcut: String { "⌥\((Self.allCases.firstIndex(of: self) ?? 0) + 1)" }
}

/// One status per row: the manual one when set, else what the files say.
enum PlanState: Int, CaseIterable, Sendable, Hashable {
    /// Wrong Spec (a spec that doesn't match) and an unsure match both read as Check: the row's flags say which.
    case missing, toQC, check, needsFix, passed, approved, delivered, onHold, dropped

    var title: String {
        switch self {
        case .missing: return "Missing"
        case .toQC: return "To QC"
        case .check: return "Check"
        case .needsFix: return "Needs Fix"
        case .passed: return "QC Passed"
        case .approved: return "Approved"
        case .delivered: return "Delivered"
        case .onHold: return "On Hold"
        case .dropped: return "Dropped"
        }
    }

    /// Counts as done for the progress figure.
    var isDone: Bool { self == .passed || self == .approved || self == .delivered }
}

/// A row's state and anything worth flagging about it.
struct PlanRowState: Equatable, Sendable {
    var state: PlanState
    var flags: [String] = []
    var upload: PlanUpload = .none
    /// Where the row, this Mac's file and Frame.io disagree.
    var mismatches: [PlanMismatch] = []

    /// A Frame.io filter value (`PlanMismatch.filterTitle`): 0 not on Frame.io, 1 on, else a mismatch.
    func passes(_ filter: Int) -> Bool {
        switch filter {
        case 0: return upload == .none
        case 1: return upload != .none
        default: return mismatches.contains { $0.rawValue == filter }
        }
    }
}

/// Where the plan, this Mac's files and Frame.io disagree. The row kinds come with each row's state; the two "not in
/// the plan" kinds are files: local ones (Inspect's extras) and Frame.io ones (files in the plan's Frame.io folders that
/// no row links to). Raw values are the Frame.io filter's values (0 and 1 are "not on" / "on Frame.io").
enum PlanMismatch: Int, CaseIterable, Sendable {
    /// Only kinds someone acts on. ("No file here" and "on Frame.io before QC" were dropped: the first is normal on a
    /// Mac without the delivery, the second is often on purpose, client previews.) Raw values stay: filters store them.
    case differs = 2, notUploaded = 5, frameioExtra = 6, localExtra = 7

    var title: String {
        switch self {
        case .differs: return "Frame.io Has Another Version"
        case .notUploaded: return "Passed, Not on Frame.io"
        case .frameioExtra: return "On Frame.io, Not in the Plan"
        case .localExtra: return "Here, Not in the Plan"
        }
    }

    var explanation: String {
        switch self {
        case .differs: return "The local file changed after its upload, or Frame.io's file is another size."
        case .notUploaded: return "QC Passed, Approved or Delivered, but the row has no Frame.io link."
        case .frameioExtra: return "Files in the plan's Frame.io folders that no row links to."
        case .localExtra: return "Inspect files that don't match any row."
        }
    }

    /// Kinds a file on this Mac can have (Inspect's menu).
    var isLocal: Bool { self == .differs || self == .notUploaded || self == .localExtra }

    /// Filter values → title: the two presence filters, then the mismatches.
    static func filterTitle(_ value: Int) -> String {
        switch value {
        case 0: return "Not on Frame.io"
        case 1: return "On Frame.io"
        default: return PlanMismatch(rawValue: value)?.title ?? "Frame.io"
        }
    }
}

/// A file in the plan's Frame.io folders that no row links to, and why.
struct PlanFrameIOExtra: Equatable, Sendable, Identifiable {
    let name: String
    let url: String
    let note: String
    var id: String { url }
}

/// Whether a row's file is on Frame.io (its Frame.io column), and whether the local file changed after the upload.
enum PlanUpload: Int, Equatable, Sendable {
    case none = 0, uploaded = 1, stale = 2

    /// "2026-11-05 10:42 UTC" (the Uploaded column) → date. Formatters are made once: this runs per linked row on
    /// every state recompute.
    static func date(_ stamp: String) -> Date? {
        let text = stamp.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix("UTC") else { return nil }
        return minutes.date(from: text) ?? seconds.date(from: text)
    }

    private static let minutes = utcFormatter("yyyy-MM-dd HH:mm 'UTC'")
    private static let seconds = utcFormatter("yyyy-MM-dd HH:mm:ss 'UTC'")
    static let stampFormatter = utcFormatter("yyyy-MM-dd HH:mm")

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

enum PlanStatusResolver {
    /// "2026-11-04 13:02:31 UTC · Ric": when and who, written to QC Updated with each status (QCpie and the sheet's
    /// script both write UTC, so Macs and the sheet in other time zones agree).
    static func stamp(_ date: Date, by name: String) -> String {
        utc.string(from: date) + " UTC" + (name.isEmpty ? "" : " · \(name)")
    }

    /// Stamps without "UTC" (written before version 3) are local time.
    static func date(fromStamp text: String) -> Date? {
        guard text.count >= 19 else { return nil }
        let prefix = String(text.prefix(19))
        return (text.dropFirst(19).hasPrefix(" UTC") ? utc : local).date(from: prefix)
    }

    private static func formatter(_ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }
    private static let utc = formatter(TimeZone(identifier: "UTC")!)
    private static let local = formatter(.current)

    /// `fileDates`: modification dates of the row's files. A file newer than the status (QC Updated) means a new
    /// version arrived since the review: the row goes back to To QC.
    static func resolve(match: PlanStatus, hasFiles: Bool, qc: String, updated: String, fileDates: [Date]) -> PlanRowState {
        guard let manual = PlanQCStatus.parse(qc) else {
            switch match {
            case .missing: return PlanRowState(state: .missing)
            case .delivered: return PlanRowState(state: .toQC)
            case .wrongSpec, .check: return PlanRowState(state: .check)
            }
        }
        if manual == .onHold || manual == .dropped { return PlanRowState(state: manual.state) }
        if let set = date(fromStamp: updated), let newest = fileDates.max(), newest > set.addingTimeInterval(2) {
            return PlanRowState(state: match == .wrongSpec ? .check : .toQC,
                                flags: ["New file since “\(manual.title)” (\(updated))."])
        }
        var flags: [String] = []
        if !hasFiles, manual != .needsFix { flags.append("No file found for a row marked “\(manual.title)”.") }
        if hasFiles, match == .wrongSpec, manual != .needsFix { flags.append("Marked “\(manual.title)” but the specs don't match.") }
        return PlanRowState(state: manual.state, flags: flags)
    }
}

/// What Inspect shows for a file: its plan row and state (nil state: not in the plan).
struct PlanFileInfo: Equatable, Sendable {
    let code: String
    let line: Int
    let rowID: String?
    let state: PlanState?
    /// The row's batch ("" when none).
    var batch: String = ""
    /// The row's Frame.io link ("" when none).
    var frameio: String = ""
    var upload: PlanUpload = .none
    var mismatches: [PlanMismatch] = []

    /// The Frame.io filter on a file: "Here, Not in the Plan" passes files without a row; the rest need one.
    func passes(_ filter: Int) -> Bool {
        if filter == PlanMismatch.localExtra.rawValue { return rowID == nil && mismatches.contains(.localExtra) }
        guard rowID != nil else { return false }
        return PlanRowState(state: state ?? .missing, upload: upload, mismatches: mismatches).passes(filter)
    }
    /// The row's channel ("" when none), for Inspect's Group By.
    var channel: String = ""
    /// The row's values, lower-cased, for Inspect's search (channel, placement, resolution…).
    var text: String = ""
}

/// Delivery batches: a sheet's Batch column, plain numbers ("1", "2", "3"…), sorted by number (2 < 10). Other text a
/// sheet already holds ("Final") sorts after them.
enum PlanBatch {
    /// The numbers in a batch name, for sorting.
    private static func parts(_ name: String) -> [Int] {
        name.split { !$0.isNumber }.compactMap { Int($0) }
    }

    static func precedes(_ a: String, _ b: String) -> Bool {
        let pa = parts(a), pb = parts(b)
        if pa != pb, !pa.isEmpty, !pb.isEmpty { return pa.lexicographicallyPrecedes(pb) }
        if pa.isEmpty != pb.isEmpty { return !pa.isEmpty }   // numbered batches first
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    static func sorted(_ names: some Sequence<String>) -> [String] {
        Array(Set(names.map { PlanGrid.normalized($0) }.filter { !$0.isEmpty })).sorted(by: precedes)
    }

    /// "2" → "Batch 2"; a name that already says more ("Final", "Batch 2") stays.
    static func title(_ name: String) -> String {
        name.first?.isNumber == true ? "Batch \(name)" : name
    }

    /// The batch after the highest one: "3" after "2".
    static func next(after names: [String]) -> String {
        let top = names.compactMap { parts($0).first }.max() ?? 0
        return "\(top + 1)"
    }
}
