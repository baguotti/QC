import AppKit
import SwiftUI
import Vision
import VideoQCLib

/// Reads the burned-in subtitles of the clip in slot A (`BurnedSubtitleReader`) in the background and shows the result
/// in the Subtitles drawer as an unsaved draft. One read at a time. Progress publishes here (a few times a second),
/// never on `PlayerEngine` or anything `ContentView` owns, and only `PictureSubtitleProgressChip` observes it.
@MainActor
final class PictureSubtitleJob: ObservableObject {
    static let shared = PictureSubtitleJob()

    /// 0…1 while reading, nil when idle.
    @Published private(set) var progress: Double? = nil
    @Published private(set) var clip: URL? = nil
    private var reader: BurnedSubtitleReader?
    private var lastPublished = Date.distantPast

    var isRunning: Bool { progress != nil }
    /// The window's toast (set by `ContentView`).
    var onToast: (String) -> Void = { _ in }

    func start(clip: URL, region: BurnedSubtitleReader.Region, engine: PlayerEngine) {
        let onToast = self.onToast
        guard !isRunning else { onToast("Already reading subtitles from \(self.clip?.lastPathComponent ?? "a clip")"); return }
        if engine.hasPictureSubtitleDraft(for: clip), !Self.confirmReplace(clip) { return }
        let reader = BurnedSubtitleReader()
        let options = BurnedSubtitleReader.Options(region: region, languages: Self.languages())
        self.reader = reader
        self.clip = clip
        progress = 0
        Log.player.notice("Reading burned-in subtitles of \(clip.lastPathComponent) (\(region.rawValue), \(options.languages.first ?? "auto"))")
        Task {
            let started = Date()
            let outcome: Result<BurnedSubtitleReader.Result, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try await reader.read(clip, options: options) { value in
                        Task { @MainActor in PictureSubtitleJob.shared.report(value, from: reader) }
                    })
                } catch {
                    return .failure(error)
                }
            }.value
            guard self.reader === reader else { return }
            self.reader = nil
            self.clip = nil
            self.progress = nil
            switch outcome {
            case .success(let result):
                Log.player.notice("Read \(result.cues.count) subtitles from \(clip.lastPathComponent) in \(Int(Date().timeIntervalSince(started))) s")
                if result.cues.isEmpty {
                    onToast(result.note ?? "No subtitles found in the picture")
                    return
                }
                engine.loadPictureSubtitles(result.cues, review: result.lowConfidence, for: clip)
                let shown = QCUtilities.isSameURL(engine.slotA.url, clip)
                var message = "Read \(result.cues.count) subtitle\(result.cues.count == 1 ? "" : "s") from \(shown ? "the picture" : clip.lastPathComponent)"
                if !result.lowConfidence.isEmpty { message += " · \(result.lowConfidence.count) to check" }
                if let note = result.note { message += ". \(note)" }
                onToast(message)
            case .failure(BurnedSubtitleReader.Failure.cancelled):
                onToast("Stopped reading subtitles")
            case .failure(let error):
                Log.player.error("Reading burned-in subtitles of \(clip.lastPathComponent)", error)
                onToast("Couldn't read subtitles: \(error.localizedDescription)")
            }
        }
    }

    func cancel() { reader?.cancel() }

    /// Remove Subtitles from the CC menu: a draft read from the picture exists nowhere else, so it asks first.
    static func remove(from engine: PlayerEngine) {
        if let clip = engine.pictureSubtitleClip {
            let alert = NSAlert()
            alert.messageText = "Discard the subtitles read from the picture?"
            alert.informativeText = "They aren't saved as an .srt for \(clip.lastPathComponent). Save them from the Subtitles drawer first to keep them."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        engine.removeSubtitles()
    }

    /// At most ~5 publishes a second (each redraws only the chip).
    private func report(_ value: Double, from reader: BurnedSubtitleReader) {
        guard self.reader === reader, progress != nil else { return }
        let now = Date()
        guard value >= 1 || now.timeIntervalSince(lastPublished) >= 0.2 else { return }
        lastPublished = now
        progress = min(1, max(0, value))
    }

    private static func confirmReplace(_ clip: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Read the subtitles again?"
        alert.informativeText = "\(clip.lastPathComponent) already has subtitles read from its picture that aren't saved as an .srt. Reading again replaces them, with any edits."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Read Again")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The Subtitles drawer's spelling language, as one Vision reads ("" there = detect the language).
    static func languages() -> [String] {
        let chosen = UserDefaults.standard.string(forKey: SubtitleSpellingModel.languageKey) ?? ""
        guard !chosen.isEmpty else { return [] }
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        let prefix = String(chosen.prefix { $0 != "_" && $0 != "-" }).lowercased()
        let exact = chosen.replacingOccurrences(of: "_", with: "-").lowercased()
        if let match = supported.first(where: { $0.lowercased() == exact }) { return [match] }
        if let match = supported.first(where: { $0.lowercased().hasPrefix(prefix + "-") || $0.lowercased() == prefix }) { return [match] }
        return []
    }
}

/// "Reading subtitles 42% ✕" next to the CC button while a read runs.
struct PictureSubtitleProgressChip: View {
    let isLightMode: Bool
    @ObservedObject private var job = PictureSubtitleJob.shared

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        if let progress = job.progress {
            HStack(spacing: 5) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: StudioTheme.scale(40))
                    .tint(palette.accentBlue)
                Text("\(Int(progress * 100))%")
                    .font(.ui(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(palette.textMuted)
                Button(action: { job.cancel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: StudioTheme.scaleFont(8), weight: .bold))
                        .foregroundColor(palette.textMuted)
                }
                .buttonStyle(.plain)
                .explain("Stop reading subtitles from the picture.")
            }
            .padding(.horizontal, 6)
            .frame(height: StudioTheme.scale(22))
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgSubtle))
            .explain("Reading the subtitles burned into \(job.clip?.lastPathComponent ?? "the clip"). They open in the Subtitles drawer as a draft.")
            .transition(.opacity)
        }
    }
}

