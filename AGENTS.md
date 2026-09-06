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
1. **Dual Layers per Slot**:
   - `playerLayerA` & `playerLayerB` (`AVPlayerLayer`): Active **ONLY** when actively playing (`isPlaying`) or actively scrubbing (`isScrubbing`).
   - `stillFrameLayerA` & `stillFrameLayerB` (`CALayer` backed by uncompressed `CGImage` in `contents`): Active **ALWAYS** when paused (`!isPlaying && !isScrubbing`).
2. **Why Static `CALayer.contents` is Immune**:
   - CoreAnimation treats a `CALayer` with a static `CGImage` as an immutable GPU texture. It **never** applies CoreMedia dynamic proxy downsampling during panning, scrolling, or zooming. The 1-pixel edge line remains solid green at all times.
3. **Compare Modes Synchronization**:
   - Every compare mode (single, split vertical, split horizontal, side-by-side, side-by-side vertical, difference, 50% overlay, blink) **MUST** update and synchronize **both** the live player layers and the still frame layers (`frames`, `masks`, `compositingFilter`, `opacity`, `zPosition`, CIFilters).
4. **Stale Frame Suppression & 1-Frame Glitch Prevention**:
   - `stillFrameLayerA` and `stillFrameLayerB` **MUST ONLY** be unhidden when their captured image timestamp verified-matches the current playhead time (`abs(lastCapturedTime - currentTime) < 0.03s`).
   - If the playhead moves (seeking, scrub clicks in timeline, or upon pausing before the new still frame has finished extracting), the still frame layer **MUST remain hidden**, allowing the live `AVPlayerLayer` to seamlessly display the frame.
   - During active playback (`isPlaying`), still frame contents must be purged to `nil` so stale textures can never flash.

---

## 2. Layer Gravity & Texture Filtering Rules

1. **`videoGravity = .resize` and `contentsGravity = .resize`**:
   - **DO NOT** change these to `.resizeAspect`.
   - `canvasLayer.bounds` (`baseSize`) is already calculated to match the video's exact aspect ratio down to the pixel.
   - Using `.resizeAspect` introduces floating-point subpixel rounding discrepancies inside `AVPlayerLayer`, causing 1-pixel letterbox/pillarbox bars that clip or wash out edge lines.
2. **Dynamic Magnification Filter (`.linear` for Fit/100%, `.nearest` for 200%+ QC Zoom)**:
   - At normal viewing scales (`isFitZoom` or `zoomScale < 1.75`), `magnificationFilter` must be `.linear`. Using `.nearest` at normal/fit scale on Retina displays causes severe nearest-neighbor aliasing, jagged text/subtitles, and stair-stepped graphics when paused.
   - When users zoom into 200%, 400%, or 800% (`zoomScale >= 1.75`) to inspect edge line glitches, `magnificationFilter` dynamically switches to `.nearest` so pixels are displayed as sharp, discrete square pixels.
   - Using `.linear` at 400% causes bilinear interpolation that blurs edge pixels into neighboring white pixels, while using `.nearest` at 100%/Fit causes jagged graphics. Dynamic switching gives both broadcast fidelity and pixel-accurate QC inspection.
3. **`minificationFilter = .linear`**:
   - Preserves smooth anti-aliased representation when zoomed out to fit smaller displays.

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
- [ ] Verify `updateLayerVisibility()` displays still frame layers when paused and live player layers when playing.
- [ ] Verify `videoGravity` and `contentsGravity` remain `.resize`.
- [ ] Verify dynamic `magnificationFilter`: `.linear` at normal/fit zoom for smooth broadcast playback & paused graphics; `.nearest` at >= 1.75x (200%+) for sharp pixel QC.
- [ ] Verify `layer.setNeedsDisplay()` is NEVER called on `playerLayer` or `stillFrameLayer`.
- [ ] Verify `playerLayer.filters` is NEVER assigned a `CIFilter` (live video filtering belongs in `AVVideoComposition`).
- [ ] Run `swift build` with 0 warnings/errors under Swift 6.
- [ ] Test in canvas mode: Zoom into an edge line, pause, and drag the canvas around with the hand tool. Verify the line **does not** turn white during motion.
- [ ] Test exposure slider: Scrub EV from -5.0 to +5.0 EV while paused and while playing. Verify video never disappears and exposure brightens/darkens smoothly.
