---
name: avfoundation-playback-engine
description: AVFoundation low-level video decode pipelines, CADisplayLink synchronization, zero-copy CVPixelBuffer conversion, CoreMedia downsampling prevention, and multi-player PLL drift correction. Use when modifying video viewports, frame extraction, scrubbing, playback clock, or A/B sync.
---

# AVFoundation High-Performance Playback & Inspection Engine

This skill governs low-level AVFoundation video decode pipelines, CADisplayLink vsync synchronization, zero-copy pixel buffer conversion, CoreMedia downsampling immunity, and multi-player phase-locked synchronization.

---

## 1. The CoreMedia Motion-Downsampling Bug & Hybrid Architecture

### The Hardware Bug
On macOS, `AVPlayerLayer` switches to a low-resolution dynamic mipmap/proxy texture whenever the layer or its container moves while paused (e.g. pan, zoom, window resize). A 1-pixel edge glitch (e.g. green line at column 1079) is averaged with neighboring pixels by bilinear downsampling, turning white during motion and popping back only after motion stops.

### The Hybrid Display Invariant
1. **Paused Inspection, Stepping & Continuous Playback (`isScrubbing == false`)**:
   - `stillFrameLayerA` and `stillFrameLayerB` (`CALayer` with uncompressed `CGImage` assigned to `.contents`) are the **exclusive** presentation layers.
   - CoreAnimation treats static `CALayer.contents` as an immutable GPU texture and **never** downsamples during panning or zooming.
   - Live playback frames are acquired via `AVPlayerItemVideoOutput` on each `CADisplayLink` tick and converted zero-copy to `CGImage` via `VTCreateCGImageFromCVPixelBuffer` (<0.14 ms overhead).
   - Unchanged frames are skipped by buffer identity to prevent redundant layer updates.
2. **Active Drag Scrubbing (`isScrubbing == true`)**:
   - `playerLayerA` and `playerLayerB` (`AVPlayerLayer`) are revealed.
   - Frames stream directly through the GPU compositor with zero copy overhead for fluid 60–120 FPS QuickTime-grade scrubbing.
   - `CADisplayLink` is paused during active scrubbing to avoid competing for decoder bandwidth.

---

## 2. Layer Gravity & Adaptive Pixel Filtering

- **Gravity Invariant**: Always use `videoGravity = .resize` and `contentsGravity = .resize`. Never use `.resizeAspect` (it introduces floating-point subpixel rounding and 1-pixel edge letterbox bars).
- **Physical Pixel Alignment**: Compute canvas bounds using rational aspect ratios (`getRationalAspect`) with an even multiplier step count (`evenSteps * num / scale`) to guarantee integer half-dimensions and zero subpixel edge bleeding. Keep `canvasLayer.masksToBounds = false`.
- **Adaptive Texture Filtering**:
  - `zoomScale < 1.75`: Use `.linear` for `magnificationFilter` and `minificationFilter` (smooth anti-aliased presentation).
  - `zoomScale >= 1.75`: Switch `magnificationFilter` to `.nearest` so individual pixels remain discrete, square, and unblurred for pixel QC inspection.

---

## 3. Decoupled Scrub Seeking & Coalescing

- Never lock decoder seek pipelines to each other. Slot A and Slot B must seek independently via `isScrubSeekingA/B` flags and `pendingScrubTimeA/B` timestamps.
- Coalesce rapid scrub movements so decoders jump directly to the latest playhead position without queuing backlogs.
- Use exact `.zero` tolerance seeks only on scrub settle (`endScrubbing`), stepping, and pause inspection.

---

## 4. Linked Dual-Slot A/B Playback & Drift Correction (PLL)

- Two independent `AVPlayer` instances inevitably drift over time due to independent hardware clocks and variable GOP decode latency.
- **Never perform destructive `seek(to:)` on Slot B during continuous playback** (it halts decoders and causes audio pops).
- **Phase-Locked Loop (PLL)**: Apply micro-rate adjustments (`slotB.player.rate = slotA.player.rate + delta`) to gently steer Slot B into phase alignment.
- **Hard Relock (`relockSlotB`)**: If Slot B falls behind by more than 3.5 frames, seek Slot B *ahead* of Slot A and resume using `setRate(_:time:atHostTime:)` at the exact host timestamp Slot A will arrive at that target frame. Rate-limit hard relocks to at most once per second.
