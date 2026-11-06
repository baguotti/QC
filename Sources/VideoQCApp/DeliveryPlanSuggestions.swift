import SwiftUI

/// The filter bar's "N Suggested" button: Frame.io files that probably belong to rows, linked only on a click.
struct PlanSuggestionsButton: View {
    let count: Int
    let isLightMode: Bool
    @State private var showing = false

    var body: some View {
        let palette = StudioPalette(isLightMode)
        Button { showing = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "link.badge.plus").font(.system(size: StudioTheme.scaleFont(9), weight: .semibold))
                Text("\(count) Suggested").font(.ui(size: 10, weight: .medium)).monospacedDigit()
            }
            .foregroundColor(palette.accentBlue)
            .planBarItem(selected: false, palette: palette)
        }
        .buttonStyle(.plain)
        .tip("Frame.io files that look like they belong to rows. Review them before they're linked.")
        .sheet(isPresented: $showing) { PlanLinkSuggestionsSheet(isLightMode: isLightMode) { showing = false } }
    }
}

struct PlanLinkSuggestionsSheet: View {
    let isLightMode: Bool
    let onClose: () -> Void
    @ObservedObject private var store = DeliveryPlanStore.shared

    var body: some View {
        let palette = StudioPalette(isLightMode)
        let items = store.pendingSuggestions
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested Frame.io Links").font(.ui(size: 15, weight: .semibold)).foregroundColor(palette.textMain)
            Text("QCpie links a file by itself only when its name holds the row's code and name. These are likely, not certain: accept the right ones, dismiss the rest.")
                .font(.ui(size: 11)).foregroundColor(palette.textMuted).fixedSize(horizontal: false, vertical: true)
            if items.isEmpty {
                Text("Nothing to review.").font(.ui(size: 11)).foregroundColor(palette.textSubtle)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(item.code)  \(item.rowName)").font(.ui(size: 11, weight: .semibold)).foregroundColor(palette.textMain)
                                        .lineLimit(1).truncationMode(.middle)
                                    Text("→ \(item.fileName)").font(.ui(size: 11)).foregroundColor(palette.textMain).lineLimit(1).truncationMode(.middle)
                                    Text(item.reason).font(.ui(size: 10)).foregroundColor(palette.textMuted).lineLimit(2)
                                }
                                Spacer(minLength: 6)
                                Button("Accept") { store.acceptSuggestions([item.id]) }.controlSize(.small)
                                Button { store.dismissSuggestions([item.id]) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).controlSize(.small)
                                    .tip("Not this file: don't suggest it again.")
                            }
                            .padding(.vertical, 6)
                            Rectangle().fill(palette.borderLine).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
            HStack {
                if !items.isEmpty {
                    Button("Accept All") { store.acceptSuggestions(items.map(\.id)) }
                }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .font(.ui(size: 11))
        }
        .padding(20)
        .frame(width: 540)
        .background(palette.bgPanel)
        .onExitCommand(perform: onClose)
    }
}
