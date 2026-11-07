import SwiftUI
import AppKit

/// One deliverable: status dot, name, the specs the sheet asks for, the matched file and anything wrong.
struct PlanRowView: View, Equatable {
    let row: PlanRow
    let result: PlanRowResult
    var state = PlanRowState(state: .missing)
    var note = ""
    var checkLines: [String] = []
    let change: DeliveryPlanStore.Change?
    /// The row's Frame.io link ("" when not uploaded / linked).
    var frameio = ""
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
                if let link = URL(string: frameio), !frameio.isEmpty {
                    Button { NSWorkspace.shared.open(link) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: StudioTheme.scaleFont(8)))
                            Text("On Frame.io")
                                .font(.ui(size: 10, weight: .medium))
                        }
                        .foregroundColor(palette.accentBlue)
                    }
                    .buttonStyle(.plain)
                    .tip(frameio)
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
