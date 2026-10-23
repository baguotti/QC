import SwiftUI

struct GuideTopic: Hashable {
    let title: String
    let body: String
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
    
    static let chapters: [GuideChapter] = [
        GuideChapter(title: "Play", icon: "play.fill", topics: [
            GuideTopic(title: "Assets", body: "Change, Add or Refresh the loaded folder or files. The line underneath shows how many videos, images and audio files are loaded. Drag and drop works anywhere in the panel."),
            GuideTopic(title: "Queue", body: "Click a file to load it into Slot A, ⌥-click (or +B) to load it into Slot B. ↑ / ↓ move through the queue (⌥↑ / ⌥↓ for Slot B). The view menu switches list and thumbnails; + / − change the thumbnail size."),
            GuideTopic(title: "Hide, Auto and Wave", body: "Hide flattens the folder list. Auto (A) plays a clip from the start when you select it. Wave (W) draws the audio waveform under the timeline; scroll over it to resize the lane."),
            GuideTopic(title: "Images, Audio and Sequences", body: "Stills and audio open in the Player too. Numbered image sequences are detected automatically and play as a clip; right-click one in the queue to change its frame rate or read it as single images."),
            GuideTopic(title: "Play and Shuttle (Space, J / K / L)", body: "Space plays and pauses. L plays forward and speeds up on each press (1×, 2×, 4×, 8×, 16×), J does the same in reverse, K stops. ⇧L / ⇧J play slowly frame by frame. ⌘L loops."),
            GuideTopic(title: "Stepping (← / →)", body: "← / → step one frame, ⇧← / ⇧→ step five. Home or ⇧I jumps to the first frame, End to the last."),
            GuideTopic(title: "Timeline", body: "Drag the playhead or click the ruler to scrub frame-accurately. Note, line and tag markers sit on the timeline; click one to jump to it."),
            GuideTopic(title: "Compare A / B", body: "With two clips loaded, C cycles the compare modes (split, side by side, difference, overlay), Tab blinks between A and B, and S or X swaps the slots. Linked A / B plays and steps both together."),
            GuideTopic(title: "Zoom and Pan", body: "Scroll to zoom (it follows the cursor; change this in User Settings) and drag to pan. Above 175% pixels are shown square for pixel-level QC."),
            GuideTopic(title: "Exposure", body: "The EV control brightens or darkens the picture to inspect shadows and highlights. It never changes your files."),
            GuideTopic(title: "Notes (N)", body: "N adds a note at the playhead; [ and ] (or ⌥N / ⌥⇧N) jump between notes. Notes can be coloured, filtered, resolved, exported to Premiere XML and synced with your team (Synced Projects in Settings)."),
            GuideTopic(title: "Scan Findings (M)", body: "After a Scan check, M / ⇧M jump to the next or previous finding in the open clip."),
            GuideTopic(title: "Missed Line", body: "Found a line the Line Check didn't catch? Missed Line in the timecode bar sends that frame and its details to the developer after you confirm."),
            GuideTopic(title: "Finder Tags (1–7, 0)", body: "Number keys apply a Finder colour tag to the open file; 0 clears it."),
            GuideTopic(title: "Overlays and Info", body: "I cycles the clip info overlay. ⌘I opens Media Info. The crosshair, title-safe and subtitle buttons sit in the transport bar."),
            GuideTopic(title: "Screenshot", body: "The camera button saves the frame on screen (including A / B compare views) at full resolution. Right-click it to choose JPG or PNG quality."),
            GuideTopic(title: "Full Screen (F / ⇧F)", body: "F shows the video full screen with no interface. ⇧F opens review full screen with timeline and transport controls. Esc exits."),
            GuideTopic(title: "Panels and Workspaces", body: "⌘⇧← / ⌘⇧→ show or hide the side panels. ⇧1, ⇧2 and ⇧3 switch to Play, Inspect and Scan. T toggles light and dark mode, ⇧T cycles the accent theme."),
        ]),
        GuideChapter(title: "Inspect", icon: "doc.text", topics: [
            GuideTopic(title: "Specs Table", body: "Reads every file's metadata without decoding: timecode length, end frame, aspect ratio and size, frame rate, file size, creation date, video codec and audio spec. Click a column header to sort; drag a divider to resize."),
            GuideTopic(title: "Name Mismatches", body: "Flags files whose name (e.g. 16x9, 1080p, 15s) disagrees with the actual stream. Right-click a warning to dismiss it."),
            GuideTopic(title: "Check Audio Levels", body: "Measures each file's loudness and peak and flags silent or muted tracks."),
            GuideTopic(title: "Check End Frames", body: "Looks at the very last frame of every video and reports whether it is pure black or not."),
            GuideTopic(title: "Cross-Check Subtitles", body: "Compares the .srt files of the selected deliverables (all of them if none is selected) and lists every line that differs."),
            GuideTopic(title: "Filter and Kinds", body: "The filter field narrows the table by name. When a folder mixes videos, images and audio, the kind icons show or hide each kind."),
            GuideTopic(title: "Fit Name, Hide and List", body: "Fit Name widens the name column to the longest name. Hide flattens folders. List / Thumbs switches the row style."),
            GuideTopic(title: "Media Info (⌘I)", body: "Opens the full technical breakdown of the selected file: tracks, codecs, bitrates and audio channels."),
            GuideTopic(title: "Export", body: "Sheets copies the table for Google Sheets (paste with ⌘V), Save CSV writes a spreadsheet, Open HTML builds a printable specs sheet. Reveal in Finder shows the selected file."),
            GuideTopic(title: "Hide Panel (⌘⇧←)", body: "Shows or hides the Specs actions panel to give the table the full width."),
        ]),
        GuideChapter(title: "Scan", icon: "viewfinder", topics: [
            GuideTopic(title: "Line Check", body: "Scans every frame's edges for thin coloured lines left by a bad crop, reframe or matte. Results list each line with its edge, thickness, timecode range and a thumbnail; click one to open it in the Player."),
            GuideTopic(title: "Target Colour", body: "The colour to look for: Green (default), Magenta, Black, White, a hex value or the colour wheel. Any Colour ignores the target and flags lines of any colour."),
            GuideTopic(title: "Sensitivity", body: "How faint or short a line can be and still be flagged. Higher finds more, and also more false alarms."),
            GuideTopic(title: "Off-Colour Lines", body: "Also reports lines close to, but not exactly, the target colour, marked as off-colour."),
            GuideTopic(title: "Split-Screen Seams", body: "Also scans the whole frame for seams between split-screen panels (slower than edges only)."),
            GuideTopic(title: "Edge Depth", body: "How many pixels in from each edge are scanned (default 12). Letterbox and pillarbox bars are detected and the picture edge inside them is scanned too."),
            GuideTopic(title: "Frame Check", body: "One fast pass per video that finds a frame-rate mismatch (e.g. 23.976 fps material exported at 25 fps, shown as a regular pattern of repeated, skipped or blended frames), flash frames (stray black or solid frames mid-edit) and Media Offline frames."),
            GuideTopic(title: "Full Check", body: "Runs the Line Check and then the Frame Check on the same files. Both reports appear on one page, Line Check first."),
            GuideTopic(title: "Results and Export", body: "Each flagged file gets a card; Inspect opens the exact frame in the Player. Export copies the line report for Google Sheets or saves it as HTML or CSV."),
            GuideTopic(title: "Mark Flagged Files in Finder", body: "Adds a red Finder tag to every file with line glitches."),
            GuideTopic(title: "Defaults", body: "Set the Line Check defaults (target, sensitivity, options, edge depth) in User Settings; they apply each time QCpie opens."),
        ]),
    ]
    
    var body: some View {
        SidebarModalShell(isPresented: $isPresented, title: "QCpie User Guide", width: 820, height: 560, sidebarWidth: 230,
                          footnote: "Version \(AppVersionInfo.version)") {
            ForEach(Array(Self.chapters.enumerated()), id: \.offset) { c, chapter in
                HStack(spacing: 6) {
                    Image(systemName: chapter.icon)
                        .font(.system(size: 10))
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
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(palette.textMain)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            ForEach(Array(paragraphs(topic.body).enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 14))
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
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
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
