import SwiftUI

struct UserGuideView: View {
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @State private var selectedGuideTab: Int = 0
    
    // Dynamic Studio Theme Palette
    private var bgMain: Color { StudioTheme.bgMain(isLightMode) }
    private var bgPanel: Color { StudioTheme.bgPanel(isLightMode) }
    private var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    private var bgCardBody: Color { StudioTheme.bgCardSubtle(isLightMode) }
    private var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    private var borderStrong: Color { StudioTheme.borderStrong(isLightMode) }
    private var textMain: Color { StudioTheme.textMain(isLightMode) }
    private var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    private var textSubtle: Color { StudioTheme.textSubtle(isLightMode) }

    var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(0.65)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    isPresented = false
                }
            
            // Modal Container
            VStack(spacing: 0) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(textMain)
                        Text("USER GUIDE // QCpie")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(textMain)
                        
                        HStack(spacing: 4) {
                            Text("v\(AppVersionInfo.version)")
                                .fontWeight(.heavy)
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(textMain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Text("CLOSE (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(bgPanel)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Tabs
                HStack(spacing: 0) {
                    guideTabButton(title: "01 // LINE SCANNER", index: 0)
                    guideTabButton(title: "02 // PLAYER", index: 1)
                    guideTabButton(title: "03 // DELIVERABLES SPECS", index: 2)
                    guideTabButton(title: "04 // BATCH RENAMER", index: 3)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(bgSubtle)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Content
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        switch selectedGuideTab {
                        case 0:
                            lineScannerGuide
                        case 1:
                            playerGuide
                        case 2:
                            deliverablesGuide
                        default:
                            batchRenamerGuide
                        }
                    }
                    .padding(18)
                }
                .background(bgMain)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Footer
                HStack {
                    Text("PRESS ESC TO DISMISS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Text("DONE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .foregroundColor(isLightMode ? Color.white : Color.black)
                            .studioBox(background: isLightMode ? Color.black : Color.white, border: borderStrong)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(bgPanel)
            }
            .frame(minWidth: 800, maxWidth: 900, minHeight: 560, maxHeight: 680)
            .studioBox(background: bgPanel, border: borderStrong)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
        }
    }
    
    private func guideTabButton(title: String, index: Int) -> some View {
        let isSel = selectedGuideTab == index
        return Button(action: { selectedGuideTab = index }) {
            Text(title)
                .font(.system(size: 10, weight: isSel ? .black : .bold, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundColor(isSel ? textMain : textMuted)
                .studioBox(background: isSel ? (isLightMode ? Color.white : Color(white: 0.22)) : Color.clear, border: isSel ? borderStrong : Color.clear)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Tab 1 Guide // LINE SCANNER
    
    private var lineScannerGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "LOAD ASSETS (CHANGE / ADD)", desc: "Selects, changes, or adds video files or folders to the working batch without losing existing assets.")
            guideRow(name: "TARGET COLOR & HEX", desc: "Sets the RGB target color for edge line detection. Hex value can be inputted at any time.")
            guideRow(name: "COLOR PRESETS & CUSTOM WHEEL", desc: "Quick targets: Green (#00FF00, default), Magenta (#FF00B4), Black (#000000), or Custom Color Wheel / Swatch.")
            guideRow(name: "TOLERANCE SLIDER", desc: "Threshold for color matching (0–100%). Default is 15%.")
            guideRow(name: "HEAD SKIP", desc: "Skips the first X seconds of video (ignores slates/countdowns).")
            guideRow(name: "EDGE DEPTH", desc: "Number of pixels inward from the frame edge to check (default 12px). All 4 outer borders are always scanned.")
            guideRow(name: "SCAN FULL SCREEN", desc: "Scans the entire frame (not just borders) to detect internal seam lines from split screens and composites.")
            guideRow(name: "10X EXPOSURE BOOST", desc: "Brightens dark scenes during black line scans so shadows are not flagged.")
            guideRow(name: "IGNORE FULL BLACK FRAMES", desc: "Skips full black frames (fades, commercial breaks).")
            guideRow(name: "[ START QC SCAN ]", desc: "Starts frame-by-frame edge analysis.")
            guideRow(name: "FINDER RED TAGGING", desc: "Applies a native macOS Red Tag in Finder to any video with detected line errors.")
            guideRow(name: "GLITCH LIST & FRAME VIEWER", desc: "Click any detected glitch to view the exact frame, timecode, and a red box over the line.")
            guideRow(name: "SAVE HTML / EXPORT CSV", desc: "Exports scan results as an interactive HTML report or CSV table.")
        }
    }
    
    // MARK: - Tab 2 Guide // PLAYER
    
    private var playerGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "DUAL A/B & DIFFERENCE MODE", desc: "Option+Click any queue asset (or click +B) to load into Slot B. Compare using interactive Split Wipe (drag the tactile center handle), Side-by-Side (horizontal left/right or vertical stacked top/bottom), or GPU Difference Mode (|RGB_A - RGB_B|). Click [(TAB)] or press Tab for rapid flicker compare, X to Swap slots, C to cycle modes, and solo Slot A or B audio.")
            guideRow(name: "J-K-L SHUTTLE PLAYBACK", desc: "Tap L to play forward (1x, 2x, 4x, 8x, 16x). Tap K to pause. Tap J to play reverse (-1x, -2x, -4x, -8x, -16x).")
            guideRow(name: "SLOW FRAME-BY-FRAME (⇧ + L / ⇧ + J)", desc: "Plays automatically frame-by-frame. Pressing repeatedly accelerates playback speed (2, 4, 8, 15, 24, 30 FPS). Dedicated transport buttons are also available.")
            guideRow(name: "VIDEO FULLSCREEN (F / ESC)", desc: "Makes video completely full screen with zero UI. All keyboard shortcuts, zooming, and panning continue to work seamlessly. Double-click or press ESC to exit.")
            guideRow(name: "REVIEW FULLSCREEN (⇧ + F)", desc: "Expands player to full screen with an on-screen cinema review HUD, full timeline scrubber, dual-video comparison toolbar, and transport controls that auto-hide when idle.")
            guideRow(name: "SPACEBAR", desc: "Quick toggle between normal 1x Play and Pause.")
            guideRow(name: "SINGLE FRAME STEPPING (← / →)", desc: "Left and right arrow keys step exactly 1 frame backward or forward.")
            guideRow(name: "SECOND JUMP (⇧ + ← / →)", desc: "Shift + Left/Right arrow jumps 1 second backward or forward.")
            guideRow(name: "HOME / END", desc: "Home key jumps directly to the first frame. End key jumps to the last frame.")
            guideRow(name: "TIMELINE SCRUBBING", desc: "Drag the playhead or click anywhere on the SMPTE ruler to scrub frame-accurately.")
            guideRow(name: "SCROLL ZOOM & HAND-PAN", desc: "Scroll your mouse wheel up or down directly to zoom into or out of the canvas (10% to 400%). Pinch on trackpad to zoom. Click and drag across the canvas with the hand tool to pan around.")
            guideRow(name: "QUEUE NAVIGATION (↑ / ↓)", desc: "Up and down arrow keys navigate through the asset queue on the left, automatically loading each deliverable into the player.")
            guideRow(name: "CENTER CROSSHAIR OVERLAY", desc: "Toggles top-to-bottom and left-to-right crosshair guide lines with a center precision reticle to inspect if elements, logos, and lower-thirds are perfectly centered.")
            guideRow(name: "JUMP TO NEXT LINE (N / NEXT LINE)", desc: "Cycles through all detected line glitches across all deliverables from Tab 1, seeking frame-accurately and pausing playback for inspection.")
            guideRow(name: "MACOS FINDER COLOR TAGS", desc: "Tag the active file with native macOS Finder color tags (Red, Orange, Yellow, Green, Blue, Purple, Gray) via the [TAGS] button or by right-clicking on any asset in the queue.")
            guideRow(name: "FRAME SCREENSHOT (CAMERA ICON)", desc: "Click the square camera button in the transport bar to export the current video frame as a medium-quality JPEG to any folder.")
            guideRow(name: "SEAMLESS LOOP (⌘L)", desc: "Toggles automatic looping. Reaching the end seamlessly restarts from the beginning without stopping.")
            guideRow(name: "AUDIO & MUTE", desc: "Master playback volume slider and instant audio mute button.")
        }
    }
    
    // MARK: - Tab 3 Guide // DELIVERABLES SPECS
    
    private var deliverablesGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "LOAD ASSETS (01)", desc: "Loads files or folders to read metadata without decoding video frames.")
            guideRow(name: "FILE NAME", desc: "Name of the file.")
            guideRow(name: "RESOLUTION & ASPECT RATIO", desc: "Pixel dimensions (e.g. 1920x1080) and ratio (16:9, 9:16, 1:1, 4:5).")
            guideRow(name: "DURATION & TIMECODE", desc: "Total seconds and exact SMPTE timecode (HH:MM:SS:FF).")
            guideRow(name: "FPS", desc: "Video track frame rate.")
            guideRow(name: "VIDEO CODEC", desc: "Compression format (ProRes, H.264, HEVC) and profile.")
            guideRow(name: "AUDIO CONFIGURATION", desc: "Channel layout (Stereo, 5.1, Mono), sample rate, and bit depth.")
            guideRow(name: "FILE SIZE", desc: "File size in MB or GB.")
            guideRow(name: "MISMATCH WARNINGS", desc: "Highlights files where filename tags (e.g. 16x9, 1080p, 15s) conflict with actual stream metadata.")
            guideRow(name: "[ EXPORT CSV ]", desc: "Exports the metadata table to a CSV file.")
            guideRow(name: "[ OPEN IN GOOGLE SHEETS ]", desc: "Copies data to clipboard and opens Google Sheets in your browser.")
            guideRow(name: "[ EXPORT HTML SPECS SHEET ]", desc: "Exports a styled HTML specs sheet.")
        }
    }
    
    // MARK: - Tab 4 Guide // BATCH RENAMER
    
    private var batchRenamerGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "RENAMING MODES", desc: "Template (token-based), Find & Replace (text match), or Prefix / Suffix.")
            guideRow(name: "PROJECT / ASSET NAME {NAME}", desc: "Custom text to replace the {NAME} token. Defaults to original filename if blank.")
            guideRow(name: "TOKENS: {NAME}, {ORIGINAL}", desc: "{NAME} = Custom field value. {ORIGINAL} = Original filename without extension.")
            guideRow(name: "TOKENS: {DUR}, {RATIO}, {TAG1-3}", desc: "{DUR} = Duration in seconds. {RATIO} = Ratio tag (16x9, 9x16). {TAG1}, {TAG2}, {TAG3} = Custom tags (empty by default, automatically added when filled).")
            guideRow(name: "TOKENS: {RES}, {DIMS}, {FPS}", desc: "{RES} = 1080p/4K. {DIMS} = 1920x1080. {FPS} = Frame rate (e.g. 25fps).")
            guideRow(name: "TOKENS: {CODEC}, {AUDIO}", desc: "{CODEC} = Video codec (e.g. ProRes422HQ). {AUDIO} = Audio channels (Stereo, 5.1).")
            guideRow(name: "TOKENS: {INDEX}, {DATE}", desc: "{INDEX} = Sequential counter (01, 02). {DATE} = Current date (YYYYMMDD).")
            guideRow(name: "CASING", desc: "Preserve, UPPERCASE, lowercase, or Capitalize.")
            guideRow(name: "INDEX SETTINGS", desc: "Sets start number and digit padding (e.g. 01 vs 001).")
            guideRow(name: "SELECT ALL / DESELECT ALL", desc: "Toggles selection for all files.")
            guideRow(name: "ROW CLICK / CHECKBOXES", desc: "Click any row to include or exclude a file. Excluded files are not renamed on disk.")
            guideRow(name: "STATUS BADGES", desc: "PENDING (ready), UNCHANGED (same name), EXCLUDED (skipped), COLLISION (duplicate name), OVERWRITE (file exists on disk).")
            guideRow(name: "[ RENAME SELECTED FILE(S) ]", desc: "Renames selected files on disk.")
            guideRow(name: "[ ⎌ UNDO / REVERT ]", desc: "Reverses the last rename operation on disk.")
        }
    }
    
    private func guideRow(name: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(textMain)
            Text(desc)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(textSubtle)
                .lineSpacing(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioBox(background: bgCardBody, border: borderLine)
    }
}
