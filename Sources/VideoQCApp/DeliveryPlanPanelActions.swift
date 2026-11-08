import SwiftUI
import AppKit

/// The Delivery Plan panel's selection, plan checks and status actions.
extension DeliveryPlanPanel {
    // MARK: Selection

    /// Rows holding a file selected in Inspect (sheet order).
    func highlightedRows(_ rows: [PlanRow], match: PlanMatch) -> [PlanRow] {
        // Via the file → row index (O(selected files)), not each row's match result: this runs several times per
        // redraw, and the plan redraws on every Inspect selection (each ↓ press).
        let ids = Set(store.selectedFiles.compactMap { store.fileIndex[$0]?.rowID })
        guard !ids.isEmpty else { return [] }
        return rows.filter { ids.contains($0.id) }
    }

    /// A row clicked in the plan: Inspect selects its files (or nothing, for a row without one); double-click plays.
    /// A Summary figure was clicked: its rows in the Sheet or List view, with only that filter on.
    func openFromSummary(_ target: PlanSummaryTarget) {
        statusFilter = nil; batchFilter = nil; uploadFilter = nil; channelFilter = nil; changedOnly = false; search = ""
        switch target {
        case .state(let state): statusFilter = state
        case .batch(let batch): batchFilter = batch
        case .channel(let channel): channelFilter = channel
        case .upload(let filter): uploadFilter = filter
        case .row(let id):
            if let row = store.rows.first(where: { $0.id == id }) {
                if let tab = store.config?.tabs.first(where: { $0.name == row.tab }) { sheetTab = tab.gid }
                select(row, match: store.match, play: false)
            }
        }
        viewMode = dataView == "list" ? "list" : "sheet"
    }

    func select(_ row: PlanRow, match: PlanMatch, play: Bool) {
        selectedRow = row.id
        store.focusedRowID = row.id
        let files = match.result(row).files
        DeliveryPlanStore.post(.reveal, files)
        if play { DeliveryPlanStore.post(.play, files) }
    }

    var currentFilter: DeliveryPlanStore.SharedFilter {
        DeliveryPlanStore.SharedFilter(state: statusFilter?.rawValue ?? -1, search: search, batch: batchFilter, upload: uploadFilter)
    }

    // MARK: Checks

    func checkSummary(_ row: PlanRow) -> PlanChecksSummary {
        summaryCache.summary(row, store: store, queue: checks)
    }

