# QCpie — Changelog & Refactoring Report
> **Changes from v0.7.0 to v0.7.8**

---

## 📌 Release Summary

| Version | Release Focus | Key Highlights |
| :--- | :--- | :--- |
| **v0.7.0** | UI Scaling & macOS Integration | Added "Open with QCpie" system integration, canvas resolution overlays, and UI zoom system. |
| **v0.7.1** | Clip Info Overhaul & Dual Navigation | 5 cyclic Clip Info modes, `Option + Up/Down` for Slot B queue selection, comparison mode state preservation. |
| **v0.7.2** | Architectural Modularization & Automated Testing | Extracted `ScannerState`, `SpecsState`, `KeyboardShortcutRouter`, split `PlayerTabView`, and added native `Swift Testing` test suite. |
| **v0.7.3** | Footage Ingest Tab, DIT Audit & Media Inspector | Added Tab 04 // `INGEST`, DIT CSV/TSV/ALE cross-referencing, lightweight `IngestInspector`, bounded 4-worker scan concurrency, and multi-preset screenshot exporter. |
| **v0.7.4** | Custom Accent Themes & Preset Persistence | Custom per-slot accent color pickers (native `ColorPicker` + direct `#RRGGBB` hex fields), saved user presets (capped at 10 total), and 22 automated tests. |
| **v0.7.5** | Line Audit Preserves Cancellation, Finder Tag Toggle, Specs Mismatch Dismiss, TB Size Formatting & DIT RTF/Text Parsing | Preserves scanned results on cancel in Line Audit, toggle for Finder red tagging (default off), dismiss/restore mismatch flags in Specs, format sizes in TB, and support `.rtf` / `.txt` / `.log` / `.md` DIT reports. |
| **v0.7.6** | Note Link Path Parsing, Minimal Speech Bubble Icon & Per-Clip Clear All Markers | Fix unquoted paths with spaces/hyphens, URLComponents path encoding, minimal `bubble.left.fill` icon matching playhead color, per-clip Clear All Markers with confirmation alert. |
| **v0.7.7** | Dynamic Thumbnail Sizing (+/-), Smooth List/Thumb Transitions, Player Tab Play Icon & Hardened Overlay Typography | Added `+`/`-` shortcuts for dynamic thumbnail scaling, seamless List View / Thumbnail mode threshold transitions, custom Play icon on PLAYER tab, 3-line consistent clip info layout, collision-free slot label width clamping, and dynamic side-by-side vertical spacing. |
| **v0.7.8** | Queue Notes Notification Badge & Playhead Theme Alignment | Dynamic queue notes notification badge styling aligned with theme playhead color. |

---

## 🚀 1. Feature Overhauls & User Experience Enhancements

### 📦 Footage Ingest & DIT Audit System (Tab 04 // INGEST)
- **Automated Directory Intake**: Point to any shoot or delivery folder to catalog all files recursively with bounded parallel concurrency (max 4 concurrent tasks).
- **Heuristic File Classification**: Automatically categorizes files into Raw Footage, Transcodes (detects `TRANSCODES` or `PROXY` folder/name conventions), Camera Reports, Location Audio, Shooting LUTs, and Other.
- **Automated Technical Details Aggregation**: Extracts dominant raw codecs, transcode codecs, shooting resolutions, main project timebase, and camera make/model from container atoms.
- **DIT Report Cross-Referencing**: Imports CSV, TSV, or ALE reports from DITs and flags discrepancies:
  - `Missing From Disk` (critical): Clips documented in DIT report but absent on storage.
  - `Not Listed in DIT Report` (info): Clips found on disk but missing from DIT documentation.
  - `FPS Mismatch`, `Resolution Mismatch`, `Codec Discrepancy` (warning): Container parameter differences.
- **Production Intake Form**: Interactive checklist matching industry-standard intake forms (job numbers, client drives status, VFX flags, HD source return notes).
- **Manifest Exports**: Exports complete intake manifests as RFC 4180 CSV, styled HTML reports, or clipboard summaries.

### 📸 Multi-Preset Screenshot Exporter
- **4 Presets at 100% Source Resolution**:
  - `JPG Medium` (Default): Medium bitrate JPEG (~70% quality).
  - `JPG High`: High bitrate JPEG (~95% quality, near-lossless).
  - `PNG Medium`: 24-bit RGB with SUB compression filter for reduced file size without downscaling.
  - `PNG High`: 32-bit RGBA master uncompressed PNG.
- **Workflow Gestures**: Left-click exports directly using active preset; right-click opens preset menu.
- **Pristine Export**: Pure deliverable frames with full comparison mode compositing (split wipes, side-by-side, difference, 50% overlay) and zero UI labels.

