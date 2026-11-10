# Burned-in subtitles: read, spell check, export .srt

Status (2026-11-10): Phases 0–3 built. Code: `VideoQCLib/BurnedSubtitleReader.swift`, `VideoQCApp/PictureSubtitleReading.swift`, the Subtitles drawer and `PlayerEngine` (picture drafts). Tests: `Tests/BurnedSubtitleTests.swift`. Bench: `scripts/SubtitleOCRBench`. The architecture notes are in `docs/architecture/player.md` §8b; this file keeps the plan and the Phase 0 measurements.

## Goal

The Player's Subtitles drawer can **Read Subtitles from Picture** for the clip in slot A. QCpie samples frames, reads the text with Apple's Vision OCR and builds timed cues. The cues load into the drawer like an .srt does today, so the existing spell check, cue list, find/replace, click-to-jump and **Save As .srt** work on them unchanged. The result is a draft to review, never ground truth.

Non-goals: no new dependencies or cloud OCR; no per-frame work in the playback path; translation is out of scope; so is word-by-word karaoke captions in v1 (they are detected and reported as "not supported" instead).

## What already exists (reuse, don't copy)

| Need | Existing code |
|---|---|
| Cue model, .srt read/write | `VideoQCLib/SubtitleParser.swift` (`SubtitleCue`, `SubtitleFileFormat`, `parseSRT`, writer) |
| Drawer: list, editing, find/replace, spell check, Save / Save As | `VideoQCApp/SubtitlesPanelView.swift` (`SubtitleSpellingModel` uses `NSSpellChecker`, language picker, `detectLanguage`) |
| Cues on the engine, unsaved-edit protection on quit | `PlayerEngine.subtitleCues`, `subtitleSourceURL`, `loadSubtitles(from:)`, static `unsavedSubtitleEdits` |
| Compare two cue lists | `VideoQCLib/SubtitleCrossCheck.swift` (`compare(reference:other:options:)`, `Difference.Kind`) |
| Background decode with `AVAssetReader`, cancellation, progress, batch | `VideoQCLib/FrameCheck.swift` (`measureSegment`, `CancellationState`, `ScanProgress`, `scanBatch`) |
| Progress that doesn't redraw the window | `ScanProgress` + `ObservingView` pattern (AGENTS.md "Values that change often") |
| Benchmarks | `scripts/FrameCheckBench`, `scripts/LoudnessBench` (`run.sh` → ALL PASSED) |

Read `AGENTS.md`, `DESIGN.md`, `docs/architecture/player.md` (§5.7 subtitles, §8) and `docs/architecture/scan.md` before starting.

## Phase 0: spike (half a day, no UI). Go / no-go

A command-line tool in `scripts/SubtitleOCRBench/` (same shape as `FrameCheckBench`) that reads 4–6 real deliverables with burned-in subtitles and prints cues as .srt plus timing.

1. Find test clips: ask the user for 4–6 deliverables with burned-in subtitles (clean white-on-dark, a styled/brand font, a 9x16 social with captions over busy picture, a non-English one). Put them in `_TEST/BurnedSubs/` (git-ignored like the rest of `_TEST`) with a hand-made reference `.srt` for each (or the supplied .srt if one exists).
2. Decode with `AVAssetReader` at the clip's native size, BGRA, keeping every Nth frame for 4 frames/s.
3. Crop to the bottom 35% (and separately the top 20%) and run `VNRecognizeTextRequest` (`.accurate`, `usesLanguageCorrection = true`, `recognitionLanguages` from a flag, `minimumTextHeight` ≈ 0.02 of the crop height).
4. Print per-clip: OCR time per frame, real-time factor, recognised lines with confidence.
5. Score against the reference `.srt`: character error rate (Levenshtein / reference length) on matched cues, plus cue recall and timing error. Write the scorer in `VideoQCLib` so tests can use it.

### Phase 0 result (2026-11-10, M4 Max, `scripts/SubtitleOCRBench`)

One clip so far: `LNEH_ROUGHCUT_24fps_E6.2_SUBS_TEST.mp4` (1080p H.264, 24 fps, 112 s, clean white sans-serif with a soft shadow over dark picture, 29 cues, two lines each), against its supplied .srt.

