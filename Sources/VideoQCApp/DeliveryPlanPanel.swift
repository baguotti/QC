import SwiftUI
import AppKit

/// The Delivery Plan: in the Inspect tab's right drawer, or popped out into its own window (`DeliveryPlanWindow`),
/// which can go on a second screen. Only one shows the plan at a time; the drawer shows a placeholder while popped out.
struct DeliveryPlanPanel: View {
    enum Placement { case drawer, window }

    let placement: Placement
    let isLightMode: Bool
    var onClose: (() -> Void)? = nil

    @ObservedObject private var store = DeliveryPlanStore.shared
    /// Published once per checked file (progress has its own object, observed by the strip only).
    @ObservedObject private var checks = PlanCheckQueue.shared
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    @AppStorage(DeliveryPlanWindow.poppedOutKey) private var poppedOut = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var linkText = ""
    @State private var search = ""
    @State private var statusFilter: PlanState? = nil
    @State private var noteDraft = ""
    /// The row the note being typed belongs to (the field shows another row's note once the selection moves).
    @State private var noteRowID: String? = nil
    @FocusState private var noteFocused: Bool
    @State private var changedOnly = false
    @State private var showRemoved = false
    @State private var selectedRow: String? = nil
    @State private var relinking = false
    /// "sheet" (the tab as Google Sheets draws it) or "list" (one card per deliverable).
    @AppStorage("deliveryPlanView") private var viewMode = "sheet"
    @AppStorage("deliveryPlanZoom") private var zoom = 1.0
    /// The tab the Sheet view shows when more than one is read.
    @State private var sheetTab: String? = nil
    @State private var showEditSetup = false
    @State private var summaryCache = PlanChecksSummaryCache()

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if placement == .drawer && poppedOut {
                poppedOutPlaceholder
            } else if store.config == nil || relinking {
                linkView
            } else {
                planView
                    .onAppear { store.panelAppeared(); checks.loadIfNeeded() }
                    .onDisappear { store.panelDisappeared() }
            }
        }
        .background(palette.bgPanel)
        .onChange(of: store.scrollRequest) { _, _ in selectedRow = nil }   // Inspect chose: its rows lead
        // Linked filters: this side's chip / search goes to Inspect, Inspect's comes here.
        .onChange(of: currentFilter) { _, filter in store.publishFilter(filter, fromPlan: true) }
        .onReceive(store.$sharedFilter) { filter in
            guard store.linkFilters, filter != currentFilter else { return }
            statusFilter = filter.state >= 0 ? PlanState(rawValue: filter.state) : nil
            if filter.state != currentFilter.state { changedOnly = false }   // a search alone keeps "Changed"
            search = filter.search
        }
        .background {
            // The plan window gets every key itself (the router passes them through): ⌥1–⌥6 / ⌥0 here.
            if placement == .window {
                ForEach(0...PlanQCStatus.allCases.count, id: \.self) { n in
                    Button("") { _ = store.setStatusForSelection(n == 0 ? nil : PlanQCStatus.allCases[n - 1]) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .option)
                        .opacity(0)
                        .allowsHitTesting(false)
                }
            }
        }
        .sheet(isPresented: $showEditSetup) {
            PlanEditSetupSheet(isLightMode: isLightMode) { showEditSetup = false }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Delivery Plan")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundColor(palette.textMain)
            Spacer(minLength: 4)
            if placement == .drawer {
                if !poppedOut {
                    Button { openWindow(id: DeliveryPlanWindow.id) } label: {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
                    }
                    .buttonStyle(TransportIconButtonStyle())
                    .tip("Open the Delivery Plan in its own window, to move it to another screen.")
                }
                if let onClose { DrawerCloseButton(isLightMode: isLightMode, action: onClose) }
            } else {
                Button("Dock in Inspect", action: dock)
                    .font(.ui(size: 11, weight: .medium))
                    .buttonStyle(.borderless)
                    .explain("Close this window and show the Delivery Plan in the Inspect tab's drawer again.")
            }
        }
        .headerBand(palette, horizontalPadding: 12)
    }

    /// Back into the drawer. Clears the flag itself: if the window isn't actually open (not restored after a relaunch),
    /// dismissing it never runs its onDisappear and the drawer would keep showing this placeholder.
    private func dock() {
        poppedOut = false
        dismissWindow(id: DeliveryPlanWindow.id)
    }

    private var poppedOutPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: StudioTheme.scaleFont(22), weight: .light))
                .foregroundColor(palette.textSubtle)
            Text("Open in Its Own Window")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text("The Delivery Plan is in a separate window.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textSubtle)
            HStack(spacing: 8) {
                Button("Show Window") { openWindow(id: DeliveryPlanWindow.id) }
                Button("Dock Here", action: dock)
            }
            .font(.ui(size: 11))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Linking

    private var linkView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link a Google Sheet")
                .font(.ui(size: 13, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text("Paste the link of the sheet listing your deliverables. Share it as “Anyone with the link” (Viewer). QCpie re-reads it every minute while this panel is open and matches its rows to the files in Inspect.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://docs.google.com/spreadsheets/d/…", text: $linkText)
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 11))
                .onSubmit(linkNow)
            HStack {
                if case .failed(let message) = store.phase {
                    Text(message)
                        .font(.ui(size: 11))
                        .foregroundColor(palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if relinking { Button("Cancel") { relinking = false } }
                Button(store.phase == .loading ? "Linking…" : "Link Sheet", action: linkNow)
                    .disabled(PlanSheetLink.parse(linkText) == nil || store.phase == .loading)
            }
            .font(.ui(size: 11))
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func linkNow() {
        guard PlanSheetLink.parse(linkText) != nil else { return }
        let text = linkText
        Task {
            await store.link(text)
            if store.config?.link.sheetID == PlanSheetLink.parse(text)?.sheetID {
                relinking = false
                linkText = ""
            }
        }
    }

    // MARK: Plan

    private var planView: some View {
        let rows = store.rows
        let match = store.match
        let counts = Dictionary(grouping: rows, by: { store.state($0).state }).mapValues(\.count)
        return VStack(spacing: 0) {
            toolbar
            VStack(alignment: .leading, spacing: 8) {
                chips(counts: counts, total: rows.count)
                searchBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            if rows.isEmpty {
                emptyRows
            } else if viewMode == "sheet" {
                sheetArea(rows: rows, match: match)
            } else {
                list(filtered(rows, match: match), match: match)   // only built in List view
            }
            if checks.isRunning { PlanCheckProgressStrip(isLightMode: isLightMode) }
            if !store.changes.isEmpty || !store.removed.isEmpty { changesFooter }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.config?.title ?? "")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                if let config = store.config { tabPicker(config) }
                statusLine
            }
            Spacer(minLength: 4)
            runChecksMenu
            viewPicker
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
            }
            .buttonStyle(TransportIconButtonStyle())
            .disabled(store.phase == .loading)
            .tip("Read the sheet again now (it's re-read every minute while this panel is open).")
            Menu {
                if let config = store.config {
                    Button("Open Sheet in Browser") { NSWorkspace.shared.open(config.link.webURL) }
                }
                if store.scriptOutdated {
                    Button("Update Script…") { showEditSetup = true }
                }
                if store.canEdit {
                    Button("Turn Off Editing") { Task { try? await store.setWriter(nil) } }
                } else {
                    Button("Set Up Editing…") { showEditSetup = true }
                }
                Button("Link Another Sheet…") { relinking = true }
                Divider()
                Button("Unlink Sheet", role: .destructive) { store.unlink() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip("Open the sheet, or link another one.")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    /// "Placement ▾ · 1,076 rows": which tabs are read. Sheets often list the same files twice (by placement and by
    /// edit), so only one tab is on at first and the choice stays in sight.
    private func tabPicker(_ config: DeliveryPlanStore.Config) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(config.tabs) { tab in
                    let count = store.tabCounts[tab.gid].map { " (\($0) rows)" } ?? ""
                    Toggle(tab.name + count, isOn: Binding(get: { !config.excluded.contains(tab.gid) },
                                                         set: { store.setIncluded(tab, $0) }))
                }
            } label: {
                Text(config.included.isEmpty ? "No tabs" : config.included.map(\.name).joined(separator: " + "))
                    .font(.ui(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tip("Choose which tabs of the sheet list the deliverables.")
            Text("· \(store.rows.count) rows")
                .font(.ui(size: 10))
                .foregroundColor(palette.textMuted)
                .monospacedDigit()
        }
    }

    private var viewPicker: some View {
        HStack(spacing: 2) {
            if viewMode == "sheet" {
                Menu {
                    ForEach([0.75, 0.9, 1.0, 1.25, 1.5], id: \.self) { value in
                        Button("\(Int(value * 100))%") { zoom = value }
                    }
                } label: {
                    Text("\(Int(zoom * 100))%")
                        .font(.ui(size: 10, weight: .medium))
                        .monospacedDigit()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tip("Zoom the sheet.")
            }
            Picker("", selection: $viewMode) {
                Image(systemName: "tablecells").tag("sheet")
                Image(systemName: "list.bullet").tag("list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .tip("Show the plan as the sheet looks in Google Sheets, or as a list of deliverables.")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch store.phase {
        case .loading:
            Text("Reading the sheet…").font(.ui(size: 10)).foregroundColor(palette.textSubtle)
        case .failed(let message):
            Text(message).font(.ui(size: 10)).foregroundColor(palette.negative).lineLimit(2)
        case .idle:
            if let date = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Updated \(date.formatted(.relative(presentation: .named)))")
                        .font(.ui(size: 10)).foregroundColor(palette.textSubtle)
                }
            } else {
                Text("Not read yet").font(.ui(size: 10)).foregroundColor(palette.textSubtle)
            }
        }
        if store.scriptOutdated {
            Button("Update the sheet's script to set QC statuses…") { showEditSetup = true }
                .buttonStyle(.borderless)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.accentSlotB)
        }
        switch store.editState {
        case .idle: EmptyView()
        case .saving(let n):
            Text(n == 1 ? "Saving to the sheet…" : "Saving \(n) edits to the sheet…").font(.ui(size: 10)).foregroundColor(palette.textSubtle)
        case .saved:
            Text("Saved to the sheet").font(.ui(size: 10)).foregroundColor(palette.positive)
        case .failed(let message):
            Text(message).font(.ui(size: 10)).foregroundColor(palette.negative).lineLimit(3)
        }
        if !store.unreadTabs.isEmpty {
            Text("No header row found in: \(store.unreadTabs.joined(separator: ", "))")
                .font(.ui(size: 10)).foregroundColor(palette.textSubtle).lineLimit(2)
        }
    }

    /// The progress strip: % done (QC Passed, Approved, Delivered of everything not dropped), then a chip per state.
    private func chips(counts: [PlanState: Int], total: Int) -> some View {
        let changed = store.changes.count
        let done = PlanState.allCases.filter(\.isDone).reduce(0) { $0 + (counts[$1] ?? 0) }
        let live = total - (counts[.dropped] ?? 0)
        return FlowChips(spacing: 4) {
            Text(live > 0 ? "\(Int((Double(done) / Double(live) * 100).rounded(.down)))% done" : "")
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.positive)
                .monospacedDigit()
                .padding(.vertical, 3)
            chip("All \(total)", selected: statusFilter == nil && !changedOnly, color: palette.textMuted) {
                statusFilter = nil; changedOnly = false
            }
            ForEach(PlanState.allCases, id: \.self) { status in
                let n = counts[status] ?? 0
                if n > 0 || status == .missing {
                    chip("\(status.title) \(n)", selected: statusFilter == status, color: color(status)) {
                        statusFilter = statusFilter == status ? nil : status
                        changedOnly = false
                    }
                }
            }
            if changed > 0 {
                chip("Changed \(changed)", selected: changedOnly, color: palette.accentBlue) {
                    changedOnly.toggle(); statusFilter = nil
                }
            }
            LinkFiltersButton(isLightMode: isLightMode) { currentFilter }
        }
    }

    private func chip(_ title: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        PlanFilterChip(title: title, selected: selected, color: color, isLightMode: isLightMode, action: action)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: StudioTheme.scaleFont(10)))
                .foregroundColor(palette.textMuted)
            ZStack(alignment: .leading) {
                if search.isEmpty {
                    Text("Filter rows (name, channel, resolution…)")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(palette.textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $search)
                    .font(.ui(size: 11, weight: .medium))
                    .textFieldStyle(.plain)
                    .foregroundColor(palette.textMain)
                    .padding(.horizontal, 4)
            }
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: StudioTheme.scaleFont(10)))
                        .foregroundColor(palette.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .studioBox(background: palette.bgSubtle, border: palette.borderLine)
    }

    private var emptyRows: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(store.phase == .loading ? "Reading the Sheet" : "No Rows")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text(store.phase == .loading ? "This takes a second or two." : "No tab has a header row with a file name column. Check the tabs in the ••• menu.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Selection

    /// Rows holding a file selected in Inspect (sheet order).
    private func highlightedRows(_ rows: [PlanRow], match: PlanMatch) -> [PlanRow] {
        // Via the file → row index (O(selected files)), not each row's match result: this runs several times per
        // redraw, and the plan redraws on every Inspect selection (each ↓ press).
        let ids = Set(store.selectedFiles.compactMap { store.fileIndex[$0]?.rowID })
        guard !ids.isEmpty else { return [] }
        return rows.filter { ids.contains($0.id) }
    }

    /// A row clicked in the plan: Inspect selects its files (or nothing, for a row without one); double-click plays.
    private func select(_ row: PlanRow, match: PlanMatch, play: Bool) {
        selectedRow = row.id
        store.focusedRowID = row.id
        let files = match.result(row).files
        DeliveryPlanStore.post(.reveal, files)
        if play { DeliveryPlanStore.post(.play, files) }
    }

    private var currentFilter: DeliveryPlanStore.SharedFilter {
        DeliveryPlanStore.SharedFilter(state: statusFilter?.rawValue ?? -1, search: search)
    }

    // MARK: Checks

    private func checkSummary(_ row: PlanRow) -> PlanChecksSummary {
        summaryCache.summary(row, store: store, queue: checks)
    }

    /// Run Checks: on the rows shown (filters apply) or the selection; which checks; Pass All Clean.
    private var runChecksMenu: some View {
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
                .disabled(clean.isEmpty)
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
    private func statusTargets(_ row: PlanRow, match: PlanMatch) -> [String] {
        let highlighted = highlightedRows(store.rows, match: match).map(\.id)
        return highlighted.contains(row.id) ? highlighted : [row.id]
    }

    private func statusNSMenu(_ targets: [String]) -> NSMenu {
        let menu = NSMenu()
        for status in PlanQCStatus.allCases {
            menu.addItem("\(status.title)  \(status.shortcut)") { [store] in store.setStatus(status, rowIDs: targets) }
        }
        menu.addItem(.separator())
        menu.addItem("Clear Status") { [store] in store.setStatus(nil, rowIDs: targets) }
        return menu
    }

    /// Status menu and QC note for the selected row(s), above its card.
    private func statusBar(_ row: PlanRow, targets: [String]) -> some View {
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
                    // Selecting another row while typing: the text goes to the row it was typed for, not lost.
                    commitDraft(to: old)
                    noteDraft = store.note(row)
                    noteRowID = new
                }
                .onChange(of: store.note(row)) { _, new in noteDraft = new }
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

    // MARK: Sheet

    /// The tab the Sheet view shows: the chosen one if still read, else the first read tab.
    private func shownTab() -> PlanTab? {
        guard let config = store.config else { return nil }
        let included = config.included
        return included.first { $0.gid == sheetTab } ?? included.first
    }

    @ViewBuilder
    private func sheetArea(rows: [PlanRow], match: PlanMatch) -> some View {
        if let tab = shownTab(), let grid = store.grids[tab.gid] {
            let tabRows = rows.filter { $0.tab == tab.name }
            let byLine = Dictionary(tabRows.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
            let marks = byLine.mapValues { PlanSheetMark(status: store.state($0).state, changed: store.changes[$0.id] != nil,
                                                         checks: checkSummary($0).result) }
            let highlighted = highlightedRows(tabRows, match: match)
            let selected = selectedRow.flatMap { id in tabRows.first { $0.id == id } } ?? highlighted.first
            VStack(spacing: 0) {
                DeliveryPlanSheetView(
                    grid: grid,
                    shownLines: shownLines(tabRows, match: match),
                    marks: marks,
                    selectedLines: Set(highlighted.map(\.line) + (selected.map { [$0.line] } ?? [])),
                    scrollToLine: highlighted.first?.line,
                    scrollToken: store.scrollRequest,
                    zoom: zoom,
                    chrome: PlanSheetChrome(palette: palette),
                    onSelect: { line, clicks in
                        guard let row = byLine[line] else { selectedRow = nil; return }
                        select(row, match: match, play: clicks >= 2)
                    },
                    menu: { line in byLine[line].map { sheetMenu($0, files: match.result($0).files, tab: tab) } },
                    canEdit: store.canEdit,
                    onEdit: { line, column, old, new in store.editCell(gid: tab.gid, line: line, column: column, old: old, new: new) },
                    onEditUnavailable: { showEditSetup = true },
                    statusColumn: store.statusColumn(gid: tab.gid),
                    statusMenu: { line in byLine[line].map { statusNSMenu(statusTargets($0, match: match)) } })
                if (store.config?.included.count ?? 0) > 1 { sheetTabs }
                if let selected {
                    Rectangle().fill(palette.borderLine).frame(height: 1)
                    VStack(spacing: 0) {
                        statusBar(selected, targets: statusTargets(selected, match: match))
                        ScrollView {
                            PlanRowView(row: selected, result: match.result(selected), state: store.state(selected),
                                        note: store.note(selected), checkLines: checkSummary(selected).lines,
                                        change: store.changes[selected.id],
                                        selected: false, wide: true, isLightMode: isLightMode,
                                        themeRevision: ThemeManager.shared.revision)
                        }
                        .frame(maxHeight: 150)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .background(palette.bgCardSubtle)
                } else if !match.extras.isEmpty {
                    Rectangle().fill(palette.borderLine).frame(height: 1)
                    HStack {
                        Text("\(match.extras.count) Inspect files aren't in the plan.")
                            .font(.ui(size: 11))
                            .foregroundColor(palette.textMuted)
                        Spacer(minLength: 4)
                        Button("Show in List") { viewMode = "list" }
                            .buttonStyle(.borderless)
                            .font(.ui(size: 11))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(palette.bgCardSubtle)
                }
            }
        } else {
            emptyRows
        }
    }

    /// Lines passing the chips and the filter field; nil when nothing filters (every row shows, as in the sheet).
    private func shownLines(_ rows: [PlanRow], match: PlanMatch) -> Set<Int>? {
        let terms = PlanMatcher.tokens(search)
        guard statusFilter != nil || changedOnly || !terms.isEmpty else { return nil }
        var lines = Set<Int>()
        for row in rows {
            if let statusFilter, store.state(row).state != statusFilter { continue }
            if changedOnly, store.changes[row.id] == nil { continue }
            if !terms.isEmpty {
                let haystack = row.searchText + " " + match.result(row).files.map(\.lastPathComponent).joined(separator: " ").lowercased()
                if !terms.allSatisfy(haystack.contains) { continue }
            }
            lines.insert(row.line)
        }
        return lines
    }

    /// Sheets-style tabs under the grid when more than one tab is read.
    private var sheetTabs: some View {
        HStack(spacing: 2) {
            ForEach(store.config?.included ?? []) { tab in
                let on = shownTab()?.gid == tab.gid
                Button { sheetTab = tab.gid; selectedRow = nil } label: {
                    Text(tab.name)
                        .font(.ui(size: 11, weight: on ? .semibold : .medium))
                        .foregroundColor(on ? palette.accentBlue : palette.textMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: Radius.control).fill(on ? palette.bgSubtle : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.bgCardHeader)
        .overlay(alignment: .top) { Rectangle().fill(palette.borderLine).frame(height: 1) }
    }

    private func sheetMenu(_ row: PlanRow, files: [URL], tab: PlanTab) -> NSMenu {
        let menu = NSMenu()
        let targets = statusTargets(row, match: store.match)
        let status = NSMenuItem(title: targets.count > 1 ? "Set Status (\(targets.count) Rows)" : "Set Status", action: nil, keyEquivalent: "")
        status.submenu = statusNSMenu(targets)
        menu.addItem(status)
        menu.addItem(.separator())
        for url in files {
            menu.addItem("Show \(url.lastPathComponent) in Inspect") { DeliveryPlanStore.post(.reveal, url) }
            menu.addItem("Play \(url.lastPathComponent)") { DeliveryPlanStore.post(.play, url) }
            menu.addItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            menu.addItem(.separator())
        }
        menu.addItem("Copy File Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.name, forType: .string)
        }
        if let config = store.config {
            menu.addItem("Open Row in Google Sheets") { NSWorkspace.shared.open(config.link.webURL(tab: tab.gid, line: row.line)) }
        }
        return menu
    }

    // MARK: List

    private enum Item: Identifiable {
        case heading(String, Int)
        case row(PlanRow)
        case extras([URL])
        var id: String {
            switch self {
            case .heading(let title, let index): return "h\(index)|\(title)"
            case .row(let row): return row.id
            case .extras: return "extras"
            }
        }
    }

    private func filtered(_ rows: [PlanRow], match: PlanMatch) -> [Item] {
        let terms = PlanMatcher.tokens(search)
        var items: [Item] = []
        var lastHeading: String? = nil
        for row in rows {
            if let statusFilter, store.state(row).state != statusFilter { continue }
            if changedOnly, store.changes[row.id] == nil { continue }
            if !terms.isEmpty {
                let haystack = row.searchText + " " + match.result(row).files.map(\.lastPathComponent).joined(separator: " ").lowercased()
                if !terms.allSatisfy(haystack.contains) { continue }
            }
            let heading = [row.tab, row.section].compactMap { $0 }.joined(separator: " · ")
            if heading != lastHeading {
                items.append(.heading(heading, items.count))
                lastHeading = heading
            }
            items.append(.row(row))
        }
        if statusFilter == nil, !changedOnly, terms.isEmpty, !match.extras.isEmpty { items.append(.extras(match.extras)) }
        return items
    }

    private func list(_ items: [Item], match: PlanMatch) -> some View {
        let highlighted = Set(highlightedRows(store.rows, match: match).map(\.id))
        return ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    switch item {
                    case .heading(let title, _):
                        Text(title.uppercased())
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(palette.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    case .row(let row):
                        PlanRowView(row: row, result: match.result(row), state: store.state(row), note: store.note(row),
                                    checkLines: checkSummary(row).lines, change: store.changes[row.id],
                                    selected: selectedRow == row.id || highlighted.contains(row.id), wide: placement == .window,
                                    isLightMode: isLightMode, themeRevision: ThemeManager.shared.revision)
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { select(row, match: match, play: true) }
                            .onTapGesture { select(row, match: match, play: false) }
                            .contextMenu { rowMenu(row, files: match.result(row).files) }
                    case .extras(let urls):
                        extrasView(urls)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .onChange(of: store.scrollRequest) { _, _ in
            let match = store.match
            if let row = highlightedRows(store.rows, match: match).first {
                withAnimation(Motion.list) { proxy.scrollTo(row.id, anchor: .center) }
            } else if let url = store.selectedFiles.first(where: { match.extras.contains($0) }) {
                withAnimation(Motion.list) { proxy.scrollTo("extras", anchor: .top) }
                _ = url
            }
        }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: PlanRow, files: [URL]) -> some View {
        let targets = statusTargets(row, match: store.match)
        Menu(targets.count > 1 ? "Set Status (\(targets.count) Rows)" : "Set Status") {
            ForEach(PlanQCStatus.allCases, id: \.self) { status in
                Button("\(status.title)  \(status.shortcut)") { store.setStatus(status, rowIDs: targets) }
            }
            Divider()
            Button("Clear Status") { store.setStatus(nil, rowIDs: targets) }
        }
        Divider()
        ForEach(files, id: \.self) { url in
            Button("Show \(url.lastPathComponent) in Inspect") { DeliveryPlanStore.post(.reveal, url) }
            Button("Play \(url.lastPathComponent)") { DeliveryPlanStore.post(.play, url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if !files.isEmpty { Divider() }
        Button("Copy File Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.name, forType: .string)
        }
        if let config = store.config {
            Button("Open Sheet in Browser") { NSWorkspace.shared.open(config.link.webURL) }
        }
    }

    private func extrasView(_ urls: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOT IN THE PLAN (\(urls.count))")
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.textMuted)
                .padding(.top, 12)
            Text("Inspect files whose names don't contain any row's file name, or whose rows already have a matching file.")
                .font(.ui(size: 10))
                .foregroundColor(palette.textSubtle)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(urls, id: \.self) { url in
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.ui(size: 11, weight: store.selectedFiles.contains(url) ? .semibold : .regular))
                        .foregroundColor(store.selectedFiles.contains(url) ? palette.accentBlue : palette.textMain)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = store.match.extraNotes[url] {
                        Text(note)
                            .font(.ui(size: 10))
                            .foregroundColor(palette.negative)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .contentShape(Rectangle())
                    .onTapGesture { DeliveryPlanStore.post(.reveal, url) }
                    .onTapGesture(count: 2) { DeliveryPlanStore.post(.play, url) }
            }
        }
        .padding(.horizontal, 12)
    }

    private var changesFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(palette.borderLine).frame(height: 1)
            HStack(spacing: 8) {
                Text(changeSummary)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.accentBlue)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !store.removed.isEmpty {
                    Button(showRemoved ? "Hide Removed" : "Show Removed") { withAnimation(Motion.list) { showRemoved.toggle() } }
                        .buttonStyle(.borderless)
                }
                Button("Mark Seen") { store.markSeen(); changedOnly = false }
                    .explain("Accept the sheet as it is now: the change highlights and the removed list clear.")
            }
            .font(.ui(size: 11))
            .padding(.horizontal, 12)
            if showRemoved && !store.removed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.removed, id: \.label) { row in
                            Text(row.label)
                                .font(.ui(size: 11))
                                .foregroundColor(palette.textMuted)
                                .strikethrough()
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(.bottom, 8)
        .background(palette.bgCardSubtle)
    }

    private var changeSummary: String {
        let added = store.changes.values.filter { $0 == .added }.count
        let changed = store.changes.count - added
        return [added > 0 ? "\(added) new" : nil, changed > 0 ? "\(changed) changed" : nil,
                store.removed.isEmpty ? nil : "\(store.removed.count) removed"]
            .compactMap { $0 }.joined(separator: " · ") + " since you last looked"
    }

    private func color(_ status: PlanState) -> Color { PlanRowView.color(status, palette) }
}

/// One deliverable: status dot, name, the specs the sheet asks for, the matched file and anything wrong.
struct PlanRowView: View, Equatable {
    let row: PlanRow
    let result: PlanRowResult
    var state = PlanRowState(state: .missing)
    var note = ""
    var checkLines: [String] = []
    let change: DeliveryPlanStore.Change?
    let selected: Bool
    let wide: Bool
    let isLightMode: Bool
    let themeRevision: Int

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    /// Status tags use the tag palette (`TagTone`), never the accents: ten states need ten distinct colours.
    static func color(_ state: PlanState, _ palette: StudioPalette) -> Color {
        let tone: TagTone
        switch state {
        case .missing: tone = .grey
        case .toQC: tone = .blue
        case .wrongSpec: tone = .red
        case .check: tone = .amber
        case .needsFix: tone = .orange
        case .passed: tone = .mint
        case .approved: tone = .cyan
        case .delivered: tone = .green
        case .onHold: tone = .sand
        case .dropped: tone = .slate
        }
        return tone.color(palette.isLight)
    }

    private var specs: String {
        var parts: [String] = []
        if let w = row.width, let h = row.height { parts.append("\(w)×\(h)") } else if !row.value(.resolution).isEmpty { parts.append(row.value(.resolution)) }
        if !row.value(.aspect).isEmpty { parts.append(row.value(.aspect)) }
        if !row.value(.length).isEmpty { parts.append(row.value(.length)) }
        if let format = row.format { parts.append(format.title) }
        if let fps = row.fps { parts.append("\(format0(fps)) fps") }
        if let max = row.maxBytes { parts.append("≤ \(ByteCountFormatter.string(fromByteCount: max, countStyle: .decimal))") }
        return parts.joined(separator: " · ")
    }

    private var flags: String {
        var parts: [String] = []
        let channel = [row.value(.channel), row.value(.placement)].filter { !$0.isEmpty }
        if !channel.isEmpty { parts.append(channel.joined(separator: " / ")) }
        for field in [PlanField.logos, .graphics, .cta, .subs, .translations, .sound] {
            let v = row.value(field)
            guard !v.isEmpty, v.lowercased() != "no" else { continue }
            parts.append(v.lowercased() == "yes" ? field.title : "\(field.title) \(v)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Self.color(state.state, palette))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if !row.number.isEmpty {
                        Text(row.number)
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundColor(palette.textMuted)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle))
                    }
                    Text(row.name)
                        .font(.ui(size: 11, weight: .medium))
                        .foregroundColor(palette.textMain)
                        .lineLimit(wide ? 1 : 2)
                    Spacer(minLength: 4)
                    Text(state.state.title)
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(Self.color(state.state, palette))
                    Text("Row \(row.line)")
                        .font(.ui(size: 10))
                        .foregroundColor(palette.textSubtle)
                        .monospacedDigit()
                }
                Text(specs)
                    .font(.ui(size: 10))
                    .foregroundColor(palette.textMuted)
                    .lineLimit(1)
                if !flags.isEmpty {
                    Text(flags)
                        .font(.ui(size: 10))
                        .foregroundColor(palette.textSubtle)
                        .lineLimit(wide ? 1 : 2)
                }
                ForEach(state.flags, id: \.self) { flag in
                    Text(flag)
                        .font(.ui(size: 10, weight: .medium))
                        .foregroundColor(palette.accentSlotB)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(checkLines, id: \.self) { line in
                    Text(line)
                        .font(.ui(size: 10))
                        .foregroundColor(line.contains("✗") ? palette.negative : line.contains("✓") ? palette.positive : palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !note.isEmpty {
                    Text("Note: \(note)")
                        .font(.ui(size: 10))
                        .foregroundColor(palette.textMain)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(result.files, id: \.self) { url in
                    HStack(spacing: 4) {
                        Image(systemName: "film")
                            .font(.system(size: StudioTheme.scaleFont(8)))
                        Text(url.lastPathComponent)
                            .font(.ui(size: 10, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundColor(palette.accentBlue)
                }
                ForEach(result.problems, id: \.self) { problem in
                    Text(problem)
                        .font(.ui(size: 10))
                        .foregroundColor(result.status == .check ? palette.accentSlotB : palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(row.issues, id: \.self) { issue in
                    Text("Sheet: \(issue)")
                        .font(.ui(size: 10))
                        .foregroundColor(palette.textSubtle)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .changed(let fields) = change {
                    ForEach(fields, id: \.self) { field in
                        Text(field)
                            .font(.ui(size: 10))
                            .foregroundColor(palette.accentBlue)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if change == .added {
                    Text("New row")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(palette.accentBlue)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? palette.accentBlue.opacity(0.12) : Color.clear)
        .overlay(alignment: .leading) {
            if change != nil { Rectangle().fill(palette.accentBlue).frame(width: 3) }
        }
    }
}

/// Chips that wrap onto more lines when the panel is narrow.
struct FlowChips: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// The popped-out Delivery Plan window (a normal window: move it to any screen, full screen, remembered frame).
struct DeliveryPlanWindow: View {
    static let id = "deliveryPlan"
    static let poppedOutKey = "deliveryPlanPoppedOut"

    @AppStorage("isLightMode") private var isLightMode = false
    @AppStorage(poppedOutKey) private var poppedOut = false

    var body: some View {
        DeliveryPlanPanel(placement: .window, isLightMode: isLightMode)
            .frame(minWidth: 380, idealWidth: 560, minHeight: 360, idealHeight: 760)
            .preferredColorScheme(isLightMode ? .light : .dark)
            .onAppear { poppedOut = true }
            .onDisappear { poppedOut = false }
    }
}

extension DeliveryPlanStore {
    enum Request { case reveal, play }
    static let revealFile = Notification.Name("QCpieDeliveryPlanRevealFile")
    static let playFile = Notification.Name("QCpieDeliveryPlanPlayFile")

    /// Rows act on the main window through notifications: the plan never holds `ContentView` state.
    @MainActor static func post(_ request: Request, _ url: URL) { post(request, [url]) }

    /// Reveal selects these files in Inspect (none: clears its selection); play loads the first.
    @MainActor static func post(_ request: Request, _ urls: [URL]) {
        if request == .reveal {
            shared.noteRevealFromPlan(urls)
            NotificationCenter.default.post(name: revealFile, object: urls)
        } else if let url = urls.first {
            NotificationCenter.default.post(name: playFile, object: url)
        }
    }
}

/// One-time set-up for editing: paste QCpie's script into the sheet, deploy it as a web app, paste its link back.
struct PlanEditSetupSheet: View {
    let isLightMode: Bool
    let onClose: () -> Void

    @ObservedObject private var store = DeliveryPlanStore.shared
    /// Updating keeps the key and link: paste the new code over the old and deploy a new version of the same deployment.
    @State private var token = DeliveryPlanStore.shared.config?.writer?.token ?? DeliveryPlanStore.shared.setupToken
    @State private var urlText = DeliveryPlanStore.shared.config?.writer?.url.absoluteString ?? ""
    @State private var copied = false
    @State private var connecting = false
    @State private var error: String? = nil

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit the Sheet from QCpie")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text("A shared link can only be read. To write cells, add QCpie's small script to the spreadsheet once. It runs as you and only accepts QCpie's secret key.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            step(1, "Copy the script.") {
                Button(copied ? "Copied" : "Copy Script") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppsScriptWriter.script(token: token), forType: .string)
                    copied = true
                }
            }
            step(2, "In the spreadsheet: Extensions → Apps Script. Replace everything there with the script, then Save.") {
                if let config = store.config {
                    Button("Open Sheet") { NSWorkspace.shared.open(config.link.webURL) }
                }
            }
            step(3, "Deploy → New deployment → Web app. Execute as: Me. Who has access: Anyone. Deploy, then allow access (if Google warns the app isn't verified: Advanced → Go to project).") { EmptyView() }
            step(4, "Copy the web app URL (ends in /exec) and paste it here.") { EmptyView() }
            if store.config?.writer != nil {
                Text("Updating: paste the new script over the old one, Save, then Deploy → Manage deployments → Edit (pencil) → Version: New version → Deploy. The link stays the same: just press Connect.")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.accentSlotB)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("https://script.google.com/macros/s/…/exec", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .font(.ui(size: 11))
            if let error {
                Text(error)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(connecting ? "Connecting…" : "Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(AppsScriptWriter.parseURL(urlText) == nil || connecting)
            }
            .font(.ui(size: 11))
        }
        .padding(20)
        .frame(width: 460)
        .background(palette.bgPanel)
    }

    private func step<Accessory: View>(_ n: Int, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.ui(size: 11, weight: .semibold))
                .foregroundColor(palette.accentBlue)
                .frame(width: 14)
            Text(text)
                .font(.ui(size: 11))
                .foregroundColor(palette.textMain)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            accessory().font(.ui(size: 11))
        }
    }

    private func connect() {
        guard let url = AppsScriptWriter.parseURL(urlText) else { return }
        connecting = true
        error = nil
        Task {
            do {
                try await store.setWriter(PlanWriteLink(url: url, token: token))
                onClose()
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

/// Inspect's right drawer holding the plan, resizable from its left edge. It owns its width so dragging re-lays out
/// the drawer and the table beside it, never re-runs `ContentView`.
struct InspectPlanDrawer: View {
    let isLightMode: Bool
    let onClose: () -> Void

    var body: some View {
        ResizableSidePanel(widthKey: "inspectPlanWidth", edge: .leading, range: 300...1100, defaultWidth: 400,
                           isLightMode: isLightMode, help: "Drag to resize the Delivery Plan. Double-click to reset (400 pt).") {
            DeliveryPlanPanel(placement: .drawer, isLightMode: isLightMode, onClose: onClose)
                .overlay(Rectangle().fill(StudioPalette(isLightMode).borderLine).frame(width: 1), alignment: .leading)
        }
    }
}

/// Inspect's per-file plan badge: the code and its state, or "Not in plan".
struct PlanPill: View {
    let info: PlanFileInfo
    let isLightMode: Bool

    var body: some View {
        let palette = StudioPalette(isLightMode)
        HStack(spacing: 4) {
            if let state = info.state {
                Circle().fill(PlanRowView.color(state, palette)).frame(width: 6, height: 6)
                if !info.code.isEmpty {
                    Text(info.code)
                        .font(.ui(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(palette.textMain)
                }
                Text(state.title)
                    .font(.ui(size: 10, weight: .medium))
                    .foregroundColor(PlanRowView.color(state, palette))
            } else {
                Text("Not in plan")
                    .font(.ui(size: 10, weight: .medium))
                    .foregroundColor(palette.textSubtle)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle))
        .help(info.state == nil ? "Not in the Delivery Plan." : "Delivery Plan row \(info.line)\(info.code.isEmpty ? "" : " · \(info.code)") · \(info.state!.title)")
    }
}

/// Progress of plan checks, with Pause / Resume and Stop. Observes only the progress object (≤ 5 updates a second).
struct PlanCheckProgressStrip: View {
    let isLightMode: Bool
    @ObservedObject private var progress = PlanCheckQueue.shared.progress
    @ObservedObject private var queue = PlanCheckQueue.shared

    var body: some View {
        let palette = StudioPalette(isLightMode)
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(palette.borderLine).frame(height: 1)
            HStack(spacing: 8) {
                Text(progress.waiting ?? progress.text)
                    .font(.ui(size: 10))
                    .foregroundColor(progress.waiting == nil ? palette.textMuted : palette.accentSlotB)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(queue.isPaused ? "Resume" : "Pause") { queue.isPaused ? queue.resume() : queue.pause() }
                    .buttonStyle(.borderless)
                Button("Stop") { queue.stop() }
                    .buttonStyle(.borderless)
            }
            .font(.ui(size: 10))
            .padding(.horizontal, 12)
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(palette.accentBlue)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        .background(palette.bgCardSubtle)
    }
}

/// A filter chip (plan and Inspect): status dot, title with count; selected = filled.
struct PlanFilterChip: View {
    let title: String
    let selected: Bool
    let color: Color
    let isLightMode: Bool
    let action: () -> Void

    var body: some View {
        let palette = StudioPalette(isLightMode)
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
                    .font(.ui(size: 10, weight: selected ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundColor(selected ? palette.textMain : palette.textMuted)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(selected ? palette.bgSubtle : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(selected ? palette.borderStrong : palette.borderLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Links the plan's and Inspect's filters (status chip + search). Accent when on.
struct LinkFiltersButton: View {
    let isLightMode: Bool
    let current: () -> DeliveryPlanStore.SharedFilter
    @ObservedObject private var store = DeliveryPlanStore.shared

    var body: some View {
        let palette = StudioPalette(isLightMode)
        Button { store.toggleLinkFilters(from: current()) } label: {
            Image(systemName: "link")
                .font(.system(size: StudioTheme.scaleFont(10), weight: store.linkFilters ? .bold : .regular))
                .foregroundColor(store.linkFilters ? palette.accentBlue : palette.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(store.linkFilters ? palette.accentBlue.opacity(0.15) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(store.linkFilters ? palette.accentBlue : palette.borderLine, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tip(store.linkFilters ? "Filters are linked: the plan and Inspect show the same status and search. Click to unlink."
                               : "Link filters: choosing a status or searching in the plan or Inspect filters the other too.")
    }
}
