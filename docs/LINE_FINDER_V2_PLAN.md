# Line Finder v2: Handover Plan

Goal: make Line Finder catch the "tricky" target lines it misses today. A small speed loss is acceptable; strength matters more. Keep the pipeline (`VideoScanner` → `FrameError` → `GlitchSegment` → report/UI); replace the per-row decision in `Sources/VideoQCLib/EdgeDetector.swift`.

## Why the current detector misses lines

| # | Cause | Where | Typical miss |
|---|---|---|---|
| 1 | Edge scan starts at the outermost row and `break`s at the first non-matching row | `scanRawBGRA`, edge loops (~L258-332) | Line 1 px in; outer row half-blended by scaling / 4:2:0 chroma |
| 2 | Absolute RGB distance to target with fixed tolerance | `checkHorizontalRowBGRA` / `checkVerticalColumnBGRA` | Semi-transparent / sub-pixel lines (blend of target + picture varies along the row) |
| 3 | Coverage = 70% of all pixels (`minSpanRatio`), not a contiguous run | same | Partial lines, lines behind graphics |
| 4 | Pixels where picture ≈ target colour count as misses | same | Green line beside foliage, black line beside a dark scene |
| 5 | Contrast check vs a 32-sample *average* of the adjacent row | `hasBoundaryContrast*` | Busy/similar content averages the contrast away |
| 6 | Uniformity gates very tight (black/white σ ≤ 2.0, colour σ ≤ 22) | end of row/column checks | Compression noise on low-bitrate H.264/HEVC |
| 7 | Every frame judged alone | `VideoScanner.scanSingleVideo` | Faint but persistent lines never strong enough in one frame |
| 8 | Clean aperture ignored (decoded buffer may include padding rows, e.g. 1088 for 1080) | `scanPixelBuffer` | Bottom-edge misses / false flags |

## New approach

1. **Per-pixel blend model against the picture just inside.** For each edge, each depth `d` in `0..<D` (D ≈ edgeDepth + margin, ~24) and each position `p` along the edge:
   - Reference `R(p)` = median of depths `D…D+3` at `p` (the picture inside the line).
   - Model `P ≈ α·T + (1−α)·R` with `T` = target colour; `α = ((P−R)·(T−R)) / |T−R|²`, residual = `|P − R − α(T−R)|`.
   - Skip positions where `|T−R|` is small (uninformative), instead of counting them as misses.
   - Evaluate every depth independently (no break at first failure); thickness = contiguous depths that pass.
2. **Coverage = longest contiguous run** of positions with α ≥ threshold and small residual, allowing gaps ≤ ~8 px; minimum run e.g. max(25% of edge, 64 px). Report span ratio from that run.
3. **Keep existing rejections, made local:** letterbox (line continues past `D`), frame-wide suppression (`isEntireFrameTargetColorOrDarkBGRA`) stays; contrast measured per pixel against `R(p)`.
4. **Temporal hysteresis** (in `VideoScanner`, per edge/depth score): flag on one high-score frame, or a lower score held for ≥ 6 consecutive frames.
5. **Small fixes:** crop to `CVImageBufferGetCleanRect`; map edge labels through the track's `preferredTransform` for rotated clips; split-screen mode uses the same model with reference = rows/cols on both sides (sample every 2nd pixel along the line for speed); optional **"any colour"** mode where `T` = median colour of the candidate line.
6. **UI:** tolerance slider becomes one sensitivity setting (α threshold); add "any colour" toggle in `ScannerState` / `LineScannerTabView`. Keep `QCConfig` backwards compatible where practical.

Cost: ~24 depths × perimeter ≈ 150k pixels per 1080p frame, similar to today. Line Finder runs separately from playback (`.utility`, progress throttled to ~5 Hz), so the player's smoothness is unaffected.

## Validation plan

1. Build a **synthetic test suite** (Swift Testing, `Tests/LineDetectorTests.swift`) that generates BGRA buffers:
   - Positives: 1 px line at edge; line 1 px in; 50% and 30% blended line; partial span (40%); noisy/compressed line; simulated 4:2:0 chroma blur; black line on dark scene; green line next to green content; internal split line.
   - Negatives: foliage/content touching the edge; letterbox bars thicker than edge depth; sky gradient; full black/white/green frames; dark scene with no line.
   - Run each case through old and new detector; the new one must pass all, and must not regress negatives.
2. **Real misses:** collect stills (PNG) / short clips of frames the current detector misses plus clean frames that must stay clean; add them as fixtures.
3. `swift build` (0 warnings) and `swift test`, then scan a real deliverables folder and compare flagged segments old vs new.

## Files

- `Sources/VideoQCLib/EdgeDetector.swift`: new detector core.
- `Sources/VideoQCLib/VideoScanner.swift`: clean aperture, rotation, temporal hysteresis.
- `Sources/VideoQCLib/DetectionModels.swift`: `QCConfig` (sensitivity, any-colour), `LineDetection` (score/α).
- `Sources/VideoQCApp/ScannerState.swift`, `LineScannerTabView.swift`: settings UI.
- `Tests/LineDetectorTests.swift`: new.
