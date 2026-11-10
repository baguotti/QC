import SwiftUI

// The User Guide's pictures: QCpie's own buttons drawn as they look in the app (same icons, labels, colours, light
// or dark, the user's accent), numbered steps, and a map of the window with the part being described lit up.
// Drawn rather than screenshots, so they never go stale or clash with the theme.

/// One piece of a guide article, drawn in order under its title.
enum GuideBlock: Hashable {
    /// A plain paragraph.
    case text(String)
    /// The window, with one area lit up and labelled.
    case window(GuideArea)
    /// Numbered steps, each with the controls to look for.
    case steps([GuideStep])
    /// Controls to look for, in a row, with a caption.
    case controls(String, [GuideControl])
    /// A short aside on a tinted background.
    case tip(String)
}

struct GuideStep: Hashable {
    let text: String
    var controls: [GuideControl] = []
    init(_ text: String, _ controls: [GuideControl] = []) {
        self.text = text
        self.controls = controls
    }
}

/// A replica of a control in the app.
enum GuideControl: Hashable {
    /// A tab in the tab bar at the top of the window.
    case tab(AppTab)
    /// A text button; `primary` draws it filled, like the main action of a panel.
    case button(String, icon: String? = nil, primary: Bool = false)
    /// Joined text buttons, like Select… | Add | Refresh.
    case segments([String])
    /// An icon-only button.
    case icon(String, label: String)
    /// A keyboard key.
    case key(String)
    /// The gear menu at the top right, opened, showing one item.
    case menuItem(icon: String, title: String)
    /// A box where files can be dropped.
    case dropZone(String)
}

/// Areas of the main window the guide can point at.
enum GuideArea: Hashable {
    case overview, tabs, leftPanel, center, drawer, settings, statusBar

    var caption: String {
        switch self {
        case .overview: return "The QCpie window"
        case .tabs: return "The tabs, at the top of the window"
        case .leftPanel: return "The left panel: your files"
        case .center: return "The middle: the work itself"
        case .drawer: return "The right drawer: details, notes and the Delivery Plan"
        case .settings: return "The gear button, top right"
        case .statusBar: return "The status bar, at the bottom"
        }
    }
}

// MARK: - Drawing

struct GuideBlockView: View {
    let block: GuideBlock
    let palette: StudioPalette

    var body: some View {
        switch block {
        case .text(let text):
            Text(text)
                .font(.ui(size: 13))
                .foregroundColor(palette.textMain)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .window(let area):
            GuideWindowMap(area: area, palette: palette)
        case .steps(let steps):
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.ui(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(palette.primaryBtnFg)
                            .frame(width: StudioTheme.scale(20), height: StudioTheme.scale(20))
                            .background(Circle().fill(palette.accentBlue))
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(step.text)
                                .font(.ui(size: 13))
                                .foregroundColor(palette.textMain)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                            if !step.controls.isEmpty { GuideControlRow(controls: step.controls, palette: palette) }
                        }
                    }
                }
            }
        case .controls(let caption, let controls):
            VStack(alignment: .leading, spacing: 8) {
                Text(caption)
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(palette.textMuted)
                GuideControlRow(controls: controls, palette: palette)
            }
        case .tip(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb")
                    .font(.system(size: StudioTheme.scaleFont(11), weight: .semibold))
                    .foregroundColor(palette.accentBlue)
                Text(text)
                    .font(.ui(size: 12))
                    .foregroundColor(palette.textMain)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.accentBlue.opacity(0.08)))
        }
    }
}

/// Controls side by side, wrapping when they don't fit.
struct GuideControlRow: View {
    let controls: [GuideControl]
    let palette: StudioPalette

    var body: some View {
        GuideFlow(spacing: 8) {
            ForEach(Array(controls.enumerated()), id: \.offset) { _, control in
                GuideControlView(control: control, palette: palette)
            }
        }
    }
}

struct GuideControlView: View {
    let control: GuideControl
    let palette: StudioPalette

