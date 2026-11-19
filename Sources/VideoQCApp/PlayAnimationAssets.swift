import AppKit
import SwiftUI

/// Preloaded & cached frames for the Play <-> Pause morph animation
@MainActor
public final class PlayAnimationAssets {
    public static let shared = PlayAnimationAssets()
    
    private var cachedImages: [NSImage] = []
    
    private init() {
        loadFrames()
    }
    
    public func frame(at index: Int) -> NSImage? {
        let clamped = max(0, min(9, index))
        guard clamped < cachedImages.count else { return nil }
        return cachedImages[clamped]
    }
    
    private func loadFrames() {
        for i in 0..<10 {
            if let img = loadFromDisk(index: i) {
                img.isTemplate = true
                cachedImages.append(img)
            }
        }
    }
    
    private func loadFromDisk(index: Int) -> NSImage? {
        let name = String(format: "anim_%02d", index)
        return AppResource.url(name, "png", subdirectory: "PlayAnimation").flatMap(NSImage.init(contentsOf:))
    }
}

/// Animated Play <-> Pause morphing button icon (following the 10-frame reference)
public struct AnimatedPlayPauseIconView: View {
    public let isPlaying: Bool
    public var color: Color = .white
    public var size: CGFloat = 18
    
    @State private var currentFrame: Int
    @State private var animTask: Task<Void, Never>? = nil
    
    public init(isPlaying: Bool, color: Color = .white, size: CGFloat = 18) {
        self.isPlaying = isPlaying
        self.color = color
        self.size = size
        _currentFrame = State(initialValue: isPlaying ? 9 : 0)
    }
    
    public var body: some View {
        Group {
            if let img = PlayAnimationAssets.shared.frame(at: currentFrame) {
                Image(nsImage: img)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(color)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.9, weight: .bold))
                    .foregroundColor(color)
            }
        }
        .onChange(of: isPlaying) { _, playing in
            startAnimation(toPlaying: playing)
        }
        .onDisappear {
            animTask?.cancel()
        }
    }
    
    private func startAnimation(toPlaying: Bool) {
        animTask?.cancel()
        let target = toPlaying ? 9 : 0
        guard currentFrame != target else { return }
        
        animTask = Task { @MainActor in
            while currentFrame != target {
                // ~22ms per frame step (total duration ~200ms across 9 transitions)
                try? await Task.sleep(nanoseconds: 22_000_000)
                if Task.isCancelled { break }
                if target > currentFrame {
                    currentFrame += 1
                } else {
                    currentFrame -= 1
                }
            }
        }
    }
}