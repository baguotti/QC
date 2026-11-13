# QCpie: Directives for AI Agents & Developers

> **CRITICAL MANDATE - READ BEFORE MODIFYING PLAYER OR VIEWPORT CODE**
>
> The viewport inspection architecture has been accidentally broken and re-fixed twice during past refactorings (e.g. during optimization passes and the A/B dual-slot compare mode introduction). Read [docs/architecture/player.md](docs/architecture/player.md) before touching it.
>
> 1. **DO NOT REMOVE OR BYPASS THE DEDICATED STILL FRAME LAYERS (`stillFrameLayerA` / `stillFrameLayerB`) UNDER ANY CIRCUMSTANCES.**
> 2. `stillFrameLayerA` and `stillFrameLayerB` are the **exclusive presentation layers** during paused inspection, single-frame stepping, and live continuous playback (via `CADisplayLink`).
> 3. `playerLayerA` and `playerLayerB` (`AVPlayerLayer`) are kept hidden and are revealed **strictly during active timeline drag scrubbing** (`isScrubbing == true`) to allow zero-copy GPU hardware seeking.
> 4. **PERFORMANCE & SMOOTH PLAYBACK/SCRUBBING ARE ABSOLUTELY PARAMOUNT**: Liquid 60–120 FPS playback, instant scrubbing, and zero-stutter timeline interaction are core product invariants. If any newly introduced feature, UI component, publisher, disk I/O, or architectural change is suspected of degrading playback or scrub performance, **YOU MUST STOP AND FLAG IT TO THE USER IMMEDIATELY** before proceeding.

> **UI / DESIGN:** before adding or changing any UI, read [DESIGN.md](DESIGN.md) (tokens, components, patterns) and run `python3 scripts/design_lint.py`. When two existing styles conflict, ask the user which is the standard.

> **LEGACY RECOVERY NOTICE:** the original architectural directive is archived at [docs/archive/AGENTS_LEGACY.md](docs/archive/AGENTS_LEGACY.md). If future changes cause regressions, refer to it for the recovery baseline.

---

## Where the details live

Read the file for the area you're changing before you change it. Each holds the reasoning, measurements and rules for its area (section numbers kept from the old single file).

| Area | File |
|---|---|
| Player, viewport layers, exposure, scrubbing, A/B compare, audio routing, keyboard routing, In/Out, subtitles, image/audio slots (§1–8a) | [docs/architecture/player.md](docs/architecture/player.md) |
| Notes sync, settings, type scale, accents, launch time, notifications (§8b, 8c, 8g, 8h, 8k) | [docs/architecture/app.md](docs/architecture/app.md) |
| Line Check, Frame Check, loudness, legal range, Pro Video Formats, Missed Line report (§8d–8f) | [docs/architecture/scan.md](docs/architecture/scan.md) |
| Frame.io upload, download, browser, comments, preview, metadata, pre-upload checks (§8i–8j3, 8i2) | [docs/architecture/frameio.md](docs/architecture/frameio.md) |
| Delivery Plan: Google Sheets sync, matching, statuses, Inspect integration (§8e5) | [docs/architecture/delivery-plan.md](docs/architecture/delivery-plan.md) |
| Scripts and benchmarks | [scripts/README.md](scripts/README.md) |
| Where the code is split | see "File layout" below |
| Research notes and parked ideas | [docs/research/](docs/research/) |

## Rules that apply everywhere

- **Per-frame work stays out of SwiftUI.** `ContentView` owns the engine and every tab's state as `@StateObject`: any publish re-renders the whole window. Per-frame values live on `PlaybackClock` and are drawn by AppKit-backed views (`PlaybackClockViews.swift`). Never add per-frame `@Published` state.
- **No synchronous disk I/O, decoding or network on the main thread**, and nothing slow at launch (`App.init`, `ContentView` stored properties, `onAppear`).
- **Large lists** use `LazyVStack`, `.equatable()` rows, integer version counters for equality, and no per-row singleton subscriptions.
- **Values that change often** (progress, counters) don't go on an object `ContentView` owns: put them in a small `ObservableObject` of their own and read them through `ObservingView` (see `ScanProgress`).
- **Busy singletons** (upload/download queues, Frame.io browser, Delivery Plan store, transfer log) are observed only by the views that show them, never by `ContentView`.
- **Keyboard**: `KeyboardShortcutRouter` handles keys app-wide; text fields and sheets must keep their keys (see player.md §8 and frameio.md "Inline text fields").
- **Saved files stay readable across versions.** A field added to a type saved to disk (outbox, upload resume, Frame.io links, plan config, check results, notes) must be optional or decoded with `decodeIfPresent`: Swift's synthesized `Codable` requires every non-optional key, even one with a default value, so files from the previous version would fail to load and read as empty (unsent edits, a resumable upload or the sent-comment records lost).
- **Benchmarks** (`scripts/*Bench/run.sh`) must print ALL PASSED after any change to what they measure.

