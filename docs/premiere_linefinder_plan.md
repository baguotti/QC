# LineFinder for Premiere Pro: Plan

Status: plan only, nothing implemented. Replaces the earlier Rust + FFmpeg plan (render to disk, decode again, four detectors), which did more work than needed.

## Goal

A Premiere Pro plugin for **macOS and Windows** that finds target-colour line glitches in a sequence and marks them on the timeline. Priorities: fast, snappy, as simple as possible. Lines only for v1.

## Core idea

Use Premiere's own export as the "prerender", but deliver each rendered frame to our analyser instead of to a video file: no temp media, no encode, no second decode. A scan is only as slow as Premiere rendering the sequence; with **Use Previews** on, already-rendered sections are nearly free.

## Architecture: two thin pieces + one shared detector

```
 UXP panel (JS, Mac + Win)                    Exporter plugin (C++, Mac + Win)
 ┌──────────────────────────┐   1. write       ┌─────────────────────────────────┐
 │ Colour · Sensitivity ·    │ ── settings.json →│ Export format "LineFinder        │
 │ In/Out or Whole · [SCAN]  │                  │ Analysis". Premiere renders each │
 │                           │  2. exportSequence│ frame (GPU, Use Previews) and    │
 │ Progress · Cancel         │ ───────────────→ │ hands us the pixels.             │
 │                           │                  │ linecore::scan(frame) per frame  │
 │ Results (click = jump)    │  3. results.json │                                  │
 │ [CLEAR MARKERS]           │ ←─────────────── │                                  │
 └───────────┬───────────────┘                  └─────────────────────────────────┘
             │ 4. one red marker per glitch segment (with duration)
             ▼
        Sequence markers
```

### 1. `linecore` (C++17, no dependencies)

- Port of QCpie's Line Finder v2: `Sources/VideoQCLib/EdgeDetector.swift` (blend model P ≈ α·T + (1−α)·R, contiguous runs, colour-residual rule, off-colour lines, split seams with coarse pre-check, letterbox handling, thick-line follow-up, frame-wide suppression) plus segment grouping and persistence gating from `DetectionModels.swift` / `VideoScanner.swift`. Keep the same thresholds; AGENTS.md §8d documents the rules.
- Interface: `scan(const uint8_t* bgra, int width, int height, int rowBytes, const Settings&) -> Detections`, plus a small `Segmenter` fed frame by frame.
- Tests: a standalone test executable using the same synthetic cases as `Tests/LineFinderScenes.swift` / `scripts/LineFinderBench`, plus PNG frames from real misses. Results must match QCpie's detector on the same frames, on both platforms.
- Budget: ≤ 1 ms of analysis per 1080p frame (QCpie measures ~0.1–1.3 ms incl. split seams), so Premiere's render is always the bottleneck.
- Later (optional, not v1): QCpie can call the same C++ via an SPM C target so both apps share one detector.

### 2. Exporter plugin (Premiere Pro C++ SDK)

- One source tree → `.bundle` (Mac) / `.prm` (Windows). Registers an export format "LineFinder Analysis", video only, 8-bit BGRA at sequence resolution.
- Reads `settings.json`, runs `linecore` on every frame Premiere renders, groups detections into segments, writes `results.json` (frame-accurate start/end, edge, thickness, colour, score). Writes no video.
- Install paths: Mac `/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/`, Windows `C:\Program Files\Adobe\Common\Plug-ins\7.0\MediaCore\`.

### 3. UXP panel (the only UI)

- Plain JS + Spectrum web components, no framework or bundler, ~300 lines.
- Controls: target colour (presets + hex), sensitivity, edges / edges + split seams, range (In/Out or whole sequence), Scan, Cancel, results list, Clear.
- Flow: write `settings.json` → `EncoderManager.exportSequence(sequence, ExportType.IMMEDIATELY, out, bundledPreset.epr, exportFull = !useInOut)` → progress from encoder events → read `results.json` → markers.
- Markers: **one red marker per segment**, with duration, name `LineFinder · Bottom · 2px`, details in the comment. Clicking a result moves the playhead. Clear removes only markers whose name starts with `LineFinder`.
- Time: frame index → sequence time from the In point and the sequence frame rate (ticks), never rounded seconds; check drop-frame.
- Shared folder for `settings.json` / `results.json`: per-user app data (`~/Library/Application Support/LineFinder`, `%APPDATA%\LineFinder`).

## Scope v1

In: four edges + optional split seams, In/Out or whole sequence, segment markers, clickable results.
Out (until v1 works): flash/duplicate/black frames (QCpie's Frame Check could be ported later), licensing, Adobe Exchange, a Premiere version older than the first with UXP generally available (25.x).

## Step 1: spike (2–3 days) before anything else

Build the minimum: an exporter that only counts frames and writes `{"frames": N}`, and a panel that runs it and drops one marker. Prove on **both** platforms:

| # | Must prove | Fallback |
|---|---|---|
| 1 | UXP can run `exportSequence` with a **third-party exporter preset**, honouring In/Out | Queue to Media Encoder, or document "Export → LineFinder Analysis" as a manual step |
| 2 | Exporter receives full-res BGRA frames at speed, with Use Previews | Request 32f frames and convert |
| 3 | UXP markers support name, colour, duration, comment | Marker at segment start, duration in the comment |
| 4 | Mac notarized `.bundle` loads in Premiere; Windows `.prm` loads | (signing work only) |

Record measured render + analysis speed for a 1080p and a 4K sequence.

## Phases after the spike

1. **`linecore` port + tests** (~1 week): match QCpie pass/fail on synthetic scenes and real frames; benchmark.
2. **Exporter** (~1 week): frame loop, settings in, results out, cancel; test 4K, odd frame rates, drop-frame, nested sequences, adjustment layers.
3. **Panel** (~1 week): UI, progress, markers, jump-to, Clear.
4. **Packaging** (2–3 days): one installer per OS placing exporter + panel (`.pkg` signed/notarized on Mac, Inno Setup `.exe` on Windows; a UXP package alone can't install a native exporter). CI builds both on a tag.

~3–4 weeks after the spike.

## Rules

- No intermediate media, no second decode, no per-frame allocations; analysis on the export thread.
- Shipped settings: colour, sensitivity, edges/splits, range. Everything else hard-coded to QCpie's tuned defaults.
- The detector lives in `linecore` only; panel and exporter contain no detection logic.

## Open decisions

1. Name: "LineFinder" or "LineFinder by QCpie".
2. Distribution v1: internal (unsigned Windows OK) or public (Apple Developer ID $99/yr; ideally a Windows code-signing certificate).
3. Split-seam scan on by default or opt-in (QCpie: opt-in).
