import Foundation
import SwiftUI
import VideoQCLib

/// Reading the sheet: polling, values, tab list, layouts and dropdowns, applying what was read.
extension DeliveryPlanStore {
    /// Panels call these on appear / disappear: the sheet is only read while one is on screen.
    func panelAppeared() {
        visiblePanels += 1
        guard visiblePanels == 1 else { return }
        pollTask = Task { [weak self] in
            await self?.loadCachedIfNeeded()
            // Coming back to Inspect or the plan within a minute of the last read: no re-read.
            if let last = self?.lastUpdated, Date().timeIntervalSince(last) < 60 {} else { await self?.refresh() }
            self?.scanFrameIORootIfDue()
            while !Task.isCancelled {
                // Every 10 s while QCpie is in front, every minute behind other apps. One call returns every included
                // tab's values (a few hundred KB for a big plan, gzipped on the wire); an unchanged reply isn't parsed.
                try? await Task.sleep(for: .seconds((NSApp.isActive ? 10 : 60) * (self?.readBackoff ?? 1)))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
                self.scanFrameIORootIfDue()
            }
        }
    }

    func panelDisappeared() {
        visiblePanels = max(0, visiblePanels - 1)
        if visiblePanels == 0 { pollTask?.cancel(); pollTask = nil }
    }

    /// Google sign-in finished: read the sheet and send what the outbox holds.
    func signedIn() {
        guard config != nil else { return }
        setHealth { $0.canWrite = nil; $0.writeError = nil }   // another account may have other rights
        versionCheck = nil; versionCheckRetry = .distantPast   // a new sign-in may carry the Drive scope
        Task { await refresh(full: true); scheduleFlush(after: 0) }
    }

    /// The tab list and title (tabs added, renamed or hidden in the sheet show up without relinking).
    func readMetadata(_ config: Config) async throws -> Config {
        let meta = try await api.metadata(config.link.sheetID)
        // Applied to the config as it is now, not as it was when the call went out: a Frame.io folder set or a tab
        // turned off meanwhile mustn't be undone by this answer.
        guard var updated = self.config, updated.link == config.link else { return config }
        updated.tabs = Self.planTabs(meta.tabs)
        if !meta.title.isEmpty { updated.title = meta.title }
        updated.qcTab = meta.tabs.first { $0.title == PlanQCTab.title }?.gid
        lastMetadata = Date()
        if updated != self.config {
            self.config = updated
            saveConfig()
        }
        return updated
    }

    private func ranges(_ config: Config) -> [String] {
        config.included.map { SheetsAPI.quoted($0.name) } + (config.qcTab != nil ? [SheetsAPI.quoted(PlanQCTab.title)] : [])
    }