    var body: some View {
        switch control {
        case .tab(let tab):
            HStack(spacing: 6) {
                Image(systemName: tab.iconName).font(.system(size: StudioTheme.scaleFont(11), weight: .semibold))
                Text(tab.title).font(.ui(size: 12, weight: .semibold))
            }
            .foregroundColor(palette.textMain)
            .padding(.horizontal, 12)
            .frame(height: StudioTheme.scale(28))
            .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgCardHeader))
            .overlay(alignment: .bottom) {
                Capsule().fill(palette.accentBlue).frame(height: 2).padding(.horizontal, 10).padding(.bottom, 2)
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderLine, lineWidth: 1))
        case .button(let title, let icon, let primary):
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: StudioTheme.scaleFont(11), weight: .medium)) }
                Text(title).font(.ui(size: 12, weight: primary ? .semibold : .medium))
            }
            .foregroundColor(primary ? palette.primaryBtnFg : palette.textMain)
            .padding(.horizontal, 12)
            .frame(height: StudioTheme.scale(26))
            .background(RoundedRectangle(cornerRadius: Radius.segment).fill(primary ? palette.primaryBtnBg : palette.bgSubtle))
            .overlay(RoundedRectangle(cornerRadius: Radius.segment).stroke(primary ? Color.clear : palette.borderLine, lineWidth: 1))
        case .segments(let titles):
            HStack(spacing: 0) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    if index > 0 { Rectangle().fill(palette.borderLine).frame(width: 1, height: StudioTheme.scale(14)) }
                    Text(title)
                        .font(.ui(size: 12, weight: .medium))
                        .foregroundColor(title == "Select…" ? palette.accentBlue : palette.textMain)   // as in the app: only an empty panel's Select… is in the accent
                        .padding(.horizontal, StudioTheme.scale(9))
                        .frame(height: StudioTheme.scale(26))
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.segment).fill(palette.bgSubtle.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: Radius.segment).stroke(palette.borderLine, lineWidth: 1))
        case .icon(let symbol, let label):
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: StudioTheme.scaleFont(12), weight: .medium))
                    .foregroundColor(palette.textMain)
                    .frame(width: StudioTheme.scale(26), height: StudioTheme.scale(26))
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(palette.borderLine, lineWidth: 1))
                Text(label).font(.ui(size: 11)).foregroundColor(palette.textMuted)
            }
        case .key(let key):
            Text(key)
                .font(.system(size: StudioTheme.scaleFont(12), weight: .medium, design: .rounded))
                .foregroundColor(palette.textMain)
                .padding(.horizontal, StudioTheme.scale(7))
                .frame(minWidth: StudioTheme.scale(24), minHeight: StudioTheme.scale(22))
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(palette.borderStrong.opacity(0.7), lineWidth: 1))
        case .menuItem(let icon, let title):
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: StudioTheme.scaleFont(12)))
                    .foregroundColor(palette.textMain)
                    .frame(width: StudioTheme.scale(26), height: StudioTheme.scale(26))
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle))
                Image(systemName: "arrow.right")
                    .font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                    .foregroundColor(palette.textSubtle)
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: StudioTheme.scaleFont(11)))
                    Text(title).font(.ui(size: 11, weight: .semibold))
                }
                .foregroundColor(palette.textMain)
                .padding(.horizontal, 10)
                .frame(height: StudioTheme.scale(26))
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(palette.borderLine, lineWidth: 1))
            }
        case .dropZone(let text):
            Text(text)
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgCardSubtle))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(palette.borderLine, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }
}

/// The main window in miniature: tab bar, left panel, middle, right drawer and status bar, with `area` lit up.
struct GuideWindowMap: View {
    let area: GuideArea
    let palette: StudioPalette

    private func lit(_ part: GuideArea) -> Bool { area == part }

    private func fill(_ part: GuideArea, _ base: Color) -> Color {
        lit(part) ? palette.accentBlue.opacity(0.22) : (area == .overview ? base : base.opacity(0.55))
    }

    private func stroke(_ part: GuideArea) -> some View {
        RoundedRectangle(cornerRadius: Radius.control)
            .stroke(lit(part) ? palette.accentBlue : Color.clear, lineWidth: 2)
    }

