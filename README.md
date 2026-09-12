# QCPIE

**VERSION 0.7.2** | MACOS VIDEO QC, DUAL-SLOT COMPARISON & METADATA TOOLKIT

---

## OVERVIEW

QCpie (LineFinder 5000) is a high-performance native macOS application for video post-production teams, QC engineers, colorists, and delivery editors. It combines a frame-accurate dual-slot video viewport with automated edge glitch scanning, container metadata inspection, and batch renaming.

---

## CORE SYSTEM ARCHITECTURE

### 1. DUAL-SLOT DELIVERY VIEWPORT (TAB 01 // PLAYER)

#### DUAL-SLOT COMPOSITING ENGINE
- **Slot A & Slot B Architecture**: Load reference cuts, graded masters, or previous passes side-by-side or overlaid.
- **8 Comparison Modes**:
  - `Single (A)`: View Slot A or toggle to Slot B.
  - `Split Wipe (V)`: Interactive vertical split wipe divider.
  - `Split Wipe (H)`: Interactive horizontal split wipe divider.
  - `Side-by-Side (H)`: Horizontal side-by-side comparison of full master deliverables.
  - `Side-by-Side (V)`: Vertical side-by-side stacked comparison of full master deliverables.
  - `Difference Mode`: Absolute mathematical pixel difference (`|RGB_A - RGB_B|`).
  - `50% Opacity Overlay`: 50% opacity blend between Slot A and Slot B.
  - `Blink Compare`: Rapid toggle between Slot A and Slot B to spot single-frame discrepancies.

#### MOTION-DOWNSAMPLING IMMUNE VIEWPORT
- **Dedicated Still Frame Architecture**: Dual CALayers (`stillFrameLayerA` / `stillFrameLayerB`) backed by uncompressed `CGImage` GPU textures. Guarantees 100% immunity to CoreMedia dynamic proxy downsampling when panning, zooming, or stepping while paused.
- **Adaptive Texture Filtering**: Smooth `.linear` anti-aliasing at normal view scale; switches dynamically to discrete `.nearest` pixel rendering at >= 1.75x zoom for square-pixel QC inspection.

#### QC & EXPOSURE TOOLS
- **Exposure Control (-5.0 to +5.0 EV)**: GPU-accelerated exposure adjustment (`CIExposureAdjust`) to reveal faint black-level line glitches, dark shadow errors, or highlight clipping.
- **Dropped Frame Telemetry**: Real-time monitor tracking dropped frames during playback with automatic reset upon playback resume.
- **Center Crosshair Overlay**: Pixel-accurate guide reticle to verify element centering.

#### MULTI-PRESET SCREENSHOT EXPORT
- **Presets (100% Source Resolution)**:
  - `JPG Medium` (Default): Medium bitrate JPEG (~70% quality).
  - `JPG High`: High bitrate JPEG (~95% quality, near-lossless).
  - `PNG Medium`: 24-bit RGB with SUB compression filter for reduced file size without downscaling.
  - `PNG High`: 32-bit RGBA master uncompressed PNG.
- **Interaction**: Left-click exports directly using active preset. Right-click opens preset menu.
- **Compositing**: Full support for split wipes with line position, side-by-side, difference, and overlay modes. Pure video deliverable frames with zero UI labels or overlays.
- **Save Dialog**: Includes an accessory format popup in `NSSavePanel` for format switching.

#### FILE & QUEUE MANAGEMENT
- **Native Finder Tags**: Apply native macOS Finder color tags (Red, Orange, Yellow, Green, Blue, Purple, Gray) directly to files on disk.

---

### 2. DELIVERABLES & SPECIFICATIONS (TAB 02 // SPECS)

- **Container Metadata Inspection**: Reads video/audio stream parameters without decoding video frames.
- **Inspected Fields**: Resolution, aspect ratio, frame rate (up to 3 decimal places), duration, SMPTE timecode, video codec & profile, audio channel configuration, sample rate, and file size.
- **Mismatch Warnings**: Automatically flags files where filename tags (e.g. `16x9`, `1080p`, `25fps`) conflict with actual container stream metadata.
- **Manifest Export**: Export deliverables inventory as CSV, formatted HTML reports, or copy TSV directly to Google Sheets.

---

### 3. AUTOMATED LINE FINDER 5000 (TAB 03 // LINE FINDER)

- **Automated Glitch Detection**: Scans video frames for edge line glitches, green border lines, matte slips, and blanking errors.
- **Target Color Selection**: Pre-configured targets (#00FF00 green, #FF00B4 magenta, #000000 black) or custom hex color picking with adjustable match tolerance (5–50%).
- **Scan Parameters**:
  - `Edge Depth`: 2–40px inward inspection boundary across all 4 outer borders.
  - `Full Screen Scan`: Toggles full-frame inspection for internal split-screen divider lines and PIP seams.
  - `10X Exposure Boost`: Shadow brightening during black line scans to eliminate false positives in dark scenes.
  - `Ignore Full Black/White`: Skips commercial fades and white slates.
- **Glitch Navigation & Reports**: Frame viewer with timecode seeking and error bounding boxes (`N` key). Export scan results as interactive HTML or CSV reports.

---

### 4. BATCH RENAMER (TAB 04 // RENAMER)

- **Pattern Modes**: Template tokens, Find & Replace, and Prefix/Suffix appending.
- **Metadata Tokens**: `{NAME}`, `{ORIGINAL}`, `{DUR}`, `{RATIO}`, `{TAG}`, `{RES}`, `{DIMS}`, `{FPS}`, `{CODEC}`, `{AUDIO}`, `{INDEX}`, `{DATE}`.
- **Safety Checks**: Collision detection, name matching, and non-destructive disk operations with instant Undo/Revert.

---

## KEYBOARD SHORTCUTS

| KEYBOARD SHORTCUT | FUNCTION |
| :--- | :--- |
| `Spacebar` | Toggle Play / Pause |
| `J` / `K` / `L` | Shuttle Reverse (-1x to -16x) / Pause / Shuttle Forward (1x to 16x) |
| `Shift + J` / `Shift + L` | Slow Frame-by-Frame Shuttle (2 to 30 FPS) |
| `Left Arrow` / `Right Arrow` | Step 1 frame backward / forward |
| `Shift + Left` / `Shift + Right` | Jump 5 frames backward / forward |
| `Shift + I` / `Home` | Jump to start of clip (Frame 0) |
| `End` | Jump to end of clip |
| `N` | Jump to next detected line glitch |
| `I` | Cycle Clip Info overlay mode (Off, A/B Only, Resolution, File Name, Full Details) |
| `Cmd + L` | Toggle seamless looping |
| `F` / `Esc` | Toggle Review Fullscreen mode / Exit |
| `Scroll Wheel` | Canvas zoom in / out (10% to 400%) |
| `Trackpad Pinch` | Pinch-to-zoom |
| `Click + Drag` | Canvas pan (Hand tool) |

---

## BUILD & COMPILATION

### SYSTEM REQUIREMENTS
- macOS 14.0 or later
- Xcode 15+ / Swift 5.9+ toolchain

### BUILD COMMANDS

Debug Compilation:
```bash
swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

Application Bundle (.app):
```bash
./BuildApp.sh
```

Disk Image Installer (.dmg):
```bash
./CreateDMG.sh
```

---

## REPOSITORY

GitHub: [https://github.com/baguotti/QC](https://github.com/baguotti/QC)
