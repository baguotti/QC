import SwiftUI
import UniformTypeIdentifiers
import VideoQCLib

/// Results of a subtitle cross-check: each file compared with the reference, differences listed by line.
/// Clicking a difference opens that file in the player at the line.
struct SubtitleCrossCheckSheet: View {
    let report: SubtitleCrossCheckReport
    let isLightMode: Bool
    let onChange: (SubtitleCrossCheckReport) -> Void
    let onOpen: (URL, Double) -> Void
    let onClose: () -> Void

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    @State private var collapsed: Set<URL> = []
    @State private var hoveredDifference: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            optionsBar
            Rectangle().fill(palette.borderLine).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(report.files) { file in
                        fileSection(file)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .background(palette.bgMain)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            footer
        }
        .frame(minWidth: 720, idealWidth: 860, maxWidth: 1200, minHeight: 520, idealHeight: 640)
        .background(palette.bgPanel)
    }

    // MARK: Header, Options & Footer

    private var header: some View {
        let total = report.totalDifferences
        let others = report.files.count - 1
        let summary = total == 0
            ? "All \(report.files.count) files match"
            : "\(total) difference\(total == 1 ? "" : "s") in \(report.mismatchedVideos.count) of \(others) file\(others == 1 ? "" : "s")"
        return HStack(alignment: .center, spacing: 10) {
            CCBadge(color: palette.textMuted, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text("Subtitle Cross-Check")
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundColor(palette.textMain)
                Text(summary)
                    .font(.ui(size: 11))
                    .foregroundColor(total == 0 ? palette.accentPositive : palette.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var optionsBar: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Text("Reference:")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMuted)
                    .fixedSize()
                Menu {
                    ForEach(report.files) { file in
                        Button(file.videoURL.lastPathComponent) { update { $0.referenceVideo = file.videoURL } }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(report.referenceVideo.lastPathComponent)
                            .font(.ui(size: 11, weight: .medium))
                            .foregroundColor(palette.textMain)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: StudioTheme.scaleFont(8), weight: .semibold))
                            .foregroundColor(palette.textMuted)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("The file every other file is compared with")
            }
            .frame(maxWidth: 480, alignment: .leading)
            Spacer(minLength: 8)
            Text("Ignore:")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
                .fixedSize()
            optionToggle("Line breaks", report.options.ignoreLineBreaks) { $0.options.ignoreLineBreaks.toggle() }
            optionToggle("Formatting", report.options.ignoreFormatting) { $0.options.ignoreFormatting.toggle() }
            optionToggle("Case", report.options.ignoreCase) { $0.options.ignoreCase.toggle() }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            Text("Click a difference to open that file at the line.")
                .font(.ui(size: 10))
                .foregroundColor(palette.textSubtle)
            Spacer()
            Button(action: onClose) {
                Text("Done")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(palette.primaryBtnFg)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.primaryBtnBg))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func optionToggle(_ title: String, _ isOn: Bool, _ change: @escaping (inout SubtitleCrossCheckReport) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in update(change) })) {
            Text(title).font(.ui(size: 11))
        }
        .toggleStyle(.checkbox)
        .fixedSize()
    }

    private func update(_ change: (inout SubtitleCrossCheckReport) -> Void) {
        var copy = report
        change(&copy)
        copy.recompute()
        onChange(copy)
    }

    // MARK: File Sections

    private func fileSection(_ file: SubtitleCrossCheckReport.File) -> some View {
        let isReference = file.videoURL == report.referenceVideo
        let hasDifferences = !isReference && !file.differences.isEmpty
        let isOpen = hasDifferences && !collapsed.contains(file.videoURL)
        let status: (String, Color) = isReference
            ? ("Reference", palette.accentBlue)
            : hasDifferences
                ? ("\(file.differences.count) difference\(file.differences.count == 1 ? "" : "s")", palette.alertRed)
                : ("Matches", palette.accentPositive)
        return VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                guard hasDifferences else { return }
                if collapsed.contains(file.videoURL) { collapsed.remove(file.videoURL) } else { collapsed.insert(file.videoURL) }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: StudioTheme.scaleFont(9), weight: .bold))
                        .foregroundColor(palette.textMuted)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .opacity(hasDifferences ? 1 : 0)
                        .frame(width: 10)
                    Image(nsImage: fileIcon(file.videoURL))
                        .resizable()
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.videoURL.lastPathComponent)
                            .font(.ui(size: 12, weight: .semibold))
                            .foregroundColor(palette.textMain)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(file.srtURL.lastPathComponent) — \(file.cues.count) lines")
                            .font(.ui(size: 10))
                            .foregroundColor(palette.textSubtle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 12)
                    statusLabel(status.0, status.1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(spacing: 0) {
                    ForEach(Array(file.differences.enumerated()), id: \.element.id) { index, difference in
                        differenceRow(difference, in: file, striped: index % 2 == 1)
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private func differenceRow(_ difference: SubtitleCrossCheck.Difference, in file: SubtitleCrossCheckReport.File, striped: Bool) -> some View {
        let refFps = report.reference?.fps ?? file.fps
        let showTiming = difference.kind == .timing
        let refText = difference.referenceCue?.displayText
        let otherText = difference.otherCue?.displayText
        let highlight = difference.kind == .text
        let rowID = "\(file.videoURL.path)#\(difference.id)"
        let isHovered = hoveredDifference == rowID
        return Button(action: { onOpen(file.videoURL, difference.time) }) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    statusLabel(difference.kind.rawValue, kindColor(difference.kind))
                    Text(timecode(difference.time, fps: file.fps))
                        .font(.system(size: StudioTheme.scaleFont(10), design: .monospaced))
                        .foregroundColor(palette.textMuted)
                }
                .frame(width: 104, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    comparisonLine("Reference", difference.referenceLine, refText.map { highlight ? marked($0, against: otherText ?? "", color: palette.alertRed) : AttributedString($0) },
                                   timing: showTiming ? difference.referenceCue.map { timing($0, fps: refFps) } : nil)
                    comparisonLine("This file", difference.otherLine, otherText.map { highlight ? marked($0, against: refText ?? "", color: palette.alertRed) : AttributedString($0) },
                                   timing: showTiming ? difference.otherCue.map { timing($0, fps: file.fps) } : nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: StudioTheme.scaleFont(12)))
                    .foregroundColor(palette.textMuted)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? palette.textMain.opacity(0.08) : (striped ? palette.textMain.opacity(0.03) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredDifference = $0 ? rowID : (hoveredDifference == rowID ? nil : hoveredDifference) }
        .help("Open \(file.videoURL.lastPathComponent) at this line")
    }

    /// One side of a difference; a missing line reads "No line".
    private func comparisonLine(_ label: String, _ line: Int?, _ text: AttributedString?, timing: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.map { "\(label) #\($0)" } ?? label)
                .font(.ui(size: 10))
                .foregroundColor(palette.textSubtle)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let text {
                    Text(text)
                        .font(.ui(size: 12))
                        .foregroundColor(palette.textMain)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No line")
                        .font(.ui(size: 12).italic())
                        .foregroundColor(palette.textSubtle)
                }
                if let timing {
                    Text(timing)
                        .font(.system(size: StudioTheme.scaleFont(10), design: .monospaced))
                        .foregroundColor(palette.textMuted)
                }
            }
        }
    }

    /// `text` with the words that differ from `other` tinted.
    private func marked(_ text: String, against other: String, color: Color) -> AttributedString {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let otherWords = other.split(whereSeparator: \.isWhitespace).map(String.init)
        var changed = Set<Int>()
        for change in words.difference(from: otherWords) {
            if case let .insert(offset, _, _) = change { changed.insert(offset) }
        }
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            if index > 0 { result += AttributedString(" ") }
            var part = AttributedString(word)
            if changed.contains(index) {
                part.foregroundColor = color
                part.backgroundColor = color.opacity(0.16)
            }
            result += part
        }
        return result
    }

    /// Finder-style label: a coloured dot and the text.
    private func statusLabel(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.ui(size: 11, weight: .medium))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// The system icon for the file type (no disk access).
    private func fileIcon(_ url: URL) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .movie)
    }

    private func kindColor(_ kind: SubtitleCrossCheck.Kind) -> Color {
        switch kind {
        case .text: return palette.alertRed
        case .timing: return .orange
        case .missing, .extra: return palette.accentBlue
        }
    }

    private func timing(_ cue: SubtitleCue, fps: Double) -> String {
        "\(timecode(cue.start, fps: fps)) → \(timecode(cue.end, fps: fps))"
    }

    private func timecode(_ seconds: Double, fps: Double) -> String {
        let safeFps = max(1, fps)
        return TimecodeFormatter.format(frameIndex: max(0, Int(ceil(seconds * safeFps - 0.5))), fps: safeFps)
    }
}
