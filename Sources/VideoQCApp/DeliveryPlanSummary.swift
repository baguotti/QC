import SwiftUI

// The Delivery Plan's Summary view: where the delivery stands at a glance (progress, states, batches, channels,
// Frame.io, recent reviews). Built from what the store already has: no reads of its own. Every figure is a way in:
// clicking it shows those rows in the Sheet or List view, filtered.

/// The figures, built once per change of the plan's states (`PlanSummaryCache`), never per redraw.
struct PlanSummary: Equatable, Sendable {
    struct Group: Equatable, Identifiable, Sendable {
        let name: String
        var total = 0
        var done = 0
        var dropped = 0
        var states: [PlanState: Int] = [:]
        var id: String { name }
        var live: Int { total - dropped }
    }

    struct Activity: Equatable, Identifiable, Sendable {
        let rowID: String
        let code: String
        let name: String
        let status: String
        let state: PlanState
        let who: String
        let date: Date
        var id: String { rowID }
    }

    var total = 0
    var done = 0
    var dropped = 0
    var states: [PlanState: Int] = [:]
    var batches: [Group] = []
    var channels: [Group] = []
    /// Every row, as the Frame.io filter counts them (dropped ones too).
    var uploads = (none: 0, on: 0)
    var recent: [Activity] = []
    /// Statuses set in the last 24 hours.
    var reviewedToday = 0

    var live: Int { total - dropped }
    var fraction: Double { live > 0 ? Double(done) / Double(live) : 0 }

    static func == (a: PlanSummary, b: PlanSummary) -> Bool {
        a.total == b.total && a.done == b.done && a.dropped == b.dropped && a.states == b.states && a.batches == b.batches
            && a.channels == b.channels && a.uploads == b.uploads && a.recent == b.recent && a.reviewedToday == b.reviewedToday
    }

    /// The order states are drawn in bars: done first, then work in hand, then what hasn't arrived.
    static let barOrder: [PlanState] = [.delivered, .approved, .passed, .needsFix, .check, .toQC, .missing, .onHold]

    /// `batches`: the plan's batch names in order ("" = none). ~1 ms for 1,100 rows.
    static func build(rows: [PlanRow], batchNames: [String], state: (PlanRow) -> PlanRowState, batch: (PlanRow) -> String,
                      status: (PlanRow) -> String, updated: (PlanRow) -> String, now: Date = Date()) -> PlanSummary {
        var summary = PlanSummary()
        var batches: [String: Group] = [:]
        var channels: [String: Group] = [:]
        // Reviews by stamp: "yyyy-MM-dd HH:mm:ss UTC" sorts by time as text, so only the newest few are parsed
        // (a DateFormatter parse per row would cost ~10 ms on every status change).
        var stamped: [(key: String, row: PlanRow, state: PlanState, qc: String, stamp: String)] = []
        let dayAgo = String(PlanStatusResolver.stamp(now.addingTimeInterval(-86_400), by: "").prefix(19))
        func add(_ group: inout Group, _ s: PlanState) {
            group.total += 1
            group.states[s, default: 0] += 1
            if s.isDone { group.done += 1 }
            if s == .dropped { group.dropped += 1 }
        }
        for row in rows {
            let rowState = state(row)
            let s = rowState.state
            summary.total += 1
            summary.states[s, default: 0] += 1
            if s.isDone { summary.done += 1 }
            if s == .dropped { summary.dropped += 1 }
            let b = batch(row)
            add(&batches[b, default: Group(name: b)], s)
            let channel = PlanGrid.normalized(row.value(.channel))
            if !channel.isEmpty { add(&channels[channel, default: Group(name: channel)], s) }
            if rowState.upload == .none { summary.uploads.none += 1 } else { summary.uploads.on += 1 }
            let stamp = updated(row)
            guard stamp.count >= 19 else { continue }
            let qc = status(row)
            guard PlanQCStatus.parse(qc) != nil else { continue }
            // Stamps from before version 3 are local time without "UTC": those few are parsed into UTC text.
            let key: String
            if stamp.dropFirst(19).hasPrefix(" UTC") { key = String(stamp.prefix(19)) } else {
                guard let date = PlanStatusResolver.date(fromStamp: stamp) else { continue }
                key = String(PlanStatusResolver.stamp(date, by: "").prefix(19))
            }
            stamped.append((key, row, s, qc, stamp))
        }
        // The same code on two tabs is one review.
        var seenCodes = Set<String>()
        for item in stamped.sorted(by: { $0.key > $1.key }) {
            if item.key < dayAgo, summary.recent.count >= 8 { break }
            let code = (item.row.code ?? item.row.id).lowercased()
            guard seenCodes.insert(code).inserted else { continue }
            if item.key >= dayAgo { summary.reviewedToday += 1 }
            if summary.recent.count < 8, let date = PlanStatusResolver.date(fromStamp: item.stamp) {
                let who = item.stamp.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
                summary.recent.append(Activity(rowID: item.row.id, code: item.row.code ?? "", name: item.row.name,
                                               status: item.qc, state: item.state, who: who, date: date))
            }
        }
        // Batches in the plan's order, "No Batch" last; only when some row has one.
        if batches.keys.contains(where: { !$0.isEmpty }) {
            summary.batches = batchNames.compactMap { batches[$0] } + (batches[""].map { [$0] } ?? [])
        }
        // Channels by size; one channel isn't a breakdown.
        if channels.count > 1 {
            summary.channels = channels.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        }
        return summary
    }
}