/// Subtitles read from the picture compared with the clip's .srt (what was supplied vs what is burned in).
struct PictureSubtitleComparison: Equatable {
    let srtName: String
    let srtCues: [SubtitleCue]
    var differences: [SubtitleCrossCheck.Difference]

    /// Within two frames counts as the same timing; quote style, line breaks and tags don't count.
    static func options(fps: Double) -> SubtitleCrossCheck.Options {
        SubtitleCrossCheck.Options(ignoreLineBreaks: true, ignoreFormatting: true, ignoreCase: false,
                                   timingTolerance: 2.5 / max(1, fps), ignoreQuoteStyle: true)
    }

    static func make(srtName: String, srtCues: [SubtitleCue], picture: [SubtitleCue], fps: Double) -> PictureSubtitleComparison {
        PictureSubtitleComparison(srtName: srtName, srtCues: srtCues,
                                  differences: SubtitleCrossCheck.compare(reference: srtCues, other: picture, options: options(fps: fps)))
    }

    /// Lines of the picture draft (0-based) that differ from the .srt.
    var differingLines: Set<Int> { Set(differences.compactMap { $0.otherLine.map { $0 - 1 } }) }
}

/// The comparison's differences; clicking one goes to it in the player.
struct PictureSubtitleComparisonView: View {
    let comparison: PictureSubtitleComparison
    let fps: Double
    let isLightMode: Bool
    let onOpen: (Double) -> Void
    let onClose: () -> Void

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Burned-in Subtitles vs \(comparison.srtName)")
                        .font(.ui(size: 13, weight: .semibold))
                        .foregroundColor(palette.textMain)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(summary)
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMuted)
                }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            if comparison.differences.isEmpty {
                VStack(spacing: 6) {
                    Text("They Match")
                        .font(.ui(size: 13, weight: .semibold))
                        .foregroundColor(palette.textMain)
                    Text("Every line burned into the picture matches \(comparison.srtName), in wording and within two frames in timing.")
                        .font(.ui(size: 11))
                        .foregroundColor(palette.textMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(comparison.differences) { difference in
                            row(difference)
                        }
                    }
                    .padding(12)
                }
            }
            Rectangle().fill(palette.borderLine).frame(height: 1)
            Text("Text read from the picture can hold OCR mistakes: check the frame before changing either file.")
                .font(.ui(size: 10))
                .foregroundColor(palette.textSubtle)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 560, height: 480)
        .background(palette.bgPanel)
    }

    private var summary: String {
        let n = comparison.differences.count
        guard n > 0 else { return "No differences" }
        let counts = Dictionary(grouping: comparison.differences, by: \.kind).mapValues(\.count)
        let parts = [SubtitleCrossCheck.Kind.text, .timing, .missing, .extra].compactMap { kind in
            counts[kind].map { "\($0) \(kind.rawValue.lowercased())" }
        }
        return "\(n) difference\(n == 1 ? "" : "s"): " + parts.joined(separator: ", ")
    }

    private func timecode(_ seconds: Double) -> String {
        TimecodeFormatter.format(frameIndex: max(0, Int((seconds * max(1, fps)).rounded())), fps: fps)
    }

    private func row(_ difference: SubtitleCrossCheck.Difference) -> some View {
        Button(action: { onOpen(difference.time) }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(difference.kind.rawValue)
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(TagTone.amber.color(palette.isLight))
                    Text(timecode(difference.time))
                        .font(.ui(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(palette.textMuted)
                    Spacer()
                }
                line(".srt", difference.referenceCue, number: difference.referenceLine)
                line("Picture", difference.otherCue, number: difference.otherLine)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(palette.bgCardSubtle))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(palette.borderLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to this line in the player")
    }

    private func line(_ label: String, _ cue: SubtitleCue?, number: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.textSubtle)
                .frame(width: 46, alignment: .leading)
            if let cue {
                Text("\(number.map { "\($0). " } ?? "")\(cue.displayText.replacingOccurrences(of: "\n", with: " / "))  ·  \(timecode(cue.start)) → \(timecode(cue.end))")
                    .font(.ui(size: 11))
                    .foregroundColor(palette.textMain)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("Not there").font(.ui(size: 11)).foregroundColor(palette.textSubtle)
            }
        }
    }
}
