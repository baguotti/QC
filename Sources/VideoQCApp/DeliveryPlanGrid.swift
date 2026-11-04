import Foundation

// The Delivery Plan's sheet as Google Sheets draws it: column widths, row heights, frozen rows, merges and each
// cell's colours, weight, alignment and borders, read from the sheet's public HTML view
// (`htmlview/sheet?headers=true&gid=`). The CSV export carries none of that; a grid built from CSV
// (`PlanGrid.fromCSV`) is the fallback when the HTML can't be read.

struct PlanGridBorder: Codable, Equatable, Sendable {
    var width: Double
    /// 0xRRGGBB.
    var color: UInt32
}

struct PlanGridStyle: Codable, Equatable, Sendable {
    enum Align: Int, Codable, Sendable { case left, center, right }
    enum VAlign: Int, Codable, Sendable { case top, middle, bottom }

    var background: UInt32? = nil
    var color: UInt32? = nil
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var align: Align = .left
    var valign: VAlign = .bottom
    /// Wrapped text; otherwise it overflows into empty cells to its right, as in Sheets.
    var wrap = false
    /// CSS points (Sheets' default is 10pt Arial).
    var fontSize: Double = 10
    var top: PlanGridBorder? = nil
    var right: PlanGridBorder? = nil
    var bottom: PlanGridBorder? = nil
    var left: PlanGridBorder? = nil
}

struct PlanGridCell: Codable, Equatable, Sendable {
    var column: Int
    var span: Int = 1
    var rowSpan: Int = 1
    var text: String
    var style: Int
}

struct PlanGridRow: Codable, Equatable, Sendable {
    /// 1-based row number in the sheet (`PlanRow.line`).
    var line: Int
    /// CSS pixels.
    var height: Double
    var cells: [PlanGridCell]
}

struct PlanGrid: Codable, Equatable, Sendable {
    /// CSS pixels.
    var columnWidths: [Double]
    var frozenRows: Int
    /// Index 0 is the sheet's default cell style.
    var styles: [PlanGridStyle]
    var rows: [PlanGridRow]
    /// Read from the sheet's HTML (true) or rebuilt from its CSV (no formatting).
    var formatted: Bool

    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(65 + r)!) + name; n = (n - 1) / 26 }
        return name
    }
}

// MARK: - HTML