/// Rebuilt only when the store's states change (each recompute bumps `statesRevision`), and once an hour so
/// "Today" doesn't keep yesterday's reviews.
@MainActor
final class PlanSummaryCache {
    private var key = (-1, -1)
    private var summary = PlanSummary()

    func summary(_ store: DeliveryPlanStore) -> PlanSummary {
        let current = (store.statesRevision, Int(Date().timeIntervalSince1970 / 3600))
        guard current != key else { return summary }
        key = current
        summary = PlanSummary.build(rows: store.rows, batchNames: store.batches, state: store.state, batch: store.batch,
                                    status: store.qcStatusText, updated: store.qcUpdated)
        return summary
    }
}

/// What a click in the Summary shows.
enum PlanSummaryTarget: Equatable {
    case state(PlanState)
    case batch(String)
    case channel(String)
    case upload(Int)
    case row(String)
}

/// Equatable on its figures: the plan panel redraws on every Inspect selection, and this view then doesn't.
/// (`open` only sets the panel's filters, so it needn't be compared.)
struct PlanSummaryView: View, Equatable {
    nonisolated static func == (a: PlanSummaryView, b: PlanSummaryView) -> Bool {
        a.summary == b.summary && a.showsFrameIO == b.showsFrameIO && a.mismatches == b.mismatches && a.isLightMode == b.isLightMode
    }

