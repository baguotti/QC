---
name: metal-coreimage-video-qc
description: GPU image processing, CoreImage video compositions, CIFilter pipelines, and pixel-level comparison modes (split wipe, difference, overlay, blink) for video QC. Use when implementing visual filters, exposure adjustments, or pixel-difference QC tools.
---

# Metal & CoreImage Video QC Architecture Guide

This skill governs real-time GPU image filtering, CoreImage compositions within AVFoundation, and pixel comparison pipelines for quality control inspection.

---

## 1. Video Exposure & Color Pipelines (`AVVideoComposition`)

### Prohibited Patterns
- **DO NOT assign `CIFilter` to `AVPlayerLayer.filters`**: CoreMedia hardware decode streams (`FigVideoContainerLayer` / `IOSurface`) do not support layer filters on macOS. Assigning filters causes compositor failure and blanks out the entire video view.
- **DO NOT call `layer.setNeedsDisplay()` on presentation layers**: In a `CALayer` backed directly by `layer.contents = cgImage`, calling `setNeedsDisplay()` triggers the default display cycle, which immediately wipes `contents` to `nil`.

### The Single Exposure Pipeline
- Real-time exposure adjustment must be applied through `AVPlayerItem.videoComposition` using `CIExposureAdjust`.
- **Dynamic EV Updates**: The composition handler reads EV values from a thread-safe box (`ExposureValueBox`) on each frame. **Never replace `item.videoComposition` while dragging EV**—rebuilding the composition resets decoder state and drops frames.
- **Zero Double-Exposure**: `AVPlayerLayer` (scrubbing) and `AVPlayerItemVideoOutput` (display loop) both receive frames that have already been composited by the video composition. Do not re-apply exposure when extracting pixel buffers.

---

## 2. Dual-Slot Video Comparison Modes

| Mode | Coordinate Frame | Layer Layout & Blending |
| :--- | :--- | :--- |
| **Split Vertical / Horizontal** | Shared canvas | Dynamic `CAShapeLayer` mask separating Slot A and Slot B with a draggable divider line. |
| **Difference** | Shared canvas | Slot B layer composited over Slot A using `CIDifferenceBlendMode` (identical pixels render pure black; alterations highlight immediately). |
| **50% Overlay** | Shared canvas | Slot B rendered at `opacity = 0.5` over Slot A. |
| **Side-by-Side (H/V)** | Dual sub-viewports | Independent sub-viewport bounds preserving the native aspect ratio of each deliverable. |
| **Blink Compare** | Overlay toggle | Hides both Slot A layers (`playerLayerA` & `stillFrameLayerA`), revealing only Slot B. |

### Aspect Ratio Invariants
- Comparison modes that slice or overlay pixels in the same coordinate frame (`.splitVertical`, `.splitHorizontal`, `.difference`, `.overlay`) require Slot A and Slot B to share identical aspect ratios (`requiresMatchingAspect == true`).
- If aspect ratios diverge, the engine must fall back cleanly to `.sideBySide` to prevent geometric tearing or distorted pixel alignments.

---

## 3. High-Fidelity Screenshot Compositing

- Screenshots must capture deliverables at 100% native unscaled source resolution with active comparison compositing (e.g. split wipes, difference blend, EV adjustment) applied cleanly.
- Do not render screen-space UI elements (playheads, timecodes, labels) into QC screenshot exports.
- Side-by-side exports should retain 1:1 pixel pitch for each slot, letterboxed/pillarboxed with neutral black padding if heights or widths differ.
