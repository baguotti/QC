import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import VideoQCLib

// MARK: - Styled Display Text

/// Subtitle text as shown in the list: styling tags removed, with the italic / bold spans they marked.
/// Search highlights and spelling issues are computed on `plain`, so their ranges line up with what is drawn.
struct SubtitleStyledText {
    let plain: String
    let italic: [NSRange]
    let bold: [NSRange]

    static func make(_ raw: String) -> SubtitleStyledText {
        var plain = ""
        var italic: [NSRange] = []
        var bold: [NSRange] = []
        var italicStart: Int? = nil
        var boldStart: Int? = nil
        var length = 0
        var index = raw.startIndex
        while index < raw.endIndex {
            let char = raw[index]
            if char == "<", let close = raw[index...].firstIndex(of: ">") {
                let tag = raw[raw.index(after: index)..<close].lowercased().trimmingCharacters(in: .whitespaces)
                switch tag {
                case "i": italicStart = length
                case "/i": if let s = italicStart { italic.append(NSRange(location: s, length: length - s)); italicStart = nil }
                case "b": boldStart = length
                case "/b": if let s = boldStart { bold.append(NSRange(location: s, length: length - s)); boldStart = nil }
                default: break
                }
                index = raw.index(after: close)
                continue
            }
            if char == "{", raw[index...].hasPrefix("{\\"), let close = raw[index...].firstIndex(of: "}") {
                index = raw.index(after: close)
                continue
            }
            plain.append(char)
            length += String(char).utf16.count
            index = raw.index(after: index)
        }
        if let s = italicStart { italic.append(NSRange(location: s, length: length - s)) }
        if let s = boldStart { bold.append(NSRange(location: s, length: length - s)) }
        return SubtitleStyledText(plain: plain, italic: italic, bold: bold)
    }
}

// MARK: - Active Line Tracker

/// Publishes the line under the playhead only when it changes (a few times per second at most),
/// so the list never re-renders at frame rate.
@MainActor
final class SubtitleCueTracker: ObservableObject {
    @Published private(set) var activeIndex: Int? = nil
    private var subscription: AnyCancellable?
    private var cues: [SubtitleCue] = []
    private var fps: Double = 25

    func bind(clock: PlaybackClock, cues: [SubtitleCue], fps: Double) {
        self.cues = cues
        self.fps = max(1, fps)
        if subscription == nil {
            // @Published emits before storing: use the emitted frame.
            subscription = clock.$currentFrame.sink { [weak self] frame in
                MainActor.assumeIsolated { self?.update(frame: frame) }
            }
        }
        update(frame: clock.currentFrame)
    }

    private func update(frame: Int) {
        let index = SubtitleParser.cueIndex(at: (Double(frame) + 0.5) / fps, in: cues)
        if index != activeIndex { activeIndex = index }
    }
}

// MARK: - Spelling

/// Checks every line with the system spellchecker after edits settle, in small batches on the main actor.
@MainActor
final class SubtitleSpellingModel: ObservableObject {
    @Published private(set) var issues: [Int: [NSRange]] = [:]
    @Published private(set) var issueCount: Int = 0
    private var task: Task<Void, Never>?
    private let documentTag = NSSpellChecker.uniqueSpellDocumentTag()

    func recheck(_ cues: [SubtitleCue], delay: Duration = .milliseconds(350)) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            var result: [Int: [NSRange]] = [:]
            for (index, cue) in cues.enumerated() {
                if Task.isCancelled { return }
                let plain = SubtitleStyledText.make(cue.text).plain
                let checks = NSSpellChecker.shared.check(
                    plain,
                    range: NSRange(location: 0, length: (plain as NSString).length),
                    types: NSTextCheckingResult.CheckingType.spelling.rawValue,
                    options: nil,
                    inSpellDocumentWithTag: self.documentTag,
                    orthography: nil,
                    wordCount: nil
                )
                let ranges = checks.map(\.range).filter { $0.length > 0 }
                if !ranges.isEmpty { result[index] = ranges }
                if index % 40 == 39 { await Task.yield() }
            }
            self.issues = result
            self.issueCount = result.values.reduce(0) { $0 + $1.count }
        }
    }
}

