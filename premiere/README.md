# LineFinder for Premiere Pro

Plan: [PLAN.md](PLAN.md). Three pieces: `panel/` (UXP, the only UI),
`exporter/` (Premiere C++ exporter that receives rendered frames) and `linecore/` (QCpie's detector in C++).

## Load the panel

1. `exporter/build.sh install` (Premiere Pro C++ SDK in `PREMIERE_SDK`, default `~/Downloads/Premiere Pro 27.0 C++ SDK`),
   then restart Premiere Pro (exporters load at launch).
2. UXP Developer Tool → Add Plugin → `premiere/panel/manifest.json` → Load (Premiere Pro 25.6+).
3. Window → UXP Plugins → LineFinder. Pick the colour, set In/Out (or untick it), Scan.

`panel/presets/LineFinder.epr` was saved once from Export Settings with the LineFinder Analysis format (`DoMetadata` set
to false by hand so no `.xmp` sidecar is written). The exporter ignores its size/rate and renders at the sequence's own.

## Mac installer (`package/build_mac.sh`)

Builds, in `package/dist/` (git-ignored): `LineFinder-<panel version>.pkg`, `LineFinder-<panel version>.dmg` (the .pkg
and a link to System Settings → Privacy & Security, for first installs: macOS blocks the unsigned .pkg until Open
Anyway), `LineFinder-<panel version>.ccx` (the panel
alone) and `LineFinderAnalysis-<exporter/VERSION>.zip` (the exporter alone, stored without compression). The .pkg
installs the exporter into `/Library/Application Support/Adobe/Common/Plug-ins/7.0/MediaCore/LineFinder/` and makes that
folder the logged-in user's (so the panel can update it without a password), removes a loose
`MediaCore/LineFinderAnalysis.bundle` from 0.0.5 and older, and puts `LineFinder.ccx` plus `uninstall.sh` into
`/Library/Application Support/LineFinder/`; its postinstall installs the .ccx for the logged-in user with Adobe's
Unified Plugin Installer Agent (UXP plugins are per user: `~/Library/Application Support/Adobe/UXP/Plugins/External/`).
Without Creative Cloud's agent, double-clicking the .ccx installs the panel. Remove with
`sudo "/Library/Application Support/LineFinder/uninstall.sh"`.

- Premiere loads plug-ins only from `/Library/…/MediaCore` (and its subfolders) and its own app bundle, not from
  `~/Library` (its `Plugin Loading.log` lists the folders it scans): hence the user-owned subfolder.
- **Releasing:** every QCpie release attaches all four files (`scripts/Release.sh publish` does, and stops if one is
  missing). A new plugin version: bump `panel/manifest.json` (and `exporter/VERSION` when the exporter changed), run
  `build_mac.sh`. QCpie's gear menu → LineFinder for Premiere Pro opens `releases/latest` (`AppConfig.latestReleaseWebURL`).
- The .ccx manifest needs `host` as an object: as an array the agent fails with status -267 ("failed to generate mxi").
- Unsigned unless `DEVELOPER_ID_APP`, `DEVELOPER_ID_INSTALLER` and `NOTARY_PROFILE` are set (Apple Developer ID,
  $99/yr): other Macs then need right-click → Open or System Settings → Privacy & Security → Open Anyway.
- The panel id is `com.qcpie.linefinder` (development used `com.qcpie.linefinder.spike`): unload the UXP Developer
  Tool copy so Premiere doesn't show two LineFinder panels.

## Panel ↔ exporter

- The panel writes `scan.settings.json` (target, anyColor, sensitivity, splits) in its data folder and calls
  `exportSequence(seq, IMMEDIATELY, <data>/scan.json, LineFinder.epr, exportFull = no In/Out)`.
- The exporter runs linecore on every frame (PPix rows are bottom-up: it passes the top row with a negative stride),
  writes `scan.progress` while running and `scan.json` at the end: frames, timing, `startTicks` / `endTicks` /
  `ticksPerFrame` and segments (frames from the export start, end inclusive).
- The panel removes older LineFinder markers in the scanned range, adds one marker per segment (red; off-colour lines
  orange; duration = the segment), lists them (click = move the playhead) and Clear removes every LineFinder marker.
- `panel-log.txt` in the data folder has the last scan's log.
- **Not a Line** (× on a result row): stored per sequence guid in the panel's `localStorage` as edge + tick range; that
  marker and row go at once, and later scans hide findings on the same edge overlapping it within 2 frames (QCpie's
  rule). **Restore N** (next to Clear Markers) brings them all back for the listed sequence.

## Updates

- Each time the panel opens it reads the 10 newest QCpie releases and uses the highest
  `LineFinder-<version>.pkg` among them (GitHub's list isn't strictly newest first) (a release without it no longer hides an update). Nothing is cached (a remembered
  answer hid a release published minutes later; one request per open is within GitHub's 60 an hour per address). The footer shows the installed panel and
  exporter versions.
- **Update in the panel** (no Installer, no password), when the exporter folder is the user's (installed by 0.0.6+):
  a newer exporter (`LineFinderAnalysis-<v>.zip` against the installed bundle's `CFBundleShortVersionString`) is
  unzipped to `MediaCore/LineFinder/LineFinderAnalysis.new`, the running bundle is renamed `LineFinderAnalysis.old`
  (Premiere keeps using it until it quits; deleted on the next panel open) and the new one takes its name: restart
  Premiere. A newer panel is the `.ccx`, handed to Creative Cloud (`shell.openPath`, one confirmation).
  Needs `localFileSystem: fullAccess` and `launchProcess` for `.ccx`.
- **The .pkg** is the fallback: first install, the old root-owned layout, a release without the .ccx/.zip, or any
  failure in the panel. Installer pages: Continue → Install → password → Close.
- Tested here: a bundle written without the executable bit loads (`CFBundleLoadExecutable`, `dlopen`) and keeps a
  valid signature; Premiere doesn't quarantine files it writes. The unzip and swap run against a mock of the UXP
  file API in Node. Not yet tested inside Premiere: `getEntryWithUrl` on `/Library` paths and `moveTo` on folders.
- 0.0.3 and older have no updater: install 0.0.4 once by hand.

## Exporter (`exporter/LineFinderExporter.cpp`)

- Registers the export format "LineFinder Analysis" (`.json`, video only). `DoMultiPassExportLoop` (Exporter Utility
  Suite) renders the range and pushes each distinct frame (thread-safe callback: detectors come from a pool) as
  `BGRA_4444_8u` in RAM, with a repeat count for held frames (analysed once, recorded on every frame).

## linecore (`linecore/`)

- Port of Line Finder v2 (`EdgeDetector.swift`) plus persistence gating and segment grouping (`LineHysteresis`,
  `VideoQCResult` segments) in C++17 behind a C API (`include/linecore.h`): `lc_detector_scan` per frame,
  `lc_segmenter_add` / `lc_segmenter_finish` per scan. No allocations per frame once warmed up; one detector per thread.
- Must be built with FP contraction off (`-ffp-contract=off`, MSVC `/fp:precise`): the arithmetic mirrors the Swift order.
- **Parity**: `linecore/tests/run.sh` runs the Swift detector and linecore on the same frames and requires identical
  detections (bit-equal scores) and segments: the synthetic scenes × 4 setting variants, a padded buffer, then every
  frame of `_TEST` (files < 500 MB; `--all` for the rest) for green, black, white and green + split seams. Run it after
  any change to either detector. 2026-11-02: 35,089 comparisons, 37 segments, ALL PASSED.
- 1080p cost (M-series, one thread): edges 0.21 ms (Swift 0.33), edges + seams 1.90 ms (2.08), any colour 0.29 ms (1.34).

## Test clips (`testclips/make.sh`)

Renders `LineFinder_Test_1080p.mp4` (60 s) and `LineFinder_Test_4K.mp4` (26 s), 23.976 fps H.264 4:2:0 (git-ignored),
green lines at known frames: top 48–95 (1 px), bottom 144–191 (2 px), left 240–287 (1 px), right 336–383 (3 px),
seam H 432–479 (row 540), seam V 528–575 (column 960); 4K doubles positions and thicknesses. QCpie's detector and
linecore find every one on exactly those frames (`linecore/tests/run.sh premiere/testclips --segments`); the black
target reports the green lines as off-colour only.

History: the 1080p right line was first found only on 342–375, 379–381 and 383. AVFoundation smears a 3 px line at an
odd column into a 4th, half off-colour column, which the step test read as a gradient; fixed by counting off-colour
pixels in the chroma-bleed rule. The 4K seam V "miss" was the clip ending at frame 479 (now 26 s).

In Premiere (26.5.2) the 1080p top line was missed at first: Premiere upsamples 4:2:0 chroma without filtering, so the
row under a 1 px line is dark saturated green (`0,129,1`; ffmpeg/AVFoundation give `0,195,0`) and the step test read
the line as a gradient. Fixed in both detectors with the chroma-bleed rule (AGENTS.md §8d); bench, parity and the
37 `_TEST` segments unchanged. The exporter can save raw frames for such comparisons: `"dumpFrames": [60]` in
`scan.settings.json` writes `scan.frame60.<w>x<h>.bgra` (top row first) next to it.

## Status: resume here

- 2026-11-02: spike panel written, never loaded.
- 2026-11-02 (later): API names checked against the Premiere UXP reference: `exportSequence` (25.6, `Promise<boolean>`),
  `EncoderManager.EVENT_RENDER_*` (documented as AME events: whether they fire for `IMMEDIATELY` is unverified),
  `EventManager.addEventListener(target, type, handler, useCapture)`, `Marker.createSetColorByIndexAction`,
  `Markers#getMarkers()` (sync), `Sequence.getTimebase()` → `Promise<string>` (taken as ticks per frame, as in
  ExtendScript: confirm with the `ticks/frame` log value, 10584000000 at 24 fps). Manifest min version raised to 25.6.
  Added Marker only / Stock export buttons so checks 1–3 run without the exporter.
- 2026-11-02 measured in Premiere 26.5.2 (Mac), 1080p 23.976 sequence:
  - Loads with `host` as an array and `localFileSystem: "request"` (`fullAccess` + object `host` timed out on Load).
  - Check 3 ✓: name, colour index 1 (red), comment and a 10-frame duration all stick. Marker lookup must use a unique name.
  - Check 1 ✓ (stock ProRes preset): In 4.004 → Out 14.014 s = 240 frames, export has exactly 240. Whole sequence: 5036 frames.
  - `exportSequence(IMMEDIATELY)` resolves when the export has **finished**; `EVENT_RENDER_*` never fire for it.
    So the panel needs no progress events (and has none to show: progress must come from the exporter, e.g. a file it updates).
  - `getTimebase()` = ticks per frame (10594584000 at 23.976). Unset In/Out reads as −400000 s.
  - Speed not measured yet: ProRes Match Source on ProRes media is a passthrough (~1000 fps). Needs a run with an effect.
- 2026-11-02: frame-counting exporter written against SDK 27.0, builds as a universal ad-hoc-signed bundle, installed
  into MediaCore. Not yet seen in Premiere 26.5.2.
- 2026-11-02 Scan ✓ (Premiere 26.5.2, SDK 27.0 exporter): "LineFinder Analysis" shows in Export formats; preset saved
  as `panel/presets/LineFinderSpike.epr`. In 3.629 → Out 14.014 s = 249 frames; exporter got exactly 249, all distinct,
  1920×1080 `BGRA_4444_8u` in RAM, rowBytes 7680 (no padding). 0.95 s in the render loop = **262 fps** at 1080p; 1.02 s
  from click to resolve. Premiere also writes `spike.json.xmp` beside the output (preset `DoMetadata` is true).
- To fix before v1: the saved preset hard-codes 1920×1080 @ 23.976 (take size/rate from the sequence instead); turn off the
  XMP sidecar; test `hideInUI` so the format isn't in the Export list; check whether a progress window shows; 4K speed.
- 2026-11-02: linecore ported, identical to the Swift detector on all of `_TEST` (see above).
- 2026-11-02: linecore wired into the exporter; real panel (colour, sensitivity, seams, In/Out, progress, results,
  markers, Clear). First real scan (CK_HOME26 16x9 E3.0, 25 fps clip in a 23.976 sequence, whole 720 frames, green):
  right edge 157–205 (6.5–8.6 s, 4 px) and left edge 340–380 (14.2–15.8 s, 1 px): both known lines, nothing else.
  0.41 s in the render loop = 1765 fps at 1080p.
- 2026-11-02: exporter `hideInUI` (LineFinder Analysis out of the Export menu) and Cancel (Scan → Cancel writes
  `scan.cancel`; the exporter stops and reports what it found so far). Not yet checked: progress bar live updates,
  Cancel, the format being gone from the Export menu (parked for now).
- 2026-11-02 Premiere scan of `LineFinder_Test_1080p` with seams: bottom, left, seam H (row 540), seam V (col 959)
  exact; top missed → chroma-bleed fix (above). With seams on 458 fps (≈ the 2.2 ms seam cost: frames arrive one at a
  time); edges only ~1840 fps.
- 2026-11-02 bug pass. Exporter: segment frames now count from the lowest `inFrameNumber` delivered (the SDK doesn't
  say whether it is export- or sequence-relative; every scan so far started at 0, so In/Out scans away from 0 were
  unverified), locale-independent number parsing and output (`milliseconds` replaces `seconds`), an early Cancel is no
  longer deleted at start, abort returns `suiteError_CompilerCompileAbort`, a cancel from Premiere's own dialog also
  reports partial results, frames that aren't 8-bit BGRA are counted as `skipped`. Panel: drop-frame timecode (29.97 /
  59.94 DF, from `getSequenceVideoTimeDisplayFormat().type` 102 / 106, assumed to match ExtendScript: logged),
  markers replaced in one undo step (+ one for colours), at most 500 markers, Clear disabled while scanning, NaN-safe
  progress, "nothing was rendered" for empty ranges, custom colours accepted without `#`.
  Verified in Premiere 26.5.2: `inFrameNumber` is **sequence-relative** (In at 00:00:13:00 → first frame number 312);
  the right-edge line came back at 00:00:14:00, 48 frames (it would have been 13 s late before). Whole-sequence scan of
  the 1080p test clip with seams: all 6 lines exact, 462 fps. A 23.976 sequence reports display format 110, ExtendScript's
  code for 23.976 timecode, so the DF codes 102 / 106 are likely right (no DF sequence tried yet).
- 2026-11-02 second bug pass. linecore under ASan + UBSan: 4,000 random frames (1×1 to 300×200, padded rows,
  both row directions, all settings) clean. Exporter: segment offset from the export start time (frame numbers are
  sequence-relative), not the first frame delivered. Panel: results capped at 500 rows (+N more), clicking a result
  from another sequence brings that sequence to the front, Clear only empties the list when it shows the active
  sequence, rejected marker transactions are reported, exporter/panel version mismatch is detected.
- Old next: exporter reads settings (colour, sensitivity, splits) and runs linecore in `onFrame` → results.json (segments in
  frames from the export start) → panel turns segments into markers. Then the pre-v1 fixes above.
- Old next step: restart Premiere → LineFinder Analysis appears in Export formats → save `panel/presets/LineFinderSpike.epr` → Scan on
  a 1080p and a 4K sequence (with an effect, so it really renders) → record fps here → port linecore.
