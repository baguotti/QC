# LineFinder for Premiere Pro: spike

Step 1 of [docs/premiere_linefinder_plan.md](../docs/premiere_linefinder_plan.md). Panel only so far; the exporter is waiting on the Premiere Pro C++ SDK.

## Panel ↔ exporter contract (spike)

- The panel calls `EncoderManager.exportSequence(seq, IMMEDIATELY, <outPath>, presets/LineFinderSpike.epr, exportFull = !useInOut)`.
- `<outPath>` is `spike.json` in the panel's UXP data folder. The exporter writes `{"frames": N}` to exactly that path when the export finishes, and writes no video.
- The panel polls for that file (100 ms), logs encoder events if `EventManager` delivers them, then adds one red 10-frame marker at the In point (or 0).

## Load the panel

1. Build and install the exporter, open Export Settings, choose the "LineFinder Analysis" format, and save the preset as `premiere/panel/presets/LineFinderSpike.epr`.
2. UXP Developer Tool → Add Plugin → `premiere/panel/manifest.json` → Load.
3. Window → UXP Plugins → LineFinder Spike. Set In/Out on a sequence, press Scan, and read the log.

## What the log answers

| Plan check | Log line |
|---|---|
| 1. `exportSequence` with a third-party preset honours In/Out | `exportSequence returned …` and `frames=N` vs the In/Out length |
| 2. Speed | `frames=N in S s → F fps` (time includes the 100 ms polling granularity) |
| 3. Marker name, colour, duration, comment | `Marker: …` line, `Colour failed` if the colour action doesn't exist |

## Status (paused 2026-11-02): resume here

- Done: spike panel only (`premiere/panel`); JS and manifest syntax-checked, never loaded in Premiere.
- Blocked on this Mac: no Premiere Pro C++ SDK, no UXP Developer Tool (both Adobe downloads behind a login).
- Unverified API names in `index.js`: `EventManager.addEventListener(encoder, …)` with `EncoderManager.EVENT_RENDER_*`,
  `marker.createSetColorByIndexAction`, and `sequence.getTimebase()` returning ticks per frame.
- Next: install the SDK and UXP Developer Tool → build the frame-counting exporter ("LineFinder Analysis", writes
  `{"frames": N}` to the output path) → save `presets/LineFinderSpike.epr` → load the panel → record 1080p / 4K speeds.