## File layout

Large types are split by area into `Type+Area.swift` extension files; stored properties stay in the main file (Swift doesn't allow them in extensions).

- `PlayerEngine.swift` (state, init, exposure, audio) + `PlayerEngine+Loading`, `+Slots`, `+Playback` (time observers, PLL, J-K-L), `+Stepping`, `+InOut`, `+Scrub`, `+Capture`; supporting types in `PlayerTypes.swift`.
- `FrameIOBrowser.swift` (model) and `FrameIOBrowserView.swift` + `+Header`, `+List`, `+Actions`; sheets in `FrameIOBrowserSheets.swift`, small views in `FrameIOBrowserParts.swift`.
- `DeliveryPlanPanel.swift` + `DeliveryPlanPanelRows.swift` (Sheet/List views), `DeliveryPlanPanelActions.swift` (selection, checks, status); `DeliveryPlanRowCard.swift`, `DeliveryPlanControls.swift` (chips, pills, filters shared with Inspect).
- `DeliveryPlanStore.swift` (state, init, linking, disk; all stored properties) + `+Reading`, `+Matching`, `+FrameIOLinks`, `+FrameIOFolders`, `+Editing` (edits, undo, outbox, QCpie tab).
- Player tab: `PlayerTabView.swift` (still a `ContentView` extension) + `PlayerSliders.swift`, `PlayerComparisonBar.swift`, `PlayerMenus.swift`, `InOutExporter.swift`.

When a member moves to another file, drop `private` only where the compiler asks; a private member called from another file can silently resolve to a different visible declaration of the same name (POSIX `select`, `accept`; SwiftUI `toolbar`).

## Logging (`Sources/VideoQCLib/Log.swift`)

- `Log.<area>` (`app`, `player`, `scan`, `inspect`, `upload`, `download`, `frameio`, `plan`, `google`, `sync`, `notes`, `update`) writes to unified logging, subsystem `com.studio.qcpie`: `log stream --predicate 'subsystem == "com.studio.qcpie"'`.
- `.notice` and `.error` also go to `~/Library/Application Support/QCpie/Logs/QCpie.log` (1 MB, three files kept, written on a background queue, opened on first write). Settings → General → Logs reveals it, and **Save Zip to Desktop** (`SettingsTransfer.exportLogs`) zips the logs, QCpie's three newest crash reports (`~/Library/Logs/DiagnosticReports/QCpie*`) and the app / macOS versions: ask a colleague for that zip when something failed on their Mac. `.debug` / `.info` are unified logging only.
- **Never log from per-frame paths** (display link, scrub, time observer, per-sample scan loops). Log events: loads, scans starting and ending, network failures, retries, failed saves.
- Saved state goes through `JSONFile.save` / `load` / `remove`: a failed write or an unreadable file is logged, a missing file is not. Use `log.attempt("what") { try … }` instead of a bare `try?` when a failure would matter to someone debugging; keep `try?` for failures that are expected and harmless (cleanup, `Task.sleep`, optional probes).
- Errors that recur on a timer (offline polling) are logged when the state changes, not on every attempt (see `DeliveryPlanStore.setHealth`).

---

## 9. Pre-Commit Checklist for Future Amends

For any UI change: `python3 scripts/design_lint.py` passes (it also runs in `scripts/BuildApp.sh`); after removing old debt, run it with `--update`.

Before committing any changes affecting `VideoViewportView.swift`, `PlayerEngine.swift` or any `PlayerEngine+*.swift`, `PlayerTransportDeckView.swift`, or `KeyboardShortcutRouter.swift`:
- [ ] Ensure `stillFrameLayerA` and `stillFrameLayerB` are present in `VideoViewportView`.
- [ ] Verify `stillFrameLayerA` and `stillFrameLayerB` are the exclusive visual presentation layers across playback and paused states, with `playerLayerA`/`playerLayerB` revealed exclusively during active scrubbing.
- [ ] Verify `videoGravity` and `contentsGravity` remain `.resize`.
- [ ] Verify adaptive texture filtering operates correctly: `.linear` at fit/normal zoom for QuickTime-grade anti-aliasing, and `.nearest` when zoomed in (>= 1.75x) for pixel QC.
- [ ] Verify rational aspect ratio with even pixel step sizing is used for canvas dimensions and `canvasLayer.masksToBounds` remains `false`.
- [ ] Verify the legal-range zebra stays paused-only (no decode or mask work while playing or scrubbing).
- [ ] Verify `layer.setNeedsDisplay()` is NEVER called on `playerLayer` or `stillFrameLayer`.
- [ ] Verify `playerLayer.filters` is NEVER assigned a `CIFilter` (live video filtering belongs in `AVVideoComposition`).
- [ ] Verify `scrubTo()` does not mutate `@Published` properties during dragging.
- [ ] Verify compare modes honor `requiresMatchingAspect` and aspect ratio mismatches fallback cleanly.
- [ ] Verify audio routing maintains mutual exclusivity (only one slot unmuted at a time).
- [ ] Verify text input fields shield keyboard shortcuts from triggering player transport.
- [ ] Run `swift build` with 0 warnings/errors under Swift 6.
- [ ] Verify scrub seeking and playback maintain fluid 60–120 FPS with large queues (100+ assets).
- [ ] Verify no synchronous disk I/O or JSON decoding runs on the main thread during view evaluations.
- [ ] Test in canvas mode: Zoom into an edge line, pause, and drag the canvas around with the hand tool. Verify the line **does not** turn white during motion.
- [ ] Test exposure slider: Scrub EV from -5.0 to +5.0 EV while paused and while playing. Verify video never disappears, exposure brightens/darkens smoothly, playback doesn't stutter while dragging, and brightness is identical when playing, paused, stepping and scrubbing.
- [ ] With EV ≠ 0, step frames with the arrow keys and verify the picture matches the timecode (not one frame behind).
- [ ] Verify no per-frame state is `@Published` on `PlayerEngine` (per-frame values belong to `PlaybackClock`, displayed by AppKit-backed views).
- [ ] During linked A/B playback of long-GOP deliverables, press TAB (Blink) on/off, fast-forward (L, L), and K→L quickly: slot B stays in phase with at most one brief re-lock hitch, never repeated B seeks.

---

**Testing settings-dependent UI:** run the debug build as the app bundle (`scripts/QuickCheck.command`: copy `.build/debug/QCpie` into `build/QCpie.app` and `open` it). The bare `.build/debug/QCpie` has no bundle id, so its UserDefaults (favourites, pages, layouts, Frame.io choices) live in a separate `QCpie` domain instead of `com.studio.qcpie`.

## 10. Absolute Workflow & Operational Directives

> **INVIOLABLE OPERATIONAL DIRECTIVE**
>
> 1. **DO NOT commit to git (`git commit`)** unless the user explicitly requests a commit in their prompt.
> 2. **DO NOT push to remote repositories (`git push`)** unless the user explicitly requests a push.
> 3. **DO NOT run packaging/release scripts (`BuildApp.sh`, `Release.sh`, etc.)** unless the user explicitly instructs to package or build the release.
> 4. **Releasing** (when asked): bump `APP_VERSION` in `BuildApp.sh` (plus `AppVersion.swift`, `README.md`), commit, `scripts/Release.sh build`, have the DMG opened on the oldest supported macOS (15: SDK availability marks have been wrong, 0.13.10–0.14.1 didn't launch there), then `scripts/Release.sh publish "notes"`. **Every release attaches the current Premiere plugin files** next to `QCpie.dmg`, all from `premiere/package/dist/` (`build_mac.sh`): `LineFinder-<panel version>.pkg`, `LineFinder-<panel version>.ccx` and `LineFinderAnalysis-<exporter/VERSION>.zip`. The plugin's Update button reads recent releases and updates the panel and exporter from them. `Release.sh publish` attaches all three and stops if one is missing; when releasing by hand, pass all four files to `gh release create`.
> 5. **Testing code changes**: ALWAYS use `swift build` (quick debug build) to verify compilation correctness and 0 errors/warnings. Never commit or package as part of routine verification.

---

## 11. Project Behavior Rules

### Communication Style
- Be extremely direct, concise, and technical.
- Zero conversational filler: no greetings, apologies, meta-announcements ("Sure, I can help with that"), or concluding summaries.
- Never flatter or validate bad architecture. Challenge assumptions if an approach is inefficient or over-engineered.

### Token Economy & Output Control
- Output ONLY relevant code diffs or targeted snippets. Never rewrite or reproduce entire files unless explicitly instructed.
- Use unified diff format or standard `// ... existing code ...` anchors to indicate placement.
- Do not repeat or parrot back the user's prompt or code before answering.
- Write zero redundant code comments (no explaining obvious syntax like `// set count to 0`).
- Explain root causes and architectural decisions in 1–2 dense sentences maximum.

### Performance-First Invariant
- Smooth playback (60/120 FPS) and butter-smooth scrubbing are paramount.
- Every time a new feature, UI layout, publisher, or disk access pattern is introduced that could hinder performance, **STOP AND FLAG IT TO THE USER IMMEDIATELY**.

### Engineering Standards
- Strict YAGNI: reject speculative abstractions, unnecessary wrappers, and unused dependencies.
- Prefer idiomatic, native implementations over adding new libraries.
- If a simpler, lower-complexity solution exists, implement that instead of patching over-engineered logic.