// MARK: - Subtitles Panel (Premiere-style Text panel)

struct SubtitlesPanelView: View {
    @ObservedObject var engine: PlayerEngine
    let isLightMode: Bool
    let onToast: (String) -> Void

    @StateObject private var tracker = SubtitleCueTracker()
    @StateObject private var spelling = SubtitleSpellingModel()

    /// Line open in the editor (double-click, or find / spelling navigation).
    @State private var selectedIndex: Int? = nil
    /// Line selected with a single click (playhead jumps there; not editing).
    @State private var highlightedIndex: Int? = nil
    @State private var draftText: String = ""
    @State private var commitTask: Task<Void, Never>? = nil
    @State private var editorSelection: NSRange? = nil
    @State private var selectionToken: Int = 0

    @State private var query: String = ""
    @State private var replacement: String = ""
    @State private var matchCase: Bool = false
    @State private var currentMatch: Int = 0
    @FocusState private var isFindFocused: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var cues: [SubtitleCue] { engine.subtitleCues }
    private var fps: Double { max(1, engine.slotA.fps) }
    private var matches: [SubtitleSearch.Match] {
        SubtitleSearch.matches(in: cues, query: query, matchCase: matchCase)
    }

    var body: some View {
        let currentMatches = matches
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.borderLine).frame(height: 1)
            findBar(currentMatches)
            Rectangle().fill(palette.borderLine).frame(height: 1)
            cueList(currentMatches)
        }
        .background(palette.bgMain)
        .onAppear {
            tracker.bind(clock: engine.clock, cues: cues, fps: fps)
            spelling.recheck(cues, delay: .zero)
        }
        .onChange(of: engine.subtitleSourceURL) { _, _ in
            selectedIndex = nil
            tracker.bind(clock: engine.clock, cues: cues, fps: fps)
            spelling.recheck(cues, delay: .zero)
        }
        .onChange(of: cues) { _, newCues in
            tracker.bind(clock: engine.clock, cues: newCues, fps: fps)
            spelling.recheck(newCues)
        }
        .onChange(of: query) { _, _ in currentMatch = 0 }
        .onChange(of: matchCase) { _, _ in currentMatch = 0 }
        .onDisappear { commitDraft() }
        .background(
            ZStack {
                Button("") { isFindFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") {
                    if let index = highlightedIndex, selectedIndex == nil, !isFindFocused { select(index, seek: false) }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(highlightedIndex == nil || selectedIndex != nil)
            }
            .opacity(0)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            CCBadge(color: palette.textMuted, size: 10)
            Text(engine.subtitleFileName ?? "Subtitles")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textMain)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(engine.subtitleSourceURL?.path ?? "")
            if engine.hasUnsavedSubtitleEdits {
                Circle().fill(palette.accentBlue).frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
            Spacer(minLength: 4)

            Button(action: goToNextIssue) {
                HStack(spacing: 3) {
                    Image(systemName: spelling.issueCount == 0 ? "checkmark.seal" : "textformat.abc.dottedunderline")
                        .font(.system(size: 9, weight: .bold))
                    Text(spelling.issueCount == 0 ? "SPELLING OK" : "\(spelling.issueCount)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .foregroundColor(spelling.issueCount == 0 ? palette.accentPositive : palette.alertRed)
                .studioBox(background: (spelling.issueCount == 0 ? palette.accentPositive : palette.alertRed).opacity(0.12),
                           border: (spelling.issueCount == 0 ? palette.accentPositive : palette.alertRed).opacity(0.45))
            }
            .buttonStyle(.plain)
            .disabled(spelling.issueCount == 0)
            .help(spelling.issueCount == 0 ? "No spelling issues found" : "\(spelling.issueCount) possible spelling issues — click to go to the next one")

            Button(action: save) {
                Text("SAVE")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .foregroundColor(engine.hasUnsavedSubtitleEdits ? palette.accentBlue : palette.textSubtle)
                    .studioBox(background: engine.hasUnsavedSubtitleEdits ? palette.accentBlue.opacity(0.15) : palette.bgSubtle,
                               border: engine.hasUnsavedSubtitleEdits ? palette.accentBlue.opacity(0.6) : palette.borderLine)
            }
            .buttonStyle(.plain)
            .disabled(!engine.hasUnsavedSubtitleEdits)
            .help("Save changes to \(engine.subtitleFileName ?? "the .srt")")

            Menu {
                Button("Save As…") { saveAs() }
                Button("Reveal in Finder") {
                    if let url = engine.subtitleSourceURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button(engine.showSubtitles ? "Hide Subtitles on Video" : "Show Subtitles on Video") {
                    engine.showSubtitles.toggle()
                }
                Button("Reset Subtitle Position") { engine.resetSubtitlePosition() }
                    .disabled(engine.subtitlePosition == PlayerEngine.defaultSubtitlePosition)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 11))
                    .foregroundColor(palette.textMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(palette.bgPanel)
    }

    // MARK: Find & Replace

    private func findBar(_ currentMatches: [SubtitleSearch.Match]) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                fieldBox {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundColor(palette.textMuted)
                    TextField("Find", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, design: .monospaced))
                        .focused($isFindFocused)
                        .onSubmit { goToMatch(currentMatch + 1, in: currentMatches) }
                    if !query.isEmpty {
                        Text(currentMatches.isEmpty ? "0" : "\(min(currentMatch, currentMatches.count - 1) + 1)/\(currentMatches.count)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(currentMatches.isEmpty ? palette.alertRed : palette.textMuted)
                    }
                }
                Button(action: { matchCase.toggle() }) {
                    Text("Aa")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .frame(width: 24, height: 22)
                        .foregroundColor(matchCase ? palette.accentBlue : palette.textMuted)
                        .studioBox(background: matchCase ? palette.accentBlue.opacity(0.15) : palette.bgSubtle,
                                   border: matchCase ? palette.accentBlue.opacity(0.6) : palette.borderLine)
                }
                .buttonStyle(.plain)
                .help("Match case")
                iconButton("chevron.up", help: "Previous match") { goToMatch(currentMatch - 1, in: currentMatches) }
                    .disabled(currentMatches.isEmpty)
                iconButton("chevron.down", help: "Next match (Return)") { goToMatch(currentMatch + 1, in: currentMatches) }
                    .disabled(currentMatches.isEmpty)
            }
            HStack(spacing: 5) {
                fieldBox {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.system(size: 9))
                        .foregroundColor(palette.textMuted)
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, design: .monospaced))
                        .onSubmit { replaceCurrent(currentMatches) }
                }
                textButton("REPLACE") { replaceCurrent(currentMatches) }
                    .disabled(currentMatches.isEmpty)
                textButton("ALL") { replaceAll() }
                    .disabled(currentMatches.isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.bgPanel)
    }

    // MARK: Line List

    private func cueList(_ currentMatches: [SubtitleSearch.Match]) -> some View {
        let focusedMatch = currentMatches.isEmpty ? nil : currentMatches[min(currentMatch, currentMatches.count - 1)]
        return ScrollViewReader { proxy in
            ScrollView {
                // Rows are identified by the ForEach index only (also the scroll target): extra `.id(index)` on
                // the editor / row branches left the old row on screen when a line switched into editing.
                LazyVStack(spacing: 6) {
                    ForEach(cues.indices, id: \.self) { index in
                        let cue = cues[index]
                        if selectedIndex == index {
                            editorRow(index: index, cue: cue)
                        } else {
                            SubtitleCueRow(
                                number: index + 1,
                                inTC: timecode(cue.start),
                                outTC: timecode(cue.end),
                                styled: SubtitleStyledText.make(cue.text),
                                searchQuery: query,
                                matchCase: matchCase,
                                isFocusedMatchRow: focusedMatch?.cueIndex == index,
                                spellingIssues: spelling.issues[index] ?? [],
                                isActive: tracker.activeIndex == index,
                                isSelected: highlightedIndex == index,
                                isLightMode: isLightMode
                            )
                            .equatable()
                            .contentShape(Rectangle())
                            .overlay {
                                ClickCountCatcher { clicks in
                                    if clicks >= 2 { select(index, seek: false) } else { highlight(index) }
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if highlightedIndex == index {
                                    Button(action: { select(index, seek: false) }) {
                                        Text("EDIT")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2.5)
                                            .foregroundColor(palette.accentBlue)
                                            .studioBox(background: palette.accentBlue.opacity(0.14), border: palette.accentBlue.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(6)
                                    .help("Edit this line (or double-click it, or press Return)")
                                }
                            }
                            .help("Click to jump here · Double-click to edit")
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: tracker.activeIndex) { _, active in
                guard let active = active, engine.isPlaying, selectedIndex == nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(active, anchor: .center) }
            }
            .onChange(of: selectedIndex) { _, selected in
                guard let selected = selected else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    private func editorRow(index: Int, cue: SubtitleCue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("\(index + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.accentBlue)
                Text("\(timecode(cue.start)) → \(timecode(cue.end))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(palette.textMuted)
                Spacer()
                Button(action: { deselect() }) {
                    Text("DONE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.accentBlue)
                }
                .buttonStyle(.plain)
                .help("Finish editing (Esc)")
            }
            SpellCheckedTextEditor(
                text: $draftText,
                fontSize: 12,
                textColor: isLightMode ? .black : .white,
                selection: editorSelection,
                selectionToken: selectionToken,
                onEscape: { deselect() },
                onEndEditing: { commitDraft() }
            )
            .onChange(of: draftText) { _, _ in scheduleCommit() }
            .padding(4)
            .studioBox(background: palette.bgPanel, border: palette.accentBlue.opacity(0.7))
        }
        .padding(8)
        .studioBox(background: palette.accentBlue.opacity(0.08), border: palette.accentBlue.opacity(0.5))
    }

    // MARK: Actions

    /// Single click: jump the playhead to the line and select it, closing any open editor.
    private func highlight(_ index: Int) {
        guard cues.indices.contains(index) else { return }
        if selectedIndex != nil { deselect() }
        highlightedIndex = index
        let frame = max(0, Int(ceil(cues[index].start * fps - 0.5)))
        engine.seek(toFrame: frame)
    }
    
    /// Opens a line in the editor.
    private func select(_ index: Int, seek: Bool) {
        guard cues.indices.contains(index) else { return }
        highlightedIndex = index
        if selectedIndex != index {
            commitDraft()
            selectedIndex = index
            draftText = SubtitleParser.editableText(cues[index].text)
        }
        if seek {
            let frame = max(0, Int(ceil(cues[index].start * fps - 0.5)))
            engine.seek(toFrame: frame)
        }
    }

    private func deselect() {
        commitDraft()
        selectedIndex = nil
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            commitDraft()
        }
    }

    private func commitDraft() {
        commitTask?.cancel()
        commitTask = nil
        guard let index = selectedIndex, cues.indices.contains(index) else { return }
        engine.updateSubtitleText(at: index, to: SubtitleParser.applyingEditedText(draftText, to: cues[index].text))
    }

    private func goToMatch(_ target: Int, in currentMatches: [SubtitleSearch.Match]) {
        guard !currentMatches.isEmpty else { NSSound.beep(); return }
        let wrapped = ((target % currentMatches.count) + currentMatches.count) % currentMatches.count
        currentMatch = wrapped
        let match = currentMatches[wrapped]
        select(match.cueIndex, seek: true)
        highlightInEditor(match.range)
    }

    private func highlightInEditor(_ range: NSRange) {
        editorSelection = range
        selectionToken &+= 1
    }

    private func replaceCurrent(_ currentMatches: [SubtitleSearch.Match]) {
        guard !currentMatches.isEmpty else { return }
        commitDraft()
        let match = currentMatches[min(currentMatch, currentMatches.count - 1)]
        let raw = cues[match.cueIndex].text
        let plain = SubtitleParser.editableText(raw) as NSString
        guard NSMaxRange(match.range) <= plain.length else { return }
        let updatedPlain = plain.replacingCharacters(in: match.range, with: replacement)
        engine.updateSubtitleText(at: match.cueIndex, to: SubtitleParser.applyingEditedText(updatedPlain, to: raw))
        if selectedIndex == match.cueIndex { draftText = updatedPlain }
        // Same position now points at the following match.
        let remaining = SubtitleSearch.matches(in: engine.subtitleCues, query: query, matchCase: matchCase)
        if remaining.isEmpty {
            currentMatch = 0
        } else {
            goToMatch(min(currentMatch, remaining.count - 1), in: remaining)
        }
    }

    private func replaceAll() {
        commitDraft()
        let (updated, count) = SubtitleSearch.replaceAll(in: cues, query: query, with: replacement, matchCase: matchCase)
        guard count > 0 else { return }
        engine.setEditedSubtitles(updated)
        if let index = selectedIndex, updated.indices.contains(index) { draftText = SubtitleParser.editableText(updated[index].text) }
        currentMatch = 0
        onToast("Replaced \(count) occurrence\(count == 1 ? "" : "s") — remember to SAVE")
    }

    private func goToNextIssue() {
        let indices = spelling.issues.keys.sorted()
        guard !indices.isEmpty else { return }
        let start = selectedIndex ?? -1
        let target = indices.first { $0 > start } ?? indices[0]
        select(target, seek: true)
        // Spelling ranges are in tag-free text, the same coordinates the editor shows.
        if let range = spelling.issues[target]?.first {
            highlightInEditor(range)
        }
    }

    private func save() {
        commitDraft()
        do {
            try engine.saveSubtitles()
            onToast("Saved \(engine.subtitleFileName ?? "subtitles")")
        } catch {
            onToast("Couldn't save subtitles: \(error.localizedDescription)")
        }
    }

    private func saveAs() {
        commitDraft()
        let panel = NSSavePanel()
        panel.title = "Save Subtitles As"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = engine.subtitleFileName ?? "subtitles.srt"
        panel.directoryURL = engine.subtitleSourceURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try engine.saveSubtitles(to: url)
            onToast("Saved as \(url.lastPathComponent)")
        } catch {
            onToast("Couldn't save subtitles: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private func timecode(_ seconds: Double) -> String {
        TimecodeFormatter.format(frameIndex: max(0, Int(ceil(seconds * fps - 0.5))), fps: fps)
    }

    private func fieldBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22)
                .foregroundColor(palette.textMain)
                .studioBox(background: palette.bgSubtle, border: palette.borderLine)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .foregroundColor(palette.textMain)
                .studioBox(background: palette.bgSubtle, border: palette.borderLine)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Line Row

/// One subtitle line (not being edited). Equatable so playback only re-renders the rows whose
/// active state flips, not the whole list.
struct SubtitleCueRow: View, Equatable {
    let number: Int
    let inTC: String
    let outTC: String
    let styled: SubtitleStyledText
    let searchQuery: String
    let matchCase: Bool
    let isFocusedMatchRow: Bool
    let spellingIssues: [NSRange]
    let isActive: Bool
    let isSelected: Bool
    let isLightMode: Bool

    nonisolated static func == (lhs: SubtitleCueRow, rhs: SubtitleCueRow) -> Bool {
        lhs.number == rhs.number && lhs.inTC == rhs.inTC && lhs.outTC == rhs.outTC &&
        lhs.styled.plain == rhs.styled.plain && lhs.styled.italic == rhs.styled.italic && lhs.styled.bold == rhs.styled.bold &&
        lhs.searchQuery == rhs.searchQuery && lhs.matchCase == rhs.matchCase && lhs.isFocusedMatchRow == rhs.isFocusedMatchRow &&
        lhs.spellingIssues == rhs.spellingIssues && lhs.isActive == rhs.isActive && lhs.isSelected == rhs.isSelected && lhs.isLightMode == rhs.isLightMode
    }

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(isActive ? palette.accentBlue : Color.clear)
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(number)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(isActive ? palette.accentBlue : palette.textSubtle)
                    Text("\(inTC) → \(outTC)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(palette.textMuted)
                    Spacer(minLength: 0)
                    if !spellingIssues.isEmpty {
                        Image(systemName: "textformat.abc.dottedunderline")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(palette.alertRed)
                    }
                }
                Text(attributedText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(palette.textMain)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioBox(background: isActive ? palette.accentBlue.opacity(0.10) : palette.bgCardSubtle,
                   border: isSelected ? palette.accentBlue : (isActive ? palette.accentBlue.opacity(0.45) : palette.borderLine),
                   width: isSelected ? 1.5 : 1)
    }

    /// Splits the line at every style / highlight boundary and styles each piece.
    private var attributedText: AttributedString {
        let plain = styled.plain as NSString
        let searchRanges = searchQuery.isEmpty ? [] :
            SubtitleSearch.ranges(of: searchQuery, in: styled.plain, options: matchCase ? [] : [.caseInsensitive])
        var cuts: Set<Int> = [0, plain.length]
        for r in styled.italic + styled.bold + searchRanges + spellingIssues {
            cuts.insert(max(0, min(plain.length, r.location)))
            cuts.insert(max(0, min(plain.length, NSMaxRange(r))))
        }
        let points = cuts.sorted()
        func covers(_ ranges: [NSRange], _ location: Int) -> Bool {
            ranges.contains { location >= $0.location && location < NSMaxRange($0) }
        }
        var result = AttributedString()
        for (a, b) in zip(points, points.dropFirst()) where b > a {
            var piece = AttributedString(plain.substring(with: NSRange(location: a, length: b - a)))
            let isItalic = covers(styled.italic, a)
            let isBold = covers(styled.bold, a)
            if isItalic || isBold {
                var font = Font.system(size: 11.5, weight: isBold ? .bold : .medium)
                if isItalic { font = font.italic() }
                piece.font = font
            }
            if covers(searchRanges, a) {
                piece.backgroundColor = (isFocusedMatchRow ? Color.orange : Color.yellow).opacity(isLightMode ? 0.55 : 0.4)
            }
            if covers(spellingIssues, a) {
                piece.underlineStyle = Text.LineStyle(pattern: .dot, color: palette.alertRed)
            }
            result += piece
        }
        return result
    }
}

// MARK: - Click Counting

/// Reports AppKit's click count for clicks on the view it covers (1 = click, 2 = double-click). Used instead of
/// SwiftUI tap gestures, which drop the second click of a double-click when a single-tap action is also present.
struct ClickCountCatcher: NSViewRepresentable {
    var onClick: (Int) -> Void
    
    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }
    
    func updateNSView(_ view: CatcherView, context: Context) {
        view.onClick = onClick
    }
    
    final class CatcherView: NSView {
        var onClick: ((Int) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?(event.clickCount) }
    }
}

// MARK: - CC Badge

/// "CC" closed-captions mark (rounded box with the letters), used for subtitle controls.
struct CCBadge: View {
    /// nil = inherit the surrounding foreground colour (e.g. a button's active / inactive tint).
    var color: Color? = nil
    var size: CGFloat = 10

    var body: some View {
        // Text centres its line box (ascender + descender), not the caps; shift so "CC" sits optically centred.
        let font = NSFont.systemFont(ofSize: size * 0.68, weight: .semibold)
        let capOffset = ((font.ascender + font.descender) - font.capHeight) / 2
        Text("CC")
            .font(.system(size: size * 0.68, weight: .semibold))
            .tracking(-0.3)
            .offset(y: capOffset)
            .frame(width: size * 1.5, height: size * 1.05)
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(.primary, lineWidth: 1))
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
    }
}
