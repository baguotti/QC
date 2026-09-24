---
name: swift-6-concurrency-and-appkit
description: Swift 6 strict concurrency, actor isolation, and AppKit/SwiftUI bridging for macOS applications. Use when writing actors, Sendable models, NSViewRepresentable wrappers, or eliminating main-thread SwiftUI evaluation overhead.
---

# Swift 6 Concurrency & AppKit / SwiftUI Architecture Guide

This skill provides patterns, constraints, and best practices for writing high-performance macOS applications using Swift 6 strict concurrency alongside AppKit and SwiftUI.

---

## 1. Swift 6 Concurrency & Actor Isolation

### Non-Sendable AVFoundation & CoreMedia Types
Many AVFoundation and CoreMedia classes (`AVAssetImageGenerator`, `AVPlayerItemVideoOutput`, `CVPixelBuffer`, `CGImage`) are non-`Sendable` reference types or CoreFoundation pointers.

- **Actor Encapsulation**: Isolate stateful non-Sendable objects inside dedicated actors (e.g. `FrameExtractor`).
- **Synchronous Extraction**: Perform image extraction (`copyCGImage`) synchronously within the actor domain to satisfy strict concurrency without `#SendingRisksDataRace`.
- **Value Delivery**: Transfer immutable results (`CGImage`, value types, structs) across isolation domains:
  ```swift
  actor FrameExtractor {
      private var generator: AVAssetImageGenerator?
      
      func capture(at time: CMTime) async throws -> CGImage {
          // Actor-isolated generation to avoid data races
          guard let generator else { throw ExtractionError.uninitialized }
          return try generator.copyCGImage(at: time, actualTime: nil)
      }
  }
  ```

### MainActor Synchronization
- UI mutations, `NSView` hierarchy alterations, and `CALayer` property updates MUST occur on the `@MainActor`.
- In asynchronous tasks dispatched from background threads (e.g. metadata extraction, asset queues), always bounce UI mutations back via `await MainActor.run { ... }` or `@MainActor` annotated methods.

---

## 2. SwiftUI vs AppKit: High-Frequency Performance

### The Per-Frame Re-evaluation Trap
- In high-frequency render loops (60–120 FPS playback or scrubbing), mutating `@Published` properties on `@StateObject` models owned high in the view tree (like `ContentView`) forces SwiftUI to re-evaluate the entire view tree.
- A single SwiftUI view transaction per frame costs ~4.7 ms in the window graph.
- **Rule**: Per-frame state (`currentFrame`, `currentTimecode`, `currentProgress`) MUST NOT live on `@Published` properties observed by SwiftUI views.

### AppKit-Backed Per-Frame Views
- Use AppKit views (`NSViewRepresentable`) that subscribe directly to the clock or notification stream:
  ```swift
  struct PlaybackClockText: NSViewRepresentable {
      let clock: PlaybackClock
      
      func makeNSView(context: Context) -> NSTextField {
          let field = NSTextField(labelWithString: clock.currentTimecode)
          field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
          // Subscribe directly via Combine or display tick
          return field
      }
      
      func updateNSView(_ nsView: NSTextField, context: Context) {
          // Keep updateNSView minimal; let the internal observer handle ticks
      }
  }
  ```
- Use a hidden static SwiftUI template view (e.g. `.opacity(0)`) to lock in layout geometry and prevent layout churn.

---

## 3. Keyboard Event Routing & Text Field Shielding

- `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` captures key events before SwiftUI views consume them.
- When an `NSTextField` or `NSTextView` is first responder, transport shortcuts (Space, J/K/L, arrows) must be bypassed:
  ```swift
  func isTextInputActive() -> Bool {
      guard let responder = NSApp.keyWindow?.firstResponder else { return false }
      return responder is NSTextField || responder is NSTextView
  }
  ```

---

## 4. Large Queue & Virtualization Best Practices

- Always use `LazyVStack` rather than eager `VStack` in scrollable file/asset queues.
- Use `Equatable` conformances on row views with integer version counters (`queueVersion`, `tagsVersion`) to achieve $O(1)$ diffing.
- Never perform synchronous disk I/O, bookmark resolution, or JSON decoding inside SwiftUI view bodies. Prewarm caches on background queues (`Task.detached(priority: .utility)`).
