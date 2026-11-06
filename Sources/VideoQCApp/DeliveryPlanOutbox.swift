import Foundation

/// Every edit QCpie makes to the plan's sheet, kept on disk until Google has it: statuses, notes, batches and
/// Frame.io links (by code, for the QCpie tab) and cells typed in the Sheet view. What it holds is laid over what was
/// read, so an edit shows at once and stays shown until a read that started after it was written. Survives quitting
/// and being offline; a refused edit (no access, the cell changed meanwhile) leaves it with the reason shown.
struct PlanOutbox: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable {
        var code: String
        var name: String
        /// `PlanField.rawValue` → value ("" clears).
        var values: [String: String]
        /// Automatic (Frame.io links, stamps): failures aren't reported.
        var quiet: Bool
        /// Last change; a write sent before it doesn't cover it.
        var changed: Date
        /// When Google took it: it leaves once a read that started after this has come back.
        var written: Date? = nil

        var fields: [PlanField: String] {
            Dictionary(uniqueKeysWithValues: values.compactMap { k, v in PlanField(rawValue: k).map { ($0, v) } })
        }
    }

    struct Cell: Codable, Equatable, Sendable, Identifiable {
        var id = UUID()
        let gid: String
        let line: Int
        /// The Sheet view's column (what the overlay uses) and the sheet's own column.
        let column: Int
        let sheetColumn: Int
        /// The row's code and the column's header, to find the cell again if rows were sorted or columns moved.
        let code: String?
        let header: String?
        let value: String
        /// The text QCpie showed: a cell changed meanwhile isn't overwritten.
        let expect: String
        var changed: Date
        var written: Date? = nil
    }

    /// By lower-cased code.
    var records: [String: Record] = [:]
    var cells: [Cell] = []

    var isEmpty: Bool { records.isEmpty && cells.isEmpty }
    var unsent: (records: [Record], cells: [Cell]) {
        (records.values.filter { $0.written == nil }.sorted { $0.code < $1.code }, cells.filter { $0.written == nil })
    }

    mutating func set(code: String, name: String, _ values: [PlanField: String], quiet: Bool, at now: Date = Date()) {
        let key = code.lowercased()
        var record = records[key] ?? Record(code: code, name: name, values: [:], quiet: quiet, changed: now)
        for (field, value) in values { record.values[field.rawValue] = value }
        record.quiet = record.quiet && quiet
        record.changed = now
        record.written = nil
        records[key] = record
    }

    mutating func add(_ cell: Cell) {
        // A newer edit of the same cell replaces an unsent one.
        cells.removeAll { $0.gid == cell.gid && $0.line == cell.line && $0.column == cell.column && $0.written == nil }
        cells.append(cell)
    }

    /// Google took these (sent at `sentAt`): marked written unless changed after they were sent.
    mutating func written(codes: [String], cells ids: Set<UUID>, sentAt: Date, at now: Date = Date()) {
        for code in codes {
            let key = code.lowercased()
            if let record = records[key], record.changed <= sentAt { records[key]?.written = now }
        }
        for i in cells.indices where ids.contains(cells[i].id) && cells[i].changed <= sentAt { cells[i].written = now }
    }

    mutating func drop(codes: [String], cells ids: Set<UUID>, sentAt: Date) {
        for code in codes {
            let key = code.lowercased()
            if let record = records[key], record.changed <= sentAt { records[key] = nil }
        }
        cells.removeAll { ids.contains($0.id) && $0.changed <= sentAt }
    }

    /// A read that started at `readStart` came back: written edits older than it are in it, so they leave.
    /// Returns whether anything left.
    @discardableResult
    mutating func settle(readStart: Date) -> Bool {
        let before = (records.count, cells.count)
        records = records.filter { $0.value.written.map { $0 >= readStart } ?? true }
        cells.removeAll { $0.written.map { $0 < readStart } ?? false }
        return before != (records.count, cells.count)
    }

    /// Values to lay over the read rows, by lower-cased code.
    var overlay: [String: [PlanField: String]] { records.mapValues(\.fields) }

    /// Cell text to lay over a tab's grid.
    func cellOverlay(gid: String) -> [DeliveryPlanStore.CellKey: String] {
        var out: [DeliveryPlanStore.CellKey: String] = [:]
        for cell in cells where cell.gid == gid { out[.init(line: cell.line, column: cell.column)] = cell.value }
        return out
    }
}