### 🎨 Clip Info Overlay System Overhaul
- **5 Cyclic Display Modes**: Pressing `I` or clicking the transport aperture cycles through:
  1. `Resolution`: Shows deliverable dimensions (e.g. `1920x1080 25fps`).
  2. `File Name`: Shows target file name cleanly.
  3. `Full Info`: Displays resolution, FPS, codec, aspect ratio, and filename.
  4. `Off`: Completely hides overlay labels.
  5. `A / B`: Shows slot badge indicators (`Slot A` / `Slot B`).
- **GPU Still-Frame Presentation**: Overlays render cleanly on `stillFrameLayer` backed by uncompressed `CGImage` contents, eliminating viewport layout shifts and keeping 100% immunity to CoreMedia dynamic proxy downsampling.
- **Unified Split Labels**: Aligned split wipe divider labels and side-by-side mode headers.

### ⌨️ Dual-Slot Queue Navigation
- **Slot B Shortcuts**: `Option + Up Arrow` and `Option + Down Arrow` cycle the active deliverable in **Slot B** directly from the queue, mirroring `Up / Down` for Slot A.
- **State Preservation**: Loading a new video into Slot B while already comparing deliverables preserves the current comparison mode (e.g., Split, Side-by-Side, Overlay) instead of resetting to single view.

### 🖼️ Viewport Scaling & Layout Fixes
- Fixed native side-by-side scaling discrepancies so both slots maintain exact aspect ratio geometry without letterboxing or pillarboxing artifacts.
- Polished settings popover button hover states and button zoom alignments.

---

## 🏗️ 2. Architectural Refactoring & Modularization

```
                  ┌─────────────────────────────────────────────────────────┐
                  │                       ContentView                       │
                  └──────┬────────────────────┬────────────────────┬────────┘
                         │                    │                    │
         ┌───────────────┴──────────┐ ┌───────┴──────────┐ ┌───────┴──────────┐
         │       ScannerState       │ │    SpecsState    │ │   IngestState    │
         │ (18 line-finder states)  │ │   (Deliverables) │ │ (Intake & DIT)   │
         └──────────────────────────┘ └──────────────────┘ └──────────────────┘
                         │                    │                    │
         ┌───────────────┴──────────┐ ┌───────┴──────────┐ ┌───────┴──────────┐
         │  KeyboardShortcutRouter  │ │PlayerQueuePan... │ │ IngestInspector  │
         │  (51 declarative rules)  │ │ (Equatable view) │ │(No sample decode)│
         └──────────────────────────┘ └──────────────────┘ └──────────────────┘
```

### Dedicated Ingest State & Lightweight Inspector
- **[`IngestInspector.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCLib/IngestInspector.swift)**: Dedicated container-level header inspector that extracts video codec, dimensions, framerate, duration, timecode, audio tracks, and camera metadata without decoding audio samples.
- **[`IngestState.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/IngestState.swift)**: State controller with bounded concurrency (max 4 workers), non-isolated background file enumeration, and task cancellation on re-scan.
- **[`IngestTabView.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/IngestTabView.swift)**: High-performance stark B&W interface with collapsible discrepancy banner and sortable file table.

### Memory & Concurrency Hardening
- **Scoped Pointer Safety**: Scoped `withMemoryRebound` safely inside closure execution in `DeliverablesInspector.swift`.
- **Clamped Conversions**: Clamped duration, framerate, and dimension calculations against NaN, infinity, and integer overflow.
- **Safe Metadata Extraction**: Replaced raw string loading with `.load(.value) as? String` to prevent crashes on binary camera atoms.

---

## 🧪 3. Automated Test Infrastructure

- Integrated Apple's native **Swift Testing** framework (`import Testing`).
- **17 automated unit tests** across 2 test suites:
  - **`PlayerEngineTests.swift`** (10 tests): State invariants, slot swapping, dropped frames tracking, aspect ratio enforcement, compare mode persistence.
  - **`IngestTests.swift`** (7 tests): CSV/TSV DIT parsing, discrepancy cross-referencing, manifest CSV/HTML report generation, corrupt/missing media resilience, and sorting safety.
- **Execution speed**: All 17 tests execute in **~0.04 seconds**.

---

## 📊 Summary Metrics

| Metric | Before (v0.7.0) | After (v0.7.3) | Change |
| :--- | :--- | :--- | :--- |
| `ContentView.swift` Lines | ~2,365 | ~1,110 | **-53%** |
| `PlayerTabView.swift` Lines | ~2,830 | ~1,402 | **-50%** |
| New Modular Components | 0 | 9 new files | **+9 components** |
| Automated Unit Tests | 0 | 17 tests | **17 tests (100% pass)** |
| Swift 6 Concurrency Warnings | 0 | 0 | **0 warnings** |
