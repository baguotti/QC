import SwiftUI

struct GuideTopic: Hashable {
    let title: String
    let body: String
    /// Keyboard Shortcuts pages: rows of keys (each drawn as a keycap) and what they do.
    var shortcuts: [GuideShortcut] = []
    /// Steps, pictures of the window and drawn buttons, shown before `body`.
    var blocks: [GuideBlock] = []
}

struct GuideShortcut: Hashable {
    let keys: [String]
    let action: String
    init(_ keys: [String], _ action: String) {
        self.keys = keys
        self.action = action
    }
}

struct GuideChapter {
    let title: String
    let icon: String
    let topics: [GuideTopic]
}

/// Help viewer in the style of Apple's user guides: table of contents on the left, one article at a time on the right.
struct UserGuideView: View {
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @State private var selection = GuideTopicID(chapter: 0, topic: 0)
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    private struct GuideTopicID: Hashable {
        let chapter: Int
        let topic: Int
    }
    
    /// Every keyboard shortcut (as registered in `KeyboardShortcutRouter`), one page per group.
    /// Rebuilt on each use: some lines follow settings (the ⇧-arrow step).
    static var shortcutsChapter: GuideChapter { GuideChapter(title: "Keyboard Shortcuts", icon: "keyboard", topics: [
        GuideTopic(title: "Playback", body: "", shortcuts: [
            GuideShortcut(["Space"], "Play / pause"),
            GuideShortcut(["J", "K", "L"], "Reverse · stop · forward (press again to speed up)"),
            GuideShortcut(["⇧J", "⇧L"], "Slow frame-by-frame reverse / forward"),
            GuideShortcut(["←", "→"], "Step one frame"),
            GuideShortcut(["⇧←", "⇧→"], UserPreferences.shiftStep == 0 ? "Step one second" : "Step \(UserPreferences.shiftStep) frames"),
            GuideShortcut(["Home"], "Go to the first frame"),
            GuideShortcut(["I", "O"], "Mark In / Out"),
            GuideShortcut(["⇧I", "⇧O"], "Go to In / Out (first / last frame when not set)"),
            GuideShortcut(["⌥X"], "Clear In and Out"),
            GuideShortcut(["End"], "Go to the last frame"),
            GuideShortcut(["⌘L"], "Loop on / off"),
        ]),
        GuideTopic(title: "Queue", body: "", shortcuts: [
            GuideShortcut(["↑", "↓"], "Previous / next file in slot A"),
            GuideShortcut(["⌥↑", "⌥↓"], "Previous / next file in slot B"),
            GuideShortcut(["A"], "Autoplay on / off"),
            GuideShortcut(["W"], "Audio waveform on / off"),
            GuideShortcut(["+", "−"], "Thumbnail size"),
        ]),
        GuideTopic(title: "Compare", body: "", shortcuts: [
            GuideShortcut(["Tab"], "Blink between A and B"),
            GuideShortcut(["C"], "Cycle compare modes"),
            GuideShortcut(["S", "X"], "Swap A and B"),
        ]),
        GuideTopic(title: "Review", body: "", shortcuts: [
            GuideShortcut(["N"], "Add a note at the playhead"),
            GuideShortcut(["[", "]"], "Previous / next note"),
            GuideShortcut(["⌥⇧N", "⌥N"], "Previous / next note"),
            GuideShortcut(["⇧M", "M"], "Previous / next Scan finding"),
            GuideShortcut(["1", "–", "7"], "Finder tag: red, green, blue, yellow, orange, purple, grey"),
            GuideShortcut(["0"], "Clear the Finder tag"),
            GuideShortcut(["⌥I"], "Cycle the clip info overlay"),
            GuideShortcut(["⌘I"], "Media Info"),
            GuideShortcut(["⌘V"], "Link the clip to the Frame.io link on the clipboard (for comments)"),
        ]),
        GuideTopic(title: "Inspect", body: "", shortcuts: [
            GuideShortcut(["↑", "↓"], "Previous / next file"),
            GuideShortcut(["⇧↑", "⇧↓"], "Extend the selection"),
            GuideShortcut(["⌘↑", "⌘↓"], "First / last file (also Home / End)"),
            GuideShortcut(["Page Up", "Page Down"], "Ten files up / down"),
            GuideShortcut(["⌥↑", "⌥↓"], "Previous / next file that needs a look"),
            GuideShortcut(["Return"], "Open in the Player"),
            GuideShortcut(["Space"], "Play / pause the preview"),
            GuideShortcut(["J", "K", "L"], "Preview: reverse · pause · forward (faster on each press)"),
            GuideShortcut(["←", "→"], "Preview: step a frame (⇧: ten)"),
            GuideShortcut(["⌘I"], "Media Info"),
            GuideShortcut(["⌘A"], "Select all"),
            GuideShortcut(["Esc"], "Clear the selection"),
            GuideShortcut(["⌘Z"], "Undo the last Delivery Plan edit"),
            GuideShortcut(["⌥1", "⌥6"], "Delivery Plan status (⌥0 clears)"),
        ]),
        GuideTopic(title: "Upload", body: "", shortcuts: [
            GuideShortcut(["Space"], "Preview the selected Frame.io file"),
            GuideShortcut(["←", "→"], "Previous / next file in the preview"),
            GuideShortcut(["⌘A"], "Select all"),
            GuideShortcut(["⌘Z"], "Undo the last rename or move"),
            GuideShortcut(["⌘V"], "Go to a pasted Frame.io link"),
            GuideShortcut(["⌘⌫"], "Delete on Frame.io (asks first)"),
        ]),
        GuideTopic(title: "View", body: "", shortcuts: [
            GuideShortcut(["F"], "Video full screen"),
            GuideShortcut(["⇧F"], "Review full screen"),
            GuideShortcut(["Esc"], "Exit full screen / close a window"),
            GuideShortcut(["⌘⇧←", "⌘⇧→"], "Show / hide the left and right panels"),
            GuideShortcut(["⇧1", "⇧2", "⇧3", "⇧4"], "Play · Inspect · Scan · Upload"),
            GuideShortcut(["⌥⌘D"], "Delivery Plan window"),
            GuideShortcut(["⌘,"], "User Settings"),
            GuideShortcut(["⌘+", "⌘−"], "Button size"),
            GuideShortcut(["T"], "Light / dark mode"),
            GuideShortcut(["⇧T"], "Next accent theme"),
            GuideShortcut(["?", "⌘/"], "User Guide"),
            GuideShortcut(["⌘S"], "Shortcuts for this tab"),
        ]),
    ]) }
    
