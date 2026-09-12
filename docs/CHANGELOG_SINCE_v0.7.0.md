# QCpie — Changelog & Refactoring Report
> **Changes from v0.7.0 to v0.7.2 (Post-PR #1 Merge)**

---

## 📌 Release Summary

| Version | Release Focus | Key Highlights |
| :--- | :--- | :--- |
| **v0.7.0** | UI Scaling & macOS Integration | Added "Open with QCpie" system integration, canvas resolution overlays, and UI zoom system. |
| **v0.7.1** | Clip Info Overhaul & Dual Navigation | 5 cyclic Clip Info modes, `Option + Up/Down` for Slot B queue selection, comparison mode state preservation. |
| **v0.7.2** | Architectural Modularization & Automated Testing | Extracted `ScannerState`, `SpecsState`, `KeyboardShortcutRouter`, split `PlayerTabView`, and added native `Swift Testing` test suite. |

---

## 🚀 1. Feature Overhauls & User Experience Enhancements

### 🎨 Clip Info Overlay System Overhaul
- **5 Cyclic Display Modes**: Pressing `I` or clicking the transport aperture cycles through:
  1. `Resolution`: Shows deliverable dimensions (e.g. `1920x1080 25fps`).
  2. `File Name`: Shows target file name cleanly.
  3. `Full Info`: Displays resolution, FPS, codec, aspect ratio, and filename.
  4. `Off`: Completely hides overlay labels.
  5. `A / B`: Shows slot badge indicators (`Slot A` / `Slot B`).
- **GPU Still-Frame Presentation**: Overlays render cleanly on `stillFrameLayer` backed by uncompressed `CGImage` contents, eliminating viewport layout shifts and keeping 100% immunity to CoreMedia dynamic proxy downsampling.
- **Unified Split Labels**: Aligned split wipe divider labels and side-by-side mode headers.

### ⌨️ Dual-Slot Queue Navigation
- **Slot B Shortcuts**: `Option + Up Arrow` and `Option + Down Arrow` cycle the active deliverable in **Slot B** directly from the queue, mirroring `Up / Down` for Slot A.
- **State Preservation**: Loading a new video into Slot B while already comparing deliverables preserves the current comparison mode (e.g., Split, Side-by-Side, Overlay) instead of resetting to single view.

### 🖼️ Viewport Scaling & Layout Fixes
- Fixed native side-by-side scaling discrepancies so both slots maintain exact aspect ratio geometry without letterboxing or pillarboxing artifacts.
- Polished settings popover button hover states and button zoom alignments.

---

## 🏗️ 2. Architectural Refactoring & Modularization

The entire codebase underwent a 4-phase architectural refactoring to decouple `ContentView`, improve state isolation, and eliminate monolithic files.

```
                  ┌──────────────────────────────────────────────┐
                  │                 ContentView                  │
                  └──────┬───────────────────┬───────────────────┘
                         │                   │
         ┌───────────────┴──────────┐ ┌──────┴───────────────────┐
         │       ScannerState       │ │        SpecsState        │
         │ (18 line-finder states)  │ │  (Media Info & CSV logic)│
         └──────────────────────────┘ └──────────────────────────┘
                         │                   │
         ┌───────────────┴──────────┐ ┌──────┴───────────────────┐
         │  KeyboardShortcutRouter  │ │   PlayerQueuePanelView   │
         │  (51 declarative rules)  │ │ (Isolated Equatable view)│
         └──────────────────────────┘ └──────────────────────────┘
```

### Phase 1: Dead Code Removal & Duplicate Consolidation
- Removed unused `PlayerEngine` computed properties (`showClipNamesOverlay`, `showTitleSafe`).
- Consolidated duplicate folder tree traversal logic into `FileSystemTreeBuilder.expandAncestors(...)`.
- Extracted `dismissFocusReset()` helper in `ContentView` to collapse 8 identical `.onChange` bodies.

### Phase 2: Interface & Type Contract Standardization
- Created `SlotSnapshot` to enforce atomic, zero-data-loss slot swapping in `PlayerEngine.swapSlots()`.
- Standardized `PlayerSlot` metadata updates across 5 synchronization sites, ensuring single-source-of-truth consistency.

### Phase 3.1: ScannerState Extraction
- Extracted 18 line-finder `@State` variables, target color helpers, and report generation methods into a dedicated `@MainActor final class ScannerState: ObservableObject` ([`ScannerState.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/ScannerState.swift)).
- Updated [`LineScannerTabView.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/LineScannerTabView.swift) to observe `ScannerState`.

### Phase 3.2: SpecsState Extraction
- Extracted deliverable inspection, filtering, tag map states, and manifest export handlers into a dedicated `@MainActor final class SpecsState: ObservableObject` ([`SpecsState.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/SpecsState.swift)).
- Streamlined [`DeliverablesTabView.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/DeliverablesTabView.swift).

### Phase 3.3: Declarative Keyboard Shortcut Router
- Replaced the 360-line event monitor closure in `ContentView` with a declarative [`KeyboardShortcutRouter.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/KeyboardShortcutRouter.swift).
- Encapsulates 51 keyboard shortcuts across 4 clear dispatch scopes (`.preModalGlobal`, `.global`, `.playerOrSpecs`, `.playerOnly`).
- Handles text responder unfocusing and modal dismissal cleanly.

### Phase 3.4: Focused Player Components
Split [`PlayerTabView.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/PlayerTabView.swift) from 2,830 lines down to 1,402 lines (~50% reduction) by extracting top-level components into dedicated files:
- **[`PlayerQueueFileRowView.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/PlayerQueueFileRowView.swift)** (385 lines): Isolated `Equatable` row view for queue items.
- **[`PlayerQueuePanelView.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/PlayerQueuePanelView.swift)** (652 lines): Isolated `Equatable` queue sidebar panel.
- **[`ReviewFullscreenHUDView.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Sources/VideoQCApp/ReviewFullscreenHUDView.swift)** (405 lines): Fullscreen HUD controls & video view.

---

## 🧪 3. Automated Test Infrastructure (Phase 4.1)

- Integrated Apple's native **Swift Testing** framework (`import Testing`).
- Added `.testTarget(name: "QCpieTests", dependencies: ["QCpie", "VideoQCLib"], path: "Tests")` to [`Package.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Package.swift).
- Implemented **9 state invariant unit tests** in [`Tests/PlayerEngineTests.swift`](file:///Users/riccardofusetti/Documents/Coding/QCpie/Tests/PlayerEngineTests.swift):
  - `initialEngineState`: Default playback state.
  - `slotSwapPreservesAllFields`: Metadata preservation across A/B slot swaps.
  - `clearSlotBResetsToSingle`: Wiping slot B resets comparison mode to `.single`.
  - `compareModeRequiresMatchingAspectFlags`: Aspect ratio requirements validation.
  - `mismatchedAspectRatioEnforcesValidMode`: Auto-redirection to `.sideBySide` on aspect ratio mismatch.
  - `matchingAspectRatioAllowsSplitModes`: Preservation of split modes on matching aspect ratio.
  - `loadSlotBPreservesCompareModeWhenAlreadyInAB`: Persistence of active comparison mode on new slot B load.
  - `loadSlotBDefaultsToSingleWhenNotInAB`: Initial slot B load defaults to `.single`.
  - `cycleClipInfoOverlayModeWraps`: Deterministic cycling across all 5 overlay modes.
- **Test execution speed**: Runs in **0.051 seconds** via `swift test`.

---

## 📊 Summary Metrics

| Metric | Before (v0.7.0) | After (v0.7.2) | Change |
| :--- | :--- | :--- | :--- |
| `ContentView.swift` Lines | ~2,365 | ~1,090 | **-54%** |
| `PlayerTabView.swift` Lines | ~2,830 | ~1,402 | **-50%** |
| New Modular Components | 0 | 6 new files | **+6 components** |
| Automated Unit Tests | 0 | 9 tests | **9 tests (100% pass)** |
| Swift 6 Concurrency Warnings | 0 | 0 | **0 warnings** |
