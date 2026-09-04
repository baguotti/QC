# Dual-Video A/B Comparison & Difference Mode: Engineering Handover Plan

**Document Version:** 1.0.0  
**Target Audience:** Autonomous Coding Agent / LLM Engineer  
**Project:** QC (VideoQCApp / VideoQCLib)  
**Target Repository:** `/Users/wildmacstudio25/Documents/QC`  
**Status:** READY FOR IMPLEMENTATION (Do NOT deviate from scope constraints)

---

## 1. Scope & Architectural Directives

### Mandatory Scope Boundaries (APPROVED BY USER)
1. **Strictly 2 Videos (Slot A and Slot B)**: Do **NOT** build a 4-video player. Do **NOT** build floating/movable freeform window cards.
2. **NO Picture-in-Picture (PiP)**: PiP is explicitly excluded from this implementation.
3. **Difference Matte Mode (Delta / Subtraction Overlay)**: **MANDATORY FEATURE**. Real-time pixel subtraction $|\text{RGB}_A - \text{RGB}_B|$ rendering directly on the GPU to spot compression differences, noise, edge anomalies, and grade deltas.
4. **Interactive A/B Split-Screen Wipe**: Draggable divider line (curtain wipe) allowing pixel-aligned comparison across identical spatial coordinates.
5. **Side-by-Side Mode**: Standard dual-monitor 50/50 horizontal split.
6. **Queue List Assignment**: Assign Slot A and Slot B directly from the existing queue list in `PlayerTabView.swift`.
7. **Single-Video Backward Compatibility**: When only Slot A is loaded, the player MUST look and behave 100% identically to the existing single-video player with zero visual clutter.

---

## 2. Codebase Architecture & File Mapping

```
Sources/
├── VideoQCLib/                 # Core line detection, renamer, and deliverables logic (DO NOT BREAK)
└── VideoQCApp/
    ├── App.swift               # Application entry point
    ├── ContentView.swift       # Master layout, navigation tabs, global state
    ├── Theme.swift             # StudioTheme tokens (cornerRadius, colors, typography)
    ├── PlayerEngine.swift      # [REFACTOR/EXTEND] Current single AVPlayer engine
    ├── VideoViewportView.swift # [REFACTOR/REPLACE] AppKit NSViewRepresentable CALayer viewport
    ├── TimelineScrubberView.swift # Timeline bar, glitch markers, playhead scrubber
    └── PlayerTabView.swift     # [UPDATE] Left Queue list, monitor header, transport strip
```

### Files to Modify / Create

| File | Action | Purpose |
| :--- | :--- | :--- |
| `Sources/VideoQCApp/PlayerEngine.swift` | **MODIFY / EXTEND** | Add dual-slot state (`slotA`, `slotB`), linked transport synchronization, time slip offsets, and comparison mode state. |
| `Sources/VideoQCApp/VideoViewportView.swift` | **REFACTOR** | Implement dual `AVPlayerLayer`s, `CAShapeLayer` split mask, interactive draggable wipe divider, and `"differenceBlendMode"` compositing filter. |
| `Sources/VideoQCApp/PlayerTabView.swift` | **MODIFY** | Add in-row `[A]` and `[B]` badges to `playerFileRow`, queue header target toggle, context menus, and comparison toolbar controls. |
| `Sources/VideoQCApp/ContentView.swift` | **MODIFY** | Update keyboard shortcut handlers (e.g. `Tab` for Blink compare, `X` for Swap A/B) and canvas drop handling. |

---

## 3. Data Model & Engine Architecture

### State Specification in `PlayerEngine.swift`

Extend `PlayerEngine` (or wrap into a dual-player coordinator) so both slots are first-class citizens:

```swift
public enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case single = "Single (A)"
    case splitVertical = "Split Wipe (V)"
    case splitHorizontal = "Split Wipe (H)"
    case sideBySide = "Side-by-Side"
    case difference = "Difference Mode"
    
    public var id: String { rawValue }
}

public enum SlotTarget: String, Sendable {
    case slotA
    case slotB
}

public final class PlayerSlot: ObservableObject {
    public let id: SlotTarget
    @Published public var url: URL? = nil
    @Published public var fileName: String = ""
    @Published public var resolution: String = ""
    @Published public var fps: Double = 25.0
    @Published public var codec: String = ""
    @Published public var duration: CMTime = .zero
    @Published public var currentTime: CMTime = .zero
    @Published public var videoSize: CGSize = CGSize(width: 1920, height: 1080)
    
    public let player = AVPlayer()
    // Slip offset relative to Master (in frames)
    @Published public var slipOffsetFrames: Int = 0
}
```

