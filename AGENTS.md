# QCpie / LineFinder 5000: Architectural Directives for AI Agents & Developers

> **CRITICAL MANDATE - READ BEFORE MODIFYING PLAYER OR VIEWPORT CODE**
>
> The viewport inspection architecture described below has been accidentally broken and re-fixed twice during past refactorings (e.g. during optimization passes and the A/B dual-slot compare mode introduction).
>
> **DO NOT REMOVE OR BYPASS THE DEDICATED STILL FRAME LAYERS (`stillFrameLayerA` / `stillFrameLayerB`) UNDER ANY CIRCUMSTANCES.**

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
   - Every compare mode (single, split vertical, split horizontal, side-by-side, side-by-side vertical, difference, 50% overlay, blink) operates directly and cleanly on both `playerLayerA/B` (during scrub) and `stillFrameLayerA/B` (when paused) (`frames`, `masks`, `compositingFilter`, `opacity`, `zPosition`).
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
3. **Hardware Playback Exposure (`AVVideoComposition`)**:
   - During live playback (`isPlaying`), exposure adjustment ($I \times 2^{\text{EV}}$) is applied via `slot.player.currentItem.videoComposition` using `CIExposureAdjust`.
   - When EV is reset to 0.0, `item.videoComposition` is set to `nil` for zero playback overhead.
4. **Instant Still Frame Exposure (`ExposureAdjuster`)**:
   - When paused, `ExposureAdjuster.shared.applyExposure(to:ev:)` computes the exposure on the pristine uncompressed `CGImage` using GPU-accelerated `CIContext` (<3.2ms per 1080p frame).
   - The resulting exposed `CGImage` is set directly to `stillFrameLayer.contents`, maintaining an immutable GPU texture that remains 100% immune to motion-downsampling during canvas panning and zooming.

---

## 5. Pre-Commit Checklist for Future Amends

Before committing any changes affecting `VideoViewportView.swift`, `PlayerEngine.swift`, or `PlayerTransportDeckView.swift`:
- [ ] Ensure `stillFrameLayerA` and `stillFrameLayerB` are present in `VideoViewportView`.
- [ ] Verify `stillFrameLayerA` and `stillFrameLayerB` are the exclusive visual presentation layers across playback, scrubbing, and paused states, with `playerLayerA`/`playerLayerB` kept hidden.
- [ ] Verify `videoGravity` and `contentsGravity` remain `.resize`.
- [ ] Verify adaptive texture filtering operates correctly: `.linear` at fit/normal zoom for QuickTime-grade anti-aliasing, and `.nearest` when zoomed in (>= 1.75x) for pixel QC.
- [ ] Verify rational aspect ratio with even pixel step sizing is used for canvas dimensions and `canvasLayer.masksToBounds` remains `false`.
- [ ] Verify `layer.setNeedsDisplay()` is NEVER called on `playerLayer` or `stillFrameLayer`.
- [ ] Verify `playerLayer.filters` is NEVER assigned a `CIFilter` (live video filtering belongs in `AVVideoComposition`).
- [ ] Run `swift build` with 0 warnings/errors under Swift 6.
- [ ] Test in canvas mode: Zoom into an edge line, pause, and drag the canvas around with the hand tool. Verify the line **does not** turn white during motion.
- [ ] Test exposure slider: Scrub EV from -5.0 to +5.0 EV while paused and while playing. Verify video never disappears and exposure brightens/darkens smoothly.

---

## 6. Absolute Workflow & Operational Directives

> **INVIOLABLE OPERATIONAL DIRECTIVE**
>
> 1. **DO NOT commit to git (`git commit`)** unless the user explicitly requests a commit in their prompt.
> 2. **DO NOT push to remote repositories (`git push`)** unless the user explicitly requests a push.
> 3. **DO NOT run packaging/release scripts (`BuildApp.sh`, `CreateDMG.sh`, etc.)** unless the user explicitly instructs to package or build the release.
> 4. **Testing code changes**: ALWAYS use `swift build` (quick debug build) to verify compilation correctness and 0 errors/warnings. Never commit or package as part of routine verification.

---

## 7. Project Behavior Rules

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

### Engineering Standards
- Strict YAGNI: reject speculative abstractions, unnecessary wrappers, and unused dependencies.
- Prefer idiomatic, native implementations over adding new libraries.
- If a simpler, lower-complexity solution exists, implement that instead of patching over-engineered logic.
