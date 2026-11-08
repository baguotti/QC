import Foundation
import SwiftUI
import VideoQCLib

/// Writing: edits, linked filters, undo, the outbox and setting up the QCpie tab.
extension DeliveryPlanStore {
    // MARK: Editing

    /// Edits need Google sign-in (Google decides who may edit the sheet).
    var canEdit: Bool { GoogleAccount.shared.signedIn }

    /// A cell typed in the Sheet view. QCpie's columns go to the QCpie tab (by code); other cells are written where
    /// they are, unless the sheet changed them meanwhile. Shown at once either way.
    func editCell(gid: String, line: Int, column: Int, old: String, new: String) {
        guard let config, new != old, let tab = config.tabs.first(where: { $0.gid == gid }) else { return }
        let grid = readGrids[gid]
        let header = headers[gid].flatMap { h in grid?.text(line: h.line, column: column) }.map(PlanGrid.normalized)
        if let field = header.flatMap(PlanField.detect), field.isTracking, line > (headers[gid]?.line ?? 0) {
            guard let row = rows.first(where: { $0.tab == tab.name && $0.line == line }) else { return }
            queueQC([row]) { $0[field] = PlanGrid.normalized(new) }
            return
        }
        let sheetColumn = grid?.sheetColumns.flatMap { column < $0.count ? $0[column] : nil } ?? column
        let code = rows.first { $0.tab == tab.name && $0.line == line }?.code
        outbox.add(PlanOutbox.Cell(gid: gid, line: line, column: column, sheetColumn: sheetColumn, code: code,
                                   header: header.flatMap { $0.isEmpty ? nil : $0 }, value: new, expect: old, changed: Date()))
        saveOutbox()
        publishGrids()
        editState = .saving(outbox.unsent.records.count + outbox.unsent.cells.count)
        scheduleFlush()
    }

    func loadCachedIfNeeded() async {
        guard !loadedFromDisk, let config else { return }
        loadedFromDisk = true
        let dir = Self.directory(config.link.sheetID)
        let (cache, seen, layoutCache, folders, dismissed, tree) = await Task.detached(priority: .userInitiated) { () -> ([String: [[String]]], [String: SeenRow], [String: PlanGrid], [String: [ListedFile]], [String], RootTree?) in
            func read<T: Decodable>(_ name: String, _ type: T.Type) -> T? {
                JSONFile.load(T.self, from: dir.appendingPathComponent(name), log: .plan)
            }
            return (read("values.json", [String: [[String]]].self) ?? [:], read("seen.json", [String: SeenRow].self) ?? [:],
                    read("layouts.json", [String: PlanGrid].self) ?? [:], read("frameio-folders.json", [String: [ListedFile]].self) ?? [:],
                    read("dismissed-mismatches.json", [String].self) ?? [], read("frameio-tree.json", RootTree.self))
        }.value
        guard self.config?.link == config.link else { return }
        if !dismissed.isEmpty { dismissedMismatches.formUnion(dismissed); scheduleRecompute() }
        if let tree, tree.root == config.frameioRoot?.folder {
            rootFolders.formUnion(tree.folders)
            if lastRootScan == nil { lastRootScan = tree.scanned; rootScan = .done(tree.scanned) }
        }
        self.seen = seen
        // Listings that came in before this read are newer than the saved ones.
        frameioFolders = folders.merging(frameioFolders) { _, listed in listed }
        if layouts.isEmpty { layouts = layoutCache }
        let tabs = config.included.filter { cache[$0.gid] != nil }
        // Only before the first read of the sheet: the cache is older than any read.
        if !tabs.isEmpty, rows.isEmpty, lastValues == nil {
            let planTables = tabs.map { cache[$0.gid]! }
            await apply(tabs: tabs, tables: planTables, qc: cache["qc"], adoptAsSeen: false)
            if grids.isEmpty, lastValues == nil {
                for (tab, table) in zip(tabs, planTables) { tables[tab.gid] = table }
                readGrids = Dictionary(uniqueKeysWithValues: zip(tabs, planTables).map { tab, table in
                    (tab.gid, layouts[tab.gid]?.withTexts(table) ?? PlanGrid.fromTable(table))
                })
                publishGrids()
            }
        }
    }

