import SwiftUI
import AppKit

// Small pieces shared by the plan panel and Inspect: chips, pills, filters, the bottom drawer, setup sheet.
/// A small × that dismisses a flagged file.
struct DismissButton: View {
    let isLightMode: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let palette = StudioPalette(isLightMode)
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: StudioTheme.scaleFont(8), weight: .semibold))
                .foregroundColor(hovering ? palette.textMain : palette.textSubtle)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip("Dismiss: stop flagging this file.")
    }
}

/// The drawer under the plan's Sheet view (the selected row's card, files not in the plan): drag its top edge to
/// resize it (double-click: back to 180 pt). Owns its height, so dragging redraws only the drawer, not the panel.
struct PlanBottomDrawer<Content: View>: View {
    let isLightMode: Bool
    @ViewBuilder let content: (CGFloat) -> Content
    @AppStorage("planDrawerHeight") private var height = 180.0
    @State private var startHeight: Double?
    @State private var hovering = false

    @State private var cursorPushed = false

    private static var range: ClosedRange<Double> { 80...700 }

    /// Pushed once while over or dragging the edge (leaving and coming back mid-drag mustn't stack cursors).
    private func pushCursor() { if !cursorPushed { NSCursor.resizeUpDown.push(); cursorPushed = true } }
    private func popCursor() { if cursorPushed { NSCursor.pop(); cursorPushed = false } }

    var body: some View {
        let palette = StudioPalette(isLightMode)
        VStack(spacing: 0) {
            Rectangle()
                .fill(startHeight != nil ? palette.accentBlue : hovering ? PanelResizeHandle.hoverLine(isLightMode) : palette.borderLine)
                .frame(height: startHeight != nil ? 2 : 1)
                .frame(maxWidth: .infinity)
                .overlay(
                    Color.clear
                        .frame(height: 9)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            hovering = inside
                            if inside { pushCursor() } else if startHeight == nil { popCursor() }
                        }
                        .onTapGesture(count: 2) { withAnimation(Motion.sleeve) { height = 180 } }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    let start = startHeight ?? height
                                    if startHeight == nil { startHeight = start }
                                    let next = min(Self.range.upperBound, max(Self.range.lowerBound, start - Double(value.translation.height)))
                                    if abs(next - height) > 0.5 { height = next }
                                }
                                .onEnded { _ in
                                    startHeight = nil
                                    if !hovering { popCursor() }
                                }
                        )
                        .help("Drag to resize. Double-click to reset.")
                )
                .zIndex(1)
            content(CGFloat(height))
        }
        .background(palette.bgCardSubtle)
        .animation(Motion.hover, value: hovering)
    }
}

/// Adding the QCpie tab: says what changes in the sheet before anything does.
struct PlanQCTabSetupSheet: View {
    let isLightMode: Bool
    let onClose: () -> Void

