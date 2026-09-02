# THE LINEFINDER 5000 (macOS Apple Silicon)

A fast, lightweight, native macOS application designed to quality-control online video deliveries frame-by-frame. It scans entire folders of videos (MP4, H.264, H.265/HEVC, ProRes 422/4444, MOV) for colored line glitches/matte errors along the edges and generates a clean, timecode-accurate Swiss-styled HTML & TXT report.

---

## 🚀 How to Run

### Option 1: Direct Double-Click (Stand-alone App)
You can directly launch or copy the app bundle to `/Applications` or any other Apple Silicon Mac:
- Open [`build/THE LINEFINDER 5000.app`](file:///Users/wildmacstudio25/Documents/QC/build/THE%20LINEFINDER%205000.app)

### Option 2: Double-Click Launcher
- Double-click [`Start_LineFinder.command`](file:///Users/wildmacstudio25/Documents/QC/Start_LineFinder.command) or [`Start_QC.command`](file:///Users/wildmacstudio25/Documents/QC/Start_QC.command)

---

## ✨ Key Features
- **3-Tab Post-Production Suite:**
  - **Tab 1 (`01 // LINE SCANNER`):** Frame-by-frame edge artifact and colored matte line detection with automatic Finder Red Tagging.
  - **Tab 2 (`02 // DELIVERABLES SPECS`):** Instant metadata specification auditor that outputs exact durations, SMPTE timecodes, aspect ratios (16:9, 9:16, 4:5, 1:1), resolutions, frame rates, file sizes (MB/GB), video codecs (ProRes, H.264, HEVC), audio track configurations with bitrates, cross-reference name vs specs validation, and 1-click folder rescanning.
  - **Tab 3 (`03 // BATCH RENAMER`):** Granular token-based batch renaming engine that reads video stream metadata (`{NAME}`, `{DUR}sec`, `{RATIO}`, `{TAG}`, `{RES}`, `{FPS}`, `{CODEC}`, `{AUDIO}`, `{INDEX}`, `{DATE}`). Features live real-time diff preview, duplicate/collision safety protection, and 1-click atomic Undo/Revert.
- **Fast Frame-by-Frame Edge Inspection:** Scans only outer edge margins (Top, Bottom, Left, Right) with zero-copy hardware memory access.
- **Enhanced Black Line Detection:** Features 10x exposure boost multiplier, row uniformity variance checks, and full-black slate suppression.
- **Google Sheets & CSV Export:** Automatically generates clean `.csv` spreadsheet documents for both line glitch reports and deliverable specs.
- **User-Friendly HTML Report:** Interactive presentation with Dark & Light theme toggles and instant 1-click Google Sheets launcher.
- **Automatic Finder Red Tagging:** Flagged video files are automatically labeled with a **Red tag** in macOS Finder for instant visual identification.
- **Batch Processing:** Drop or select folders with up to 100+ delivery videos or individual video files.

---

## 🔨 Rebuilding the Standalone App
To recompile the release bundle at any time:
```bash
./BuildApp.sh
```
This produces `build/THE LINEFINDER 5000.app` (~700 KB).