    /// The status filter and search shared by the plan and Inspect while `linkFilters` is on.
    /// `state`: -1 all, -2 not in the plan (Inspect only), else a `PlanState` raw value.
    /// `batch`: nil all, "" no batch, else a batch name.
    /// `upload`: nil all, else a `PlanUpload.passes` filter value.
    struct SharedFilter: Equatable { var state = -1; var search = ""; var batch: String? = nil; var upload: Int? = nil }

    /// A side's filter changed: the other side follows while linked.
    func publishFilter(_ filter: SharedFilter, fromPlan: Bool = false) {
        guard linkFilters, filter != sharedFilter else { return }
        // The plan has no "Not in Plan" chip: showing everything there mustn't undo Inspect's choice.
        if fromPlan, sharedFilter.state == -2, filter.state == -1 {
            // …but its search and batch still go across.
            let kept = SharedFilter(state: -2, search: filter.search, batch: filter.batch, upload: filter.upload)
            if kept != sharedFilter { sharedFilter = kept }
            return
        }
        sharedFilter = filter
    }

    /// The link button: on copies this side's filter to the other.
    func toggleLinkFilters(from filter: SharedFilter) {
        linkFilters.toggle()
        if linkFilters { sharedFilter = filter }
    }

    /// ⌥1–⌥6 / ⌥0: the rows of Inspect's selected files, else the plan's focused row. False when there's nothing.
    func setStatusForSelection(_ status: PlanQCStatus?) -> Bool {
        var ids = rowIDs(forFiles: Array(selectedFiles))
        if ids.isEmpty, let focused = focusedRowID, rows.contains(where: { $0.id == focused }) { ids = [focused] }
        guard !ids.isEmpty, config != nil else { return false }
        setStatus(status, rowIDs: ids)
        return true
    }

    /// Rows of the Inspect files given (setting a status from Inspect).
    func rowIDs(forFiles urls: [URL]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap { fileIndex[$0]?.rowID }.filter { seen.insert($0).inserted }
    }

    /// Queues QCpie's columns for rows (by code) in the outbox: shown at once, written to the QCpie tab in one call
    /// 0.3 s after the last change. A status change is stamped (QC Updated) with time and reviewer.
    /// `quiet`: automatic writes (Frame.io links) say nothing when they can't be saved.
    /// `refresh: false` leaves the recompute and redraw to the caller (several rows queued in a row).



    @discardableResult
    func undoLastEdit() -> Bool {
        guard undoTitle != nil, !undoValues.isEmpty else { return false }
        let entries = undoValues
        undoValues = []
        undoTitle = nil
        for entry in entries {
            guard let row = rows(withCode: entry.code).first else { continue }   // row gone
            queueQC([row], refresh: false, undoable: false, stamp: false) { $0 = entry.values }
        }
        recomputeStates()
        publishGrids()
        return true
    }

    private static func undoTitle(_ fields: Set<PlanField>) -> String {
        if fields.contains(.qcStatus) { return "Status" }
        if fields.contains(.frameio) { return "Frame.io Link" }
        if fields.contains(.batch) { return "Batch" }
        if fields.contains(.qcNote) { return "Note" }
        return "Edit"
    }