    @ObservedObject private var store = DeliveryPlanStore.shared
    @State private var error: String?
    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up the QCpie Tab")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text("QCpie keeps QC Status, QC Note, QC Updated, Batch, Frame.io and Uploaded in one tab of this spreadsheet, called QCpie, with one row per code. Every tab listing a code shows the same values, so they can't disagree.")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMain)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                bullet("Adds the QCpie tab, filled with what those columns hold today (the newest QC Updated wins when tabs disagree).")
                bullet("Turns those columns on the other tabs into lookups of the QCpie tab: they show the same values but can't be typed in (Sheets warns). Anything else typed in them is cleared.")
                bullet("From then on, set statuses in QCpie or on the QCpie tab. Clients who can see the sheet can see the QCpie tab too.")
            }
            if let error {
                Text(error).font(.ui(size: 11)).foregroundColor(palette.negative).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button(store.settingUpQCTab ? "Setting Up…" : "Set Up") {
                    error = nil
                    Task {
                        error = await store.setUpQCTab()
                        if store.hasQCTab { onClose() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.settingUpQCTab)
            }
            .font(.ui(size: 11))
        }
        .padding(20)
        .frame(width: 460)
        .background(palette.bgPanel)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundColor(palette.textMuted)
            Text(text).foregroundColor(palette.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .font(.ui(size: 11))
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
                if info.upload != .none || !info.mismatches.isEmpty {
                    // Filled: on Frame.io; outlined: not there (yet should be). Amber: a mismatch.
                    Image(systemName: info.upload != .none ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: StudioTheme.scaleFont(9)))
                        .foregroundColor(info.mismatches.isEmpty ? palette.accentBlue : TagTone.amber.color(palette.isLight))
                }
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
        .help(info.state == nil ? "Not in the Delivery Plan." : "Delivery Plan row \(info.line)\(info.code.isEmpty ? "" : " · \(info.code)") · \(info.state!.title)"
              + (info.upload != .none ? " · On Frame.io" : "")
              + info.mismatches.map { " · \($0.title)" }.joined())
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
    var count: Int? = nil
    let selected: Bool
    /// The status colour; nil for "All" (no dot).
    let color: Color?
    let isLightMode: Bool
    let action: () -> Void

    var body: some View {
        let palette = StudioPalette(isLightMode)
        Button(action: action) {
            HStack(spacing: 4) {
                if let color { Circle().fill(color).frame(width: 5, height: 5) }
                Text(title)
                    .font(.ui(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? palette.textMain : palette.textMuted)
                if let count {
                    Text("\(count)")
                        .font(.ui(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(selected ? palette.textMuted : palette.textSubtle)
                }
            }
            .planBarItem(selected: selected, palette: palette)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// The filter bar's items: no box; the selected one sits on a soft segment.
    func planBarItem(selected: Bool, palette: StudioPalette) -> some View {
        self
            .padding(.horizontal, 6)
            .frame(height: PlanBar.itemHeight)
            .background(RoundedRectangle(cornerRadius: Radius.segment).fill(selected ? palette.bgSubtle : Color.clear))
            .contentShape(Rectangle())
    }
}

/// Every item in the filter bar is this tall, so a line's chips, menus, meter and divider share one centre line.
@MainActor enum PlanBar {
    static var itemHeight: CGFloat { StudioTheme.scaleFont(20) }
}

/// "% done" as a slim bar and a figure (QC Passed, Approved, Delivered of everything not dropped).
struct PlanProgressMeter: View {
    let done: Int
    let live: Int
    let isLightMode: Bool

    var body: some View {
        let palette = StudioPalette(isLightMode)
        let fraction = live > 0 ? Double(done) / Double(live) : 0
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle)
                RoundedRectangle(cornerRadius: Radius.control).fill(palette.positive).frame(width: 36 * fraction)
            }
            .frame(width: 36, height: 3)
            Text("\(Int((fraction * 100).rounded(.down)))%")
                .font(.ui(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(palette.textMuted)
        }
        .padding(.trailing, 4)
        .frame(height: PlanBar.itemHeight)
        .tip("\(done) of \(live) done (QC Passed, Approved or Delivered; dropped rows don't count).")
    }
}

/// Between the status filters and the menus.
struct PlanBarDivider: View {
    let isLightMode: Bool

    var body: some View {
        Rectangle().fill(StudioPalette(isLightMode).borderLine).frame(width: 1, height: 12).padding(.horizontal, 4).frame(height: PlanBar.itemHeight)
    }
}

/// The plan's and Inspect's filters linked or not: a small chain at the far end of each filter bar, always there, faint
/// while off. `current`: this side's filter, copied to the other when linking.
struct PlanFilterLinkToggle: View {
    let isLightMode: Bool
    let current: () -> DeliveryPlanStore.SharedFilter
    @ObservedObject private var store = DeliveryPlanStore.shared
    @State private var hovering = false

    var body: some View {
        let palette = StudioPalette(isLightMode)
        let on = store.linkFilters
        Button { store.toggleLinkFilters(from: current()) } label: {
            Image(systemName: "link")
                .font(.system(size: StudioTheme.scaleFont(9), weight: on ? .bold : .medium))
                .foregroundColor(on ? palette.accentBlue : hovering ? palette.textMuted : palette.textSubtle.opacity(0.7))
                .frame(width: PlanBar.itemHeight, height: PlanBar.itemHeight)
                .background(RoundedRectangle(cornerRadius: Radius.segment).fill(on ? palette.accentBlue.opacity(0.12) : hovering ? palette.bgSubtle : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .tip(on ? "Filters linked with \(Self.other): status, batch, Frame.io and search follow each other. Click to unlink."
                : "Link these filters with \(Self.other): status, batch, Frame.io and search follow each other.")
    }

    private static var other: String { "the other view (Delivery Plan ⇄ Inspect)" }
}

// MARK: - Batches

/// The batch filter shared by the plan and Inspect: a chip-styled menu (All Batches, each batch with its progress,
/// No Batch).
enum PlanBatchFilter {
    /// A batch with its row counts (filter menus, Summary).
    struct Item: Equatable { let name: String; let count: Int; let done: Int; let live: Int }
}

/// Set Batch: each batch in the plan, New Batch…, Clear Batch. `rowIDs` is read when an item is chosen.
/// Doesn't observe the store: it sits in every Inspect row's context menu (no per-row singleton subscriptions); the
/// batches are read when the menu is built.
struct PlanBatchMenu: View {
    let title: String
    let rowIDs: () -> [String]
    private var store: DeliveryPlanStore { DeliveryPlanStore.shared }

    var body: some View {
        Menu(title) {
            ForEach(store.batches, id: \.self) { name in
                Button(PlanBatch.title(name)) { store.setBatch(name, rowIDs: rowIDs()) }
            }
            if !store.batches.isEmpty { Divider() }
            Button("New Batch…") {
                if let name = Self.askNewBatch(store) { store.setBatch(name, rowIDs: rowIDs()) }
            }
            Button("Clear Batch") { store.setBatch("", rowIDs: rowIDs()) }
        }
    }

    @MainActor static func nsMenu(store: DeliveryPlanStore, rowIDs: [String]) -> NSMenu {
        let menu = NSMenu()
        for name in store.batches {
            menu.addItem(PlanBatch.title(name)) { store.setBatch(name, rowIDs: rowIDs) }
        }
        if !store.batches.isEmpty { menu.addItem(.separator()) }
        menu.addItem("New Batch…") { if let name = askNewBatch(store) { store.setBatch(name, rowIDs: rowIDs) } }
        menu.addItem("Clear Batch") { store.setBatch("", rowIDs: rowIDs) }
        return menu
    }

    /// Asks for a batch number, offering the next one ("3" after "2"). Batches are whole numbers.
    @MainActor static func askNewBatch(_ store: DeliveryPlanStore) -> String? {
        let alert = NSAlert()
        alert.messageText = "New Batch"
        alert.informativeText = "Batches are numbered 1, 2, 3…"
        let field = NSTextField(string: PlanBatch.next(after: store.batches))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set Batch")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), number > 0 else {
            NSSound.beep()
            return nil
        }
        return String(number)
    }
}

/// Link Frame.io File…: asks for a Frame.io file link (the clipboard's, when it holds one) and puts it in the rows'
/// Frame.io column.
enum PlanFrameIOLinker {
    @MainActor static func ask(store: DeliveryPlanStore, rowIDs: [String]) {
        let alert = NSAlert()
        alert.messageText = rowIDs.count > 1 ? "Link \(rowIDs.count) Rows to a Frame.io File" : "Link a Frame.io File"
        alert.informativeText = "Paste the file's Frame.io link (Copy Asset URL in Frame.io or QCpie's browser). A link set here isn't replaced by one QCpie finds."
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let field = NSTextField(string: clipboard.contains("frame.io") || clipboard.contains("f.io/") ? clipboard : "")
        field.placeholderString = "https://next.frame.io/project/…/view/…"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Link")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task { @MainActor in await store.linkFrameIO(text, rowIDs: rowIDs) }
    }
}

/// Frame.io presence counts for the Filters menu (`PlanFiltersMenu`) and the Summary.
enum PlanUploadFilter {
    /// The three Frame.io counts in one pass.
    nonisolated static func counts(_ uploads: some Sequence<PlanUpload>) -> (none: Int, on: Int, stale: Int) {
        var none = 0, on = 0, stale = 0
        for upload in uploads {
            switch upload {
            case .none: none += 1
            case .uploaded: on += 1
            case .stale: on += 1; stale += 1
            }
        }
        return (none, on, stale)
    }
}