- **Text:** 29/29 cues found, none extra. Word for word identical except: straight apostrophes where the .srt has curly ones (’), and one invented leading "- " on cue 24 (not in the picture; a stray mark near the text). The scorer ignores punctuation, so it reports 0.00% character error rate; by eye it's 1 error in 29 cues.
- **Timing:** every cue's start and end land on the exact frame of the reference (0 frames off; the only differences are millisecond rounding of the same frame).
- **Speed:** 25.8 s for 112 s of video = 4.3× real time, single-threaded (541 OCR calls at 45 ms each; decoding 1.2 s). Two OCR calls in parallel should roughly double it.
- **Not tested yet:** styled brand fonts, coloured or animated captions, 9x16 social captions over busy picture, non-English text. These are the risky cases and need clips before Phase 1 is signed off.

Later real-life runs (encodes of the same clip, generated clips) are recorded in `docs/architecture/player.md` §8b.

Follow-ups for Phase 1 from this run (all done): map straight quotes back to curly ones (or ignore the difference in cross-check), drop a leading "-" when the line has no dialogue partner, and run two OCR calls in parallel.

**Go** if, on clean subtitles: character error rate ≤ 3%, cue recall ≥ 95%, ≥ 4× real time for 1080p on the M4 Max. Report the numbers to the user either way before Phase 1.

## Phase 1: engine in VideoQCLib (1–1.5 days)

New file `VideoQCLib/BurnedSubtitleReader.swift`, pure and testable, no UI:

```swift
public struct BurnedSubtitleOptions: Sendable, Equatable {
    public var region: Region = .bottom          // .bottom (lower 35%), .top (upper 20%), .both
    public var languages: [String] = ["en-US"]  // Vision codes; from the drawer's language picker
    public var samplesPerSecond: Double = 4
    public var minimumConfidence: Float = 0.3
}
public struct BurnedSubtitleResult: Sendable {
    public var cues: [SubtitleCue]
    public var lowConfidence: Set<Int>          // cue indices to review
    public var skipped: [String]                // e.g. "word-by-word captions not supported"
}
public final class BurnedSubtitleReader: Sendable {
    public func read(_ url: URL, options: BurnedSubtitleOptions,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> BurnedSubtitleResult
    public nonisolated func cancel()
}
```

Pipeline:

1. **Sample**: `AVAssetReader` + `AVAssetReaderTrackOutput` (BGRA, `alwaysCopiesSampleData = false`), keep frames at `samplesPerSecond`. Record each kept frame's presentation time. Crop with `regionOfInterest` on the Vision request, not by copying pixels.
2. **Recognise**: one `VNImageRequestHandler(cvPixelBuffer:)` per kept frame; run up to 2 frames concurrently (`TaskGroup`, same cap as `FrameCheck.scanBatch`). Keep observations whose box is wider than 10% of the frame; join lines top to bottom with `\n`.
3. **Merge into cues** (pure function `BurnedSubtitleReader.cues(from samples:)`, unit-tested): consecutive samples whose normalised text is similar (normalised Levenshtein ≤ 0.15, case/punctuation-insensitive) form one cue; the cue's text is the highest-confidence reading. Empty samples end a cue.
4. **Refine timings**: for each cue boundary, decode the frames between the two samples around it (a second short `AVAssetReader` pass over that time range, all frames) and find the first/last frame whose text matches. Times land on exact frames (`frame / fps`).
5. **Filter non-subtitles** (pure, unit-tested): drop cues shorter than 0.4 s or longer than 10 s; drop text whose box centre moves more than 5% of the width across the cue (moving graphics); drop text present in > 60% of the clip (logos, bugs); drop single tokens that look like timecode or slate data.
6. **Detect word-by-word captions**: more than 3 cues per second over a 5 s window where each cue's text extends the previous one → merge into one cue per phrase if the merge is unambiguous, else stop and return `skipped` with a reason.
7. **Confidence**: mark a cue low-confidence when its best reading's average confidence < 0.6 or its readings disagreed (normalised distance > 0.1 between samples).

Tests (`Tests/BurnedSubtitleTests.swift`):
- Pure merge/filter/refine on synthetic `samples` arrays (no video): same text with OCR noise merges; a logo present all clip is dropped; a moving super is dropped; word-by-word growth is merged or skipped.
- One end-to-end test on a tiny generated clip: render 3 known subtitles into frames with Core Graphics, write with `AVAssetWriter` into a temp file, read back; text matches exactly and boundaries land within ±1 frame. Skip if Vision is unavailable on the test runner.

