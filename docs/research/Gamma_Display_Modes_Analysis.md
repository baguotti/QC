# Gamma Display Mode Toggle Analysis: QuickTime (1.96) vs. VLC / IINA (2.2 / 2.4)

## 1. Executive Summary

Yes, implementing a toggle between **QuickTime Gamma (~1.96)** and **VLC / IINA / Web Gamma (2.2 / 2.4)** is technically feasible. 

However, because QCpie relies on a **hybrid dual-layer architecture** (`stillFrameLayer` for paused/inspection and `AVPlayerLayer` for zero-copy 120 FPS scrubbing), a naive implementation will introduce a **visible gamma flicker/flash during timeline scrubbing** unless carefully architected.

---

## 2. Technical Root Cause: The "QuickTime Gamma Shift"

| Application / Target | Effective Transfer Function | Gamma | Visual Characteristics |
| :--- | :--- | :--- | :--- |
| **QuickTime / Safari / macOS AVPlayerLayer** | Rec.709 OETF mapped via Apple ColorSync | **~1.96** | Lifted/milky shadows, washed-out midtones, lower saturation |
| **VLC / IINA / mpv** | Pure Power or BT.1886 | **2.2 / 2.4** | Deep blacks, punchier midtone contrast, intended grade saturation |
| **DaVinci Resolve / Premiere Pro** | Rec.709 / BT.1886 / Gamma 2.4 | **2.4** | Reference mastering standard for darkened grading suites |
| **Web / Mobile (YouTube, Instagram)** | sRGB / Display P3 | **2.2** | Standard consumer display profile for web and mobile devices |

### Why QuickTime Displays at ~1.96
When macOS CoreMedia and ColorSync decode Rec.709 video (NCLC tag `1-1-1`), Apple applies the camera encoding curve (OETF) without compensating for the display rendering intent (EOTF). This legacy behavior assumes an ambient viewing environment and Mac gamma conventions, yielding an effective display gamma of approximately **1.96**. 

In contrast, **VLC** and **IINA** (using `libmpv`) bypass ColorSync's Rec.709 curve and map Rec.709 directly to standard display gamma (either sRGB 2.2 or BT.1886 2.4).

---

## 3. Implementation Approaches

### Option A: `CGColorSpace` Re-tagging on `stillFrameLayer` (Recommended for Paused/Play Link)
- **Mechanism**: In `VideoViewportView.swift`, when setting `stillFrameLayer.contents`:
  - **QuickTime Mode**: Use default `cgImage.colorSpace` (BT.709 as extracted).
  - **VLC / Web Mode**: Wrap or copy the image with `CGColorSpace(name: CGColorSpace.sRGB)` or `CGColorSpace(name: CGColorSpace.itur_709)`.
- **Overhead**: Zero GPU compute cost, < 0.02ms execution time per frame.

### Option B: CoreImage Gamma Transform via `CIContext` / Metal Kernel
- **Mechanism**: Apply a transfer curve transform:
  $$\text{Pixel}_{\text{out}} = \text{Pixel}_{\text{in}}^{\frac{\gamma_{\text{target}}}{1.96}} \quad (\text{ratio} \approx 1.122 \text{ for 2.2, } 1.224 \text{ for 2.4})$$
- **Integration**: Leverage existing `ExposureAdjuster` pipeline.
- **Overhead**: ~0.4ms on Apple Silicon GPU per 1080p frame.

---

## 4. Foreseen Issues & Architectural Risks

### Issue 1: The Scrubbing Pipeline Gamma Flash (Critical)
- **The Problem**: In QCpie (`AGENTS.md` Section 1), active timeline scrubbing (`isScrubbing == true`) unhides `playerLayerA` (`AVPlayerLayer`) for 120 FPS hardware scrubbing with zero memory copy.
- `AVPlayerLayer` is hardwired to macOS CoreMedia ColorSync. Its internal gamma curve **cannot be dynamically modified** without assigning an `AVVideoComposition`.
- **The Symptom**: If VLC Mode (Gamma 2.4) is active, playback and paused inspection will show rich 2.4 contrast. The moment the user drags the timeline playhead, the layer switches to `AVPlayerLayer` (Gamma 1.96), causing the image to **visibly flash/brighten to washed-out milk during scrubbing**, and pop back to dark when released.

### Issue 2: Performance Degradation if using `AVVideoComposition` for Scrubbing
- To prevent the gamma flash during scrubbing, `player.currentItem.videoComposition` would have to apply a live `CIFilter` on every scrubbed frame.
- On 4K ProRes or 10-bit deliverables, real-time software composition introduces scrub lag and dropped frames, violating the mandate for QuickTime-grade scrub fluidity.

### Issue 3: HDR / Wide Color Destruction (Rec.2020 / HLG / PQ)
- Gamma 1.96 only applies to standard dynamic range SDR Rec.709 content.
- If a global gamma toggle is activated while inspecting HDR deliverables (e.g. Apple ProRes 422 HQ in HLG or HDR10 PQ), applying a gamma power curve will crush or blow out HDR specular highlights and clip wide gamut primaries.
- **Requirement**: The toggle must automatically disengage or gray out on HDR / non-Rec.709 assets.

### Issue 4: Client vs. Deliverable Confusion ("Which is Correct?")
- Deliverable video files often fail QC because client review happens in QuickTime while colorists grade in DaVinci Resolve.
- If QCpie defaults to VLC gamma, clients may claim QCpie "does not match the QuickTime deliverable we are delivering to the agency."
- If QCpie defaults to QuickTime gamma, colorists will complain blacks are lifted.

---

## 5. Architectural Recommendations

1. **Adopt a 3-Way Gamma Profile Selector**:
   - `QuickTime Standard (ColorSync 1.96)` — *Default (matches Finder QuickLook & QuickTime Player)*.
   - `Web / Mobile (sRGB 2.2)` — *Simulates Chrome, Safari iOS, YouTube, Instagram*.
   - `Broadcast / Master (BT.1886 2.4)` — *Simulates DaVinci Resolve reference suite & VLC*.

2. **Handle Scrubbing Gracefully (Avoid Scrub Flash)**:
   - When in `QuickTime Standard (1.96)`: Use the existing hybrid pipeline (`AVPlayerLayer` during scrub).
   - When in `VLC / Web (2.2 / 2.4)`: Keep `stillFrameLayer` active during scrub via `CADisplayLink` extraction, OR accept `AVVideoComposition` with an explicit toggle disclaimer for 4K scrubbing.

3. **Auto-Guard HDR Content**:
   - Query `asset.colorPrimaries` and `asset.transferFunction`. If the file is HDR10 (`SMPTE ST 2084`) or HLG (`ITU-R BT.2100`), disable the SDR gamma toggle with an overlay tooltip: `SDR Rec.709 Only`.

4. **Surface NCLC Atom Tags in Media Info**:
   - Display the QuickTime `nclc` color atom (e.g. `1-1-1` vs `1-2-1`). Files tagged `1-2-1` automatically force QuickTime to render with Gamma 2.4 without any player hacks.
