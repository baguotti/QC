import SwiftUI

/// The filter bar's one menu for everything beyond the status chips: batch, on Frame.io or not, and each mismatch
/// (with counts). Its label stays short ("Filters"), with an amber count while anything disagrees; what's chosen
/// shows as removable chips beside it (`PlanActiveFilterChip`). Used by the Delivery Plan and Inspect.
struct PlanFiltersMenu: View {
    let batches: [PlanBatchFilter.Item]
    let unbatched: Int
    @Binding var batch: String?
    /// Frame.io presence counts; nil hides that section (the plan doesn't use Frame.io).
    let uploads: (none: Int, on: Int)?
    let mismatches: [PlanMismatch: Int]
    let mismatchTotal: Int
    let kinds: [PlanMismatch]
    @Binding var upload: Int?
    var dismissed = 0
    let isLightMode: Bool

    var body: some View {
        let palette = StudioPalette(isLightMode)
        let amber = TagTone.amber.color(palette.isLight)
        let shownKinds = kinds.filter { (mismatches[$0] ?? 0) > 0 || $0.rawValue == upload }
        // Nothing to filter by (no batches, no Frame.io, nothing disagrees) and nothing on: no menu.
        if batches.isEmpty && batch == nil && uploads == nil && shownKinds.isEmpty && dismissed == 0 && upload == nil {
            EmptyView()
        } else {
            menu(palette: palette, amber: amber, shownKinds: shownKinds)
        }
    }

    private func menu(palette: StudioPalette, amber: Color, shownKinds: [PlanMismatch]) -> some View {
        Menu {
            // Only when some row has a batch: "No Batch · 1,100" alone is noise.
            if !batches.isEmpty {
                Section("Batch") {
                    ForEach(batches, id: \.name) { item in
                        let pct = item.live > 0 ? "  ·  \(Int((Double(item.done) / Double(item.live) * 100).rounded(.down)))% done" : ""
                        Button("\(batch == item.name ? "✓ " : "")\(PlanBatch.title(item.name))  ·  \(item.count)\(pct)") {
                            batch = batch == item.name ? nil : item.name
                        }
                    }
                    if unbatched > 0 {
                        Button("\(batch == "" ? "✓ " : "")No Batch  ·  \(unbatched)") { batch = batch == "" ? nil : "" }
                    }
                }
            }
            if let uploads {
                Section("Frame.io") {
                    option(1, uploads.on)
                    option(0, uploads.none)
                }
            }
            if !shownKinds.isEmpty {
                Section("Mismatches") {
                    ForEach(shownKinds, id: \.self) { kind in
                        option(kind.rawValue, mismatches[kind] ?? 0).help(kind.explanation)
                    }
                }
            }
            if dismissed > 0 {
                Button("Show Dismissed Mismatches (\(dismissed))") { DeliveryPlanStore.shared.restoreDismissedMismatches() }
            }
            if batch != nil || upload != nil {
                Divider()
                Button("Clear Filters") { batch = nil; upload = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                    .foregroundColor(palette.textMuted)
                Text("Filters").font(.ui(size: 10, weight: .medium)).foregroundColor(palette.textMuted)
                if mismatchTotal > 0 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: StudioTheme.scaleFont(8))).foregroundColor(amber)
                    Text("\(mismatchTotal)").font(.ui(size: 10, weight: .semibold)).monospacedDigit().foregroundColor(amber)
                }
                Image(systemName: "chevron.down").font(.system(size: StudioTheme.scaleFont(7), weight: .semibold)).foregroundColor(palette.textSubtle)
            }
            .planBarItem(selected: false, palette: palette)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)   // borderlessButton redraws the label its own way (chevron first, system font)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip(mismatchTotal > 0
             ? "Batch, Frame.io and mismatch filters. \(mismatchTotal) mismatch\(mismatchTotal == 1 ? "" : "es") between the plan, this Mac and Frame.io."
             : "Batch, Frame.io and mismatch filters.")
    }

    private func option(_ value: Int, _ count: Int) -> some View {
        Button("\(upload == value ? "✓ " : "")\(PlanMismatch.filterTitle(value))  ·  \(count)") { upload = upload == value ? nil : value }
    }
}

/// A filter that's on, with an × to turn it off (batch, Frame.io / mismatch, channel).
struct PlanActiveFilterChip: View {
    let title: String
    var alert = false
    let isLightMode: Bool
    let clear: () -> Void

    var body: some View {
        let palette = StudioPalette(isLightMode)
        Button(action: clear) {
            HStack(spacing: 4) {
                if alert {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: StudioTheme.scaleFont(8)))
                        .foregroundColor(TagTone.amber.color(palette.isLight))
                }
                Text(title).font(.ui(size: 10, weight: .semibold)).foregroundColor(palette.textMain).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: StudioTheme.scaleFont(8), weight: .semibold)).foregroundColor(palette.textMuted)
            }
            .planBarItem(selected: true, palette: palette)
        }
        .buttonStyle(.plain)
        .tip("Showing \(title) only. Click to remove this filter.")
    }

}
