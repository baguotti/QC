import SwiftUI
import AppKit

/// The Delivery Plan: in the Inspect tab's right drawer, or popped out into its own window (`DeliveryPlanWindow`),
/// which can go on a second screen. Only one shows the plan at a time; the drawer shows a placeholder while popped out.
struct DeliveryPlanPanel: View {
    enum Placement { case drawer, window }

    let placement: Placement
    let isLightMode: Bool
    var onClose: (() -> Void)? = nil

    @ObservedObject var store = DeliveryPlanStore.shared
    @ObservedObject private var account = GoogleAccount.shared
    /// Published once per checked file (progress has its own object, observed by the strip only).
    @ObservedObject var checks = PlanCheckQueue.shared
    @ObservedObject private var themeManager = ThemeManager.shared   // accent changes redraw
    @AppStorage(DeliveryPlanWindow.poppedOutKey) private var poppedOut = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State var search = ""
    @State var statusFilter: PlanState? = nil
    /// nil: every batch; "": rows without one; else a batch name.
    @State var batchFilter: String? = nil
    /// nil: all; else a `PlanUpload.passes` value (0 not on Frame.io, 1 on, 2 changed since upload).
    @State var uploadFilter: Int? = nil
    /// A channel picked in the Summary (nil: all). Shown as a removable chip in the filter bar.
    @State var channelFilter: String? = nil
    @State var noteDraft = ""
    /// The row the note being typed belongs to (the field shows another row's note once the selection moves).
    @State var noteRowID: String? = nil
    @FocusState var noteFocused: Bool
    @State var changedOnly = false
    @State var showRemoved = false
    @State var selectedRow: String? = nil
    @State private var relinking = false
    /// "sheet" (the tab as Google Sheets draws it) or "list" (one card per deliverable).
    /// "summary": where the delivery stands (`PlanSummaryView`).
    @AppStorage("deliveryPlanView") var viewMode = "sheet"
    /// The Sheet or List view the Summary's clicks open.
    @AppStorage("deliveryPlanDataView") var dataView = "sheet"
    @State private var planSummary = PlanSummaryCache()
    @AppStorage("deliveryPlanZoom") var zoom = 1.0
    /// The tab the Sheet view shows when more than one is read.
    @State var sheetTab: String? = nil
    @State private var showEditSetup = false
    @State private var showFrameIORoot = false
    @State private var showSetupGuide = false
    @State private var signInError: String?
    @State var summaryCache = PlanChecksSummaryCache()