    /// Run Checks: on the rows shown (filters apply) or the selection; which checks; Pass All Clean.
    var runChecksMenu: some View {
        let rows = store.rows
        let shown = rowsShownForChecks(rows)
        let selection = selectedRowsForChecks(rows)
        let clean = rows.filter { store.state($0).state == .toQC && checkSummary($0).result == .passed }
        return Menu {
            Button("Check \(fileCount(shown)) Files in Shown Rows") { runChecks(shown) }
                .disabled(fileCount(shown) == 0 || checks.kinds.isEmpty)
            Button("Check \(fileCount(selection)) Files in Selection") { runChecks(selection) }
                .disabled(fileCount(selection) == 0 || checks.kinds.isEmpty)
            Divider()
            ForEach(PlanCheckKind.allCases, id: \.self) { kind in
                Toggle(kind.title, isOn: Binding(get: { checks.kinds.contains(kind) },
                                                 set: { on in if on { checks.kinds.insert(kind) } else { checks.kinds.remove(kind) } }))
            }
            Divider()
            Button("Pass All Clean (\(clean.count))…") { passAllClean(clean) }
                .disabled(clean.isEmpty || checks.kinds.isEmpty)
        } label: {
            Image(systemName: "checkmark.shield")
                .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Run loudness and Frame Check on plan files: one file at a time, never while the Player plays.")
    }

    private func rowsShownForChecks(_ rows: [PlanRow]) -> [PlanRow] {
        let match = store.match
        guard let lines = shownLines(rows, match: match) else { return rows }
        return rows.filter { lines.contains($0.line) }
    }

    private func selectedRowsForChecks(_ rows: [PlanRow]) -> [PlanRow] {
        let highlighted = highlightedRows(rows, match: store.match)
        if !highlighted.isEmpty { return highlighted }
        return rows.filter { $0.id == selectedRow }
    }

    private func fileCount(_ rows: [PlanRow]) -> Int { Set(rows.flatMap { store.match.result($0).files }).count }

    private func runChecks(_ rows: [PlanRow]) {
        var seen = Set<URL>()
        let files = rows.flatMap { store.fileStamps($0) }.filter { seen.insert($0.url).inserted }
        checks.enqueue(files, kinds: checks.kinds)
    }

    /// Unlinking deletes this Mac's copy of the plan, the outbox included: edits Google doesn't have yet (offline, no
    /// QCpie tab) were lost without a word. Asks first when there are any.
    func confirmUnlink() {
        let unsent = store.outbox.unsent.records.count + store.outbox.unsent.cells.count
        guard unsent > 0 else { store.unlink(); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unlink with \(unsent) unsaved edit\(unsent == 1 ? "" : "s")?"
        alert.informativeText = "\(unsent == 1 ? "An edit hasn't" : "\(unsent) edits haven't") reached the sheet yet (statuses, notes, typed cells). Unlinking discards \(unsent == 1 ? "it" : "them")."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Unlink").hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { store.unlink() }
    }

    /// Marks every To QC row whose checks all passed as QC Passed, after asking.
    private func passAllClean(_ rows: [PlanRow]) {
        let alert = NSAlert()
        alert.messageText = "Mark \(rows.count) row\(rows.count == 1 ? "" : "s") QC Passed?"
        alert.informativeText = "Each has a file and every chosen check (\(PlanCheckKind.allCases.filter(checks.kinds.contains).map(\.title).joined(separator: ", "))) passed. The status is written to the sheet."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Mark QC Passed")
        if alert.runModal() == .alertSecondButtonReturn {
            store.setStatus(.passed, rowIDs: rows.map(\.id))
        }
    }

    // MARK: Status

    /// The rows a status applies to: every row highlighted from Inspect when this row is one of them, else this row.
    func statusTargets(_ row: PlanRow, match: PlanMatch) -> [String] {
        let highlighted = highlightedRows(store.rows, match: match).map(\.id)
        return highlighted.contains(row.id) ? highlighted : [row.id]
    }

    func statusNSMenu(_ targets: [String]) -> NSMenu {
        let menu = NSMenu()
        for status in PlanQCStatus.allCases {
            menu.addItem("\(status.title)  \(status.shortcut)") { [store] in store.setStatus(status, rowIDs: targets) }
        }
        menu.addItem(.separator())
        menu.addItem("Clear Status") { [store] in store.setStatus(nil, rowIDs: targets) }
        return menu
    }

    /// Status menu and QC note for the selected row(s), above its card.
    func statusBar(_ row: PlanRow, targets: [String]) -> some View {
        let state = store.state(row).state
        return HStack(spacing: 8) {
            Menu {
                ForEach(PlanQCStatus.allCases, id: \.self) { status in
                    Button("\(status.title)  \(status.shortcut)") { store.setStatus(status, rowIDs: targets) }
                }
                Divider()
                Button("Clear Status") { store.setStatus(nil, rowIDs: targets) }
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(color(state)).frame(width: 7, height: 7)
                    Text(targets.count > 1 ? "\(state.title) · \(targets.count) rows" : state.title)
                        .font(.ui(size: 11, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tip("Set the QC status (⌥1–⌥6). It's written to the sheet's QC Status column.")
            if store.hasBatchColumn || !store.batches.isEmpty {
                let batch = store.batch(row)
                PlanBatchMenu(title: batch.isEmpty ? "No Batch" : PlanBatch.title(batch), rowIDs: { targets })
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.ui(size: 11, weight: .semibold))
                    .tip("Set the delivery batch. It's written to the sheet's Batch column.")
            }
            let summary = checkSummary(row)
            if state == .toQC || state == .needsFix || state == .check {
                if summary.result == .passed {
                    Button("Pass") { store.setStatus(.passed, rowIDs: targets) }
                        .tip("All checks passed: mark QC Passed (⌥2).")
                } else if summary.result == .failed {
                    Button("Needs Fix") {
                        store.setStatus(.needsFix, rowIDs: targets)
                        if targets.count == 1 { store.setNote(summary.failures.joined(separator: "; "), rowID: row.id) }
                    }
                    .tip("Mark Needs Fix with the failed checks as the QC note (⌥1).")
                }
            }
            TextField("QC note", text: $noteDraft)
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 11))
                .onAppear { noteDraft = store.note(row); noteRowID = row.id }
                .onChange(of: row.id) { old, new in
                    // Selecting another row while typing: the text goes to the row it was typed for, not lost. Not
                    // typing, there's nothing to keep (leaving the field saves), and the draft may already show the
                    // new row's note (the note onChange below can run first): committing it would copy it to the old row.
                    if noteFocused { commitDraft(to: old) }
                    noteDraft = store.note(row)
                    noteRowID = new
                }
                // A read while typing mustn't replace the text being typed.
                .onChange(of: store.note(row)) { _, new in if !noteFocused { noteDraft = new } }
                .focused($noteFocused)
                .onSubmit { commitNote(row) }
                // Clicking away saves; Esc (which the shortcut router turns into "unfocus") puts it back.
                .onChange(of: noteFocused) { _, focused in
                    guard !focused else { return }
                    if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 53 { noteDraft = store.note(row) } else { commitNote(row) }
                }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func commitNote(_ row: PlanRow) { commitDraft(to: noteRowID ?? row.id) }

    private func commitDraft(to id: String) {
        guard let row = store.rows.first(where: { $0.id == id }) else { return }
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != store.note(row) else { return }
        store.setNote(text, rowID: id)
    }
}