    func queueQC(_ targets: [PlanRow], quiet: Bool = false, refresh: Bool = true, undoable: Bool = true, stamp: Bool = true,
                         _ change: (inout [PlanField: String]) -> Void) {
        guard config != nil else { return }
        let coded = targets.filter { !($0.code ?? "").isEmpty }
        guard !coded.isEmpty else { if !quiet { editState = .failed("Statuses need a Code column in the sheet.") }; return }
        var values: [PlanField: String] = [:]
        change(&values)
        guard !values.isEmpty else { return }
        // Only a status change is stamped: QC Updated dates the review, and a note edited later must not hide a new
        // version that arrived before it.
        if stamp, values[.qcStatus] != nil {
            let reviewer = UserDefaults.standard.string(forKey: "reviewerName").flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
            values[.qcUpdated] = PlanStatusResolver.stamp(Date(), by: reviewer)
        }
        // A hand edit can be undone: each code's values before it (automatic writes don't replace the last undo).
        if !quiet, undoable {
            var seen = Set<String>()
            undoValues = coded.compactMap { row in
                guard seen.insert(row.code!.lowercased()).inserted else { return nil }
                return (row.code!, row.name, Dictionary(uniqueKeysWithValues: values.keys.map { ($0, shown($0, row)) }))
            }
            undoTitle = Self.undoTitle(Set(values.keys))
        }
        for row in coded { outbox.set(code: row.code!, name: row.name, values, quiet: quiet) }
        if let link = values[.frameio], !link.isEmpty {
            for row in coded where linkSuggestions[row.code!.lowercased()] != nil { linkSuggestions[row.code!.lowercased()] = nil }
        }
        saveOutbox()
        if refresh {
            recomputeStates()
            publishGrids()
        }
        if !quiet { editState = .saving(outbox.unsent.records.count + outbox.unsent.cells.count) }
        scheduleFlush()
    }



    func scheduleFlush(after seconds: Double = 0.3) {
        flushTask?.cancel()
        flushTask = Task {
            // Gathers a burst of clicks / shortcuts / Frame.io listings into one call.
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self.flush()
        }
    }

