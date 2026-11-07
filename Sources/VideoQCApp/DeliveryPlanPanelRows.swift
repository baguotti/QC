import SwiftUI
import AppKit

/// The Delivery Plan panel's Sheet and List views, their menus and the not-in-the-plan lists.
extension DeliveryPlanPanel {
    // MARK: Sheet

    /// The tab the Sheet view shows: the chosen one if still read, else the first read tab.
    private func shownTab() -> PlanTab? {
        guard let config = store.config else { return nil }
        let included = config.included
        return included.first { $0.gid == sheetTab } ?? included.first
    }

    @ViewBuilder
    func sheetArea(rows: [PlanRow], match: PlanMatch) -> some View {
        if let tab = shownTab(), let grid = store.grids[tab.gid] {
            let tabRows = rows.filter { $0.tab == tab.name }
            let byLine = Dictionary(tabRows.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
            let marks = byLine.mapValues { PlanSheetMark(status: store.state($0).state, changed: store.changes[$0.id] != nil,
                                                         checks: checkSummary($0).result, upload: store.state($0).upload,
                                                         mismatch: !store.state($0).mismatches.isEmpty) }
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
                    onEditUnavailable: { signInWithGoogle() },
                    statusColumn: store.statusColumn(gid: tab.gid),
                    statusMenu: { line in byLine[line].map { statusNSMenu(statusTargets($0, match: match)) } },
                    listColumns: store.listColumns(gid: tab.gid),
                    headerLine: store.headerLine(gid: tab.gid))
                if (store.config?.included.count ?? 0) > 1 { sheetTabs }
                if let selected, (uploadFilter ?? 0) < PlanMismatch.frameioExtra.rawValue {
                    PlanBottomDrawer(isLightMode: isLightMode) { maxHeight in
                        VStack(spacing: 0) {
                            statusBar(selected, targets: statusTargets(selected, match: match))
                            ScrollView {
                                PlanRowView(row: selected, result: match.result(selected), state: store.state(selected),
                                            note: store.note(selected), checkLines: checkSummary(selected).lines,
                                            change: store.changes[selected.id], frameio: store.frameioLink(selected),
                                            selected: false, wide: true, isLightMode: isLightMode,
                                            themeRevision: ThemeManager.shared.revision)
                            }
                            .frame(maxHeight: maxHeight)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    sheetExtrasFooter(match)
                }
            }
        } else {
            emptyRows
        }
    }

    /// Lines passing the chips and the filter field; nil when nothing filters (every row shows, as in the sheet).
    func shownLines(_ rows: [PlanRow], match: PlanMatch) -> Set<Int>? {
        let terms = PlanMatcher.tokens(search)
        guard statusFilter != nil || changedOnly || !terms.isEmpty || batchFilter != nil || uploadFilter != nil || channelFilter != nil else { return nil }
        var lines = Set<Int>()
        for row in rows {
            if let statusFilter, store.state(row).state != statusFilter { continue }
            if let batchFilter, store.batch(row) != batchFilter { continue }
            if let uploadFilter, !store.state(row).passes(uploadFilter) { continue }
            if let channelFilter, PlanGrid.normalized(row.value(.channel)) != channelFilter { continue }
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
        let batch = NSMenuItem(title: targets.count > 1 ? "Set Batch (\(targets.count) Rows)" : "Set Batch", action: nil, keyEquivalent: "")
        batch.submenu = PlanBatchMenu.nsMenu(store: store, rowIDs: targets)
        menu.addItem(batch)
        menu.addItem(.separator())
        let link = store.frameioLink(row)
        if let url = URL(string: link), !link.isEmpty {
            menu.addItem("Open in Frame.io") { NSWorkspace.shared.open(url) }
            menu.addItem("Copy Frame.io Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
        }
        menu.addItem(link.isEmpty ? "Link Frame.io File…" : "Change Frame.io Link…") { [store] in PlanFrameIOLinker.ask(store: store, rowIDs: targets) }
        if !link.isEmpty { menu.addItem("Clear Frame.io Link") { [store] in store.clearFrameIO(rowIDs: targets) } }
        if !store.state(row).mismatches.isEmpty {
            menu.addItem(targets.count > 1 ? "Dismiss Mismatches (\(targets.count) Rows)" : "Dismiss Mismatch") { [store] in store.dismissMismatches(rowIDs: targets) }
        }
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

    enum Item: Identifiable {
        case heading(String, Int)
        case row(PlanRow)
        case extras([URL])
        case frameioExtras([PlanFrameIOExtra])
        var id: String {
            switch self {
            case .heading(let title, let index): return "h\(index)|\(title)"
            case .row(let row): return row.id
            case .extras: return "extras"
            case .frameioExtras: return "frameioExtras"
            }
        }
    }

    func filtered(_ rows: [PlanRow], match: PlanMatch) -> [Item] {
        let terms = PlanMatcher.tokens(search)
        var items: [Item] = []
        var lastHeading: String? = nil
        for row in rows {
            if let statusFilter, store.state(row).state != statusFilter { continue }
            if let batchFilter, store.batch(row) != batchFilter { continue }
            if let uploadFilter, !store.state(row).passes(uploadFilter) { continue }
            if let channelFilter, PlanGrid.normalized(row.value(.channel)) != channelFilter { continue }
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
        let unfiltered = statusFilter == nil && batchFilter == nil && uploadFilter == nil && channelFilter == nil && !changedOnly && terms.isEmpty
        if unfiltered || uploadFilter == PlanMismatch.localExtra.rawValue, !store.localExtras.isEmpty { items.append(.extras(store.localExtras)) }
        if unfiltered || uploadFilter == PlanMismatch.frameioExtra.rawValue, !store.frameioExtras.isEmpty {
            items.append(.frameioExtras(store.frameioExtras))
        }
        return items
    }

    func list(_ items: [Item], match: PlanMatch) -> some View {
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
                                    frameio: store.frameioLink(row),
                                    selected: selectedRow == row.id || highlighted.contains(row.id), wide: placement == .window,
                                    isLightMode: isLightMode, themeRevision: ThemeManager.shared.revision)
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { select(row, match: match, play: true) }
                            .onTapGesture { select(row, match: match, play: false) }
                            .contextMenu { rowMenu(row, files: match.result(row).files) }
                    case .extras(let urls):
                        extrasView(urls)
                    case .frameioExtras(let files):
                        frameioExtrasView(files)
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
        PlanBatchMenu(title: targets.count > 1 ? "Set Batch (\(targets.count) Rows)" : "Set Batch", rowIDs: { targets })
        Divider()
        let link = store.frameioLink(row)
        if let url = URL(string: link), !link.isEmpty {
            Button("Open in Frame.io") { NSWorkspace.shared.open(url) }
            Button("Copy Frame.io Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
        }
        Button(link.isEmpty ? "Link Frame.io File…" : "Change Frame.io Link…") { PlanFrameIOLinker.ask(store: store, rowIDs: targets) }
        if !link.isEmpty { Button("Clear Frame.io Link") { store.clearFrameIO(rowIDs: targets) } }
        if !store.state(row).mismatches.isEmpty {
            Button(targets.count > 1 ? "Dismiss Mismatches (\(targets.count) Rows)" : "Dismiss Mismatch") { store.dismissMismatches(rowIDs: targets) }
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
            extrasHeader("NOT IN THE PLAN (\(urls.count))") { store.dismissLocalExtras(urls) }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topTrailing) { DismissButton(isLightMode: isLightMode) { store.dismissLocalExtras([url]) } }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { DeliveryPlanStore.post(.play, url) }   // before the single tap, or it never fires
                    .onTapGesture { DeliveryPlanStore.post(.reveal, url) }
                    .contextMenu { Button("Dismiss") { store.dismissLocalExtras([url]) } }
            }
        }
        .padding(.horizontal, 12)
    }

    /// Files in the plan's Frame.io folders that no row links to. Double-click opens one in Frame.io.
    private func frameioExtrasView(_ files: [PlanFrameIOExtra]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            extrasHeader("ON FRAME.IO, NOT IN THE PLAN (\(files.count))") { store.dismissFrameIOExtras(files.map(\.url)) }
            Text("Files in the plan's Frame.io folders that no row links to (as of the last time QCpie listed them).")
                .font(.ui(size: 10))
                .foregroundColor(palette.textSubtle)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(files) { file in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.ui(size: 11))
                            .foregroundColor(palette.textMain)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.note)
                            .font(.ui(size: 10))
                            .foregroundColor(palette.textSubtle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if let url = URL(string: file.url) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: StudioTheme.scaleFont(10)))
                                .foregroundColor(palette.textMuted)
                        }
                        .buttonStyle(.plain)
                        .tip("Open in Frame.io")
                    }
                    DismissButton(isLightMode: isLightMode) { store.dismissFrameIOExtras([file.url]) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let url = URL(string: file.url) { NSWorkspace.shared.open(url) } }
                .contextMenu {
                    if let url = URL(string: file.url) { Button("Open in Frame.io") { NSWorkspace.shared.open(url) } }
                    Button("Copy Frame.io Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.url, forType: .string)
                    }
                    Button("Copy File Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(file.name, forType: .string)
                    }
                    Divider()
                    Button("Dismiss") { store.dismissFrameIOExtras([file.url]) }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    /// A "not in the plan" list's title, with Dismiss All.
    private func extrasHeader(_ title: String, dismissAll: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.textMuted)
            Spacer(minLength: 4)
            Button("Dismiss All", action: dismissAll)
                .buttonStyle(.borderless)
                .font(.ui(size: 10))
                .foregroundColor(palette.textMuted)
                .tip("Stop flagging these files. The mismatch menu's Show Dismissed brings them back.")
        }
        .padding(.top, 12)
    }

    /// Under the Sheet view: the files a "not in the plan" filter shows (they have no sheet line), else a quiet line
    /// counting them.
    @ViewBuilder
    private func sheetExtrasFooter(_ match: PlanMatch) -> some View {
        let frameio = store.frameioExtras
        if uploadFilter == PlanMismatch.localExtra.rawValue || uploadFilter == PlanMismatch.frameioExtra.rawValue {
            PlanBottomDrawer(isLightMode: isLightMode) { maxHeight in
                ScrollView {
                    if uploadFilter == PlanMismatch.localExtra.rawValue { extrasView(store.localExtras) } else { frameioExtrasView(frameio) }
                }
                .padding(.bottom, 8)
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else if !store.localExtras.isEmpty || !frameio.isEmpty {
            Rectangle().fill(palette.borderLine).frame(height: 1)
            HStack(spacing: 10) {
                Text("Not in the plan:").foregroundColor(palette.textSubtle)
                if !store.localExtras.isEmpty { extrasLink("\(store.localExtras.count) here", .localExtra) }
                if !frameio.isEmpty { extrasLink("\(frameio.count) on Frame.io", .frameioExtra) }
                Spacer(minLength: 0)
            }
            .font(.ui(size: 11))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(palette.bgCardSubtle)
        }
    }

    private func extrasLink(_ title: String, _ kind: PlanMismatch) -> some View {
        Button(title) { uploadFilter = kind.rawValue; selectedRow = nil }
            .buttonStyle(.borderless)
            .foregroundColor(palette.accentBlue)
            .tip(kind.explanation)
    }

    var changesFooter: some View {
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

    func color(_ status: PlanState) -> Color { PlanRowView.color(status, palette) }
}
