# QCpie / LineFinder 5000: Architectural Directives for AI Agents & Developers

> **LEGACY RECOVERY NOTICE**
> The unedited historical architectural directive is archived at [docs/archive/AGENTS_LEGACY.md](file:///Users/macstudio-smalloffice/Documents/_RIC/QC/docs/archive/AGENTS_LEGACY.md).
> If future changes cause regressions, refer to the legacy archive for recovery baseline.

> **CRITICAL MANDATE - READ BEFORE MODIFYING PLAYER OR VIEWPORT CODE**
>
> The viewport inspection architecture described below has been accidentally broken and re-fixed twice during past refactorings (e.g. during optimization passes and the A/B dual-slot compare mode introduction).
>
> 1. **DO NOT REMOVE OR BYPASS THE DEDICATED STILL FRAME LAYERS (`stillFrameLayerA` / `stillFrameLayerB`) UNDER ANY CIRCUMSTANCES.**
> 2. `stillFrameLayerA` and `stillFrameLayerB` are the **exclusive presentation layers** during paused inspection, single-frame stepping, and live continuous playback (via `CADisplayLink`).
> 3. `playerLayerA` and `playerLayerB` (`AVPlayerLayer`) are kept hidden and are revealed **strictly during active timeline drag scrubbing** (`isScrubbing == true`) to allow zero-copy GPU hardware seeking.
> 4. **PERFORMANCE & SMOOTH PLAYBACK/SCRUBBING ARE ABSOLUTELY PARAMOUNT**: Liquid 60–120 FPS playback, instant scrubbing, and zero-stutter timeline interaction are core product invariants. If any newly introduced feature, UI component, publisher, disk I/O, or architectural change is suspected of degrading playback or scrub performance, **YOU MUST STOP AND FLAG IT TO THE USER IMMEDIATELY** before proceeding.

---

## 1. The CoreMedia Motion-Downsampling Bug & Permanent Architecture

### The Problem:
- In macOS, Apple's `AVPlayerLayer` is optimized purely for continuous video playback throughput, **not** photo-editor-grade still frame inspection.
- When an `AVPlayerLayer` or its container layer (`canvasLayer`) moves across the screen while paused (e.g. hand tool panning, zooming, trackpad drag), **CoreMedia's compositor automatically switches to a low-resolution dynamic mipmap/proxy texture** to maintain 120 FPS compositing.
- On a 1080×1080 deliverable with a 1-pixel edge glitch (e.g., at column 1079), bilinear downsampling averages that 1-pixel green line with the neighboring white background, **turning the green line white while moving**.
- When the mouse stops moving, CoreMedia waits ~500ms to 1s before restoring full resolution, causing the line to pop back to green.

### The Inviolable Rule:
1. **Hybrid Direct-Pixel & Hardware Scrub Pipeline**:
   - **Active Timeline Scrubbing (`isScrubbing == true`)**: `playerLayerA` & `playerLayerB` (`AVPlayerLayer`) are revealed directly. Frames are presented on the GPU hardware compositor with zero copy overhead, streaming fluidly at 60–120 FPS with QuickTime-grade responsiveness.
   - **Paused Inspection, Stepping & Canvas Pan/Zoom (`isScrubbing == false`)**: `stillFrameLayerA` & `stillFrameLayerB` (`CALayer` backed by uncompressed `CGImage` in `contents`) are the EXCLUSIVE visual display layers. This ensures 100% immunity to CoreMedia dynamic proxy downsampling when panning or zooming with the hand tool. Single-pixel edge lines retain 100% saturation and square pixel fidelity.
   - *How Live Playback Works*: Each `PlayerSlot` attaches an `AVPlayerItemVideoOutput` (32BGRA). `VideoViewportView` uses AppKit's native `CADisplayLink` (synchronized to 60Hz / 120Hz ProMotion). On each display tick, the frame for the vsync it will appear on is selected with `itemTime(forHostTime: link.targetTimestamp)`, extracted via `copyPixelBuffer` and converted zero-copy to `CGImage` via `VTCreateCGImageFromCVPixelBuffer` (<0.14 ms per frame), then set directly to `stillFrameLayer.contents`.
   - Buffers already on screen are skipped by identity (`presentFrame`): with 25 fps content on a 120 Hz display, 77% of ticks would otherwise re-present the same frame. Do not switch this to `hasNewPixelBuffer` — it marks buffers as acquired, so a second live viewport (fullscreen overlay) would starve.
2. **Why Static `CALayer.contents` is Immune While Paused**:
   - CoreAnimation treats a `CALayer` with a static `CGImage` as an immutable GPU texture. It **never** applies CoreMedia dynamic proxy downsampling during panning, scrolling, stepping, or zooming while paused. The 1-pixel edge line remains solid green at all times.
3. **Compare Modes Synchronization**:
   - Every compare mode (single, split vertical, split horizontal, side-by-side, side-by-side vertical, difference, 50% overlay, blink) operates directly and cleanly on both `playerLayerA/B` (during scrub) and `stillFrameLayerA/B` (when paused/playing) (`frames`, `masks`, `compositingFilter`, `opacity`, `zPosition`).
   - **Blink mode** has a unique visibility pattern: `updateLayerVisibility` hides *both* A-slot layers (`playerLayerA` and `stillFrameLayerA`) entirely, displaying only the B-slot layer (`stillFrameLayerB` when paused/playing, `playerLayerB` when scrubbing). This is distinct from all other compare modes where A-slot layers remain visible.
4. **Instant Seeking & Frame Delivery**:
   - When scrubbing ends or stepping, exact frame seek (`.zero` tolerance) snaps to the exact target frame, and `displayImmediateDecodedFrame` or `slot.frameExtractor.capture(at:)` delivers the uncompressed still frame immediately.
   - Seek completions reach every live viewport through `PlayerEngine.attachViewport(_:frameDecoded:seekSettled:)` (player tab and fullscreen overlay can both be live). Paused seeks never broadcast `objectWillChange` (that re-rendered the whole window per step).
   - With an exposure composition installed, the composited frame reaches the video output a few ms *after* the seek completion (the output still holds the previous frame at completion). `watchForFreshStill` keeps the display link ticking for 0.5 s after a paused seek to present it — without it, stepping with EV ≠ 0 shows the previous frame.

---

## 2. Layer Gravity & Texture Filtering Rules

1. **`videoGravity = .resize` and `contentsGravity = .resize`**:
   - **DO NOT** change these to `.resizeAspect`.
   - `canvasLayer.bounds` (`baseSize`) is already calculated to match the video's exact aspect ratio down to the pixel.
   - Using `.resizeAspect` introduces floating-point subpixel rounding discrepancies inside `AVPlayerLayer`, causing 1-pixel letterbox/pillarbox bars that clip or wash out edge lines.
2. **Adaptive High-Fidelity & QC Pixel Texture Filtering**:
   - **Normal Viewing & Fit Zoom (`zoomScale < 1.75` or `isFitZoom == true`)**: ALL presentation layers (`canvasLayer`, `playerLayerA/B`, `stillFrameLayerA/B`) use `.linear` for both `magnificationFilter` and `minificationFilter`. This eliminates jagged staircase aliasing on diagonal lines, graphics, text, and logos, matching QuickTime's anti-aliased GPU rendering quality at full 60/120 FPS performance.
   - **Zoomed-In Pixel QC (`zoomScale >= 1.75`, e.g. 200%, 400%, 800%)**: `magnificationFilter` dynamically switches to `.nearest` so individual square pixels and single-pixel QC glitches remain discrete, square, and unblurred.
   - **`minificationFilter = .linear`**: Downsampling always uses `.linear` to prevent nearest-neighbor pixel-dropping and staircasing when fitting deliverables into the window.
3. **Even Physical Pixel Dimensions & Rational Aspect Ratios (`getRationalAspect`)**:
   - `canvasLayer.bounds` (`baseSize`) dimensions MUST be computed using rational aspect ratios (`getRationalAspect(width:height:)`) with an even multiplier step count (`evenSteps * num / scale`), guaranteeing an exact aspect ratio with 0.0 subpixel rounding distortion.
   - Snapping both width and height to even physical pixels guarantees that half-dimensions (`w/2`, `h/2`) are integers in display pixels, aligning all four edges squarely with the physical pixel grid without subpixel edge bleeding against the background.
   - `canvasLayer.masksToBounds` MUST ALWAYS remain `false` so outer edge pixels are never clipped.

---

## 3. Frame Extraction & Swift 6 Concurrency (`FrameExtractor`)

1. **Actor Isolation**:
   - `FrameExtractor` is an isolated `actor` stored on `PlayerSlot`.
   - `AVAssetImageGenerator` is a non-`Sendable` reference type. To comply with Swift 6 strict concurrency without data-race warnings (`#SendingRisksDataRace`), image extraction (`copyCGImage`) is performed synchronously inside `FrameExtractor`'s actor domain.
2. **Warm Generator Cache**:
   - Creating a new `AVAssetImageGenerator` on every frame takes ~122ms.
   - Reusing the warm generator inside `FrameExtractor` takes **~15 ms** (1080p H.264 long-GOP, M4 Max) versus ~2 ms for a seek + video output read, so it is only a fallback for when the video output has no buffer (e.g. right after load) and for screenshot export.
3. **Boundary Fallback**:
   - `capture(at:fallbackURL:)` must always attempt `.zero` tolerance first for frame accuracy.
   - If `.zero` tolerance fails on edge timestamps (e.g. file start/end PTS truncation), it automatically falls back to a 0.02s tolerance retry before failing, ensuring textures never turn blank.
4. **Pause Time Synchronization**:
   - In `PlayerEngine.pause()`, `self.currentTime` must be immediately synchronized to `slotA.player.currentTime()` to eliminate playhead drift upon pausing.

---

## 4. Exposure (EV) Adjustment Architecture & Prohibitions

1. **NO `CALayer.filters` on `AVPlayerLayer`**:
   - `AVPlayerLayer` relies on CoreMedia hardware video decode pipelines (`FigVideoContainerLayer` / `IOSurface`).
   - Assigning a `CIFilter` to `AVPlayerLayer.filters` is unsupported by CoreMedia for hardware video streams on macOS and causes WindowServer / compositor failure, **making the entire video layer blank out or disappear**.
2. **NO `setNeedsDisplay()` on Player or Still Layers**:
   - Calling `layer.setNeedsDisplay()` on a `CALayer` backed directly by `layer.contents = cgImage` invokes Core Animation's default display cycle, which **immediately wipes `layer.contents` to `nil`** if no custom delegate `draw(in:)` is present.
   - Calling `setNeedsDisplay()` on `AVPlayerLayer` similarly disrupts hardware frame presentation.
3. **Single Exposure Pipeline (`AVVideoComposition`)**:
   - Exposure is applied in exactly one place for decoded video: the item's `videoComposition` (`CIExposureAdjust`). `AVPlayerLayer` (scrub) **and** `AVPlayerItemVideoOutput` (playback & paused stills) both receive composited frames, so video output buffers are display-ready. **Never re-apply exposure to video output buffers** — that doubled the EV (measured: +1 EV dialed displayed as +2 EV).
   - The composition handler reads the EV from a lock-protected box at render time (`ExposureValueBox`), so EV changes **never replace** `item.videoComposition`. Replacing it rebuilds the render pipeline and drops frames during playback (measured at 4K: 44 of 76 frames delivered while dragging EV).
   - The composition is installed when EV leaves 0 and removed 400 ms after EV settles back at 0 (zero playback overhead at 0 EV; dragging through 0 doesn't rebuild twice).
   - A paused frame is only re-composited by a seek, and a seek to the exact current time is a no-op, so an EV change while paused nudges a seek within the same frame (`refreshPausedFramesForExposure`).
   - `FrameExtractor` decodes without the composition: `captureCurrentFrame` applies `ExposureAdjuster` once, so every frame it returns (and `lastDecodedFrame`) is display-ready. Screenshot compositing must not apply exposure again.

---

## 5. Timeline Scrubbing Architecture & Dual-Slot A/B Performance Awareness

> **AWARENESS NOTE FOR FUTURE AMENDS & TROUBLESHOOTING**
>
> Dual-slot A/B scrubbing performance was optimized to eliminate main-thread stuttering on high-spec machines (e.g. Mac Studio M1 Ultra / M3 Max driving 4K/5K displays). Keep the following architecture in mind if modifying scrubbing or playback code:

1. **Zero `@Published` Mutations During Drag Scrubbing (`scrubTo`)**:
   - Never mutate `@Published` properties (such as `slotB.currentTime` or `currentProgress`) inside `scrubTo()`. The `scrubTo()` call path itself is strictly mutation-free.
   - Mutating `@Published` properties during mouse drag triggers Combine `objectWillChange` broadcasts that force SwiftUI to re-evaluate the entire view tree at 120 FPS (`ContentView`, `PlayerTabView`, `TimelineScrubberView`, `VideoViewportView`), saturating the main thread.
   - Timeline playhead dragging is driven 100% locally via `@State private var dragProgress` in `TimelineScrubberView`.
   - *Exception*: The seek-completion handler in `dispatchScrubSeekSlotA` updates `currentFrame` and `currentTimecode` to keep the timecode HUD accurate during scrub. Seek completions keep pace with drag events (~110/s measured for 1080p/4K H.264), so these values live on `PlaybackClock` (see §5.7), never on `PlayerEngine`'s `objectWillChange`. **Do not remove these updates** — they are necessary for timecode display during scrub.
2. **Decoupled Parallel Scrub Seeking (`dispatchScrubSeek`)**:
   - `dispatchScrubSeek(timeA:)` maintains separate seek pipelines (`isScrubSeekingA`/`B` and `pendingScrubTimeA`/`B`).
   - Slot A and Slot B hardware decoders seek independently without locking each other. If Slot A takes 8ms and Slot B takes 35ms, Slot A must never be forced to idle waiting for Slot B before grabbing the next pending seek frame.
   - Intermediate seek timestamps are coalesced into `pendingScrubTimeA`/`B` so decoders immediately jump to the latest mouse position without backlog.
   - Synchronized parallel seeking with exact `.zero` tolerance is reserved for settle (`endScrubbing`), stepping, and pause inspection.
   - Slot B's target time incorporates `slotB.slipOffsetFrames` (converted to seconds via `slipOffsetFrames / slotB.fps`) for A/B frame slip sync correction. Do not remove this offset calculation during scrub refactoring.
3. **DisplayLink Suppression During Active Scrubbing**:
   - `displayLink` is explicitly paused while `engine.isScrubbing` is true, and `renderPlaybackFrames()` guards against running during scrub.
   - Extracting `videoOutput` pixel buffers for `stillFrameLayerA`/`B` during scrubbing wastes CPU/GPU cycles and locks buffer pools while `playerLayerA`/`B` are presenting frames directly.
4. **SwiftUI View Modifier Complexity Limits**:
   - Avoid chaining 20+ view modifiers directly onto a single `body` view expression in `ContentView.swift`. De-nest into computed sub-expression properties (`baseContent`, `contentWithAnimations`, `contentWithChangeHandlers`) to keep Swift type-checking under reasonable compile-time budgets.
5. **Linked A/B Playback Drift Correction (PLL)**:
   - During continuous linked playback (`isLinkedPlaybackRunning`: linked, playing, not scrubbing, and slot A's player actually running), `updateCurrentTime` applies a Phase-Locked Loop (PLL) micro-rate adjustment to Slot B's `AVPlayer` to prevent cumulative clock drift between two independent hardware decoders.
   - **Never perform a destructive `seek(to:)` on Slot B while playing** — seeking halts video decode and creates audio pops. The PLL adjusts `slotB.player.rate` by tiny increments to smoothly converge Slot B's playhead onto the target offset.
   - **Hard re-sync is `relockSlotB()` only**: when B stalls or lags more than 3.5 frames of wall-clock time (threshold scaled by |rate|), B seeks *ahead* of A and is started with `setRate(_:time:atHostTime:)` at the host time A reaches that position — one seek, landing in phase, at most once per second. Never seek B to A's *current* time and then `playImmediately`: an exact long-GOP seek takes ~100–200 ms, so B restarts ~4 frames behind and the recovery loops (measured in v0.7.11: B at ~6 fps with 6–7 seeks/s after TAB, fast-forward or pause→play, continuing even while B is hidden).
   - `syncSlotBToMaster()` during linked playback re-locks only when B is off by more than half a frame (TAB/Blink must not seek an already phase-locked B). `setPlaybackRate` waits for any in-flight B seek (pause alignment, re-lock) before starting both players.
   - Do not remove or bypass this drift correction when refactoring the time observer or playback code, or A/B sync will gradually diverge during long playback sessions.
6. **Large Queue & View Hierarchy Scalability (100+ Assets)**:
   - **Never use eager `VStack` for asset/file lists**: Always use `LazyVStack` in scrollable queues so only visible rows are instantiated and measured.
   - **Zero Synchronous Disk I/O or JSON Decoding in View Bodies**: Heavy file checks (e.g. `notesCount`) must be backed by an in-memory thread-safe cache (`QCNotesManager.notesCountCache`). View bodies read `QCNotesManager.cachedNotesCount(for:)` (never touches disk); the cache is prewarmed off the main thread in `loadFinderTagsForQueue()`. Folder enumeration (`findVideoFiles`) runs off the main thread via `AssetLoadQueue`.
   - **O(1) Equatable Checks (`queueVersion` / `tagsVersion`)**: Never recursively compare large trees (`playerTreeNodes`), dictionaries (`fileTagsMap`), or URL arrays inside `==` on 60/120 FPS render paths. Track integer versions to allow instantaneous equality checks.
   - **Per-Row View Isolation**: Queue row views must conform to and use `.equatable()`, must avoid per-row `@ObservedObject` subscriptions to global singletons, and must use stable URLs/IDs rather than dynamic concatenated strings in `.id(...)`.
   - **One `ForEach` per lazy list**: A list that switches between tree and flat layouts must render both through a single `ForEach` keyed by file path (`PlayerQueuePanelView.queueRows`). Separate `if`/`else` `ForEach` branches whose rows share ids leave rows of the first layout orphaned in the `LazyVStack` — stale selection highlight and indent until the panel is rebuilt (seen on first queue load, which renders flat before the tree is built).
   - **AVAssetImageGenerator Throttling**: Cap open thumbnail/frame generator instances (LRU cache) to avoid CoreMedia hardware decoder and file descriptor exhaustion.
7. **Playback Clock & Per-Frame Views**:
   - `ContentView` owns the engine as `@StateObject`: any `PlayerEngine` publish re-renders the whole window. Per-frame values (`currentFrame`, `currentTimecode`, `currentProgress`) therefore live on `engine.clock` (`PlaybackClock`); `engine.currentFrame` etc. forward to it. **Never re-add per-frame state as `@Published` on `PlayerEngine`.**
   - Views that change every frame must not be SwiftUI views observing the clock: a SwiftUI transaction per frame costs ~4.7 ms in the window graph (measured, M4 Max) and ~0.6 ms even in an isolated `NSHostingView`. Use the AppKit-backed views in `PlaybackClockViews.swift` (`PlaybackClockText`, `TimelinePlayhead`, `TimelineProgressFill`), which subscribe to the clock directly. A hidden template `Text` reserves their layout size.
   - Subtitles follow the same rule: the viewport's `subtitleLayer` (CATextLayer) and the Subtitles panel's `SubtitleCueTracker` subscribe to the clock and act only when the cue under the playhead changes; the panel's rows are `.equatable()`.
   - Background progress (Line Finder scans) is throttled to ~5 Hz and runs at `.utility` priority; any `@StateObject` owned by `ContentView` re-renders the whole window when it publishes.

---

## 6. Compare Modes & Aspect Ratio Invariants

1. **`requiresMatchingAspect` Constraint**:
   - Comparison modes that overlay or slice pixels in the same coordinate frame (`.splitVertical`, `.splitHorizontal`, `.difference`, `.overlay`) require Slot A and Slot B to share identical aspect ratios.
   - If two loaded deliverables have different aspect ratios, the engine automatically falls back to `.sideBySide` and disables overlay/split options in the UI to avoid geometric tearing and misaligned pixel comparison.
2. **Independent Aspect Ratios in Side-by-Side**:
   - `.sideBySide` (Horizontal) and `.sideBySideVertical` compute separate sub-viewport bounds for each slot, preserving the native aspect ratio of each deliverable without clipping or distorting either video.
3. **Blink Compare (`isBlinkCompareB`)**:
   - Blink is a toggle overlay on `.single` mode (not a distinct `CompareMode` case). When active, `updateLayerVisibility` hides all A-slot layers and shows only the B-slot layer, creating a clean A↔B blink toggle.
   - `isBlinkCompareB` auto-disables if `compareMode` changes away from `.single`, and auto-syncs Slot B when linked.

4. **Images & Audio (`PlayerSlot.mediaKind`)**:
   - The kind is decided once per load from the extension (`QCUtilities.mediaKind(of:)`). Video code paths are unchanged; non-video slots opt out of them instead of each feature checking.
   - **Image**: no `AVPlayerItem` (the slot's player has none, `hasTimeline == false` when it is slot A: no time observer, play, step or scrub). The ImageIO-decoded `stillImage` is shown on `stillFrameLayer` and stays visible while scrubbing slot B. An item-less `AVPlayer` still reports the previous file's time, so never read `slotA.player.currentTime()` when slot A is an image.
   - **Audio**: normal `AVPlayerItem`, but no video output, frame extractor or exposure composition. The slot's `stillImage` is a rendered info card.
   - **Waveform** (opt-in, queue WAVE toggle = `drawsWaveforms`, off by default): slot A's audio (audio files and videos) is drawn in a lane under the scrub track (`AudioWaveform`: 8 kHz mono decode of the audio track only, once per file at `.utility`, cancellable, cached; drawn by an equatable `Canvas`, never per frame). Vertical scrolling over the lane resizes it (elsewhere on the timeline the wheel still scrubs) (`waveformLaneHeight`, 20–200 pt); the timeline sizes itself, so callers must not fix its height.
   - TAB between two audio slots switches `audioSlot` with the blink.
   - **Kind filter** (`MediaKindFilter`, bit mask in `@AppStorage`, shared by queue and Specs): icon toggles appear only when a list mixes kinds; a mask that would hide every kind present shows everything.
   - **Image sequences** (`ImageSequence.swift` in VideoQCLib, `ImageSequencePlayback.swift`): numbered stills (≥ 6, same folder/prefix/extension) are detected by file name only and collapsed to their first frame in `scanAssetInputs` / refresh (`ImageSequenceStore.collapse`); the per-sequence choice (sequence vs single images) and frame rate are remembered. A sequence slot is `mediaKind == .video` with `slot.sequence` set: its item is a 1-frame placeholder clip stretched to the sequence length plus a custom `AVVideoCompositing` that draws each frame from `SequenceFrameSource` (ImageIO decode, ~256 MB LRU, 8-frame read-ahead), so playback, scrub (AVPlayerLayer), A/B sync and timecode use the normal pipeline. **Paused frames come from `slot.sequenceSource`, not the video output** (AVFoundation doesn't re-run the compositor for 1-frame seeks of a single-sample source). The compositor applies EV itself: never install/remove the CIFilter exposure composition on a sequence slot. Gaps render as a dark red MISSING FRAME card and are flagged in Specs.

---

## 7. Audio Routing & Slot Exclusivity

1. **Mutual Audio Exclusivity (`updateAudioVolumes`)**:
   - Only one slot plays audio at any given time: `audioSlot == .slotA` or `.slotB`.
   - The inactive slot's audio volume is strictly set to `0.0`.
   - Simultaneous audio output from both slots is strictly prohibited to avoid acoustic comb filtering, phase cancellation, and core audio mixer clipping.
2. **Global Mute Override**:
   - When `isMuted == true`, both slots are forced to `0.0` volume regardless of the selected `audioSlot`.

---

## 8. Keyboard Event Routing & Text Input Shielding

1. **First-Responder Text Field Shielding**:
   - `KeyboardShortcutRouter` intercepts key events application-wide.
   - When a text field (`NSTextView`, `NSTextField`, search bars, QC notes editor, EV number field) is the active first responder, transport and navigation shortcuts (Space, J/K/L, arrow keys, numbers) **MUST be bypassed**.
   - Pressing ESC or Return inside a text field unfocuses the responder (`makeFirstResponder(nil)`).
2. **Modal Scope Protection**:
   - When a modal dialog is active (`isModalActive == true`), background shortcuts must be blocked to prevent accidental state mutations behind the modal.

---

## 8b. Notes Sync (`NotesSync.swift`, `server/notes-sync`)

- Off unless `AppConfig.notesSyncServer` is set and at least one project (name + password, `NotesSyncProject` in UserDefaults) is added (gear menu → Synced Projects, `NotesSyncModalView`). Several projects can be connected at once; each clip is assigned to one (`assignments.json`, keyed by file name + size): the project that already has notes for it, else the default project once it has local notes, or the one picked in the Notes drawer's SYNC bar. Unassigned clips are probed in every project on each poll. Room id, clip ids (HMAC of file name + size) and the ChaChaPoly key all derive from the password; the Worker stores opaque blobs with an optimistic `version` (409 → re-fetch, merge, retry).
- Merge is three-way against the last synced notes (`Application Support/QCpie/NotesSync`): `QCNotesManager.threeWayMerge`. Plain `merge` cannot sync deletions or un-resolving.
- Only the clip whose notes are shown is polled (10 s, `?since=` → 204 when unchanged); saves push via `ContentView.saveNotes`. All network, crypto and JSON run on the `NotesSync` actor; the main thread only receives `NotesSync.didMergeRemoteNotes` when notes actually changed (new notes then show as a `+N` cloud badge on the Notes tab until it is viewed: `ContentView.unseenSyncedNoteIDs`). `NotesSyncStatus` publishes on state/project changes only and is observed only by the Settings modal and the drawer's `NotesSyncProjectBar`.

## 8c. Settings Menu & User Settings

- The gear menu opens separate popups: **User Settings** (`UserSettingsModalView`), **Theme & Accents** (`ThemeSettingsModalView`), **Synced Projects** (`NotesSyncModalView`, `SettingsModalShell`). User Settings (Premiere-style preferences) and the **User Guide** (Apple-help style, `UserGuideView.chapters`) share `SidebarModalShell`: source list on the left, detail on the right. Each popup's flag must be in `isAnyModalActive` and `dismissTopmostModalOrFullscreen`.
- Launch defaults live in `UserPreferences` (start muted, link A/B, clip info overlay, show queue) and are read once by `PlayerEngine`/`ContentView` at creation; autoplay, waveforms and queue/specs view modes are the existing live settings.

---

## 8d. Scan tab → Line Check (`EdgeDetector.swift`, `VideoScanner.swift`)

- **Benchmark before and after every detector change**: `scripts/LineFinderBench/run.sh` (Command Line Tools only; the swift-testing suite needs Xcode). It runs the synthetic v1/v2 cases (`Tests/LineFinderScenes.swift`, shared with `LineDetectorTests`), per-frame cost, and real-footage ground truth from `_TEST` (local, git-ignored). It must print ALL PASSED.
- **Colour rule**: a pixel is the target only if its residual is within `colorResidualRatio` (0.5) of the line's own strength α·|T − R| (or the noise floor). The old loose rule (0.3·|T − R|) let grey columns pass as green and green lines as white; lines passing only the loose rule are **off-colour**: reported separately, always weak (persistence-gated), toggle `reportOffColorLines`.
- **Split seams**: compared with the picture 2 px and `edgeDepth + 1` px away; a seam pixel needs a strict match on one side and a loose match on the other (a blended seam's base belongs to one side). A coarse pre-check (every 8th sample) skips rows/columns that can't hold a seam (11.5 → ~2 ms/frame at 1080p). Black/white targets need α ≥ 0.6 for seams: partial dark/bright seams are indistinguishable from window frames and table edges.
- **Letterbox / pillarbox**: when an edge has a uniform near-black bar thicker than `edgeDepth`, the picture edge inside the bar is scanned too (not for a black target); `LineDetection.position` holds the bar depth (edges) or the seam row/column (splits, buffer coordinates).
- Frame numbers come from sample timestamps rounded to the nearest frame (`VideoScanner.frameIndex`), not from counting decoded samples: the Player seeks to frame centres, so frame n is the n-th sample, and on a 600 time base (QuickTime, iPhone) NTSC-rate timestamps sit up to half a tick early, where `floor` lands one frame low. Timecodes stay 0-based NDF like the rest of the app.
- A file that can't be opened or stops decoding early is never clean: `VideoQCResult.readError` / `FrameCheckResult.readError` flag it (lines found before the failure are kept) and the results and reports show it as Unreadable.
- Edge lines must start within `edgeDepth`; when a band fills the whole scan depth it is followed `thickLineMargin` (16) px further to find where it stops, so lines as thick as the edge depth are caught. That second pass runs only in that case.
- **Throughput is hardware-decode bound** (measured, M4 Max 1080p H.264: one decode stream ~950 fps, two ~1,780, more add nothing; detection ~0.1–1.3 ms/frame overlaps fully). Files run two at a time and a file ≥ 20 s is read as **two segments in parallel** (`VideoScanner.splitMinimumSeconds`): each segment reads 3 frames past the split and keeps only its side, frame numbers count from the first segment's first sample, so results are identical to one pass (verified on `_TEST`: all 204 flagged frames). Machines with two decode engines (M1/M2 Ultra) scan roughly twice as fast.

---

## 8e. Scan tab → Frame Check (`FrameCheck.swift`)

- One decode pass per video finds three things: **frame-rate mismatch** (stutter), **flash frames** and **Media Offline** frames. Results list only flagged files, one row per finding.
- **Benchmark**: `scripts/FrameCheckBench/run.sh` renders clips with known conversions (24→25 repeats, 25→24 / 30→25 skips, 3:2 pulldown, 24→25 blending), flash frames (black mid-shot, white at a cut, 2-frame solid colour), a Media Offline card, and clean controls (hold + cut, static, one-off repeat, dip to black with black head/tail, orange/magenta graphics); then it reports the `_TEST` clips. Must print ALL PASSED. Real ground truth: CK_HOME26 E3.0 (25 fps) = 23.976 → 25 (1 repeat every 24 frames); everything else in `_TEST` is clean.
- Same parallelism as Line Check: two files at a time, files ≥ 20 s split into two segments (the second starts 3 frames early so kept frames have their neighbours for motion, blend and shift); results identical to one pass.
- Decode is hardware-scaled to 192 px 4:2:0 (luma + CbCr planes), ~600–3000 fps. Per frame: **motion** (90th-percentile 8×8 block difference: a repeat reads ≤ 0.2), **speed** (region brightness-profile shift in px; a skip reads ~2×), **blend ratio**, and a **look** (luma/chroma p2–p98 spread, mean colour, share of offline-card red).
- **Mismatch only**: repeats/skips count only as a regular cadence (≥ 4 events, ≥ 60% regular spacing); blends only as a cycle (detrended autocorrelation ≥ 0.7 at P, ≤ −0.5 at P/2). One-off repeats/skips/blends are not reported. Repeat bar: ≤ max(0.35, 0.08 × local motion).
- **Flash frame**: 1–2 solid frames (spread ≤ 12; up to fps/12.5 frames at high rates) with a picture (spread ≥ 30) on both sides. Head/tail black, holds and dips to black are not flash frames.
- **Media Offline**: ≥ 60% of the frame in saturated red (Cr ≥ 180, 70 ≤ Cb ≤ 140, Y ≤ 140: Premiere/Resolve/FCP offline cards; excludes orange and magenta).

## 8e2. Inspect → Check Loudness (`Loudness.swift`)

- One decode of the first audio track (`DeliverablesInspector.extractAudioLevels`, Float32 via AVAssetReader) feeds `LoudnessMeter`: K-weighting (vDSP biquads, coefficients for any sample rate), 100 ms sub-blocks → 400 ms momentary / 3 s short-term, gated integrated loudness (−70 abs, −10 rel), LRA (EBU 3342: −20 rel, p10–p95), true peak with the BS.1770-4 Annex 2 48-tap 4× interpolator (vDSP_conv), plus channel notes (silent channel, out of phase, dual mono). Channel weights come from the track's channel layout labels (LFE excluded, surrounds 1.41; AAC 5.1 decodes C L R Ls Rs LFE, so never assume an order when labels exist); unlabelled 6-channel audio is taken as SMPTE order. Clips shorter than one 400 ms block are measured as a single block. Late results of a cancelled run are dropped (`audioAnalysisRun`).
- `peakDB` = true peak; mute = nothing above the gate or true peak < −60 dBTP. Pass/warn/fail is evaluated at display/export time against `LoudnessTarget` (`prefLoudnessTarget`, Settings → Loudness), so changing the target recolours without re-measuring.
- **Benchmark**: `scripts/LoudnessBench/run.sh` compares against ffmpeg `ebur128=peak=true` (integrated ±0.1 LU, true peak ±0.5 dB, LRA ±0.5 LU) and an exact inter-sample-peak case (ffmpeg over-reads it). Must print ALL PASSED.

## 8e3. Legal Range (`LegalRange.swift`: Frame Check + Player zebra)

- Presets (`LegalRangeSpec`): **EBU R103 (UK)** is the default (luma −1…103 %, R′G′B′ −5…105 %, frames flagged when > 1 % of the picture is out), Strict 0…100 %. The choice lives on `PlayerEngine.legalRangePreset` (mirrored to UserDefaults `prefLegalRangePreset`), shared by the Scan tab menu and the zebra's context menu; Frame Check reads it at scan start.
- **Frame Check decodes narrow range (`420v`)**: a full-range output clips super-whites/blacks before they can be measured (verified: Y 250 decodes as 255). The legal measure runs on the raw codes; the other Frame Check measures get a LUT expansion to full range, so their thresholds are unchanged.
- Measured per 2×2 block (`LegalRangeBlocks`): luma per pixel, gamut with the block's mean luma, then 4-neighbour erosion. Without these, 4:2:0 chroma smear at hard edges (white text on red reads 130 %) and scaler/codec ringing flag clean graphics and colour bars; at the 192 px analysis size an un-eroded check flagged a `_TEST` clip that a full-resolution check (0.25 % of pixels) shows legal. Flagged frames ≤ ½ s apart form one run.
- **Zebra** (`showLegalZebra`): sublayers of `stillFrameLayerA/B` (they inherit split masks, frames and visibility), **paused only**, hidden while playing/scrubbing and in difference/overlay modes. Each mask is one frame decoded with `AVAssetReader` off the main thread (≤ 1920 px, ~30 ms at 1080p long-GOP) 80 ms after stepping settles, keyed by file/frame/preset; nothing runs on the playback or scrub path. It shows source levels (no EV), same blocks as the scan. Image sequences, stills and audio have no zebra.
- Benchmark: `scripts/FrameCheckBench/run.sh` includes super-white, super-black, illegal-colour, sub-1 % speck and full-swing bars cases plus zebra frame accuracy (H.264 long GOP, ProRes). Must print ALL PASSED.

## 8f. Missed Line Report (`MissedLineReporter.swift`, Player timecode bar)

- MISSED LINE sends the frame on screen for the active slot (`notesTargetURL`), captured with `captureCurrentFrame(applyingExposure: false)` (original pixels; EV is noted in the email), as a lossless PNG to the notes-sync Worker (`POST /v1/frames`, KV binding `FRAMES`, 90-day TTL), then emails clip / timecode / settings / Line Check findings / reviewer / frame link via Web3Forms. Encoding runs off the main thread; nothing runs during playback (it pauses first).

---

## 8g. Type Scale & Button Size

- All UI text uses `Font.ui(size:weight:)`, which snaps to six sizes (`TypeScale`: 10 caption, 11 small, 12 body, 13 emphasis, 15 title, 22 large title) and multiplies by the Button Size factor (Small 1.0, Medium 1.2, Large 1.25). Never pass `StudioTheme.scaleFont` into `.ui` (double scaling); `.system(size:)` fonts (icons, monospaced) go through `StudioTheme.scaleFont`.
- Bars that can run out of width degrade instead of clipping: the timecode bar's Notes/Tags/Missed Line drop to icons (`ViewThatFits`), the queue tools wrap under "Queue (n)", Inspect stats sit on their own row. Check all three Button Sizes when changing a toolbar.

## 9. Pre-Commit Checklist for Future Amends

Before committing any changes affecting `VideoViewportView.swift`, `PlayerEngine.swift`, `PlayerTransportDeckView.swift`, or `KeyboardShortcutRouter.swift`:
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

## 10. Absolute Workflow & Operational Directives

> **INVIOLABLE OPERATIONAL DIRECTIVE**
>
> 1. **DO NOT commit to git (`git commit`)** unless the user explicitly requests a commit in their prompt.
> 2. **DO NOT push to remote repositories (`git push`)** unless the user explicitly requests a push.
> 3. **DO NOT run packaging/release scripts (`BuildApp.sh`, `CreateDMG.sh`, etc.)** unless the user explicitly instructs to package or build the release.
> 4. **Testing code changes**: ALWAYS use `swift build` (quick debug build) to verify compilation correctness and 0 errors/warnings. Never commit or package as part of routine verification.

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