    var palette: StudioPalette { StudioPalette(isLightMode) }

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
        // Another sheet: a batch or channel picked in the old one would hide every row with no visible reason.
        .onChange(of: store.config?.link.sheetID) { _, _ in channelFilter = nil; batchFilter = nil; selectedRow = nil }
        .onReceive(store.$sharedFilter) { filter in
            guard store.linkFilters, filter != currentFilter else { return }
            statusFilter = filter.state >= 0 ? PlanState(rawValue: filter.state) : nil
            if filter.state != currentFilter.state { changedOnly = false }   // a search alone keeps "Changed"
            search = filter.search
            batchFilter = filter.batch
            uploadFilter = filter.upload
        }
        .background {
            // The plan window gets every key itself (the router passes them through): ⌥1–⌥6 / ⌥0 here.
            if placement == .window {
                // ⌘Z: the plan's last edit; in a text field, the field's own undo.
                Button("") {
                    if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                    else { store.undoLastEdit() }
                }
                    .keyboardShortcut("z", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .disabled(store.undoTitle == nil)
                ForEach(0...PlanQCStatus.allCases.count, id: \.self) { n in
                    Button("") { _ = store.setStatusForSelection(n == 0 ? nil : PlanQCStatus.allCases[n - 1]) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .option)
                        .opacity(0)
                        .allowsHitTesting(false)
                }
            }
        }
        .sheet(isPresented: $showSetupGuide) {
            PlanSetupGuide(isLightMode: isLightMode) { showSetupGuide = false }
        }
        .sheet(isPresented: $showFrameIORoot) {
            PlanFrameIORootSheet(isLightMode: isLightMode) { showFrameIORoot = false }
        }
        .sheet(isPresented: $showEditSetup) {
            PlanQCTabSetupSheet(isLightMode: isLightMode) { showEditSetup = false }
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

    /// Before a sheet is linked (or while relinking): the setup steps, inline.
    private var linkView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PlanSetupGuide(isLightMode: isLightMode, relinking: relinking) {
                    // Relinking the same sheet doesn't change its id: leave the guide here, not only on a new link.
                    relinking = false
                    if !store.hasQCTab || store.config?.frameioRoot == nil { showSetupGuide = true }
                }
                if relinking {
                    Button("Cancel") { relinking = false }.font(.ui(size: 11)).padding(.horizontal, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Linked from here: the remaining steps (QCpie tab, Frame.io folder) open as a sheet over the plan.
        .onChange(of: store.config?.link.sheetID) { _, id in
            guard id != nil else { return }
            relinking = false
            if !store.hasQCTab || store.config?.frameioRoot == nil { showSetupGuide = true }
        }
    }

    func signInWithGoogle() {
        signInError = nil
        Task {
            do { try await account.signIn() } catch { signInError = DeliveryPlanStore.describe(error) }
        }
    }

    // MARK: Plan

    private var planView: some View {
        let rows = store.rows
        let match = store.match
        return VStack(spacing: 0) {
            toolbar
            if viewMode != "summary" {
                // Counted only where the chips show (the Summary has its own cached figures).
                let counts = Dictionary(grouping: rows, by: { store.state($0).state }).mapValues(\.count)
                VStack(alignment: .leading, spacing: 8) {
                    chips(counts: counts, total: rows.count)
                    searchBar
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            Rectangle().fill(palette.borderLine).frame(height: 1)
            if rows.isEmpty {
                emptyRows
            } else if viewMode == "summary" {
                PlanSummaryView(summary: planSummary.summary(store), showsFrameIO: store.hasFrameIOColumn,
                                mismatches: store.planCounts.mismatches, isLightMode: isLightMode, open: openFromSummary)
                    .equatable()
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
                HStack(spacing: 6) {
                    Text(store.config?.title ?? "")
                        .font(.ui(size: 12, weight: .semibold))
                        .foregroundColor(palette.textMain)
                        .lineLimit(1)
                    PlanHealthBadge(isLightMode: isLightMode, signIn: signInWithGoogle, setUpQCTab: { showEditSetup = true },
                                    chooseFrameIOFolder: { showFrameIORoot = true })
                }
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
                if account.signedIn {
                    if !store.hasQCTab { Button("Set Up QCpie Tab…") { showEditSetup = true } }
                } else {
                    Button("Sign In with Google…") { signInWithGoogle() }
                }
                Button("Set Up Plan…") { showSetupGuide = true }
                Button(store.config?.frameioRoot == nil ? "Set Frame.io Folder…" : "Frame.io Folder…") { showFrameIORoot = true }
                if store.hasQCTab {
                    Button(store.config?.frameioRoot == nil ? "Find Frame.io Links" : "Read Frame.io Folder Now") { Task { await store.findFrameIOLinks() } }
                        .disabled(store.linkSearch != nil && store.linkSearch!.hasSuffix("…"))
                }
                Button("Link Another Sheet…") { relinking = true }
                Divider()
                if account.signedIn {
                    Button("Sign Out of Google (\(account.email ?? "signed in"))") { Task { await account.signOut() } }
                }
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
                Image(systemName: "chart.bar.xaxis").tag("summary")
                Image(systemName: "tablecells").tag("sheet")
                Image(systemName: "list.bullet").tag("list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: viewMode) { _, mode in if mode != "summary" { dataView = mode } }
            .tip("Show where the delivery stands, the plan as the sheet looks in Google Sheets, or a list of deliverables.")
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
        if let signInError {
            Text(signInError).font(.ui(size: 10)).foregroundColor(palette.negative).lineLimit(2)
        }
        if !account.signedIn {
            Button("Sign in with Google to read and edit the sheet…") { signInWithGoogle() }
                .buttonStyle(.borderless)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.accentSlotB)
        } else if !store.hasQCTab {
            Button("Set up the QCpie tab to save statuses and links…") { showEditSetup = true }
                .buttonStyle(.borderless)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.accentSlotB)
        }
        switch store.editState {
        case .idle: EmptyView()
        case .saving(let n):
            Text(n == 1 ? "Saving to the sheet…" : "Saving \(n) edits to the sheet…").font(.ui(size: 10)).foregroundColor(palette.textSubtle)
        case .saved:
            HStack(spacing: 6) {
                Text("Saved to the sheet").font(.ui(size: 10)).foregroundColor(palette.positive)
                if let undo = store.undoTitle {
                    Button("Undo \(undo)") { store.undoLastEdit() }
                        .buttonStyle(.borderless)
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(palette.accentBlue)
                        .tip("Put back what the last edit changed (⌘Z).")
                }
            }
        case .failed(let message):
            Text(message).font(.ui(size: 10)).foregroundColor(palette.negative).lineLimit(3)
        }
        if let search = store.linkSearch {
            Text(search).font(.ui(size: 10)).foregroundColor(palette.textSubtle).lineLimit(2)
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
        return HStack(alignment: .top, spacing: 4) {
        FlowChips(spacing: 2) {
            if live > 0 { PlanProgressMeter(done: done, live: live, isLightMode: isLightMode) }
            chip("All", count: total, selected: statusFilter == nil && !changedOnly, color: nil) {
                statusFilter = nil; changedOnly = false
            }
            ForEach(PlanState.allCases, id: \.self) { status in
                let n = counts[status] ?? 0
                if n > 0 || status == .missing {
                    chip(status.title, count: n, selected: statusFilter == status, color: color(status)) {
                        statusFilter = statusFilter == status ? nil : status
                        changedOnly = false
                    }
                }
            }
            if changed > 0 {
                chip("Changed", count: changed, selected: changedOnly, color: palette.accentBlue) {
                    changedOnly.toggle(); statusFilter = nil
                }
            }
            PlanBarDivider(isLightMode: isLightMode)
            // Also while their filter is on (set from Inspect through the link): a hidden active filter hides rows silently.
            PlanFiltersMenu(batches: store.planCounts.batches, unbatched: store.planCounts.unbatched, batch: $batchFilter,
                            uploads: store.hasFrameIOColumn ? (store.planCounts.uploads.none, store.planCounts.uploads.on) : nil,
                            mismatches: store.planCounts.mismatches, mismatchTotal: store.planCounts.mismatchTotal,
                            kinds: PlanMismatch.allCases, upload: $uploadFilter, dismissed: store.planCounts.dismissed,
                            isLightMode: isLightMode)
            if let batch = batchFilter {
                PlanActiveFilterChip(title: batch.isEmpty ? "No Batch" : PlanBatch.title(batch), isLightMode: isLightMode) { batchFilter = nil }
            }
            if let upload = uploadFilter {
                PlanActiveFilterChip(title: PlanMismatch.filterTitle(upload), alert: upload > 1, isLightMode: isLightMode) { uploadFilter = nil }
            }
            if let channel = channelFilter {
                PlanActiveFilterChip(title: channel, isLightMode: isLightMode) { channelFilter = nil }
            }
        }
            // Always in the tree: Accept All empties the list, and removing the button would yank its open sheet.
            PlanSuggestionsButton(count: store.linkSuggestions.count, isLightMode: isLightMode)
        // No Spacer: FlowChips takes the width it's offered, and a Spacer would split it in half.
        PlanFilterLinkToggle(isLightMode: isLightMode) { currentFilter }
        }
    }

    /// Batches with their row counts and % done (QC Passed, Approved, Delivered of rows not dropped).

    private func chip(_ title: String, count: Int, selected: Bool, color: Color?, action: @escaping () -> Void) -> some View {
        PlanFilterChip(title: title, count: count, selected: selected, color: color, isLightMode: isLightMode, action: action)
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

    var emptyRows: some View {
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
