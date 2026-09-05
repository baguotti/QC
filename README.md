# QCpie
**Version 0.2.2** • [GitHub Repository](https://github.com/baguotti/QC)

Video QC, metadata inspection, and batch renaming for macOS (Apple Silicon).

---

## 🚀 How to Install & Run

- **Disk Image Installer (.dmg):** Open `build/QCpie.dmg` and drag `QCpie` to `/Applications`.
- **Standalone App (.app):** Open `build/QCpie.app` directly.
- **Terminal Launcher:** Double-click `Start_QCpie.command`.

---

## What Each Tab Does

### 01 // LINE SCANNER
Scans video frames for edge line glitches, matte slips, and blanking errors.
- **[ + CHOOSE FOLDER / FILES ]:** Selects or drags in video files or folders to scan.
- **Color Picker & Hex:** Sets the RGB target color for edge line detection.
- **Color Presets:** One-click targets: Green (#00FF00), Magenta (#FF00B4), Black (#000000), or Custom Color Wheel.
- **Tolerance Slider:** Sets color match sensitivity (5–50%).
- **Head Skip:** Skips the first X seconds of video (ignores slates/countdowns).
- **Edge Depth:** Number of pixels inward from outer frame boundary to inspect (2–40px). All 4 borders are always scanned.
- **Scan Full Screen:** Toggles full-frame inspection for internal split-screen dividing lines and PIP seams.
- **10X Exposure Boost:** Brightens shadows during black scans to prevent dark scenes from being flagged.
- **Ignore Full Black Frames:** Skips full black frames (fades, commercial breaks).
- **[ START QC SCAN ]:** Starts frame-by-frame analysis.
- **Finder Red Tagging:** Automatically applies a macOS Red Tag to flagged video files in Finder.
- **Glitch List & Frame Viewer:** Click any detected error to view the exact frame, timecode, and red bounding box.
- **Save HTML / Export CSV:** Exports scan results as an interactive HTML page or CSV table.

---

### 02 // PLAYER
High-performance delivery playback and inspection engine mimicking Adobe Premiere Pro's Program Monitor.
- **[ + SELECT FILES OR FOLDER ] / Queue:** Left sidebar displays all video files in batch with instant switching and name filtering.
- **Queue Navigation:** Press `Up Arrow` (↑) and `Down Arrow` (↓) to quickly cycle through all deliverables in the queue, automatically loading each into the player.
- **Jump to Next Line Finding (`NEXT LINE` or `N`):** Automatically cycles through all line glitches detected in Tab 1 across all deliverables, seeking frame-accurately and pausing playback for inspection.
- **Native macOS Finder Color Tags (`TAGS` / Right-Click):** Tag any deliverable with native macOS Finder color tags (Red, Orange, Yellow, Green, Blue, Purple, Gray) via the `[ TAGS ]` popover in the transport bar or by right-clicking on any asset in the queue. Tags are applied directly to files on disk in macOS Finder.
- **Center Crosshair Overlay:** Toggle button (`CROSSHAIR: ON/OFF`) draws a pixel-accurate top-to-bottom and left-to-right crosshair guide with a center reticle to verify element centering.
- **J-K-L Shuttling:** Tap `L` to shuttle forward (1x, 2x, 4x, 8x, 16x), `K` to pause, `J` to shuttle reverse (-1x, -2x, -4x, -8x, -16x).
- **Slow Frame-by-Frame Automatic Shuttle:** Tap `Shift + L` (forward) or `Shift + J` (reverse) or use the dedicated UI buttons. Tapping repeatedly accelerates frame-by-frame playback speed (2, 4, 8, 15, 24, 30 FPS).
- **Spacebar:** Toggles 1x playback and pause.
- **Single Frame Stepping:** Left / Right arrow keys step exactly 1 frame backward / forward.
- **Second Stepping:** Shift + Left / Right arrow jumps 1 second.
- **Home / End:** Jumps instantly to the first frame or last frame.
- **Timeline Scrubber:** Frame-accurate time ruler with playhead needle and click-to-seek.
- **Canvas Zoom & Pan:** Scroll mouse wheel directly up/down to zoom in/out (from 10% to 400%). Pinch-to-zoom on trackpad. Click and drag with the hand tool to pan anywhere on the canvas at any zoom level.
- **Seamless Loop:** Toggle button (`Loop ON/OFF` or `⌘L`) for continuous looping.
- **Audio Monitoring:** Master volume slider and instant audio mute toggle.

---

### 03 // DELIVERABLES SPECS
Reads container metadata across multiple files without decoding video frames.
- **[ + SELECT DELIVERY FOLDER / FILES ]:** Loads files or folders for inspection.
- **File Name:** Name of the file.
- **Resolution & Aspect Ratio:** Pixel dimensions (e.g. 1920x1080) and ratio (16:9, 9:16, 1:1, 4:5).
- **Duration & Timecode:** Total duration in seconds and SMPTE timecode (HH:MM:SS:FF).
- **FPS:** Video track frame rate.
- **Video Codec:** Compression format (ProRes, H.264, HEVC) and profile.
- **Audio Configuration:** Channel layout (Stereo, 5.1, Mono), sample rate, and bit depth.
- **File Size:** File size in MB or GB.
- **Mismatch Warnings:** Highlights files where filename tags (e.g. 16x9, 1080p, 15s) conflict with actual stream metadata.
- **[ EXPORT CSV ]:** Exports the specs table to a CSV file.
- **[ OPEN IN GOOGLE SHEETS ]:** Copies tab-separated data to clipboard and opens Google Sheets.
- **[ EXPORT HTML SPECS SHEET ]:** Exports a styled HTML report.

---

### 04 // BATCH RENAMER
Renames files using inspected video metadata.
- **Renaming Modes:**
  - **Template:** Builds new names using text and metadata tokens.
  - **Find & Replace:** Finds and replaces text in filenames.
  - **Prefix / Suffix:** Adds text to the start or end of filenames.
- **Project / Asset Name ({NAME}):** Text field to replace the `{NAME}` token. Defaults to original filename if left blank.
- **Metadata Tokens:**
  - `{NAME}`: Value from the Project Name field.
  - `{ORIGINAL}`: Original filename without extension.
  - `{DUR}`: Duration rounded to integer seconds.
  - `{RATIO}`: Aspect ratio tag (16x9, 9x16, 1x1, 4x5).
  - `{TAG}`: Orientation tag (HORIZONTAL, VERTICAL, SQUARE).
  - `{RES}`: Resolution label (1080p, 4K, 720p).
  - `{DIMS}`: Exact pixel dimensions (e.g. 1920x1080).
  - `{FPS}`: Frame rate label (e.g. 25fps).
  - `{CODEC}`: Video codec name (e.g. ProRes422HQ, H264).
  - `{AUDIO}`: Audio layout (Stereo, 5.1, Mono).
  - `{INDEX}`: Sequential counter with custom padding.
  - `{DATE}`: Current date in YYYYMMDD format.
- **Casing:** Sets name to Preserve, UPPERCASE, lowercase, or Title Case.
- **Index Settings:** Configures start number and digit padding (01 vs 001).
- **Select All / Deselect All:** Toggles selection for all files.
- **File Checkboxes:** Click any row to include or exclude a file. Excluded files are not renamed on disk.
- **Status Badges:**
  - `PENDING`: Ready to rename.
  - `UNCHANGED`: New name matches current name.
  - `EXCLUDED`: File bypassed by user.
  - `COLLISION`: Warning: Multiple files would share the same name.
  - `OVERWRITE`: Warning: Target name already exists on disk.
- **[ RENAME SELECTED FILE(S) ]:** Executes renaming on disk.
- **[ ⎌ UNDO / REVERT ]:** Reverses the last rename operation on disk.

---

## 🔨 Rebuild & Package
- **Compile Application (.app):**
  ```bash
  ./BuildApp.sh
  ```
- **Create Installer Disk Image (.dmg):**
  ```bash
  ./CreateDMG.sh
  ```