### Key Engine Properties:
- `@Published public var slotA = PlayerSlot(id: .slotA)` (Master)
- `@Published public var slotB = PlayerSlot(id: .slotB)` (Comparison / Follower)
- `@Published public var activeTarget: SlotTarget = .slotA` (Determines click destination in Queue)
- `@Published public var compareMode: CompareMode = .single`
- `@Published public var splitPosition: CGFloat = 0.5` (0.0 to 1.0, where 0.5 is dead center)
- `@Published public var isLinked: Bool = true` (Gang sync: transport controls drive both players)
- `@Published public var audioSlot: SlotTarget = .slotA` (Solo audio routing)

---

## 4. Viewport & Rendering Pipeline (`VideoViewportView.swift`)

The viewport must be built using native AppKit `CALayer` hierarchy for zero-copy, 120fps hardware compositing.

### CALayer Hierarchy Diagram

```
PlayerContainerNSView (wantsLayer = true)
  │
  └── canvasLayer (centered container for zoom & pan)
        │
        ├── playerLayerB (Underneath: displays Slot B video full-frame)
        │
        ├── playerLayerA (On top: displays Slot A video full-frame)
        │     │
        │     └── maskLayer: CAShapeLayer
        │           (In Split Mode: clips playerLayerA to bounds [0, 0, splitX, height])
        │           (In Single/Difference Mode: unmasked)
        │
        ├── splitDividerLayer: CALayer (1.5px cyan vertical divider line)
        │     │
        │     └── splitHandleLayer: CALayer (draggable pill thumb icon: [ ◄► ])
        │
        └── crosshairLayer: CAShapeLayer (existing center guide overlay)
```

### Implementing Difference Matte Mode (Delta Overlay)
CoreAnimation on macOS natively supports CoreImage blend filters directly on `CALayer`:

```swift
private func applyCompareMode(_ mode: CompareMode) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    
    switch mode {
    case .single:
        playerLayerB.isHidden = true
        playerLayerA.isHidden = false
        playerLayerA.mask = nil
        playerLayerA.compositingFilter = nil
        splitDividerLayer.isHidden = true
        layoutSingleLayer(playerLayerA)
        
    case .splitVertical:
        playerLayerB.isHidden = false
        playerLayerA.isHidden = false
        playerLayerA.compositingFilter = nil
        splitDividerLayer.isHidden = false
        
        // Mask Layer A to left half
        updateSplitWipeMask(horizontal: false)
        
    case .splitHorizontal:
        playerLayerB.isHidden = false
        playerLayerA.isHidden = false
        playerLayerA.compositingFilter = nil
        splitDividerLayer.isHidden = false
        
        // Mask Layer A to top half
        updateSplitWipeMask(horizontal: true)
        
    case .sideBySide:
        playerLayerB.isHidden = false
        playerLayerA.isHidden = false
        playerLayerA.mask = nil
        playerLayerA.compositingFilter = nil
        splitDividerLayer.isHidden = true
        layoutSideBySideLayers()
        
    case .difference:
        // PIXEL DIFFERENCE MATTE
        // Video A is composited directly over Video B using difference blend mode
        playerLayerB.isHidden = false
        playerLayerA.isHidden = false
        playerLayerA.mask = nil
        playerLayerA.frame = playerLayerB.frame
        
        // Native GPU CoreAnimation difference blend
        playerLayerA.compositingFilter = "differenceBlendMode"
        splitDividerLayer.isHidden = true
    }
    
    CATransaction.commit()
}
```

> **Why this is critical:** Using `playerLayerA.compositingFilter = "differenceBlendMode"` computes $|\text{RGB}_A - \text{RGB}_B|$ directly in the macOS WindowServer Metal pipeline. It requires zero CPU memory copies, works with 4K 60fps video, and renders pixel differences with 100% hardware acceleration.

---

## 5. Queue List Assignment UI (`PlayerTabView.swift`)

