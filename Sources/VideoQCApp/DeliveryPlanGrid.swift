import Foundation

// The Delivery Plan's sheet as Google Sheets draws it: column widths, row heights, frozen rows, merges and each
// cell's colours, weight, alignment and borders, read through the Sheets API (`SheetsAPI.layout`). A grid built from
// the values alone (`PlanGrid.fromTable`) shows until the layout has been read.

struct PlanGridBorder: Codable, Hashable, Sendable {
    var width: Double
    /// 0xRRGGBB.
    var color: UInt32
}

struct PlanGridStyle: Codable, Hashable, Sendable {
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
    /// Read with Sheets' formatting (true) or rebuilt from the values alone.
    var formatted: Bool
    /// Formatted grids: the sheet column (0-based) of each view column (hidden columns are left out), and the size
    /// of the values table the layout was read with (a table of another size needs the layout read again).
    var sheetColumns: [Int]? = nil
    var sourceRows: Int? = nil
    var sourceColumns: Int? = nil

    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(65 + r)!) + name; n = (n - 1) / 26 }
        return name
    }
}

// MARK: - Sheets API layout

extension PlanGrid {
    /// The Sheet view's grid from a `SheetsAPI.layout` reply (formats, sizes, merges, hidden rows/columns) with the
    /// text of `table` (the tab's values). Rows and columns past the table's extent are left out; hidden ones too, as
    /// Sheets' own view does. Nil when the reply holds no grid.
    static func fromSheets(layout data: Data, table: [[String]]) -> PlanGrid? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sheet = (json["sheets"] as? [[String: Any]])?.first,
              let grid = (sheet["data"] as? [[String: Any]])?.first else { return nil }
        let rowMeta = grid["rowMetadata"] as? [[String: Any]] ?? []
        let columnMeta = grid["columnMetadata"] as? [[String: Any]] ?? []
        let rowData = grid["rowData"] as? [[String: Any]] ?? []
        let width = table.map(\.count).max() ?? 0
        let height = table.count
        guard width > 0, height > 0 else { return nil }
        func hidden(_ meta: [[String: Any]], _ i: Int, filter: Bool) -> Bool {
            guard i < meta.count else { return false }
            return meta[i]["hiddenByUser"] as? Bool == true || (filter && meta[i]["hiddenByFilter"] as? Bool == true)
        }
        let sheetColumns = (0..<width).filter { !hidden(columnMeta, $0, filter: false) }
        var viewColumn: [Int: Int] = [:]
        for (view, sheetColumn) in sheetColumns.enumerated() { viewColumn[sheetColumn] = view }
        let visibleRows = (0..<height).filter { !hidden(rowMeta, $0, filter: true) }
        let visibleRowSet = Set(visibleRows)

        // Merges: top-left → (rows, columns) spanned among the visible ones; other covered cells are skipped.
        var spans: [Int: [Int: (rows: Int, columns: Int)]] = [:]
        var covered = Set<Int>()   // row * 100_000 + column
        for merge in (sheet["merges"] as? [[String: Any]]) ?? [] {
            let r0 = merge["startRowIndex"] as? Int ?? 0, r1 = merge["endRowIndex"] as? Int ?? 0
            let c0 = merge["startColumnIndex"] as? Int ?? 0, c1 = merge["endColumnIndex"] as? Int ?? 0
            guard r1 > r0, c1 > c0 else { continue }
            let rows = (r0..<r1).filter(visibleRowSet.contains).count
            let columns = (c0..<c1).filter { viewColumn[$0] != nil }.count
            spans[r0, default: [:]][c0] = (max(1, rows), max(1, columns))
            for r in r0..<min(r1, height) { for c in c0..<min(c1, width) where r != r0 || c != c0 { covered.insert(r * 100_000 + c) } }
        }

