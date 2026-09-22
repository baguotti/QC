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
   - *How Live Playback Works*: Each `PlayerSlot` attaches an `AVPlayerItemVideoOutput` (32BGRA). `VideoViewportView` uses AppKit's native `CADisplayLink` (synchronized to 60Hz / 120Hz ProMotion). On each display tick, frames are extracted via `copyPixelBuffer` and converted zero-copy to `CGImage` via `VTCreateCGImageFromCVPixelBuffer` (<0.14 ms per frame), then set directly to `stillFrameLayer.contents`.
2. **Why Static `CALayer.contents` is Immune While Paused**:
   - CoreAnimation treats a `CALayer` with a static `CGImage` as an immutable GPU texture. It **never** applies CoreMedia dynamic proxy downsampling during panning, scrolling, stepping, or zooming while paused. The 1-pixel edge line remains solid green at all times.
3. **Compare Modes Synchronization**:
   - Every compare mode (single, split vertical, split horizontal, side-by-side, side-by-side vertical, difference, 50% overlay, blink) operates directly and cleanly on both `playerLayerA/B` (during scrub) and `stillFrameLayerA/B` (when paused/playing) (`frames`, `masks`, `compositingFilter`, `opacity`, `zPosition`).
   - **Blink mode** has a unique visibility pattern: `updateLayerVisibility` hides *both* A-slot layers (`playerLayerA` and `stillFrameLayerA`) entirely, displaying only the B-slot layer (`stillFrameLayerB` when paused/playing, `playerLayerB` when scrubbing). This is distinct from all other compare modes where A-slot layers remain visible.
4. **Instant Seeking & Frame Delivery**:
   - When scrubbing ends or stepping, exact frame seek (`.zero` tolerance) snaps to the exact target frame, and `displayImmediateDecodedFrame` or `slot.frameExtractor.capture(at:)` delivers the uncompressed still frame immediately.

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
2. **Warm Generator Cache (<10ms)**:
   - Creating a new `AVAssetImageGenerator` on every frame takes ~122ms.
   - Reusing the warm generator inside `FrameExtractor` executes in **~9.8ms**, providing near-instant still frame display upon pausing or stepping.
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
3. **Dual-Pipeline Exposure Architecture**:
   - **Playback & Paused Inspection (`stillFrameLayerA/B`)**: Exposure is applied directly to the uncompressed `CGImage` via `ExposureAdjuster.shared.applyExposure(to:ev:)` using a GPU-accelerated `CIContext` (<3.2ms per 1080p frame). The result is set directly to `stillFrameLayer.contents`, keeping the texture 100% immune to motion-downsampling during canvas panning and zooming.
   - **Active Timeline Scrubbing (`playerLayerA/B`)**: When the hardware layers are temporarily revealed for dragging, exposure is applied via `slot.player.currentItem.videoComposition` using `CIExposureAdjust`. When EV is 0.0, `videoComposition` is set to `nil` for zero playback overhead.
   - This dual approach ensures exposure remains identical across playback, paused inspection, zooming, and active scrub scrubbing.

---

## 5. Timeline Scrubbing Architecture & Dual-Slot A/B Performance Awareness

> **AWARENESS NOTE FOR FUTURE AMENDS & TROUBLESHOOTING**
>
> Dual-slot A/B scrubbing performance was optimized to eliminate main-thread stuttering on high-spec machines (e.g. Mac Studio M1 Ultra / M3 Max driving 4K/5K displays). Keep the following architecture in mind if modifying scrubbing or playback code:

1. **Zero `@Published` Mutations During Drag Scrubbing (`scrubTo`)**:
   - Never mutate `@Published` properties (such as `slotB.currentTime` or `currentProgress`) inside `scrubTo()`. The `scrubTo()` call path itself is strictly mutation-free.
   - Mutating `@Published` properties during mouse drag triggers Combine `objectWillChange` broadcasts that force SwiftUI to re-evaluate the entire view tree at 120 FPS (`ContentView`, `PlayerTabView`, `TimelineScrubberView`, `VideoViewportView`), saturating the main thread.
   - Timeline playhead dragging is driven 100% locally via `@State private var dragProgress` in `TimelineScrubberView`.
   - *Exception*: The seek-completion handler in `dispatchScrubSeekSlotA` updates `currentFrame` and `currentTimecode` (both `@Published`) to keep the timecode HUD accurate during scrub. This is safe because it fires at seek-completion cadence (throttled by hardware decoder latency), not at raw 120 FPS mouse-event rate. **Do not remove these updates** — they are necessary for timecode display during scrub.
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
   - During continuous linked playback (`isLinked && isPlaying && rate != 0`), `updateCurrentTime` applies a Phase-Locked Loop (PLL) micro-rate adjustment to Slot B's `AVPlayer` to prevent cumulative clock drift between two independent hardware decoders.
   - **Never perform a destructive `seek(to:)` on Slot B while playing** — seeking halts video decode and creates audio pops. The PLL adjusts `slotB.player.rate` by tiny increments to smoothly converge Slot B's playhead onto the target offset.
   - Do not remove or bypass this drift correction when refactoring the time observer or playback code, or A/B sync will gradually diverge during long playback sessions.
6. **Large Queue & View Hierarchy Scalability (100+ Assets)**:
   - **Never use eager `VStack` for asset/file lists**: Always use `LazyVStack` in scrollable queues so only visible rows are instantiated and measured.
   - **Zero Synchronous Disk I/O or JSON Decoding in View Bodies**: Heavy file checks (e.g. `notesCount`) must be backed by an in-memory thread-safe cache (`QCNotesManager.notesCountCache`).
   - **O(1) Equatable Checks (`queueVersion` / `tagsVersion`)**: Never recursively compare large trees (`playerTreeNodes`), dictionaries (`fileTagsMap`), or URL arrays inside `==` on 60/120 FPS render paths. Track integer versions to allow instantaneous equality checks.
   - **Per-Row View Isolation**: Queue row views must conform to and use `.equatable()`, must avoid per-row `@ObservedObject` subscriptions to global singletons, and must use stable URLs/IDs rather than dynamic concatenated strings in `.id(...)`.
   - **AVAssetImageGenerator Throttling**: Cap open thumbnail/frame generator instances (LRU cache) to avoid CoreMedia hardware decoder and file descriptor exhaustion.

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

## 9. Pre-Commit Checklist for Future Amends

Before committing any changes affecting `VideoViewportView.swift`, `PlayerEngine.swift`, `PlayerTransportDeckView.swift`, or `KeyboardShortcutRouter.swift`:
- [ ] Ensure `stillFrameLayerA` and `stillFrameLayerB` are present in `VideoViewportView`.
- [ ] Verify `stillFrameLayerA` and `stillFrameLayerB` are the exclusive visual presentation layers across playback and paused states, with `playerLayerA`/`playerLayerB` revealed exclusively during active scrubbing.
- [ ] Verify `videoGravity` and `contentsGravity` remain `.resize`.
- [ ] Verify adaptive texture filtering operates correctly: `.linear` at fit/normal zoom for QuickTime-grade anti-aliasing, and `.nearest` when zoomed in (>= 1.75x) for pixel QC.
- [ ] Verify rational aspect ratio with even pixel step sizing is used for canvas dimensions and `canvasLayer.masksToBounds` remains `false`.
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
- [ ] Test exposure slider: Scrub EV from -5.0 to +5.0 EV while paused and while playing. Verify video never disappears and exposure brightens/darkens smoothly.

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
