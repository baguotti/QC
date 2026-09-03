# THE LINEFINDER 5000
**Version 0.1.1** • [GitHub Repository](https://github.com/baguotti/QC)

Video QC, metadata inspection, and batch renaming for macOS (Apple Silicon).

---

## 🚀 How to Install & Run

- **Disk Image Installer (.dmg):** Open [`build/THE_LINEFINDER_5000.dmg`](file:///Users/wildmacstudio25/Documents/QC/build/THE_LINEFINDER_5000.dmg) and drag `THE LINEFINDER 5000` to `/Applications`.
- **Standalone App (.app):** Open [`build/THE LINEFINDER 5000.app`](file:///Users/wildmacstudio25/Documents/QC/build/THE%20LINEFINDER%205000.app) directly.
- **Terminal Launcher:** Double-click [`Start_LineFinder.command`](file:///Users/wildmacstudio25/Documents/QC/Start_LineFinder.command).

---

## What Each Tab Does

### 01 // LINE SCANNER
Scans video frames for edge line glitches, matte slips, and blanking errors.
- **[ + CHOOSE FOLDER / FILES ]:** Selects or drags in video files or folders to scan.
- **Color Picker & Hex:** Sets the RGB target color for edge line detection.
- **Color Presets:** One-click targets: Magenta, Cyan, Green, Red, White, Black.
- **Tolerance Slider:** Sets color match threshold (0–100%).
- **Head Skip:** Skips the first X seconds of video (ignores slates/countdowns).
- **Edge Depth:** Number of pixels inward from frame edge to check (1–32px).
- **Top / Bottom / Left / Right:** Toggles which edges to inspect.
- **10X Exposure Boost:** Brightens shadows during black scans to prevent dark scenes from being flagged.
- **Ignore Full Black Frames:** Skips full black frames (fades, commercial breaks).
- **[ START QC SCAN ]:** Starts frame-by-frame analysis.
- **Finder Red Tagging:** Automatically applies a macOS Red Tag to flagged video files in Finder.
- **Glitch List & Frame Viewer:** Click any detected error to view the exact frame, timecode, and red bounding box.
- **Save HTML / Export CSV:** Exports scan results as an interactive HTML page or CSV table.

---

### 02 // DELIVERABLES SPECS
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

### 03 // BATCH RENAMER
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
