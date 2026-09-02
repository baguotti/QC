# Video QC (macOS Apple Silicon)

A fast, lightweight, native macOS application designed to quality-control online video deliveries frame-by-frame. It scans entire folders of videos (MP4, H.264, H.265/HEVC, ProRes 422/4444, MOV) for colored line glitches/matte errors along the edges and generates a clean, timecode-accurate text report.

---

## 🚀 How to Run

### Option 1: Direct Double-Click (Stand-alone App)
You can directly launch or copy the app bundle to `/Applications` or any other Apple Silicon Mac:
- Open [`build/VideoQC.app`](file:///Users/wildmacstudio25/Documents/QC/build/VideoQC.app)

### Option 2: Double-Click Launcher
- Double-click [`Start_QC.command`](file:///Users/wildmacstudio25/Documents/QC/Start_QC.command)

---

## ✨ Key Features
- **100% Native & Portable:** Built in Swift & SwiftUI using Apple's **AVFoundation** and hardware media engines. Requires **no Python, no Homebrew, no FFmpeg installs** — runs standalone on any Apple Silicon Mac.
- **Fast Frame-by-Frame Edge Inspection:** Scans only outer edge margins (Top, Bottom, Left, Right) with zero-copy hardware memory access.
- **Enhanced Black Line Detection:** Features 10x exposure boost multiplier, row uniformity variance checks, and full-black slate suppression.
- **Automatic Finder Red Tagging:** Flagged video files are automatically labeled with a **Red tag** in macOS Finder for instant visual identification.
- **User-Friendly HTML Report:** Generates a modern HTML report that groups glitches into continuous segments (Start TC $\rightarrow$ End TC, duration in frames/seconds, edge, thickness, color swatch).
- **Configurable Hex Color & Tolerance:** Enter any hex code (e.g. `#FF00B4`, `#000000`, `#00FF00`, `#00FFFF`) with live swatch preview.
- **Batch Processing:** Drop or select folders with up to 100+ delivery videos.

---

## 🔨 Rebuilding the Standalone App
To recompile the release bundle at any time:
```bash
./BuildApp.sh
```
This produces `build/VideoQC.app` (~700 KB).