The left sidebar queue list (`playerFileRow`) must be upgraded to support assigning both Slot A and Slot B cleanly:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  QUEUE (12)            TARGET: [ • SLOT A ] [ SLOT B ]    [ ⇄ SWAP ]    │
├─────────────────────────────────────────────────────────────────────────┤
│  ▌ ▶ Master_ProRes422_v01.mov                 [ A: MASTER ]  [ +B ]     │
│    3840x2160 • 25.0fps • ProRes 422HQ                                   │
├─────────────────────────────────────────────────────────────────────────┤
│  ▌ ▶ Delivery_H264_1080p_v01.mov              [ +A ]    [ B: COMPARE ]  │
│    1920x1080 • 25.0fps • H.264                                          │
├─────────────────────────────────────────────────────────────────────────┤
│    ▶ Archive_Clean_v02.mov                    [ +A ]    [ +B ]          │
│    1920x1080 • 25.0fps • ProRes 422                                     │
└─────────────────────────────────────────────────────────────────────────┘
```

### Implementation Details for `playerFileRow`:
1. **Badges**:
   - If `slotA.url == url`, show `[ A: MASTER ]` badge (styled with `StudioTheme.positive` or Cyan).
   - If `slotB.url == url`, show `[ B: COMPARE ]` badge (styled with Amber/Orange).
   - If neither, show subtle ghost buttons `[ +A ]` and `[ +B ]` on row hover.
2. **Row Click Logic**:
   ```swift
   Button(action: {
       if NSEvent.modifierFlags.contains(.option) {
           engine.loadVideo(url: url, into: .slotB)
       } else {
           engine.loadVideo(url: url, into: engine.activeTarget)
       }
   })
   ```
3. **Context Menu**:
   ```swift
   .contextMenu {
       Button("Set as Slot A (Master)") { engine.loadVideo(url: url, into: .slotA) }
       Button("Set as Slot B (Compare)") { engine.loadVideo(url: url, into: .slotB) }
       if engine.slotB.url != nil {
           Divider()
           Button("Swap Slot A ⇄ B") { engine.swapSlots() }
           Button("Clear Slot B (Single Mode)") { engine.clearSlotB() }
       }
       Divider()
       // Existing Tags and Reveal in Finder options...
   }
   ```
4. **Viewport Drag-and-Drop Drop Zones**:
   - Update `.onDrop` on the viewport:
     - Drop location $X < \text{width} / 2$: Loads into `.slotA`.
     - Drop location $X \ge \text{width} / 2$: Loads into `.slotB`.

---

## 6. Playback Synchronization & Transport Controls

### Host-Time Scheduled Playback
To avoid the 2–5 frame asynchronous decode drift when starting playback:

```swift
public func playSynchronized(rate: Float = 1.0) {
    guard slotA.player.currentItem != nil else { return }
    
    if !isLinked || slotB.url == nil {
        slotA.player.rate = rate
        return
    }
    
    // Host-Clock synchronization for locked multi-stream playback
    let hostClock = CMClockGetHostTimeClock()
    let anchorTime = CMClockGetTime(hostClock) + CMTime(seconds: 0.08, preferredTimescale: 1000)
    
    slotA.player.setRate(rate, time: slotA.player.currentTime(), atHostTime: anchorTime)
    
    // Calculate follower time accounting for slip offset
    let offsetSeconds = Double(slotB.slipOffsetFrames) / max(1.0, slotB.fps)
    let targetTimeB = CMTime(seconds: CMTimeGetSeconds(slotA.player.currentTime()) + offsetSeconds, preferredTimescale: 600)
    
    slotB.player.setRate(rate, time: targetTimeB, atHostTime: anchorTime)
    self.isPlaying = true
}
```

### Seeking & Scrubbing
- Scrubbing the timeline scrubber drives `slotA.player.seek(to: toleranceBefore: .zero, toleranceAfter: .zero)`.
- When `isLinked == true`, calculate target time for Slot B ($\text{Time}_A + \Delta_{\text{offset}}$) and execute frame-accurate zero-tolerance seek on `slotB.player`.

### Audio Routing (Solo Active)
- By default, `slotA.player.volume = 1.0` and `slotB.player.volume = 0.0`.
- If user toggles audio to Slot B (or presses key `B`), crossfade: `slotA.volume = 0.0`, `slotB.volume = 1.0`.

---

## 7. Comparison Toolbar in Monitor Header

In `playerMonitorHeader` (`PlayerTabView.swift`), when `slotB.url != nil`, render the comparison control strip:

```
[ SINGLE (A) ]  [ SPLIT WIPE ]  [ SIDE-BY-SIDE ]  [ DIFFERENCE ]  |  [ ⇄ SWAP ]  [ LINK: ON ]  [ SLIP: -2 F ]  [ ✕ CLEAR B ]
```

- **Compare Mode Picker**: Segmented buttons for Single, Split Wipe, Side-by-Side, Difference.
- **Link Toggle**: Lock/unlock playheads.
- **Slip Nudge Buttons (`[-1F]`, `[+1F]`)**: Allows slipping Slot B forward or backward by 1 frame to align unsynced slates or head-leaders.
- **Blink / Flicker Shortcut (`Tab` or `\`)**: Rapidly toggles between 100% Slot A and 100% Slot B.

---

## 8. Step-by-Step Implementation Instructions for the LLM

Follow these phases sequentially. Test each phase before advancing.

### Phase 1: Dual Player Engine Refactor
1. Open `Sources/VideoQCApp/PlayerEngine.swift`.
2. Add `PlayerSlot` or refactor existing properties into `slotA` and `slotB`.
3. Add `loadVideo(url: URL, into: SlotTarget)`.
4. Ensure all existing single-player features (markers, glitch cycler, JKL shuttles, frame capture) continue functioning flawlessly when targeting `slotA`.
5. Implement `swapSlots()` and `clearSlotB()`.

### Phase 2: Queue UI & Slot Assignment
1. Open `Sources/VideoQCApp/PlayerTabView.swift`.
2. Update `playerMonitorHeader` and `playerFileRow` to display `[A]` and `[B]` badges.
3. Add the Queue Header target toggle (`[• SLOT A] [SLOT B] [⇄ SWAP]`).
4. Add context menu items (`Set as Slot A`, `Set as Slot B`).
5. Add `⌥ + Click` modifier on rows to load directly into Slot B.

### Phase 3: Viewport Layer Compositing & Difference Mode
1. Open `Sources/VideoQCApp/VideoViewportView.swift`.
2. Add `playerLayerB` into `canvasLayer` underneath `playerLayerA`.
3. Implement `CAShapeLayer` mask for `playerLayerA` to support vertical/horizontal split wipe.
4. Implement mouse drag tracking for the split divider line.
5. Implement **Difference Mode**:
   ```swift
   playerLayerA.compositingFilter = "differenceBlendMode"
   ```
6. Add Side-by-Side layout calculations when `compareMode == .sideBySide`.

### Phase 4: Gang Transport, Slip Offset & Shortcuts
1. Connect `playSynchronized`, pause, and seek routines across both players.
2. Add slip offset adjustment methods (`nudgeSlip(frames: Int)`).
3. Connect keyboard shortcuts:
   - `Tab`: Blink / Flicker compare between A and B.
   - `X`: Swap Slot A and Slot B.
   - `Space` / `J` / `K` / `L`: Gang synchronized playback.
4. Audio solo enforcement.

---

## 9. Verification & Quality Assurance Checklist

Once implemented, run the following verification steps:

- [ ] **Build Validation**:
  ```bash
  swift build
  ```
  Must compile with zero errors and zero warnings.
- [ ] **Single Mode Sanity**:
  - Load a single video into Slot A.
  - Verify that no comparison toolbar appears and that the player functions 100% identically to QC v0.2.4.
- [ ] **Slot B Ingestion**:
  - `⌥ + Click` a second video in the Queue list.
  - Verify Slot B loads, badges update, and the comparison toolbar appears.
- [ ] **Split Wipe Verification**:
  - Drag the split divider handle left and right.
  - Verify zero lag (smooth 60/120fps dragging) and correct video reveal.
- [ ] **Difference Matte Verification**:
  - Switch to **Difference Mode**.
  - If File A and File B are the exact same file, verify the screen is pitch black.
  - If File B is a compressed or graded version, verify differences glow clearly.
- [ ] **Gang Playback Sync**:
  - Press `Space` or `L`. Both videos must start simultaneously with zero frame jitter.
  - Press Left/Right arrow keys. Both videos must step frame-by-frame in lockstep.
- [ ] **Audio Sanity**:
  - Verify that audio only outputs from the selected slot with no phase echo.
- [ ] **Slot B Clearing**:
  - Click `[✕ CLEAR B]`.
  - Viewport should instantly collapse back to single-video view.

---

## 10. Summary Handover Command

When the executing LLM begins, execute from the workspace root:
```bash
# Verify current clean build before making any edits
swift build
```
Follow the instructions in this document directly. All specifications are fixed and approved.
