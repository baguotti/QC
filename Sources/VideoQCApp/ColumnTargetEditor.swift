import SwiftUI
import VideoQCLib

/// The popover under an Inspect column header for setting its target ("≤ 5 MB"): files that miss it turn red.
struct ColumnTargetEditor: View {
    let column: SpecsSortColumn
    let current: ColumnTarget?
    let isLightMode: Bool
    /// The new target, or nil to clear it.
    let onSet: (ColumnTarget?) -> Void
    let onClose: () -> Void

    @State private var comparison: ColumnTarget.Comparison
    @State private var text: String
    @State private var unit: ColumnTarget.Unit
    @FocusState private var fieldFocused: Bool

    init(column: SpecsSortColumn, current: ColumnTarget?, isLightMode: Bool,
         onSet: @escaping (ColumnTarget?) -> Void, onClose: @escaping () -> Void) {
        self.column = column
        self.current = current
        self.isLightMode = isLightMode
        self.onSet = onSet
        self.onClose = onClose
        let units = ColumnTarget.units(for: column)
        _comparison = State(initialValue: current?.comparison ?? (column == .fps ? .equal : .atMost))
        _text = State(initialValue: current.map(Self.editableText) ?? "")
        _unit = State(initialValue: current.flatMap { t in units.first { t.valueText.hasSuffix(" \($0.rawValue)") } } ?? units[0])
    }

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var parsed: ColumnTarget? { ColumnTarget(column: column, comparison: comparison, text: text, unit: unit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(column.displayName) Target")
                .font(.ui(size: 13, weight: .semibold))
                .foregroundColor(palette.textMain)
            Picker("", selection: $comparison) {
                ForEach(ColumnTarget.comparisons(for: column), id: \.self) { Text(Self.title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                TextField(column == .timecode ? "00:00:30:00" : "Value", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.ui(size: 12).monospacedDigit())
                    .focused($fieldFocused)
                    .onSubmit(apply)
                let units = ColumnTarget.units(for: column)
                if units.count > 1 {
                    Picker("", selection: $unit) {
                        ForEach(units, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else if !units[0].rawValue.isEmpty {
                    Text(units[0].rawValue).font(.ui(size: 12)).foregroundColor(palette.textMuted)
                }
            }
            Text(hint)
                .font(.ui(size: 10))
                .foregroundColor(palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if current != nil {
                    Button("Clear") { onSet(nil); onClose() }
                }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Set", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
            .font(.ui(size: 11))
        }
        .padding(14)
        .frame(width: 250)
        .onAppear { fieldFocused = true }
        .onDisappear(perform: onClose)   // closed by a click outside, a tab switch or the column hiding
        // Clicking a control drops the field's focus (the window's click-away rule): give it back for typing.
        .onChange(of: comparison) { fieldFocused = true }
        .onChange(of: unit) { fieldFocused = true }
    }

    private var hint: String {
        let flagged = comparison == .atMost ? "over" : comparison == .atLeast ? "under" : "other than"
        let what = column == .timecode ? "Seconds, MM:SS, HH:MM:SS or HH:MM:SS:FF, counted as the Timecode column counts. " : ""
        return "\(what)Files \(flagged) the target are flagged red for this session."
    }

    private func apply() {
        guard let parsed else { fieldFocused = true; return }   // Return unfocuses the field: keep typing
        onSet(parsed)
        onClose()
    }

    private static func title(_ comparison: ColumnTarget.Comparison) -> String {
        switch comparison {
        case .atMost: return "At Most"
        case .atLeast: return "At Least"
        case .equal: return "Exactly"
        }
    }

    /// The typed value without its unit ("5" from "5 MB", "30" from "30 s").
    private static func editableText(_ target: ColumnTarget) -> String {
        let parts = target.valueText.split(separator: " ")
        return parts.count == 2 ? String(parts[0]) : target.valueText
    }
}

/// A right-click menu only where `enabled`, so other headers keep the menu of the header row around them.
struct ColumnTargetMenu<Menu: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        if enabled { content.contextMenu { menu() } } else { content }
    }
}

extension View {
    /// A tooltip only when there's something to say (no tooltip view on every unflagged cell).
    @ViewBuilder func helpIfAny(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
