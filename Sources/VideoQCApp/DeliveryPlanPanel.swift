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
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    @AppStorage(DeliveryPlanWindow.poppedOutKey) private var poppedOut = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var linkText = ""
    @State private var search = ""
    @State private var statusFilter: PlanStatus? = nil
    @State private var changedOnly = false
    @State private var showRemoved = false
    @State private var selectedRow: String? = nil
    @State private var relinking = false

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
                    .onAppear { store.panelAppeared() }
                    .onDisappear { store.panelDisappeared() }
            }
        }
        .background(palette.bgPanel)
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
                Button("Dock in Inspect") { dismissWindow(id: DeliveryPlanWindow.id) }
                    .font(.ui(size: 11, weight: .medium))
                    .buttonStyle(.borderless)
                    .explain("Close this window and show the Delivery Plan in the Inspect tab's drawer again.")
            }
        }
        .headerBand(palette, horizontalPadding: 12)
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
                Button("Dock Here") { dismissWindow(id: DeliveryPlanWindow.id) }
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
        let counts = Dictionary(grouping: rows, by: { match.result($0).status }).mapValues(\.count)
        let shown = filtered(rows, match: match)
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
            } else {
                list(shown, match: match)
            }
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
        if !store.unreadTabs.isEmpty {
            Text("No header row found in: \(store.unreadTabs.joined(separator: ", "))")
                .font(.ui(size: 10)).foregroundColor(palette.textSubtle).lineLimit(2)
        }
    }

    private func chips(counts: [PlanStatus: Int], total: Int) -> some View {
        let changed = store.changes.count
        return FlowChips(spacing: 4) {
            chip("All \(total)", selected: statusFilter == nil && !changedOnly, color: palette.textMuted) {
                statusFilter = nil; changedOnly = false
            }
            ForEach(PlanStatus.allCases, id: \.self) { status in
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
        }
    }

    private func chip(_ title: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
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
            if let statusFilter, match.result(row).status != statusFilter { continue }
            if changedOnly, store.changes[row.id] == nil { continue }
            if !terms.isEmpty {
                let haystack = (row.values.values.joined(separator: " ") + " " + match.result(row).files.map(\.lastPathComponent).joined(separator: " ")).lowercased()
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
                        PlanRowView(row: row, result: match.result(row), change: store.changes[row.id],
                                    selected: selectedRow == row.id, wide: placement == .window,
                                    isLightMode: isLightMode, themeRevision: ThemeManager.shared.revision)
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { if let url = match.result(row).files.first { DeliveryPlanStore.post(.play, url) } }
                            .onTapGesture {
                                selectedRow = row.id
                                if let url = match.result(row).files.first { DeliveryPlanStore.post(.reveal, url) }
                            }
                            .contextMenu { rowMenu(row, files: match.result(row).files) }
                    case .extras(let urls):
                        extrasView(urls)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: PlanRow, files: [URL]) -> some View {
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
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMain)
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

    private func color(_ status: PlanStatus) -> Color { PlanRowView.color(status, palette) }
}

/// One deliverable: status dot, name, the specs the sheet asks for, the matched file and anything wrong.
struct PlanRowView: View, Equatable {
    let row: PlanRow
    let result: PlanRowResult
    let change: DeliveryPlanStore.Change?
    let selected: Bool
    let wide: Bool
    let isLightMode: Bool
    let themeRevision: Int

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    static func color(_ status: PlanStatus, _ palette: StudioPalette) -> Color {
        switch status {
        case .missing: return palette.textSubtle
        case .delivered: return palette.positive
        case .wrongSpec: return palette.negative
        case .check: return palette.accentSlotB
        }
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
                .fill(Self.color(result.status, palette))
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
    static func post(_ request: Request, _ url: URL) {
        NotificationCenter.default.post(name: request == .reveal ? revealFile : playFile, object: url)
    }
}