## Phase 2: drawer integration (1 day)

Performance first: everything runs off the main thread at `.utility`; progress goes through a small `ObservableObject` read with `ObservingView`; nothing touches `PlayerEngine` until the result is ready; no work while playing. Flag to the user if any of this can't hold.

1. **Button**: in the Subtitles drawer's ••• menu and in its empty state ("No subtitles. Load an .srt or Read Subtitles from Picture"), `Read Subtitles from Picture…`. It opens a small popover: region (Bottom / Top / Both), language (reuse the drawer's spell-check language list mapped to Vision's supported languages, `VNRecognizeTextRequest.supportedRecognitionLanguages`), and Read. Copy rules from DESIGN.md (Title Case buttons, sentence-case help).
2. **Progress**: a bar with percentage and Cancel in the drawer header while reading; the clip can still be played (reading uses its own `AVAsset`).
3. **Result**: new `PlayerEngine.loadSubtitles(cues:source:)` that sets `subtitleCues`, sets `subtitleSourceURL = nil`, and records the cues in `unsavedSubtitleEdits` under a key like `"picture:" + clipPath` so the quit prompt protects them like unsaved .srt edits. The drawer's header shows "Read from picture · draft" instead of a file name. **Save** acts as **Save As…**, defaulting to `<clip name>.srt` next to the clip; after saving, the source becomes that file (the existing path).
4. **Review aid**: low-confidence cues get an amber marker in `SubtitleCueRow` (reuse the spell-check issue styling, `TagTone.amber`), and the existing "next issue" button also visits them. Selecting a cue seeks the player to it, so the frame is on screen beside the text.
5. **Spell check**: unchanged; it runs on the loaded cues. Brand names go to the existing ignore list.
6. **Settings**: Settings → Checks gets the default region and language (`@AppStorage`), like Line Check's defaults.
7. **Docs**: add a §8 subsection to `docs/architecture/player.md` (what runs where, the measured speed, the merge/filter rules); a User Guide topic in the Play chapter (`UserGuideView.swift`) with the button drawn via `GuideControl`.

## Phase 3: cross-check against a supplied .srt (half a day)

1. When an .srt is attached to the clip (`SubtitleAttachments`) and cues were read from the picture, the drawer offers **Compare with Burned-in Subtitles**: runs `SubtitleCrossCheck.compare(reference: srtCues, other: pictureCues, options:)` with a looser text option (ignore case, punctuation and line breaks) and a timing tolerance of 3 frames.
2. Differences list in the drawer like the Inspect cross-check does, each row jumping to the frame.
3. Optional later: run it for every selected file from Inspect (batch), reusing `scanBatch`'s concurrency and progress pattern.

## Benchmark

`scripts/SubtitleOCRBench/run.sh` (from Phase 0) becomes the regression bench: on the `_TEST/BurnedSubs` clips it checks character error rate, cue recall, boundary error (±1 frame) and real-time factor against stored thresholds and prints ALL PASSED. Add it to `scripts/README.md`. Per AGENTS.md it must pass after any change to the reader.

## Risks and how the plan handles them

| Risk | Handling |
|---|---|
| OCR mistakes look like typos | Low-confidence marking, the frame on screen when a cue is selected, the result labelled as a draft |
| Stylised, coloured or animated captions | Measured in Phase 0; word-by-word captions merged or skipped with a reason, never silently wrong |
| Logos and supers read as subtitles | Position, duration and presence filters (Phase 1.5) |
| Wrong language guess | Language chosen per read, default from Settings |
| Speed on long clips | 4 samples/s, region of interest, 2-way concurrency; measured in Phase 0 and the bench |
| Playback impact | Separate `AVAsset` and reader, `.utility` priority, no engine publishes until done, no work in the display link |
| Unsaved results lost on quit | Stored in `unsavedSubtitleEdits`, so the existing quit prompt covers them |

## Estimate

Phase 0: ½ day. Phase 1: 1–1.5 days. Phase 2: 1 day. Phase 3: ½ day. About 3–3.5 days in all, after a go from Phase 0.
