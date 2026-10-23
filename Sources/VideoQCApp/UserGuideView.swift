import SwiftUI

struct UserGuideView: View {
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @State private var selectedGuideTab: Int = 0
    
    // Dynamic Studio Theme Palette
    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(isPresented ? 0.65 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture {
                    dismissModal()
                }
            
            // Modal Container
            VStack(spacing: 0) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(palette.textMain)
                        Text("User Guide")
                            .font(.ui(size: 12, weight: .semibold))
                            .foregroundColor(palette.textMain)
                        
                        HStack(spacing: 4) {
                            Text("v\(AppVersionInfo.version)")
                                .fontWeight(.heavy)
                        }
                        .font(.ui(size: 9))
                        .foregroundColor(palette.textMain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    Spacer()
                    Button(action: { dismissModal() }) {
                        Text("Close (Esc)")
                            .font(.ui(size: 10, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(palette.bgPanel)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Tabs
                HStack(spacing: 0) {
                    guideTabButton(title: "Player", index: 0)
                    guideTabButton(title: "Specs", index: 1)
                    guideTabButton(title: "Glitch Finder", index: 2)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(palette.bgSubtle)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Content Body
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        switch selectedGuideTab {
                        case 0: playerGuide
                        case 1: deliverablesGuide
                        default: lineScannerGuide
                        }
                    }
                    .padding(18)
                }
                .background(palette.bgMain)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Footer
                HStack {
                    Text("Press Esc to close this guide.")
                        .font(.ui(size: 9))
                        .foregroundColor(palette.textMuted)
                    Spacer()
                    Button(action: { dismissModal() }) {
                        Text("Done")
                            .font(.ui(size: 10, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                            .foregroundColor(palette.primaryBtnFg)
                            .background(palette.primaryBtnBg)
                            .cornerRadius(StudioTheme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(palette.bgPanel)
            }
            .frame(minWidth: 800, maxWidth: 900, minHeight: 560, maxHeight: 680)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
        }
        .allowsHitTesting(isPresented)
    }
    
    private func dismissModal() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
        }
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
    
    private func guideTabButton(title: String, index: Int) -> some View {
        let isSel = selectedGuideTab == index
        return Button(action: { selectedGuideTab = index }) {
            Text(title)
                .font(.ui(size: 10, weight: isSel ? .semibold : .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundColor(isSel ? palette.textMain : palette.textMuted)
                .studioBox(background: isSel ? (isLightMode ? palette.bgPanel : Color(white: 0.22)) : Color.clear, border: isSel ? palette.borderStrong : Color.clear)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Tab 1 Guide // PLAYER
    
    private var playerGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "Assets", desc: "Change, Add or Refresh the loaded folder or files. The line underneath shows how many videos, images and audio files are loaded. Drag and drop works anywhere in the panel.")
            guideRow(name: "Queue", desc: "Click a file to load it into Slot A, ⌥-click (or +B) to load it into Slot B. ↑ / ↓ move through the queue (⌥↑ / ⌥↓ for Slot B). The view menu switches list and thumbnails; + / − change the thumbnail size.")
            guideRow(name: "Hide, Auto and Wave", desc: "Hide flattens the folder list. Auto (A) plays a clip from the start when you select it. Wave (W) draws the audio waveform under the timeline; scroll over it to resize the lane.")
            guideRow(name: "Images, Audio and Sequences", desc: "Stills and audio open in the Player too. Numbered image sequences are detected automatically and play as a clip; right-click one in the queue to change its frame rate or read it as single images.")
            guideRow(name: "Play and Shuttle (Space, J / K / L)", desc: "Space plays and pauses. L plays forward and speeds up on each press (1×, 2×, 4×, 8×, 16×), J does the same in reverse, K stops. ⇧L / ⇧J play slowly frame by frame. ⌘L loops.")
            guideRow(name: "Stepping (← / →)", desc: "← / → step one frame, ⇧← / ⇧→ step five. Home or ⇧I jumps to the first frame, End to the last.")
            guideRow(name: "Timeline", desc: "Drag the playhead or click the ruler to scrub frame-accurately. Note, line and tag markers sit on the timeline; click one to jump to it.")
            guideRow(name: "Compare A / B", desc: "With two clips loaded, C cycles the compare modes (split, side by side, difference, overlay), Tab blinks between A and B, and S or X swaps the slots. Linked A / B plays and steps both together.")
            guideRow(name: "Zoom and Pan", desc: "Scroll to zoom (it follows the cursor; change this in User Settings) and drag to pan. Above 175% pixels are shown square for pixel-level QC.")
            guideRow(name: "Exposure", desc: "The EV control brightens or darkens the picture to inspect shadows and highlights. It never changes your files.")
            guideRow(name: "Notes (N)", desc: "N adds a note at the playhead; [ and ] (or ⌥N / ⌥⇧N) jump between notes. Notes can be coloured, filtered, resolved, exported to Premiere XML and synced with your team (Synced Projects in Settings).")
            guideRow(name: "Glitch Findings (M)", desc: "After a Glitch Finder check, M / ⇧M jump to the next or previous finding in the open clip.")
            guideRow(name: "Missed Line", desc: "Found a line the Line Check didn't catch? Missed Line in the timecode bar sends that frame and its details to the developer after you confirm.")
            guideRow(name: "Finder Tags (1–7, 0)", desc: "Number keys apply a Finder colour tag to the open file; 0 clears it.")
            guideRow(name: "Overlays and Info", desc: "I cycles the clip info overlay. ⌘I opens Media Info. The crosshair, title-safe and subtitle buttons sit in the transport bar.")
            guideRow(name: "Screenshot", desc: "The camera button saves the frame on screen (including A / B compare views) at full resolution. Right-click it to choose JPG or PNG quality.")
            guideRow(name: "Full Screen (F / ⇧F)", desc: "F shows the video full screen with no interface. ⇧F opens review full screen with timeline and transport controls. Esc exits.")
            guideRow(name: "Panels and Workspaces", desc: "⌘⇧← / ⌘⇧→ show or hide the side panels. ⇧1, ⇧2 and ⇧3 switch to Player, Specs and Glitch Finder. T toggles light and dark mode, ⇧T cycles the accent theme.")
        }
    }
    
    // MARK: - Tab 2 Guide // SPECS
    
    private var deliverablesGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "Specs Table", desc: "Reads every file's metadata without decoding: timecode length, end frame, aspect ratio and size, frame rate, file size, creation date, video codec and audio spec. Click a column header to sort; drag a divider to resize.")
            guideRow(name: "Name Mismatches", desc: "Flags files whose name (e.g. 16x9, 1080p, 15s) disagrees with the actual stream. Right-click a warning to dismiss it.")
            guideRow(name: "Check Audio Levels", desc: "Measures each file's loudness and peak and flags silent or muted tracks.")
            guideRow(name: "Check End Frames", desc: "Looks at the very last frame of every video and reports whether it is pure black or not.")
            guideRow(name: "Cross-Check Subtitles", desc: "Compares the .srt files of the selected deliverables (all of them if none is selected) and lists every line that differs.")
            guideRow(name: "Filter and Kinds", desc: "The filter field narrows the table by name. When a folder mixes videos, images and audio, the kind icons show or hide each kind.")
            guideRow(name: "Fit Name, Hide and List", desc: "Fit Name widens the name column to the longest name. Hide flattens folders. List / Thumbs switches the row style.")
            guideRow(name: "Media Info (⌘I)", desc: "Opens the full technical breakdown of the selected file: tracks, codecs, bitrates and audio channels.")
            guideRow(name: "Export", desc: "Sheets copies the table for Google Sheets (paste with ⌘V), Save CSV writes a spreadsheet, Open HTML builds a printable specs sheet. Reveal in Finder shows the selected file.")
            guideRow(name: "Hide Panel (⌘⇧←)", desc: "Shows or hides the Specs actions panel to give the table the full width.")
        }
    }
    
    // MARK: - Tab 3 Guide // GLITCH FINDER
    
    private var lineScannerGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "Line Check", desc: "Scans every frame's edges for thin coloured lines left by a bad crop, reframe or matte. Results list each line with its edge, thickness, timecode range and a thumbnail; click one to open it in the Player.")
            guideRow(name: "Target Colour", desc: "The colour to look for: Green (default), Magenta, Black, White, a hex value or the colour wheel. Any Colour ignores the target and flags lines of any colour.")
            guideRow(name: "Sensitivity", desc: "How faint or short a line can be and still be flagged. Higher finds more, and also more false alarms.")
            guideRow(name: "Off-Colour Lines", desc: "Also reports lines close to, but not exactly, the target colour, marked as off-colour.")
            guideRow(name: "Split-Screen Seams", desc: "Also scans the whole frame for seams between split-screen panels (slower than edges only).")
            guideRow(name: "Edge Depth", desc: "How many pixels in from each edge are scanned (default 12). Letterbox and pillarbox bars are detected and the picture edge inside them is scanned too.")
            guideRow(name: "Frame Check", desc: "One fast pass per video that finds a frame-rate mismatch (e.g. 23.976 fps material exported at 25 fps, shown as a regular pattern of repeated, skipped or blended frames), flash frames (stray black or solid frames mid-edit) and Media Offline frames.")
            guideRow(name: "Full Check", desc: "Runs the Line Check and then the Frame Check on the same files. Both reports appear on one page, Line Check first.")
            guideRow(name: "Results and Export", desc: "Each flagged file gets a card; Inspect opens the exact frame in the Player. Export copies the line report for Google Sheets or saves it as HTML or CSV.")
            guideRow(name: "Mark Flagged Files in Finder", desc: "Adds a red Finder tag to every file with line glitches.")
            guideRow(name: "Defaults", desc: "Set the Line Check defaults (target, sensitivity, options, edge depth) in User Settings; they apply each time QCpie opens.")
        }
    }
    
    private func guideRow(name: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.ui(size: 10, weight: .semibold))
                .foregroundColor(palette.textMain)
            Text(desc)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(palette.textSubtle)
                .lineSpacing(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioBox(background: palette.bgCardBody, border: palette.borderLine)
    }
}