    /// Rebuilt on each use, so the shortcuts chapter shows the current settings.
    static var chapters: [GuideChapter] { [
        gettingStarted,
        GuideChapter(title: "Play", icon: "play.fill", topics: [
            GuideTopic(title: "Assets", body: "Change, Add or Refresh the loaded folder or files. The line underneath shows how many videos, images and audio files are loaded. Drag and drop works anywhere in the panel.",
                       blocks: [.window(.leftPanel), .controls("Look for", [.segments(["Change", "Add", "Refresh"])])]),
            GuideTopic(title: "Queue", body: "Click a file to load it into Slot A, ⌥-click (or +B) to load it into Slot B. ↑ / ↓ move through the queue (⌥↑ / ⌥↓ for Slot B). The view menu switches list and thumbnails; + / − change the thumbnail size."),
            GuideTopic(title: "Hide, Auto and Wave", body: "Hide flattens the folder list. Auto (A) plays a clip from the start when you select it. Wave (W) draws the audio waveform under the timeline; scroll over it to resize the lane."),
            GuideTopic(title: "Images, Audio and Sequences", body: "Stills and audio open in the Player too. Numbered image sequences are detected automatically and play as a clip; right-click one in the queue to change its frame rate or read it as single images."),
            GuideTopic(title: "Play and Shuttle (Space, J / K / L)", body: "Space plays and pauses. L plays forward and speeds up on each press (1×, 2×, 4×, 8×, 16×), J does the same in reverse, K stops. ⇧L / ⇧J play slowly frame by frame. ⌘L loops."),
            GuideTopic(title: "Stepping (← / →)", body: "← / → step one frame, ⇧← / ⇧→ step five (or the step set in User Settings). Home jumps to the first frame, End to the last."),
            GuideTopic(title: "In and Out (I / O)", body: "I and O mark an In and Out point on the timeline; ⇧I and ⇧O go to them, ⌥X clears them. With loop on (⌘L), playback loops between them, to review one shot over and over. The range's length shows next to the duration: click it to export the range as its own file (original quality when the format allows)."),
            GuideTopic(title: "Timeline", body: "Drag the playhead or click the ruler to scrub frame-accurately. Note, line and tag markers sit on the timeline; click one to jump to it."),
            GuideTopic(title: "Compare A / B", body: "With two clips loaded, C cycles the compare modes (split, side by side, difference, overlay), Tab blinks between A and B, and S or X swaps the slots. Linked A / B plays and steps both together."),
            GuideTopic(title: "Zoom and Pan", body: "Scroll to zoom (it follows the cursor; change this in User Settings) and drag to pan. Above 175% pixels are shown square for pixel-level QC."),
            GuideTopic(title: "Exposure", body: "The EV control brightens or darkens the picture to inspect shadows and highlights. It never changes your files."),
            GuideTopic(title: "Notes (N)", body: "N adds a note at the playhead; [ and ] (or ⌥N / ⌥⇧N) jump between notes. Notes can be coloured, filtered, resolved, exported to Premiere XML and synced with your team (Synced Projects in Settings)."),
            GuideTopic(title: "Scan Findings (M)", body: "After a Scan check, M / ⇧M jump to the next or previous finding in the open clip."),
            GuideTopic(title: "Missed Line", body: "Found a line the Line Check didn't catch? Missed Line in the timecode bar sends that frame and its details to the developer after you confirm."),
            GuideTopic(title: "Finder Tags (1–7, 0)", body: "Number keys apply a Finder colour tag to the open file; 0 clears it."),
            GuideTopic(title: "Read Subtitles from the Picture", body: "For subtitles burned into the video: right-click the CC button, choose Read Subtitles from Picture, then Bottom or Top of the Picture. QCpie reads them in the background (the chip by the CC button shows progress; ✕ stops it) and opens them in the Subtitles drawer as a draft, with spell check. Lines worth a look (hard to read, or unusually long) get an eye mark; the \"to check\" button steps through them. If the clip has an .srt, ••• → Compare with that file lists every line that differs in wording or timing. Save writes the draft as an .srt next to the clip. Reading can misread stylised or busy text: check the frame before changing anything.",
                       blocks: [.controls("Look for (right-click the CC button)", [.button("Read Subtitles from Picture"), .button("Bottom of the Picture"), .button("Top of the Picture")])]),
            GuideTopic(title: "Overlays and Info", body: "I cycles the clip info overlay. ⌘I opens Media Info. The crosshair, title-safe and subtitle buttons sit in the transport bar."),
            GuideTopic(title: "Legal Range Zebra", body: "The striped button in the transport bar stripes the paused frame where brightness or colour is outside broadcast-legal levels: red above the limits, blue below. It shows the file's own levels (EV doesn't change it) and hides during playback. Right-click it to choose the standard: EBU R103 (UK and Europe: luma −1 to 103%, RGB −5 to 105%) or Strict (0 to 100%)."),
            GuideTopic(title: "Screenshot", body: "The camera button saves the frame on screen (including A / B compare views) at full resolution. Right-click it to choose JPG or PNG quality."),
            GuideTopic(title: "Full Screen (F / ⇧F)", body: "F shows the video full screen with no interface. ⇧F opens review full screen with timeline and transport controls. Esc exits."),
            GuideTopic(title: "Panels and Workspaces", body: "⌘⇧← / ⌘⇧→ show or hide the side panels. ⇧1, ⇧2, ⇧3 and ⇧4 switch to Play, Inspect, Scan and Upload. T toggles light and dark mode, ⇧T cycles the accent theme."),
        ]),
        GuideChapter(title: "Inspect", icon: "doc.text", topics: [
            GuideTopic(title: "Specs Table", body: "Reads every file's metadata without decoding: timecode length, end frame, aspect ratio and size, frame rate, file size, creation date, video codec and audio spec. Click a column header to sort; drag a divider to resize.",
                       blocks: [.window(.center)]),
            GuideTopic(title: "Name Mismatches", body: "Flags files whose name (e.g. 16x9, 1080p, 15s) disagrees with the actual stream. Right-click a warning to dismiss it."),
            GuideTopic(title: "Check Loudness", body: "Measures each file's integrated loudness (LUFS), true peak (dBTP), loudness range and max short-term loudness to ITU-R BS.1770-4, and passes, warns or fails it against the target picked under the button (EBU R128, ATSC A/85, Streaming / Social, Apple or a custom target in Settings → Checks). It also flags a silent channel, out-of-phase stereo and dual mono. Hover the value in the Audio column for details; the numbers are included in exports."),
            GuideTopic(title: "Check End Frames", body: "Looks at the very last frame of every video and reports whether it is pure black or not."),
            GuideTopic(title: "Check Subs & Graphics", body: "Reads the text in each video's picture. Subs says LIKELY when text keeps changing in the lower centre (burned-in subtitles). Graphics lists the other text it saw (titles, supers, text logos, end cards) with when it appears, or CLEAN when there's none; click a cell to open that moment in the Player. In the Player, pink diamonds on the ruler mark where each text graphic starts: click one to go there. A file named CLEAN that shows text, or named TITLED or SUBS without it, turns red. Logos without letters aren't seen, and text in the footage itself (a sign) counts, so check the tooltip before acting on it.",
                       blocks: [.controls("Look for (Inspect, left panel)", [.button("Check Subs & Graphics", icon: "textformat")])]),
            GuideTopic(title: "Cross-Check Subtitles", body: "Compares the .srt files of the selected deliverables (all of them if none is selected) and lists every line that differs."),
            GuideTopic(title: "Filter and Kinds", body: "The filter field narrows the table by name. When a folder mixes videos, images and audio, the kind icons show or hide each kind."),
            GuideTopic(title: "Fit Name, Hide and List", body: "Fit Name widens the name column to the longest name. Hide flattens folders. List / Thumbs switches the row style."),
            GuideTopic(title: "Media Info (⌘I)", body: "Opens the full technical breakdown of the selected file: tracks, codecs, bitrates and audio channels."),
            GuideTopic(title: "Keyboard", body: "↑ / ↓ move through the files and ⇧↑ / ⇧↓ extend the selection; ⌘↑ / ⌘↓ (or Home / End) go to the first or last, Page Up / Down jump ten. ⌥↑ / ⌥↓ jump to the next file that needs a look (a mismatch, or Check or Needs Fix in the Delivery Plan). Return plays the file in the Player, Space plays or pauses the preview, Esc clears the selection. The Delivery Plan follows the selection."),
            GuideTopic(title: "Preview", body: "The bottom of the left panel previews the selected file; its arrow folds it away. Double-clicking a file opens the preview in its own window, centred, and plays it. Space plays and pauses, J / K / L shuttle, ← / → step frames (Open in Player is in the right-click menu of the list and the preview, or Return), the bar scrubs (fast, to the nearest keyframe), the speaker mutes it. The window button opens it in its own window, any size, on any screen; Dock brings it back. It's a glance: QC in the Player (Return)."),
            GuideTopic(title: "Thumbnails and Skimming", body: "List / Thumbs switches to thumbnails (size up to 220 pt in the view options, or + / −). Move the mouse across a video's thumbnail to skim through it. Drag the left panel's edge to resize it (double-click resets)."),
            GuideTopic(title: "Export", body: "Sheets copies the table for Google Sheets (paste with ⌘V), Save CSV writes a spreadsheet, Open HTML builds a printable specs sheet. Reveal in Finder shows the selected file."),
            GuideTopic(title: "Hide Panel (⌘⇧←)", body: "Shows or hides the Specs actions panel to give the table the full width."),
            GuideTopic(title: "Delivery Plan (⌘⇧→)", body: "Link the Google Sheet that lists every deliverable (sign in with your studio Google account; the sheet only needs to be shared with you). QCpie re-reads it every few seconds while the plan is open, highlights rows that changed since you last looked, and matches each row to the Inspect file whose name contains the row's file name, checking resolution, length, frame rate, format, file size and sound. Rows show Missing, Delivered, Check (specs that don't match, or an unsure match: the row says which); files no row names are listed as Not in the Plan. Click a row to select its file in Inspect, double-click to play it. The window button opens the plan in its own window, for a second screen (⌥⌘D)."),
        ]),
        GuideChapter(title: "Scan", icon: "viewfinder", topics: [
            GuideTopic(title: "Line Check", body: "Scans every frame's edges for thin coloured lines left by a bad crop, reframe or matte. Results list each line with its edge, thickness, timecode range and a thumbnail; click one to open it in the Player.",
                       blocks: [.controls("Look for", [.button("Run Line Check", icon: "play.fill", primary: true), .button("Run Frame Check"), .button("Run Full Check")])]),
            GuideTopic(title: "Target Colour", body: "The colour to look for: Green (default), Magenta, Black, White, a hex value or the colour wheel. Any Colour ignores the target and flags lines of any colour."),
            GuideTopic(title: "Sensitivity", body: "How faint or short a line can be and still be flagged. Higher finds more, and also more false alarms."),
            GuideTopic(title: "Off-Colour Lines", body: "Also reports lines close to, but not exactly, the target colour, marked as off-colour."),
            GuideTopic(title: "Split-Screen Seams", body: "Also scans the whole frame for seams between split-screen panels (slower than edges only)."),
            GuideTopic(title: "Edge Depth", body: "How many pixels in from each edge are scanned (default 12). Letterbox and pillarbox bars are detected and the picture edge inside them is scanned too."),
            GuideTopic(title: "Frame Check", body: "One fast pass per video that finds a frame-rate mismatch (e.g. 23.976 fps material exported at 25 fps, shown as a regular pattern of repeated, skipped or blended frames), flash frames (stray black or solid frames mid-edit), Media Offline frames and out-of-legal-range levels (super-whites, super-blacks and illegal colours covering more than 1% of the picture, judged against the Legal Range standard). Inspect opens a legal-range finding with the zebra on."),
            GuideTopic(title: "Full Check", body: "Runs the Line Check and then the Frame Check on the same files. Both reports appear on one page, Line Check first."),
            GuideTopic(title: "Results and Export", body: "Each flagged file gets a card; Inspect opens the exact frame in the Player. Export copies the line report for Google Sheets or saves it as HTML or CSV."),
            GuideTopic(title: "Mark Flagged Files in Finder", body: "Adds a red Finder tag to every file with line glitches."),
            GuideTopic(title: "Defaults", body: "Set the Line Check defaults (target, sensitivity, options, edge depth) in User Settings; they apply each time QCpie opens."),
        ]),
        shortcutsChapter,
    ] }
    