    /// Reads every included tab and the QCpie tab in one call. Parsing, matching and the grids run only when the reply
    /// differs from the last one. The tab list is read every 3 minutes, on `full`, and when a tab can't be found.
    /// `adoptAsSeen`: the first read of a new link isn't "changes".
    func refresh(adoptAsSeen: Bool = false, full: Bool = false) async {
        // A new link's first read waits for a read of the old one to finish (it'll be thrown away).
        if adoptAsSeen { while reading { try? await Task.sleep(for: .milliseconds(50)) } }
        guard var config, !reading else { return }
        reading = true
        defer { reading = false }
        if rows.isEmpty || adoptAsSeen { phase = .loading }
        let started = Date()
        do {
            if full || Date().timeIntervalSince(lastMetadata) > 180 { config = try await readMetadata(config) }
            // Cheap check first: nothing changed since the last read → no read (at most 3 minutes apart).
            var version: String?
            if versionCheck != false || Date() > versionCheckRetry {
                do {
                    version = try await api.version(config.link.sheetID)
                    versionCheck = true
                } catch SheetsAPI.Failure.noAccess(_) {
                    versionCheck = false
                    versionCheckRetry = Date().addingTimeInterval(1800)
                } catch SheetsAPI.Failure.notFound {
                    versionCheck = false
                    versionCheckRetry = Date().addingTimeInterval(1800)
                } catch {
                    // Anything else (offline, Google busy): the values read below says what's wrong, if anything.
                }
            }
            if !full, !adoptAsSeen, let version, version == lastVersion, lastValues != nil, ranges(config) == lastRanges,
               Date().timeIntervalSince(lastValuesRead) < 180 {
                if outbox.settle(readStart: started) { saveOutbox(); recomputeStates(); publishGrids() }
                readBackoff = 1
                if phase != .idle { phase = .idle }
                setHealth { $0.readError = nil }
                if lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true { lastUpdated = Date() }
                if !outbox.unsent.records.isEmpty || !outbox.unsent.cells.isEmpty { scheduleFlush(after: 0) }
                return
            }
            var data: Data
            do {
                // Every tab left out and no QCpie tab: nothing to read (Google refuses a read of no ranges).
                data = ranges(config).isEmpty ? Data(#"{"valueRanges":[]}"#.utf8) : try await api.values(config.link.sheetID, ranges: ranges(config))
            } catch SheetsAPI.Failure.http(400, _) {
                // A tab renamed or deleted since the last tab list.
                config = try await readMetadata(config)
                data = try await api.values(config.link.sheetID, ranges: ranges(config))
            }
            guard self.config?.link == config.link else { return }   // relinked meanwhile
            lastVersion = version
            lastValuesRead = Date()
            lastRanges = ranges(config)
            readBackoff = 1
            // Edits Google took before this read started are in it: they leave the overlay now, with the new values.
            let settled = outbox.settle(readStart: started)
            if settled { saveOutbox() }
            if data != lastValues || adoptAsSeen {
                lastValues = data
                let included = config.included
                let all = try await Task.detached(priority: .userInitiated) { try SheetsAPI.tables(data) }.value
                let planTables = Array(all.prefix(included.count))
                let qcValues = config.qcTab != nil && all.count > included.count ? all[included.count] : nil
                await apply(tabs: included, tables: planTables, qc: qcValues, adoptAsSeen: adoptAsSeen)
                await applyGrids(tabs: included, tables: planTables)
                let dir = Self.directory(config.link.sheetID)
                var cache = Dictionary(uniqueKeysWithValues: zip(included.map(\.gid), planTables))
                if let qcValues { cache["qc"] = qcValues }
                Task.detached(priority: .utility) { Self.writeCache(cache, to: dir) }
                lastUpdated = Date()
            } else {
                if settled { recomputeStates(); publishGrids() }
                // "Updated" moves on once a minute when nothing changed (each publish redraws the panels).
                if lastUpdated.map({ Date().timeIntervalSince($0) > 60 }) ?? true { lastUpdated = Date() }
            }
            if phase != .idle { phase = .idle }
            setHealth { $0.readError = nil }
            // Tabs turned on or off while this read was out (its own refresh was skipped): read them now.
            if let now = self.config, now.link == config.link, now.included != config.included {
                Task { await self.refresh() }
            }
            if !outbox.unsent.records.isEmpty || !outbox.unsent.cells.isEmpty { scheduleFlush(after: 0) }
        } catch is CancellationError {
            if phase != .idle { phase = .idle }
        } catch {
            if case GoogleAuth.Failure.signedOut = error { GoogleAccount.shared.noteSignedOut() }
            if case SheetsAPI.Failure.http(429, _) = error {
                // Too many requests for the project (several Macs on the plan): read less often until Google answers.
                readBackoff = min(readBackoff * 2, 12)
                setHealth { $0.readError = "Google Sheets is busy: reading every \(Int(10 * self.readBackoff)) s for now." }
                return
            }
            phase = .failed(Self.describe(error))
            setHealth { $0.readError = Self.describe(error) }
        }
    }

    func apply(tabs: [PlanTab], tables: [[[String]]], qc: [[String]]?, adoptAsSeen: Bool) async {
        applyGeneration += 1
        let generation = applyGeneration
        let oldRows = rows
        let parsed = await Task.detached(priority: .userInitiated) { () -> ([PlanRow], [String], [String: (line: Int, columns: [PlanField: Int])], PlanQCTab.Table?, Bool, Bool) in
            var all: [PlanRow] = []
            var unread: [String] = []
            var headers: [String: (line: Int, columns: [PlanField: Int])] = [:]
            for (tab, table) in zip(tabs, tables) {
                let (rows, header) = PlanParser.parse(table: table, tab: tab.name)
                if let header {
                    headers[tab.gid] = (header.index + 1, header.columns)
                } else if rows.isEmpty {
                    unread.append(tab.name)
                }
                all += rows
            }
            // QCpie's own values come from its tab (the plan tabs' QC columns are lookups of it, or old copies).
            let qcTable = qc.flatMap(PlanQCTab.parse)
            if let qcTable { all = all.map { $0.withTracking(qcTable.values[($0.code ?? "").lowercased()] ?? [:]) } }
            PlanParser.flagDuplicates(&all)
            // Compared here, not on the main thread (~50 ms for 1,100 rows on efficiency cores).
            let rowsChanged = all != oldRows
            // Matching ignores QC columns: a status change doesn't re-run it.
            let matchChanged = rowsChanged && all.map(\.matchSignature) != oldRows.map(\.matchSignature)
            return (all, unread, headers, qcTable, rowsChanged, matchChanged)
        }.value
        guard generation == applyGeneration else { return }
        let (newRows, unread, newHeaders, newQC, rowsChanged, matchChanged) = parsed
        headers = newHeaders
        stampSheetsEdits(old: qcTable, new: newQC, adoptAsSeen: adoptAsSeen)
        qcTable = newQC
        var counts = tabCounts
        for tab in tabs { counts[tab.gid] = newRows.filter { $0.tab == tab.name }.count }
        if counts != tabCounts { tabCounts = counts }
        if adoptAsSeen || (seen.isEmpty && rows.isEmpty) {
            seen = Self.snapshot(newRows)
            saveSeen()
        }
        if rowsChanged { rows = newRows }
        if unread != unreadTabs { unreadTabs = unread }
        recomputeChanges()
        if matchChanged { rematch() } else if rowsChanged { recomputeStates() }
    }

    /// A QC Status changed in Google Sheets (on the QCpie tab) without a new QC Updated: stamp it, so a file exported
    /// after it still sends the row back to To QC. Any Mac reading the change may stamp it; they agree to the second.
    private func stampSheetsEdits(old: PlanQCTab.Table?, new: PlanQCTab.Table?, adoptAsSeen: Bool) {
        guard let old, let new, !adoptAsSeen else { return }
        let stamp = PlanStatusResolver.stamp(Date(), by: "Sheets")
        var stamped = false
        defer { if stamped { saveOutbox(); scheduleFlush(after: 1) } }
        for (key, values) in new.values where outbox.records[key] == nil {
            let before = old.values[key] ?? [:]
            guard (values[.qcStatus] ?? "") != (before[.qcStatus] ?? ""), (values[.qcUpdated] ?? "") == (before[.qcUpdated] ?? ""),
                  !(values[.qcStatus] ?? "").isEmpty else { continue }
            outbox.set(code: key, name: "", [.qcUpdated: stamp], quiet: true)
            stamped = true
        }
    }

    /// Each tab's grid: its formatted layout filled with the latest values when the layout still fits them, else
    /// the values unformatted (or the last grid) until the layout has been read again. Layouts are read in the
    /// background every 5 minutes, and when rows or columns were added or removed.
    private func applyGrids(tabs: [PlanTab], tables newTables: [[[String]]]) async {
        let generation = applyGeneration
        let oldTables = tables
        for (tab, table) in zip(tabs, newTables) { tables[tab.gid] = table }
        let layouts = layouts
        let built = await Task.detached(priority: .userInitiated) { () -> ([String: PlanGrid], [String], [String: [ClosedRange<Int>]]) in
            var out: [String: PlanGrid] = [:]
            var stale: [String] = []
            var changed: [String: [ClosedRange<Int>]] = [:]
            for (tab, table) in zip(tabs, newTables) {
                guard let layout = layouts[tab.gid] else { out[tab.gid] = PlanGrid.fromTable(table); stale.append(tab.gid); continue }
                // A layout of another size still shows the values it has cells for, until it's read again.
                if !layout.fits(table) { stale.append(tab.gid) } else if let old = oldTables[tab.gid], old.count == table.count {
                    // Same size, some values changed: their rows' formats are read again (conditional colours).
                    let lines = PlanGrid.changedLines(old, table)
                    if lines.count > 40 { stale.append(tab.gid) } else if !lines.isEmpty { changed[tab.gid] = lines }
                }
                out[tab.gid] = layout.withTexts(table)
            }
            return (out, stale, changed)
        }.value
        guard generation == applyGeneration else { return }
        readGrids = built.0
        publishGrids()
        let due = tabs.filter { tab in built.1.contains(tab.gid) || layoutRead[tab.gid].map { Date().timeIntervalSince($0) > 300 } ?? true }
        if !due.isEmpty, layoutTask == nil { layoutTask = Task { await self.readLayouts(due); self.layoutTask = nil } }
        for tab in tabs where !due.contains(tab) {
            if let lines = built.2[tab.gid] { Task { await self.readRowFormats(tab, lines: lines) } }
        }
    }

    /// Re-reads the formats of rows whose values changed (a status set: Sheets' conditional formatting recolours the
    /// cell) and lays them into the tab's layout. A few KB per row range, only after a read that changed them.
    private func readRowFormats(_ tab: PlanTab, lines: [ClosedRange<Int>]) async {
        guard let config, let data = await Log.plan.attempt("Reading row formats of \(tab.name)", { try await api.rowFormats(config.link.sheetID, tab: tab.name, rows: lines) }),
              self.config?.link == config.link, let layout = layouts[tab.gid] else { return }
        let patched = await Task.detached(priority: .userInitiated) { layout.patchingFormats(data) }.value
        guard layouts[tab.gid] == layout else { return }   // re-read meanwhile: that one is newer
        layouts[tab.gid] = patched
        if let table = tables[tab.gid] { readGrids[tab.gid] = patched.withTexts(table) }
        publishGrids()
    }

    /// Reads tabs' formatting and dropdown choices (one tab at a time, off the main thread). ~1–3 MB per 1,000-row
    /// tab: only on link, every 5 minutes and when the sheet's size changed, never on the 10 s check.
    private func readLayouts(_ tabs: [PlanTab]) async {
        guard let config else { return }
        let id = config.link.sheetID
        for tab in tabs {
            guard let table = tables[tab.gid] else { continue }
            guard let data = await Log.plan.attempt("Reading the layout of \(tab.name)", { try await api.layout(id, tab: tab.name) }) else {
                layoutRead[tab.gid] = Date().addingTimeInterval(-240)   // try again in a minute, not every 10 s
                continue
            }
            let grid = await Task.detached(priority: .utility) { PlanGrid.fromSheets(layout: data, table: table) }.value
            guard self.config?.link == config.link else { return }
            layoutRead[tab.gid] = Date()
            if let grid {
                layouts[tab.gid] = grid
                // Values read while the layout was on its way win.
                readGrids[tab.gid] = tables[tab.gid].map { grid.withTexts($0) } ?? grid
            }
            if let header = headers[tab.gid] { await readLists(tab: tab, headerLine: header.line, table: table) }
        }
        publishGrids()
        // Rows or columns added while this read was out (or while another tab's was): read those once more, or new rows
        // would stay out of the Sheet view until the sheet changed again.
        let outgrown = tabs.filter { tab in
            guard let layout = layouts[tab.gid], let table = tables[tab.gid] else { return false }
            return !layout.fits(table)
        }
        let others = config.included.filter { tab in
            !tabs.contains(tab) && layouts[tab.gid].map { layout in tables[tab.gid].map { !layout.fits($0) } ?? false } ?? false
        }
        if !outgrown.isEmpty || !others.isEmpty, !Task.isCancelled, rereadDepth < 2 {
            rereadDepth += 1
            await readLayouts(outgrown + others)
            rereadDepth -= 1
        }
        let dir = Self.directory(id), cache = layouts
        Task.detached(priority: .utility) { Self.writeLayouts(cache, to: dir) }
    }

    /// Dropdown choices of the row under the header, keyed by header text (lower case), else "#" + sheet column.
    private func readLists(tab: PlanTab, headerLine: Int, table: [[String]]) async {
        guard let config, let data = await Log.plan.attempt("Reading dropdowns of \(tab.name)", { try await api.validations(config.link.sheetID, tab: tab.name, row: headerLine + 1) }) else { return }
        let (lists, ranges) = Self.parseValidations(data)
        var resolved = lists
        if !ranges.isEmpty, let values = try? await api.values(config.link.sheetID, ranges: ranges.map(\.range)),
           let read = try? SheetsAPI.tables(values) {
            for (item, cells) in zip(ranges, read) {
                let options = cells.flatMap { $0 }.map(PlanGrid.normalized).filter { !$0.isEmpty }
                if !options.isEmpty { resolved[item.column] = options }
            }
        }
        let names = headerLine - 1 < table.count ? table[headerLine - 1] : []
        var out: [String: [String]] = [:]
        for (column, options) in resolved {
            let name = column < names.count ? PlanGrid.normalized(names[column]).lowercased() : ""
            out[name.isEmpty ? "#\(column)" : name] = options
        }
        if cellLists[tab.gid] != (out.isEmpty ? nil : out) { cellLists[tab.gid] = out.isEmpty ? nil : out }
    }

    /// Lists (`ONE_OF_LIST`) and ranges to read (`ONE_OF_RANGE`) by sheet column, from a `validations` reply.
    nonisolated static func parseValidations(_ data: Data) -> (lists: [Int: [String]], ranges: [(column: Int, range: String)]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let grid = ((json["sheets"] as? [[String: Any]])?.first?["data"] as? [[String: Any]])?.first,
              let values = (grid["rowData"] as? [[String: Any]])?.first?["values"] as? [[String: Any]] else { return ([:], []) }
        var lists: [Int: [String]] = [:]
        var ranges: [(Int, String)] = []
        for (column, cell) in values.enumerated() {
            guard let condition = (cell["dataValidation"] as? [String: Any])?["condition"] as? [String: Any],
                  let type = condition["type"] as? String else { continue }
            let entries = (condition["values"] as? [[String: Any]] ?? []).compactMap { $0["userEnteredValue"] as? String }
            if type == "ONE_OF_LIST" {
                let options = entries.map(PlanGrid.normalized).filter { !$0.isEmpty }
                if !options.isEmpty { lists[column] = options }
            } else if type == "ONE_OF_RANGE", let range = entries.first {
                ranges.append((column, range.hasPrefix("=") ? String(range.dropFirst()) : range))
            }
        }
        return (lists, ranges)
    }

    /// Read grids with the outbox's edits laid over (QCpie's columns by code, typed cells by position).
    func publishGrids() {
        var out = readGrids
        if let config {
            let overlay = outbox.overlay
            for tab in config.included {
                guard var grid = out[tab.gid] else { continue }
                var edits = outbox.cellOverlay(gid: tab.gid)
                if !overlay.isEmpty, headers[tab.gid] != nil {
                    // QCpie's columns in this tab's view, found once per tab.
                    var columns: [PlanField: Int] = [:]
                    for field in PlanField.allCases where field.isTracking { columns[field] = gridColumn(field, gid: tab.gid) }
                    if !columns.isEmpty {
                        for row in rows where row.tab == tab.name {
                            guard let code = row.code, let values = overlay[code.lowercased()] else { continue }
                            for (field, value) in values {
                                if let column = columns[field] { edits[CellKey(line: row.line, column: column)] = value }
                            }
                        }
                    }
                }
                if !edits.isEmpty { grid = grid.applying(edits); out[tab.gid] = grid }
            }
        }
        if out != grids { grids = out }
    }
}
