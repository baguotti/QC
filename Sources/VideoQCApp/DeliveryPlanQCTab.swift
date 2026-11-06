import Foundation

/// QCpie's own tab in the plan's spreadsheet: one row per code holding everything QCpie tracks (QC Status, QC Note,
/// QC Updated, Batch, Frame.io, Uploaded). It's the only place these are written, so the same deliverable listed on
/// several tabs can't disagree. Plan tabs show them through one lookup formula per column (`formula`), read-only.
/// Columns are found by header text; Code must stay in column A (the lookups key on it).
enum PlanQCTab {
    static let title = "QCpie"
    static let fields: [PlanField] = [.qcStatus, .qcNote, .qcUpdated, .batch, .frameio, .uploaded]
    static let header = ["Code", "Deliverable"] + fields.map(\.title)

    struct Table: Equatable, Sendable {
        /// 0-based column of each field (`.id` = Code, `.name` = Deliverable).
        var columns: [PlanField: Int]
        /// 1-based lines of each code (lower case). A code can appear twice (two Macs adding it at once).
        var lines: [String: [Int]]
        /// Values by code (lower case): the first non-empty value of each field among the code's lines.
        var values: [String: [PlanField: String]]
        var width: Int
    }

    /// The tab's values (header in row 1). Nil without a Code column.
    static func parse(_ table: [[String]]) -> Table? {
        guard let head = table.first else { return nil }
        var columns: [PlanField: Int] = [:]
        for (index, text) in head.enumerated() {
            if let field = PlanField.detect(text), columns[field] == nil { columns[field] = index }
        }
        guard let codeColumn = columns[.id] else { return nil }
        var lines: [String: [Int]] = [:]
        var values: [String: [PlanField: String]] = [:]
        for (index, row) in table.enumerated() where index > 0 {
            guard codeColumn < row.count else { continue }
            let key = PlanGrid.normalized(row[codeColumn]).lowercased()
            guard !key.isEmpty else { continue }
            lines[key, default: []].append(index + 1)
            for field in fields {
                guard let column = columns[field], column < row.count else { continue }
                let value = PlanGrid.normalized(row[column])
                if !value.isEmpty, values[key]?[field] == nil { values[key, default: [:]][field] = value }
            }
        }
        return Table(columns: columns, lines: lines, values: values, width: max(head.count, (columns.values.max() ?? 0) + 1))
    }

    struct Change: Equatable, Sendable {
        let code: String
        let name: String
        let values: [PlanField: String]
    }

    /// Ranges to write for `changes` into the tab as it is now (`table`: read just before writing), plus rows to
    /// append for codes it doesn't have yet. Fields whose column is missing get a header cell after the last column.
    static func writes(_ changes: [Change], into table: Table) -> (updates: [(range: String, values: [[String]])], appends: [[String]]) {
        var columns = table.columns
        var updates: [(range: String, values: [[String]])] = []
        var next = table.width
        for field in fields where columns[field] == nil && changes.contains(where: { $0.values[field] != nil }) {
            columns[field] = next
            updates.append((cell(row: 1, column: next), [[field.title]]))
            next += 1
        }
        let width = max(next, (columns.values.max() ?? 0) + 1)
        var appends: [[String]] = []
        for change in changes {
            if let lines = table.lines[change.code.lowercased()] {
                for line in lines {
                    for field in fields {
                        guard let value = change.values[field], let column = columns[field] else { continue }
                        updates.append((cell(row: line, column: column), [[value]]))
                    }
                }
            } else {
                var row = [String](repeating: "", count: width)
                if let column = columns[.id] { row[column] = change.code }
                if let column = columns[.name] { row[column] = change.name }
                for field in fields { if let value = change.values[field], let column = columns[field] { row[column] = value } }
                appends.append(row)
            }
        }
        return (updates, appends)
    }

    static func cell(row: Int, column: Int) -> String {
        "\(SheetsAPI.quoted(title))!\(PlanGrid.columnName(column))\(row)"
    }

    /// The lookup a plan tab's column holds: the field for each row's code, "" when the code has none.
    /// `codeColumn` is the plan tab's Code column (0-based), `firstRow` the first row under its header (1-based).
    static func formula(_ field: PlanField, codeColumn: Int, firstRow: Int) -> String {
        let codes = "\(PlanGrid.columnName(codeColumn))\(firstRow):\(PlanGrid.columnName(codeColumn))"
        let tab = SheetsAPI.quoted(title)
        return "=ARRAYFORMULA(IF(LEN(\(codes)), IFERROR(VLOOKUP(\(codes), \(tab)!$A:$Z, MATCH(\"\(field.title)\", \(tab)!$1:$1, 0), FALSE)&\"\", \"\"), \"\"))"
    }

    /// The values to start the tab with, from the QC columns plan tabs hold today (before they become lookups). Per
    /// code: QC Status / Note / Updated from the row with the newest QC Updated (else the first that has any), each
    /// other field from the first row that has it.
    static func migrate(_ rows: [PlanRow]) -> [Change] {
        var order: [String] = []
        var byCode: [String: [PlanRow]] = [:]
        for row in rows {
            guard let code = row.code, !code.isEmpty else { continue }
            let key = code.lowercased()
            if byCode[key] == nil { order.append(key) }
            byCode[key, default: []].append(row)
        }
        return order.compactMap { key in
            let rows = byCode[key]!
            var values: [PlanField: String] = [:]
            let qcRows = rows.filter { r in [PlanField.qcStatus, .qcNote, .qcUpdated].contains { !r.value($0).isEmpty } }
            let newest = qcRows.max { a, b in
                (PlanStatusResolver.date(fromStamp: a.value(.qcUpdated)) ?? .distantPast) < (PlanStatusResolver.date(fromStamp: b.value(.qcUpdated)) ?? .distantPast)
            }
            for field in [PlanField.qcStatus, .qcNote, .qcUpdated] {
                if let value = newest?.value(field), !value.isEmpty { values[field] = value }
            }
            for field in [PlanField.batch, .frameio, .uploaded] {
                if let value = rows.lazy.map({ $0.value(field) }).first(where: { !$0.isEmpty }) { values[field] = value }
            }
            return Change(code: rows[0].code!, name: rows[0].name, values: values)
        }
    }
}