    /// Sends what the outbox holds that Google doesn't have yet. QCpie's columns: the QCpie tab is read first (rows
    /// may have been sorted or added), then the values for codes it has are written and the others appended, as text.
    /// Cells: each tab is read, the cell found again by code and header, and written only if it still shows what
    /// QCpie showed. Offline or Google busy: kept and retried. No access: dropped with the reason.
    private func flush() async {
        guard !flushing, let config else { return }
        var (records, cells) = outbox.unsent
        guard !records.isEmpty || !cells.isEmpty else { return }
        let loud = records.contains { !$0.quiet } || !cells.isEmpty
        guard await GoogleAuth.shared.isSignedIn else {
            if loud { report(.failed("Saved on this Mac: sign in with Google (Delivery Plan ••• menu) to send it to the sheet.")) }
            return
        }
        if config.qcTab == nil {
            if records.contains(where: { !$0.quiet }) {
                report(.failed("Saved on this Mac: set up the QCpie tab (Delivery Plan ••• menu) to send statuses to the sheet."))
            }
            records = []
            guard !cells.isEmpty else { return }
        }
        flushing = true
        defer { flushing = false }
        let before = outbox
        let id = config.link.sheetID
        let sentAt = Date()
        var refused: [String] = []
        do {
            if !records.isEmpty {
                let data = try await api.values(id, ranges: [SheetsAPI.quoted(PlanQCTab.title)])
                let (table, hasValues) = try await Task.detached(priority: .userInitiated) { () -> (PlanQCTab.Table?, Bool) in
                    let values = try SheetsAPI.tables(data).first ?? []
                    return (PlanQCTab.parse(values), values.contains { $0.contains { !$0.isEmpty } })
                }.value
                var updates: [(range: String, values: [[String]])] = []
                let current: PlanQCTab.Table
                if table == nil, hasValues {
                    // Something else is in row 1 (a title added above the header?): writing there would overwrite it.
                    // Kept until the tab's first row is its header again.
                    if loud { report(.failed("Not saved yet: the QCpie tab's first row must be its header (Code, Deliverable, QC Status…).")) }
                    setHealth { $0.writeError = "The QCpie tab's first row must be its header (Code, Deliverable, QC Status…)."; $0.retrying = true }
                    return
                }
                if let table { current = table } else {
                    // The header row was cleared: put it back.
                    updates.append((PlanQCTab.cell(row: 1, column: 0), [PlanQCTab.header]))
                    var columns: [PlanField: Int] = [.id: 0, .name: 1]
                    for (i, field) in PlanQCTab.fields.enumerated() { columns[field] = i + 2 }
                    current = PlanQCTab.Table(columns: columns, lines: [:], values: [:], width: PlanQCTab.header.count)
                }
                let changes = records.map { PlanQCTab.Change(code: $0.code, name: $0.name, values: $0.fields) }
                let writes = PlanQCTab.writes(changes, into: current)
                try await api.update(id, updates + writes.updates, raw: true)
                try await api.append(id, range: "\(SheetsAPI.quoted(PlanQCTab.title))!A1", rows: writes.appends)
                outbox.written(codes: records.map(\.code), cells: [], sentAt: sentAt)
            }
            for gid in Set(cells.map(\.gid)) {
                guard let tab = config.tabs.first(where: { $0.gid == gid }) else {
                    outbox.drop(codes: [], cells: Set(cells.filter { $0.gid == gid }.map(\.id)), sentAt: sentAt)
                    refused.append("that tab is no longer in the sheet")
                    continue
                }
                let data = try await api.values(id, ranges: [SheetsAPI.quoted(tab.name)])
                let table = try SheetsAPI.tables(data).first ?? []
                var writes: [(range: String, values: [[String]])] = []
                var written = Set<UUID>(), conflicts = Set<UUID>()
                for cell in cells where cell.gid == gid {
                    switch Self.locate(cell, in: table) {
                    case .success(let (row, column)):
                        writes.append(("\(SheetsAPI.quoted(tab.name))!\(PlanGrid.columnName(column))\(row + 1)", [[cell.value]]))
                        written.insert(cell.id)
                    case .failure(let reason):
                        conflicts.insert(cell.id)
                        refused.append(reason.message)
                    }
                }
                try await api.update(id, writes, raw: false)
                outbox.written(codes: [], cells: written, sentAt: sentAt)
                outbox.drop(codes: [], cells: conflicts, sentAt: sentAt)
            }
            retryDelay = 0
            if loud { report(refused.isEmpty ? .saved : .failed("Not saved: \(refused[0]).")) }
            setHealth { $0.canWrite = true; $0.retrying = false; $0.writeError = refused.first.map { "Not saved: \($0)." } }
        } catch {
            switch error {
            case GoogleAuth.Failure.signedOut:
                GoogleAccount.shared.noteSignedOut()
                if loud { report(.failed("Saved on this Mac: sign in with Google (Delivery Plan ••• menu) to send it to the sheet.")) }
            case SheetsAPI.Failure.http(400, _):
                // Usually a tab renamed or deleted (the QCpie tab too): read the tab list and keep the edits; if the
                // QCpie tab is gone they wait for it to be set up again.
                _ = try? await readMetadata(config)
                retryDelay = min(max(5, retryDelay * 2), 120)
                setHealth { $0.writeError = Self.describe(error); $0.retrying = true }
                if loud { report(.failed("Not saved yet (\(Self.describe(error))): trying again in \(Int(retryDelay)) s.")) }
                scheduleFlush(after: retryDelay)
            case let failure as SheetsAPI.Failure where !failure.isTransient:
                // Google won't take these however often they're sent (no edit access, bad range): drop them.
                outbox.drop(codes: records.map(\.code), cells: Set(cells.map(\.id)), sentAt: sentAt)
                if loud { report(.failed("Not saved: \(Self.describe(error))")) }
                setHealth {
                    if case .noAccess = failure { $0.canWrite = false }
                    $0.writeError = Self.describe(error); $0.retrying = false
                }
            default:
                // Offline or Google busy: kept, tried again later (and on the next read).
                retryDelay = min(max(5, retryDelay * 2), 120)
                if loud { report(.failed("Not saved yet (\(Self.describe(error))): trying again in \(Int(retryDelay)) s.")) }
                setHealth { $0.writeError = Self.describe(error); $0.retrying = true }
                scheduleFlush(after: retryDelay)
            }
        }
        // Nothing sent or refused (offline, retrying): no save, recompute or read.
        guard outbox != before else { return }
        saveOutbox()
        recomputeStates()
        publishGrids()
        // Read again shortly, so the written edits come back from the sheet (and leave the outbox).
        refreshAfterEdit?.cancel()
        refreshAfterEdit = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await refresh()
            if !outbox.unsent.records.isEmpty || !outbox.unsent.cells.isEmpty { scheduleFlush(after: 0.3) }
        }
    }

    /// The outbox's messages, published only when they change: a send retried after every read (no QCpie tab yet,
    /// offline) would otherwise redraw the plan and toast in Inspect every 10 s.
    private func report(_ state: EditState) { if editState != state { editState = state } }

    struct CellRefusal: Error { let message: String }

    /// Where a typed cell is now (0-based row and sheet column): its row by code when the sheet was sorted, its
    /// column by header when columns moved. Refused when the row is gone or the cell no longer shows what QCpie did.
    nonisolated static func locate(_ cell: PlanOutbox.Cell, in table: [[String]]) -> Result<(Int, Int), CellRefusal> {
        func text(_ r: Int, _ c: Int) -> String { table.indices.contains(r) && table[r].indices.contains(c) ? table[r][c] : "" }
        var row = cell.line - 1
        var column = cell.sheetColumn
        if let header = PlanParser.header(table) {
            if let code = cell.code, let codeColumn = header.columns[.id],
               PlanGrid.normalized(text(row, codeColumn)).lowercased() != code.lowercased() {
                guard let moved = table.indices.first(where: { $0 > header.index && PlanGrid.normalized(text($0, codeColumn)).lowercased() == code.lowercased() }) else {
                    return .failure(CellRefusal(message: "the row \(code) is no longer in the sheet"))
                }
                row = moved
            }
            // Moved only when the column there no longer has the header (two "Notes" columns: keep the one typed in).
            if let name = cell.header?.lowercased(), PlanGrid.normalized(text(header.index, column)).lowercased() != name,
               let found = table[header.index].firstIndex(where: { PlanGrid.normalized($0).lowercased() == name }) {
                column = found
            }
        }
        let current = text(row, column)
        guard PlanGrid.normalized(current) == PlanGrid.normalized(cell.expect) else {
            return .failure(CellRefusal(message: "the cell was changed in the sheet meanwhile (now “\(current)”)"))
        }
        return .success((row, column))
    }



    func saveOutbox() {
        noteOutbox()
        guard let config, outboxLoaded else { return }
        let file = Self.directory(config.link.sheetID).appendingPathComponent("outbox.json")
        let snapshot = outbox
        let previous = outboxSaveTask
        outboxSaveTask = Task.detached(priority: .utility) {
            await previous?.value
            if snapshot.isEmpty { JSONFile.remove(file, log: .plan) } else { JSONFile.save(snapshot, to: file, log: .plan) }
        }
    }

    func loadOutbox() async {
        guard let config else { return }
        let file = Self.directory(config.link.sheetID).appendingPathComponent("outbox.json")
        let saved = await Task.detached(priority: .utility) {
            JSONFile.load(PlanOutbox.self, from: file, log: .plan)
        }.value
        guard self.config?.link == config.link else { return }
        outboxLoaded = true
        guard let saved else { if !outbox.isEmpty { saveOutbox() }; return }
        // Edits made since launch are newer than the saved ones.
        for (key, record) in saved.records where outbox.records[key] == nil { outbox.records[key] = record }
        outbox.cells = saved.cells.filter { old in !outbox.cells.contains { $0.id == old.id } } + outbox.cells
        saveOutbox()
        recomputeStates()
        publishGrids()
        scheduleFlush(after: 1)
    }



    /// Adds the QCpie tab: one row per code with the values the plan tabs' QC columns hold today (plus edits waiting
    /// in the outbox), then turns those columns into lookups of it (cleared, one formula each, dropdowns removed, a
    /// warning when someone edits them in Sheets). The values are written before any column is cleared.
    /// Returns why it failed, nil when the tab is there.
    @discardableResult
    func setUpQCTab() async -> String? {
        guard var config, !settingUpQCTab else { return nil }
        settingUpQCTab = true
        defer { settingUpQCTab = false }
        let id = config.link.sheetID
        do {
            let meta = try await api.metadata(id)
            if meta.tabs.contains(where: { $0.title == PlanQCTab.title }) {
                config = try await readMetadata(config)
                await refresh(full: true)
                return nil
            }
            let tabs = meta.tabs.filter { $0.title != PlanQCTab.title }
            let data = try await api.values(id, ranges: tabs.map { SheetsAPI.quoted($0.title) })
            let pendingAt = Date()
            let pending = outbox.records.values.map { PlanQCTab.Change(code: $0.code, name: $0.name, values: $0.fields) }
            let plan = try await Task.detached(priority: .userInitiated) { try Self.qcTabPlan(tabs: tabs, tables: SheetsAPI.tables(data), pending: pending) }.value

            // One atomic batch: the tab with its values, header and dropdown, and the plan tabs' QC columns turned
            // into lookups (cleared, one formula, no dropdown, a warning when edited by hand). All or nothing, so a
            // failure can't leave columns cleared without the tab holding their values.
            let used = Set(meta.tabs.compactMap { Int($0.gid) })
            var gidNumber = Int.random(in: 1_000_000...2_000_000_000)
            while used.contains(gidNumber) { gidNumber = Int.random(in: 1_000_000...2_000_000_000) }
            let body = try JSONSerialization.data(withJSONObject: ["requests": Self.qcTabRequests(plan, sheetID: gidNumber)])
            _ = try await api.batchUpdate(id, body: body)
            // Waiting edits are in the tab now.
            outbox.written(codes: pending.map(\.code), cells: [], sentAt: pendingAt)
            saveOutbox()
            // Onto the config as it is now (settings changed during the set-up stay).
            if var current = self.config, current.link == config.link {
                current.qcTab = String(gidNumber)
                self.config = current
                saveConfig()
            }
            lastValues = nil
            editState = .saved
            await refresh(full: true)
            scheduleFlush(after: 0)
            return nil
        } catch {
            if case GoogleAuth.Failure.signedOut = error { GoogleAccount.shared.noteSignedOut() }
            let message = "Couldn't set up the QCpie tab: \(Self.describe(error))"
            Log.plan.error(message)
            editState = .failed(message)
            return message
        }
    }

    struct QCTabPlan: Sendable {
        struct Lookup: Sendable { let gid: String; let title: String; let field: PlanField; let column: Int; let codeColumn: Int; let firstRow: Int }
        /// The tab's rows under its header.
        let rows: [[String]]
        /// The plan tabs' QC columns that become lookups.
        let lookups: [Lookup]
    }

    /// The `batchUpdate` requests that add the QCpie tab (`sheetID`) and turn the plan tabs' QC columns into lookups.
    nonisolated static func qcTabRequests(_ plan: QCTabPlan, sheetID: Int) -> [[String: Any]] {
        func text(_ value: String) -> [String: Any] { value.isEmpty ? [:] : ["userEnteredValue": ["stringValue": value]] }
        let statusColumn = PlanQCTab.header.firstIndex(of: PlanField.qcStatus.title)!
        var requests: [[String: Any]] = [
            ["addSheet": ["properties": [
                "sheetId": sheetID, "title": PlanQCTab.title,
                // 26 columns: the lookups read A:Z (a range past the tab's last column is an error in Sheets).
                "gridProperties": ["rowCount": plan.rows.count + 200, "columnCount": 26, "frozenRowCount": 1],
            ]]],
            // Strings as given (stringValue): "2", "2026-11-05 10:42 UTC" stay text.
            ["updateCells": ["start": ["sheetId": sheetID, "rowIndex": 0, "columnIndex": 0],
                             "rows": ([PlanQCTab.header] + plan.rows).map { ["values": $0.map(text)] },
                             "fields": "userEnteredValue"]],
            ["repeatCell": ["range": ["sheetId": sheetID, "startRowIndex": 0, "endRowIndex": 1],
                            "cell": ["userEnteredFormat": ["textFormat": ["bold": true]]],
                            "fields": "userEnteredFormat.textFormat.bold"]],
            ["setDataValidation": ["range": ["sheetId": sheetID, "startRowIndex": 1, "startColumnIndex": statusColumn, "endColumnIndex": statusColumn + 1],
                                   "rule": ["condition": ["type": "ONE_OF_LIST", "values": PlanQCStatus.allCases.map { ["userEnteredValue": $0.title] }],
                                            "showCustomUi": true, "strict": false]]],
        ]
        for column in plan.lookups {
            let range: [String: Any] = ["sheetId": Int(column.gid) ?? 0, "startRowIndex": column.firstRow - 1,
                                        "startColumnIndex": column.column, "endColumnIndex": column.column + 1]
            // With a range, cells the rows don't cover are cleared too: the formula in the first, the rest emptied.
            requests.append(["updateCells": [
                "range": range,
                "rows": [["values": [["userEnteredValue": ["formulaValue": PlanQCTab.formula(column.field, codeColumn: column.codeColumn, firstRow: column.firstRow)]]]]],
                "fields": "userEnteredValue,dataValidation",
            ]])
            requests.append(["addProtectedRange": ["protectedRange": [
                "range": range, "warningOnly": true,
                "description": "Filled from the QCpie tab: set \(column.field.title) there or in QCpie.",
            ]]])
        }
        return requests
    }

    /// What setting up the QCpie tab writes, from every tab's values and the outbox (whose edits win).
    nonisolated static func qcTabPlan(tabs: [SheetsAPI.Tab], tables: [[[String]]], pending: [PlanQCTab.Change]) -> QCTabPlan {
        var rows: [PlanRow] = []
        var lookups: [QCTabPlan.Lookup] = []
        for (tab, table) in zip(tabs, tables) {
            let parsed = PlanParser.parse(table: table, tab: tab.title)
            rows += parsed.rows
            guard let header = parsed.header, let codeColumn = header.columns[.id] else { continue }
            for field in PlanQCTab.fields {
                if let column = header.columns[field] {
                    lookups.append(.init(gid: tab.gid, title: tab.title, field: field, column: column, codeColumn: codeColumn, firstRow: header.index + 2))
                }
            }
        }
        var changes = PlanQCTab.migrate(rows)
        for edit in pending {
            if let i = changes.firstIndex(where: { $0.code.lowercased() == edit.code.lowercased() }) {
                changes[i] = PlanQCTab.Change(code: changes[i].code, name: changes[i].name,
                                              values: changes[i].values.merging(edit.values) { _, new in new })
            } else {
                changes.append(edit)
            }
        }
        let header = PlanQCTab.header
        let out = changes.map { change -> [String] in
            [change.code, change.name] + PlanQCTab.fields.map { change.values[$0] ?? "" }
        }
        precondition(header.count == 2 + PlanQCTab.fields.count)
        return QCTabPlan(rows: out, lookups: lookups)
    }

    /// The tab's header line (1-based), once read.
    func headerLine(gid: String) -> Int? { headers[gid]?.line }

    /// Dropdown choices by the Sheet view's column (0-based), matched by header: the view leaves hidden columns
    /// out, so the sheet's column numbers can't be used.
    func listColumns(gid: String) -> [Int: [String]] {
        guard let lists = cellLists[gid], !lists.isEmpty, let grid = grids[gid] else { return [:] }
        let headerLine = headers[gid]?.line
        var out: [Int: [String]] = [:]
        for column in grid.columnWidths.indices {
            let name = headerLine.flatMap { grid.text(line: $0, column: column) }.map { PlanGrid.normalized($0).lowercased() } ?? ""
            let sheetColumn = grid.sheetColumns.flatMap { column < $0.count ? $0[column] : nil } ?? column
            if let list = (name.isEmpty ? nil : lists[name]) ?? lists["#\(sheetColumn)"] { out[column] = list }
        }
        return out
    }
}
