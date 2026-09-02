import SwiftUI

struct UserGuideView: View {
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    @State private var selectedGuideTab: Int = 0
    
    // Dynamic Studio Theme Palette
    private var bgMain: Color { isLightMode ? Color(white: 0.96) : Color(red: 0.04, green: 0.04, blue: 0.04) }
    private var bgPanel: Color { isLightMode ? Color.white : Color(red: 0.08, green: 0.08, blue: 0.08) }
    private var bgSubtle: Color { isLightMode ? Color(white: 0.92) : Color(white: 0.13) }
    private var bgCardBody: Color { isLightMode ? Color(white: 0.98) : Color(white: 0.06) }
    private var borderLine: Color { isLightMode ? Color(white: 0.82) : Color(white: 0.20) }
    private var borderStrong: Color { isLightMode ? Color(white: 0.60) : Color(white: 0.40) }
    private var textMain: Color { isLightMode ? Color(white: 0.06) : Color.white }
    private var textMuted: Color { isLightMode ? Color(white: 0.45) : Color(white: 0.45) }
    private var textSubtle: Color { isLightMode ? Color(white: 0.25) : Color(white: 0.70) }
    private var accentCyan: Color { isLightMode ? Color(red: 0.0, green: 0.45, blue: 0.80) : Color(red: 0.20, green: 0.80, blue: 1.0) }

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
                            .foregroundColor(accentCyan)
                        Text("USER GUIDE // THE LINEFINDER 5000")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(textMain)
                        
                        Link(destination: AppVersionInfo.commitURL) {
                            HStack(spacing: 4) {
                                Text("v\(AppVersionInfo.version)")
                                    .fontWeight(.heavy)
                                Text("(\(AppVersionInfo.gitCommit))")
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 8))
                            }
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(accentCyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(bgSubtle)
                            .border(borderLine, width: 1)
                        }
                        .buttonStyle(.plain)
                        .help("View commit on GitHub")
                    }
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Text("CLOSE (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
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
                    guideTabButton(title: "02 // DELIVERABLES SPECS", index: 1)
                    guideTabButton(title: "03 // BATCH RENAMER", index: 2)
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
                            tabOneGuide
                        case 1:
                            tabTwoGuide
                        default:
                            tabThreeGuide
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(isLightMode ? Color.black : Color.white)
                            .foregroundColor(isLightMode ? Color.white : Color.black)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(bgPanel)
            }
            .frame(minWidth: 800, maxWidth: 900, minHeight: 560, maxHeight: 680)
            .background(bgPanel)
            .border(borderStrong, width: 1)
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
                .background(isSel ? (isLightMode ? Color.white : Color(white: 0.22)) : Color.clear)
                .foregroundColor(isSel ? textMain : textMuted)
                .border(isSel ? borderStrong : Color.clear, width: 1)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Tab 1 Guide
    
    private var tabOneGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "[ + CHOOSE FOLDER / FILES ]", desc: "Selects or drags in video files or folders to scan.")
            guideRow(name: "TARGET COLOR & HEX", desc: "Sets the RGB target color for edge line detection.")
            guideRow(name: "COLOR PRESETS", desc: "Quick targets: Magenta (#FF00B4), Cyan (#00FFFF), Green (#00FF00), Red (#FF0000), White (#FFFFFF), Black (#000000).")
            guideRow(name: "TOLERANCE SLIDER", desc: "Threshold for color matching (0–100%). Default is 15%.")
            guideRow(name: "HEAD SKIP", desc: "Skips the first X seconds of video (ignores slates/countdowns).")
            guideRow(name: "EDGE DEPTH", desc: "Number of pixels inward from the frame edge to check (1–32px, default 12px).")
            guideRow(name: "TOP / BOTTOM / LEFT / RIGHT", desc: "Toggles which edges of the frame are inspected.")
            guideRow(name: "10X EXPOSURE BOOST", desc: "Brightens dark scenes during black line scans so shadows are not flagged.")
            guideRow(name: "IGNORE FULL BLACK FRAMES", desc: "Skips full black frames (fades, commercial breaks).")
            guideRow(name: "[ START QC SCAN ]", desc: "Starts frame-by-frame edge analysis.")
            guideRow(name: "FINDER RED TAGGING", desc: "Applies a native macOS Red Tag in Finder to any video with detected line errors.")
            guideRow(name: "GLITCH LIST & FRAME VIEWER", desc: "Click any detected glitch to view the exact frame, timecode, and a red box over the line.")
            guideRow(name: "SAVE HTML / EXPORT CSV", desc: "Exports scan results as an interactive HTML report or CSV table.")
        }
    }
    
    // MARK: - Tab 2 Guide
    
    private var tabTwoGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "[ + SELECT DELIVERY FOLDER / FILES ]", desc: "Loads files or folders to read metadata without decoding video frames.")
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
    
    // MARK: - Tab 3 Guide
    
    private var tabThreeGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            guideRow(name: "RENAMING MODES", desc: "Template (token-based), Find & Replace (text match), or Prefix / Suffix.")
            guideRow(name: "PROJECT / ASSET NAME {NAME}", desc: "Custom text to replace the {NAME} token. Defaults to original filename if blank.")
            guideRow(name: "TOKENS: {NAME}, {ORIGINAL}", desc: "{NAME} = Custom field value. {ORIGINAL} = Original filename without extension.")
            guideRow(name: "TOKENS: {DUR}, {RATIO}, {TAG}", desc: "{DUR} = Duration in seconds. {RATIO} = Ratio tag (16x9, 9x16). {TAG} = HORIZONTAL, VERTICAL, SQUARE.")
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
        .background(bgCardBody)
        .border(borderLine, width: 1)
    }
}