    let summary: PlanSummary
    let showsFrameIO: Bool
    /// Rows or files per mismatch (`PlanCounts.mismatches`).
    let mismatches: [PlanMismatch: Int]
    let isLightMode: Bool
    let open: (PlanSummaryTarget) -> Void

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    /// Every row's label is this wide, so bars line up across sections.
    private var labelWidth: CGFloat { StudioTheme.scaleFont(120) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                LazyVGrid(columns: [GridItem(.adaptive(minimum: StudioTheme.scaleFont(360)), spacing: 28, alignment: .top)], alignment: .leading, spacing: 20) {
                    statusSection
                    if !summary.batches.isEmpty { groupSection("Batches", summary.batches) { .batch($0) } }
                    if !summary.channels.isEmpty { groupSection("Channels", summary.channels) { .channel($0) } }
                    if showsFrameIO { frameIOSection }
                    if !summary.recent.isEmpty { recentSection }
                }
            }
            .padding(16)
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int((summary.fraction * 100).rounded(.down)))%")
                    .font(.ui(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(palette.textMain)
                Text("done")
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundColor(palette.textMuted)
                Spacer(minLength: 8)
                Text("\(summary.done) of \(summary.live) deliverables" + (summary.dropped > 0 ? " · \(summary.dropped) dropped" : ""))
                    .font(.ui(size: 11))
                    .monospacedDigit()
                    .foregroundColor(palette.textMuted)
                    .lineLimit(1)
            }
            PlanStateBar(states: summary.states, height: 8, isLightMode: isLightMode, open: { open(.state($0)) })
            HStack(spacing: 0) {
                figure("To Arrive", summary.states[.missing] ?? 0, .missing)
                figure("In QC", [.toQC, .check].reduce(0) { $0 + (summary.states[$1] ?? 0) }, nil,
                       help: "To QC and Check rows. Click one of them under Status to see it.")
                figure("Needs Fix", summary.states[.needsFix] ?? 0, .needsFix)
                figure("Done", summary.done, nil, help: "QC Passed, Approved and Delivered rows. Click one of them under Status to see it.")
                if summary.reviewedToday > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today").font(.ui(size: 10, weight: .semibold)).foregroundColor(palette.textMuted).lineLimit(1)
                        Text("\(summary.reviewedToday)").font(.ui(size: 15, weight: .semibold)).monospacedDigit().foregroundColor(palette.textMain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tip("Statuses set in the last 24 hours.")
                }
            }
        }
    }

    /// A headline figure. One state's figure opens its rows; a figure of several states only explains itself (the
    /// filter takes one state).
    @ViewBuilder
    private func figure(_ title: String, _ value: Int, _ state: PlanState?, help: String = "") -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(size: 10, weight: .semibold)).foregroundColor(palette.textMuted).lineLimit(1)
            Text("\(value)").font(.ui(size: 15, weight: .semibold)).monospacedDigit().foregroundColor(palette.textMain)
        }
        if let state {
            SummaryButton(isLightMode: isLightMode, action: { open(.state(state)) }) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tip("Show the \(title.lowercased()) rows.")
        } else {
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tip(help)
        }
    }

    // MARK: Sections

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.ui(size: 12, weight: .semibold)).foregroundColor(palette.textMuted)
    }

    private var statusSection: some View {
        let largest = summary.states.values.max() ?? 1
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Status")
            ForEach(PlanState.allCases.filter { (summary.states[$0] ?? 0) > 0 }, id: \.self) { state in
                let n = summary.states[state] ?? 0
                SummaryButton(isLightMode: isLightMode, action: { open(.state(state)) }) {
                    HStack(spacing: 8) {
                        Circle().fill(PlanRowView.color(state, palette)).frame(width: 6, height: 6)
                        Text(state.title).font(.ui(size: 11, weight: .medium)).foregroundColor(palette.textMain)
                            .frame(width: labelWidth, alignment: .leading).lineLimit(1)
                        PlanFractionBar(fraction: Double(n) / Double(max(1, largest)), color: PlanRowView.color(state, palette), isLightMode: isLightMode)
                        Text("\(n)").font(.ui(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(palette.textMain)
                            .frame(width: StudioTheme.scaleFont(40), alignment: .trailing)
                    }
                }
                .tip("Show the \(state.title) rows.")
            }
        }
    }

    private func groupSection(_ title: String, _ groups: [PlanSummary.Group], target: @escaping (String) -> PlanSummaryTarget) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title)
            ForEach(groups) { group in
                let name = group.name.isEmpty ? (title == "Batches" ? "No Batch" : "None") : (title == "Batches" ? "Batch \(group.name)" : group.name)
                SummaryButton(isLightMode: isLightMode, action: { open(target(group.name)) }) {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 6, height: 6)
                        Text(name).font(.ui(size: 11, weight: .medium)).foregroundColor(palette.textMain)
                            .frame(width: labelWidth, alignment: .leading).lineLimit(1)
                        PlanStateBar(states: group.states, height: 5, isLightMode: isLightMode, open: nil)
                        Text("\(group.done)/\(group.live)").font(.ui(size: 10)).monospacedDigit().foregroundColor(palette.textMuted)
                            .frame(width: StudioTheme.scaleFont(56), alignment: .trailing)
                        Text(group.live > 0 ? "\(Int((Double(group.done) / Double(group.live) * 100).rounded(.down)))%" : "–")
                            .font(.ui(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(palette.textMain)
                            .frame(width: StudioTheme.scaleFont(40), alignment: .trailing)
                    }
                }
                .tip("Show the rows of \(name): \(group.done) of \(group.live) done.")
            }
        }
    }

    private var frameIOSection: some View {
        let live = max(1, summary.uploads.on + summary.uploads.none)
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Frame.io")
            uploadRow("On Frame.io", summary.uploads.on, live, palette.positive, filter: 1)
            uploadRow("Not on Frame.io", summary.uploads.none, live, palette.textSubtle, filter: 0)
            if let stale = mismatches[.differs], stale > 0 { uploadRow("Changed Locally", stale, live, TagTone.amber.color(palette.isLight), filter: PlanMismatch.differs.rawValue) }
            // Every other way the plan, this Mac and Frame.io disagree (amber: the mismatch colour).
            ForEach(PlanMismatch.allCases.filter { $0 != .differs && (mismatches[$0] ?? 0) > 0 }, id: \.self) { kind in
                SummaryButton(isLightMode: isLightMode, action: { open(.upload(kind.rawValue)) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: StudioTheme.scaleFont(8)))
                            .foregroundColor(TagTone.amber.color(palette.isLight))
                            .frame(width: 6)
                        Text(kind.title).font(.ui(size: 11, weight: .medium)).foregroundColor(palette.textMain).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(mismatches[kind] ?? 0)").font(.ui(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(palette.textMain)
                    }
                }
                .tip(kind.explanation)
            }
        }
    }

    private func uploadRow(_ title: String, _ n: Int, _ live: Int, _ color: Color, filter: Int) -> some View {
        SummaryButton(isLightMode: isLightMode, action: { open(.upload(filter)) }) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.ui(size: 11, weight: .medium)).foregroundColor(palette.textMain)
                    .frame(width: labelWidth, alignment: .leading).lineLimit(1)
                PlanFractionBar(fraction: Double(n) / Double(live), color: color, isLightMode: isLightMode)
                Text("\(n)").font(.ui(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(palette.textMain)
                    .frame(width: StudioTheme.scaleFont(40), alignment: .trailing)
            }
        }
        .tip("Show the rows \(title.lowercased()).")
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Recent Reviews")
            ForEach(summary.recent) { item in
                SummaryButton(isLightMode: isLightMode, action: { open(.row(item.rowID)) }) {
                    HStack(spacing: 8) {
                        Circle().fill(PlanRowView.color(item.state, palette)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.code.isEmpty ? item.name : "\(item.code)  \(item.name)")
                                .font(.ui(size: 11, weight: .medium)).foregroundColor(palette.textMain).lineLimit(1).truncationMode(.middle)
                            Text(item.status + (item.who.isEmpty ? "" : " · \(item.who)"))
                                .font(.ui(size: 10)).foregroundColor(palette.textMuted).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(item.date.formatted(.relative(presentation: .named)))
                            .font(.ui(size: 10)).foregroundColor(palette.textSubtle).lineLimit(1)
                    }
                }
                .tip("Show this row.")
            }
        }
    }
}