        var styles = [PlanGridStyle()]
        var styleIndex: [PlanGridStyle: Int] = [PlanGridStyle(): 0]
        var rows: [PlanGridRow] = []
        rows.reserveCapacity(visibleRows.count)
        for r in visibleRows {
            let values = r < rowData.count ? (rowData[r]["values"] as? [[String: Any]] ?? []) : []
            var cells: [PlanGridCell] = []
            cells.reserveCapacity(sheetColumns.count)
            for (view, c) in sheetColumns.enumerated() {
                if covered.contains(r * 100_000 + c) { continue }
                let text = c < table[r].count ? table[r][c] : ""
                var style = c < values.count ? Self.style(values[c]["effectiveFormat"] as? [String: Any]) : PlanGridStyle()
                // Sheets right-aligns numbers that have no alignment of their own.
                if c < values.count, (values[c]["effectiveFormat"] as? [String: Any])?["horizontalAlignment"] == nil,
                   Double(text.replacingOccurrences(of: ",", with: "")) != nil { style.align = .right }
                let index: Int
                if let known = styleIndex[style] { index = known } else { index = styles.count; styles.append(style); styleIndex[style] = index }
                let span = spans[r]?[c]
                cells.append(PlanGridCell(column: view, span: span?.columns ?? 1, rowSpan: span?.rows ?? 1, text: text, style: index))
            }
            let pixel = r < rowMeta.count ? rowMeta[r]["pixelSize"] as? Double : nil
            rows.append(PlanGridRow(line: r + 1, height: pixel ?? 21, cells: cells))
        }
        let widths = sheetColumns.map { c in (c < columnMeta.count ? columnMeta[c]["pixelSize"] as? Double : nil) ?? 100 }
        let gridProps = ((sheet["properties"] as? [String: Any])?["gridProperties"] as? [String: Any])
        let frozen = gridProps?["frozenRowCount"] as? Int ?? 0
        let frozenVisible = visibleRows.filter { $0 < frozen }.count
        var result = PlanGrid(columnWidths: widths, frozenRows: frozenVisible, styles: styles, rows: rows, formatted: true)
        result.sheetColumns = sheetColumns
        result.sourceRows = height
        result.sourceColumns = width
        return result
    }

    /// Whether this layout was read for a table of this size (rows or columns added or removed: read it again).
    func fits(_ table: [[String]]) -> Bool {
        sheetColumns != nil && table.count == sourceRows && (table.map(\.count).max() ?? 0) == sourceColumns
    }

    /// The same layout with the texts of a newer read of the tab's values: formatting is read rarely (it's large),
    /// values on every check. Cells the layout doesn't have (rows added since) wait for the next layout read.
    func withTexts(_ table: [[String]]) -> PlanGrid {
        guard let sheetColumns else { return self }
        var grid = self
        for i in grid.rows.indices {
            let r = grid.rows[i].line - 1
            let cells = r < table.count ? table[r] : []
            for j in grid.rows[i].cells.indices {
                let c = sheetColumns[grid.rows[i].cells[j].column]
                grid.rows[i].cells[j].text = c < cells.count ? cells[c] : ""
            }
        }
        return grid
    }

    private static func rgb(_ value: Any?) -> UInt32? {
        guard let color = value as? [String: Any] else { return nil }
        func channel(_ key: String) -> UInt32 { UInt32(((color[key] as? Double) ?? 0) * 255 + 0.5) & 0xFF }
        return channel("red") << 16 | channel("green") << 8 | channel("blue")
    }

    static func style(_ format: [String: Any]?) -> PlanGridStyle {
        var style = PlanGridStyle()
        guard let format else { return style }
        // White fills and black text are the sheet's defaults: left unset, as in Sheets' own HTML.
        if let fill = rgb(format["backgroundColor"]), fill != 0xFFFFFF { style.background = fill }
        if let text = format["textFormat"] as? [String: Any] {
            if let color = rgb(text["foregroundColor"]), color != 0 { style.color = color }
            style.bold = text["bold"] as? Bool ?? false
            style.italic = text["italic"] as? Bool ?? false
            style.underline = text["underline"] as? Bool ?? false
            style.strike = text["strikethrough"] as? Bool ?? false
            if let size = text["fontSize"] as? Double { style.fontSize = size }
        }
        switch format["horizontalAlignment"] as? String {
        case "CENTER": style.align = .center
        case "RIGHT": style.align = .right
        default: break
        }
        switch format["verticalAlignment"] as? String {
        case "TOP": style.valign = .top
        case "MIDDLE": style.valign = .middle
        default: break
        }
        style.wrap = format["wrapStrategy"] as? String == "WRAP"
        if let borders = format["borders"] as? [String: Any] {
            func border(_ key: String) -> PlanGridBorder? {
                guard let b = borders[key] as? [String: Any], let kind = b["style"] as? String, kind != "NONE" else { return nil }
                let width: Double = kind == "SOLID_MEDIUM" ? 2 : (kind == "SOLID_THICK" || kind == "DOUBLE") ? 3 : 1
                return PlanGridBorder(width: width, color: rgb(b["color"]) ?? 0)
            }
            style.top = border("top"); style.right = border("right"); style.bottom = border("bottom"); style.left = border("left")
        }
        return style
    }
}

// MARK: - Unformatted fallback

extension PlanGrid {
    /// The same rows without formatting: widths from the longest text, the header row frozen.
    static func fromTable(_ table: [[String]]) -> PlanGrid {
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