    var body: some View {
        SidebarModalShell(isPresented: $isPresented, title: "QCpie User Guide", width: 820, height: 560, sidebarWidth: 230,
                          footnote: "Version \(AppVersionInfo.version)") {
            ForEach(Array(Self.chapters.enumerated()), id: \.offset) { c, chapter in
                HStack(spacing: 6) {
                    Image(systemName: chapter.icon)
                        .font(.system(size: StudioTheme.scaleFont(10)))
                        .foregroundColor(palette.textMuted)
                    Text(chapter.title)
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(palette.textMuted)
                }
                .padding(.horizontal, 8)
                .padding(.top, c == 0 ? 2 : 14)
                .padding(.bottom, 4)
                ForEach(Array(chapter.topics.enumerated()), id: \.offset) { t, topic in
                    let id = GuideTopicID(chapter: c, topic: t)
                    SidebarRow(title: topic.title, indent: true, isSelected: selection == id, isLightMode: isLightMode) {
                        selection = id
                    }
                }
            }
        } detail: {
            article
        }
    }
    
    private var article: some View {
        let chapter = Self.chapters[selection.chapter]
        let topic = chapter.topics[selection.topic]
        let next = nextTopic(after: selection)
        return VStack(alignment: .leading, spacing: 0) {
            Text(chapter.title)
                .font(.ui(size: 12, weight: .medium))
                .foregroundColor(palette.accentBlue)
                .padding(.bottom, 6)
            Text(topic.title)
                .font(.system(size: StudioTheme.scaleFont(24), weight: .bold))
                .foregroundColor(palette.textMain)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            if !topic.shortcuts.isEmpty {
                shortcutTable(topic.shortcuts)
            }
            ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                GuideBlockView(block: block, palette: palette)
                    .padding(.bottom, 18)
            }
            ForEach(Array(paragraphs(topic.body).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: StudioTheme.scaleFont(14)))
                    .foregroundColor(palette.textMain.opacity(0.88))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.bottom, 12)
            }
            if let next {
                Rectangle().fill(palette.borderLine).frame(height: 1).padding(.top, 18).padding(.bottom, 12)
                Button(action: { selection = next }) {
                    HStack(spacing: 4) {
                        Text("Next: \(Self.chapters[next.chapter].topics[next.topic].title)")
                        Image(systemName: "chevron.right").font(.system(size: StudioTheme.scaleFont(10), weight: .semibold))
                    }
                    .font(.ui(size: 12, weight: .medium))
                    .foregroundColor(palette.accentBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: 560, alignment: .leading)
        .id(selection)
    }
    
    private func shortcutTable(_ rows: [GuideShortcut]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .center, spacing: 16) {
                    HStack(spacing: 5) {
                        ForEach(row.keys, id: \.self) { key in
                            if key == "–" {
                                Text("–").font(.ui(size: 12)).foregroundColor(palette.textMuted)
                            } else {
                                keycap(key)
                            }
                        }
                    }
                    .frame(width: StudioTheme.scale(120), alignment: .leading)
                    Text(row.action)
                        .font(.ui(size: 13))
                        .foregroundColor(palette.textMain.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                if index < rows.count - 1 {
                    Rectangle().fill(palette.borderLine.opacity(0.6)).frame(height: 1)
                }
            }
        }
        .padding(.bottom, 8)
    }
    
    /// One key, drawn as a subtle keycap.
    private func keycap(_ key: String) -> some View {
        Text(key)
            .font(.system(size: StudioTheme.scaleFont(12), weight: .medium, design: .rounded))
            .foregroundColor(palette.textMain)
            .padding(.horizontal, StudioTheme.scale(7))
            .frame(minWidth: StudioTheme.scale(24), minHeight: StudioTheme.scale(22))
            .background(RoundedRectangle(cornerRadius: 5).fill(palette.bgSubtle))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.borderStrong.opacity(0.7), lineWidth: 1))
    }
    
    /// Splits long entries into short paragraphs at sentence ends ("e.g. 23.976" is not a sentence end).
    private func paragraphs(_ text: String) -> [String] {
        let sentences = text.replacingOccurrences(of: #"(?<=[a-z0-9)])\. (?=[A-Z])"#, with: ".\n", options: .regularExpression)
            .components(separatedBy: "\n")
        guard sentences.count > 2 else { return [text] }
        var out: [String] = []
        var current = ""
        for sentence in sentences {
            current += (current.isEmpty ? "" : " ") + sentence
            if current.count > 160 { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
    
    private func nextTopic(after id: GuideTopicID) -> GuideTopicID? {
        if id.topic + 1 < Self.chapters[id.chapter].topics.count { return GuideTopicID(chapter: id.chapter, topic: id.topic + 1) }
        if id.chapter + 1 < Self.chapters.count { return GuideTopicID(chapter: id.chapter + 1, topic: 0) }
        return nil
    }
}


/// ⌘S: the shortcuts that work in the current tab, from the User Guide's lists. Shown over the window until ⌘S or Esc.
struct ShortcutCheatSheet: View {
    let tab: AppTab
    let isLightMode: Bool

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    private var topics: [GuideTopic] {
        let names: [String]
        switch tab {
        case .player: names = ["Playback", "Queue", "Compare", "Review", "View"]
        case .upload: names = ["Upload", "View"]
        case .specs: names = ["Inspect", "View"]
        default: names = ["View"]
        }
        return names.compactMap { name in UserGuideView.shortcutsChapter.topics.first { $0.title == name } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts")
                .font(.ui(size: 15, weight: .semibold))
                .foregroundColor(palette.textMain)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: StudioTheme.scale(300)), alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(topics, id: \.title) { topic in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(topic.title)
                            .font(.ui(size: 11, weight: .semibold))
                            .foregroundColor(palette.textMuted)
                        ForEach(topic.shortcuts, id: \.self) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.keys.joined(separator: " "))
                                    .font(.system(size: StudioTheme.scaleFont(11), weight: .medium, design: .rounded))
                                    .foregroundColor(palette.textMain)
                                    .frame(width: StudioTheme.scale(84), alignment: .leading)
                                Text(row.action)
                                    .font(.ui(size: 11))
                                    .foregroundColor(palette.textMain.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            Text("⌘S or Esc to close. Every shortcut is in the User Guide (?).")
                .font(.ui(size: 11))
                .foregroundColor(palette.textMuted)
        }
        .padding(20)
        .frame(maxWidth: StudioTheme.scale(980))
        .background(RoundedRectangle(cornerRadius: Radius.container).fill(palette.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: Radius.container).stroke(palette.borderStrong, lineWidth: 1))
        .padding(40)
        .allowsHitTesting(false)
    }
}