/// A row or figure in the Summary that opens its rows: a soft hover, nothing else.
private struct SummaryButton<Label: View>: View {
    let isLightMode: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(hovering ? StudioPalette(isLightMode).bgSubtle : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
    }
}

/// One share of a whole as a slim bar on a track.
struct PlanFractionBar: View {
    let fraction: Double
    let color: Color
    let isLightMode: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Radius.control).fill(StudioPalette(isLightMode).bgSubtle)
                RoundedRectangle(cornerRadius: Radius.control).fill(color)
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
    }
}

/// Rows by state as one bar in `PlanSummary.barOrder` (done, in hand, to arrive; dropped left out). With `open`,
/// each segment shows its rows.
struct PlanStateBar: View {
    let states: [PlanState: Int]
    let height: CGFloat
    let isLightMode: Bool
    let open: ((PlanState) -> Void)?

    var body: some View {
        let palette = StudioPalette(isLightMode)
        let parts = PlanSummary.barOrder.compactMap { s in (states[s] ?? 0) > 0 ? (s, states[s]!) : nil }
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        GeometryReader { geo in
            // Hairline gaps only on the big bar: on slim ones they read as dashes.
            let gap: CGFloat = parts.count > 1 && height >= 8 ? 1 : 0
            let usable = geo.size.width - gap * CGFloat(max(0, parts.count - 1))
            HStack(spacing: gap) {
                ForEach(parts, id: \.0) { state, n in
                    let segment = Rectangle().fill(PlanRowView.color(state, palette))
                        .frame(width: max(2, usable * CGFloat(n) / CGFloat(total)))
                    if let open {
                        segment.contentShape(Rectangle()).onTapGesture { open(state) }
                            .tip("\(state.title): \(n). Click to show them.")
                    } else {
                        segment
                    }
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .background(palette.bgSubtle)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .frame(height: height)
    }
}