extension PlanGrid {
    /// Parses `htmlview/sheet?headers=true&gid=` output. Nil when it holds no grid (sign-in page, error page).
    static func parseHTML(_ html: String) -> PlanGrid? {
        let classes = parseStyles(html)
        var styles = [PlanGridStyle()]
        var styleIndex: [String: Int] = [:]
        for (name, style) in classes {
            styleIndex[name] = styles.count
            styles.append(style)
        }

        var widths: [Int: Double] = [:]
        for m in matches(#"id="\d+C(\d+)" style="width:\s*(\d+(?:\.\d+)?)px"#, in: html) {
            if let c = Int(m[1]), let w = Double(m[2]) { widths[c] = w }
        }
        guard let lastColumn = widths.keys.max() else { return nil }
        var columnWidths = (0...lastColumn).map { widths[$0] ?? 100 }

        let ns = html as NSString
        let rowRegex = try! NSRegularExpression(pattern: #"<tr([^>]*)>(.*?)</tr>"#, options: [.dotMatchesLineSeparators])
        let lineRegex = try! NSRegularExpression(pattern: #"<th id="\d+R(\d+)""#)
        let cellRegex = try! NSRegularExpression(pattern: #"<td([^>]*)>(.*?)</td>"#, options: [.dotMatchesLineSeparators])
        var rows: [PlanGridRow] = []
        var frozenRows = 0
        var occupied: [Int: Int] = [:]   // column → rows still covered by a rowspan from above
        for m in rowRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attributes = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            if body.contains("freezebar-horizontal-handle") { frozenRows = rows.count; continue }
            let bodyNS = body as NSString
            guard let lm = lineRegex.firstMatch(in: body, range: NSRange(location: 0, length: bodyNS.length)),
                  let index = Int(bodyNS.substring(with: lm.range(at: 1))) else { continue }
            let height = firstNumber(#"height:\s*(\d+(?:\.\d+)?)px"#, in: attributes) ?? 21
            var cells: [PlanGridCell] = []
            var column = 0
            for cm in cellRegex.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
                let attrs = bodyNS.substring(with: cm.range(at: 1))
                if attrs.contains("freezebar-cell") { continue }
                while (occupied[column] ?? 0) > 0 { column += 1 }
                let span = max(1, Int(firstNumber(#"colspan="(\d+)""#, in: attrs) ?? 1))
                let rowSpan = max(1, Int(firstNumber(#"rowspan="(\d+)""#, in: attrs) ?? 1))
                let className = matches(#"class="([^"]*)""#, in: attrs).first?[1]
                    .split(separator: " ").first { $0.hasPrefix("s") && Int($0.dropFirst()) != nil }.map(String.init)
                let style = className.flatMap { styleIndex[$0] } ?? 0
                cells.append(PlanGridCell(column: column, span: span, rowSpan: rowSpan,
                                          text: cellText(bodyNS.substring(with: cm.range(at: 2))), style: style))
                if rowSpan > 1 { for c in column..<(column + span) { occupied[c] = rowSpan } }
                column += span
            }
            for (c, n) in occupied { occupied[c] = n - 1 }   // rows below this one
            occupied = occupied.filter { $0.value > 0 }
            if column > columnWidths.count { columnWidths += Array(repeating: 100, count: column - columnWidths.count) }
            rows.append(PlanGridRow(line: index + 1, height: height, cells: cells))
        }
        guard !rows.isEmpty else { return nil }
        return PlanGrid(columnWidths: columnWidths, frozenRows: frozenRows, styles: styles, rows: rows, formatted: true)
    }

    /// `.ritz .waffle .s3{…}` rules → style per class name.
    static func parseStyles(_ html: String) -> [(String, PlanGridStyle)] {
        matches(#"\.ritz \.waffle \.(s\d+)\{([^}]*)\}"#, in: html).map { m in
            var style = PlanGridStyle()
            for declaration in m[2].split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let (key, value) = (parts[0].lowercased(), parts[1])
                switch key {
                case "background-color": style.background = color(value)
                case "color": style.color = color(value)
                case "font-weight": style.bold = value == "bold" || (Int(value) ?? 400) >= 600
                case "font-style": style.italic = value == "italic"
                case "text-decoration":
                    style.underline = value.contains("underline")
                    style.strike = value.contains("line-through")
                case "text-align": style.align = value == "center" ? .center : value == "right" ? .right : .left
                case "vertical-align": style.valign = value == "top" ? .top : value == "middle" ? .middle : .bottom
                case "white-space": style.wrap = value == "normal"
                case "font-size":
                    if let n = Double(value.replacingOccurrences(of: "pt", with: "")) { style.fontSize = n }
                case "border-top": style.top = border(value)
                case "border-right": style.right = border(value)
                case "border-bottom": style.bottom = border(value)
                case "border-left": style.left = border(value)
                default: break
                }
            }
            return (m[1], style)
        }
    }

    /// "#rrggbb" / "#rgb" → 0xRRGGBB.
    static func color(_ text: String) -> UInt32? {
        guard let hash = text.firstIndex(of: "#") else { return nil }
        let hex = text[text.index(after: hash)...].prefix { $0.isHexDigit }
        if hex.count == 6 { return UInt32(hex, radix: 16) }
        if hex.count == 3 {
            return UInt32(hex.map { "\($0)\($0)" }.joined(), radix: 16)
        }
        return nil
    }

    /// "2px SOLID #999999".
    private static func border(_ text: String) -> PlanGridBorder? {
        let lower = text.lowercased()
        guard !lower.contains("none"), let width = firstNumber(#"(\d+(?:\.\d+)?)px"#, in: lower) else { return nil }
        return PlanGridBorder(width: width, color: color(text) ?? 0)
    }

    /// Cell HTML → its text: line breaks kept, tags dropped, entities decoded.
    static func cellText(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var text = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        guard text.contains("&") else { return text }
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            if let semi = tail.prefix(10).firstIndex(of: ";") {
                let entity = String(tail[...semi])
                if let value = named[entity] {
                    out += value; rest = tail[tail.index(after: semi)...]; continue
                }
                if entity.hasPrefix("&#") {
                    let digits = entity.dropFirst(2).dropLast()
                    let code = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                    if let code, let scalar = UnicodeScalar(code) {
                        out.unicodeScalars.append(scalar); rest = tail[tail.index(after: semi)...]; continue
                    }
                }
            }
            out += "&"
            rest = tail.dropFirst()
        }
        return out + rest
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    private static func firstNumber(_ pattern: String, in text: String) -> Double? {
        matches(pattern, in: text).first.flatMap { Double($0[1]) }
    }
}

// MARK: - CSV fallback

extension PlanGrid {
    /// The same rows without formatting: widths from the longest text, the header row frozen.
    static func fromCSV(_ text: String) -> PlanGrid {
        let table = PlanParser.csv(text)
        let columns = table.map(\.count).max() ?? 0
        var widths = [Double](repeating: 60, count: columns)
        for row in table {
            for (c, cell) in row.enumerated() {
                let longest = cell.split(separator: "\n").map(\.count).max() ?? 0
                widths[c] = min(360, max(widths[c], Double(longest) * 6.5 + 8))
            }
        }
        let rows = table.enumerated().map { index, cells in
            PlanGridRow(line: index + 1, height: 21,
                        cells: cells.enumerated().map { PlanGridCell(column: $0.offset, text: $0.element, style: 0) })
        }
        let header = PlanParser.header(table).map { $0.index + 1 } ?? 0
        return PlanGrid(columnWidths: widths, frozenRows: header, styles: [PlanGridStyle()], rows: rows, formatted: false)
    }
}

// MARK: - Edits

extension PlanGrid {
    /// Whitespace-collapsed text, for comparing what QCpie shows with what the sheet holds.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The cell covering a sheet row (1-based) and column (0-based), with its row index.
    func cell(line: Int, column: Int) -> (row: Int, index: Int)? {
        guard let row = rows.firstIndex(where: { $0.line == line }) else { return nil }
        guard let index = rows[row].cells.firstIndex(where: { column >= $0.column && column < $0.column + $0.span }) else { return nil }
        return (row, index)
    }

    func text(line: Int, column: Int) -> String? {
        cell(line: line, column: column).map { rows[$0.row].cells[$0.index].text }
    }

    func applying(_ edits: [DeliveryPlanStore.CellKey: String]) -> PlanGrid {
        var grid = self
        for (key, value) in edits {
            if let (row, index) = grid.cell(line: key.line, column: key.column) { grid.rows[row].cells[index].text = value }
        }
        return grid
    }
}
