import SwiftUI
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(palette.borderLine).frame(height: 1)
            optionsBar
            Rectangle().fill(palette.borderLine).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(report.files) { file in
                        fileSection(file)
                    }
                }
                .padding(14)
            }
            .background(palette.bgMain)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            HStack {
                Text("Click a difference to open that file at the line.")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.bgPanel)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 560)
        .background(palette.bgPanel)
    }

    // MARK: Header & Options

    private var header: some View {
        let total = report.totalDifferences
        let others = report.files.count - 1
        return HStack(spacing: 8) {
            CCBadge(color: palette.textMain, size: 12)
            Text("SUBTITLE CROSS-CHECK")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMain)
            Spacer()
            Label(total == 0 ? "All \(report.files.count) files match" : "\(total) difference\(total == 1 ? "" : "s") in \(report.mismatchedVideos.count) of \(others) file\(others == 1 ? "" : "s")",
                  systemImage: total == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(total == 0 ? palette.accentPositive : palette.alertRed)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var optionsBar: some View {
        let refFps = report.reference?.fps ?? 25
        let toleranceFrames = Int((report.options.timingTolerance * refFps).rounded())
        return HStack(spacing: 14) {
            Menu {
                ForEach(report.files) { file in
                    Button(file.videoURL.lastPathComponent) { update { $0.referenceVideo = file.videoURL } }
                }
            } label: {
                Text("Reference: \(report.referenceVideo.lastPathComponent)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("The file every other file is compared with")

            Spacer(minLength: 4)
            optionToggle("Ignore line breaks", report.options.ignoreLineBreaks) { $0.options.ignoreLineBreaks.toggle() }
            optionToggle("Ignore formatting", report.options.ignoreFormatting) { $0.options.ignoreFormatting.toggle() }
            optionToggle("Ignore case", report.options.ignoreCase) { $0.options.ignoreCase.toggle() }
            Stepper(value: Binding(
                get: { toleranceFrames },
                set: { frames in update { $0.options.timingTolerance = (Double(max(0, frames)) + 0.01) / refFps } }
            ), in: 0...25) {
                Text("Timing ±\(toleranceFrames)f")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .fixedSize()
            .help("In/out times may differ by this many frames before it is reported")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.bgSubtle)
    }

    private func optionToggle(_ title: String, _ isOn: Bool, _ change: @escaping (inout SubtitleCrossCheckReport) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in update(change) })) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .toggleStyle(.checkbox)
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
        let isMatch = file.differences.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(file.videoURL.lastPathComponent)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(file.srtURL.lastPathComponent) · \(file.cues.count) lines")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isReference {
                    badge("REFERENCE", palette.accentBlue)
                } else if isMatch {
                    badge("MATCH", palette.accentPositive)
                } else {
                    badge("\(file.differences.count) DIFF\(file.differences.count == 1 ? "" : "S")", palette.alertRed)
                }
            }
            if !isReference {
                ForEach(file.differences) { difference in
                    differenceRow(difference, in: file)
                }
            }
        }
        .padding(10)
        .studioBox(background: palette.bgCardSubtle, border: !isReference && !isMatch ? palette.alertRed.opacity(0.45) : palette.borderLine)
    }

    private func differenceRow(_ difference: SubtitleCrossCheck.Difference, in file: SubtitleCrossCheckReport.File) -> some View {
        let refFps = report.reference?.fps ?? file.fps
        return Button(action: { onOpen(file.videoURL, difference.time) }) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    badge(difference.kind.rawValue.uppercased(), kindColor(difference.kind))
                    Text(timecode(difference.time, fps: file.fps))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.textMuted)
                }
                .frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    if let cue = difference.referenceCue {
                        lineText("REF #\(difference.referenceLine ?? 0)", cue, fps: refFps, showTiming: difference.kind == .timing)
                    }
                    if let cue = difference.otherCue {
                        lineText("THIS #\(difference.otherLine ?? 0)", cue, fps: file.fps, showTiming: difference.kind == .timing)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 11))
                    .foregroundColor(palette.textMuted)
            }
            .padding(7)
            .contentShape(Rectangle())
            .studioBox(background: palette.bgPanel, border: palette.borderLine)
        }
        .buttonStyle(.plain)
        .help("Open \(file.videoURL.lastPathComponent) at this line")
    }

    private func lineText(_ label: String, _ cue: SubtitleCue, fps: Double, showTiming: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                .foregroundColor(palette.textSubtle)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(cue.displayText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(palette.textMain)
                    .fixedSize(horizontal: false, vertical: true)
                if showTiming {
                    Text("\(timecode(cue.start, fps: fps)) → \(timecode(cue.end, fps: fps))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(palette.textMuted)
                }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundColor(color)
            .studioBox(background: color.opacity(0.14), border: color.opacity(0.5))
    }

    private func kindColor(_ kind: SubtitleCrossCheck.Kind) -> Color {
        switch kind {
        case .text: return palette.alertRed
        case .timing: return .orange
        case .missing, .extra: return palette.accentBlue
        }
    }

    private func timecode(_ seconds: Double, fps: Double) -> String {
        let safeFps = max(1, fps)
        return TimecodeFormatter.format(frameIndex: max(0, Int(ceil(seconds * safeFps - 0.5))), fps: safeFps)
    }
}