    private func label(_ text: String, _ part: GuideArea, number: Int) -> some View {
        HStack(spacing: 5) {
            if area == .overview {
                Text("\(number)")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(palette.primaryBtnFg)
                    .frame(width: StudioTheme.scale(16), height: StudioTheme.scale(16))
                    .background(Circle().fill(palette.accentBlue))
            }
            Text(text)
                .font(.ui(size: 10, weight: lit(part) ? .semibold : .regular))
                .foregroundColor(lit(part) ? palette.accentBlue : palette.textMuted)
                .lineLimit(1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                // Tab bar with the gear on the right.
                HStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(AppTab.visibleTabs) { tab in
                            HStack(spacing: 3) {
                                Image(systemName: tab.iconName).font(.system(size: StudioTheme.scaleFont(8), weight: .semibold))
                                Text(tab.title).font(.ui(size: 10, weight: .medium))
                            }
                            .foregroundColor(lit(.tabs) || area == .overview ? palette.textMain : palette.textSubtle)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(2)
                    .background(fill(.tabs, palette.bgSubtle))
                    .overlay(stroke(.tabs))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    if area == .overview { label("Tabs", .tabs, number: 1) }
                    Spacer(minLength: 4)
                    if area == .overview { label("Settings", .settings, number: 5) }
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: StudioTheme.scaleFont(10)))
                        .foregroundColor(lit(.settings) ? palette.accentBlue : palette.textMuted)
                        .frame(width: StudioTheme.scale(22), height: StudioTheme.scale(20))
                        .background(fill(.settings, palette.bgSubtle))
                        .overlay(stroke(.settings))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                }
                .padding(.horizontal, 8)
                .frame(height: StudioTheme.scale(32))
                .background(palette.bgCardHeader)
                Rectangle().fill(palette.borderLine).frame(height: 1)

                // Left panel | middle | right drawer.
                HStack(spacing: 6) {
                    region(.leftPanel, base: palette.bgPanel, title: "Your files", number: 2) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<5, id: \.self) { i in
                                RoundedRectangle(cornerRadius: Radius.control).fill(palette.textSubtle.opacity(i == 1 ? 0.5 : 0.2)).frame(height: 5)
                            }
                        }
                    }
                    .frame(width: StudioTheme.scale(120))
                    region(.center, base: palette.bgMain, title: "The work", number: 3) {
                        RoundedRectangle(cornerRadius: Radius.control).fill(Color.black.opacity(0.75))   // design-ok: stands for video
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay(Image(systemName: "play.fill").foregroundColor(.white.opacity(0.6)))   // design-ok: on the video
                    }
                    region(.drawer, base: palette.bgPanel, title: "Details", number: 4) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<4, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: Radius.control).fill(palette.textSubtle.opacity(0.2)).frame(height: 5)
                            }
                        }
                    }
                    .frame(width: StudioTheme.scale(100))
                }
                .padding(6)
                .frame(height: StudioTheme.scale(150))

                // Status bar.
                Rectangle().fill(palette.borderLine).frame(height: 1)
                HStack(spacing: 6) {
                    if area == .overview { label("Status bar", .statusBar, number: 6) }
                    Text("Hover over any button to read what it does here.")
                        .font(.ui(size: 10))
                        .foregroundColor(lit(.statusBar) ? palette.accentBlue : palette.textSubtle)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: StudioTheme.scale(22))
                .background(fill(.statusBar, palette.bgCardHeader))
                .overlay(stroke(.statusBar))
            }
            .background(palette.bgMain)
            .clipShape(RoundedRectangle(cornerRadius: Radius.container))
            .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderStrong, lineWidth: 1))

            if area != .overview {
                Text(area.caption)
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
            }
        }
    }

    private func region<Content: View>(_ part: GuideArea, base: Color, title: String, number: Int,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title, part, number: number)
            content()
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(fill(part, base)))
        .overlay(stroke(part))
    }
}

/// Lays children out left to right, wrapping onto new lines (for rows of controls).
struct GuideFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: widest, height: y + line)
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
