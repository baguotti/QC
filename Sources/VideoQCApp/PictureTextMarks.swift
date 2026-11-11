import SwiftUI
import VideoQCLib

/// Where Check Subs & Graphics saw text graphics, per file, for the Player's timeline. Published only when a check
/// result lands; only `PictureTextTimelineMarks` observes it (never `ContentView`).
@MainActor
final class PictureTextMarks: ObservableObject {
    static let shared = PictureTextMarks()
    @Published private(set) var byURL: [URL: [PictureTextCheck.Sighting]] = [:]

    func set(_ check: PictureTextCheck, for url: URL) {
        let key = url.standardizedFileURL   // Player URLs are standardized
        let sightings = check.graphics.sorted { $0.start < $1.start }
        if byURL[key] != sightings { byURL[key] = sightings.isEmpty ? nil : sightings }
    }

    /// Files Inspect reads again (Refresh, a re-export, the list replaced): their markers go with their old result.
    func clear(_ urls: [URL]) {
        let keys = Set(urls.map(\.standardizedFileURL))
        guard byURL.keys.contains(where: keys.contains) else { return }
        byURL = byURL.filter { !keys.contains($0.key) }
    }
}

/// A small pink diamond on the ruler at the start of each text graphic of the clip on screen; clicking one goes to
/// that frame.
struct PictureTextTimelineMarks: View {
    let url: URL?
    let durSecs: Double
    let fps: Double
    let trackWidth: CGFloat
    let trackInset: CGFloat
    let isLightMode: Bool
    let onSeek: (Int) -> Void
    @ObservedObject private var marks = PictureTextMarks.shared

    var body: some View {
        if let url, durSecs > 0, let sightings = marks.byURL[url.standardizedFileURL] {
            ForEach(Array(sightings.enumerated()), id: \.offset) { _, sighting in
                let frame = max(0, Int((sighting.start * max(1, fps)).rounded(.down)))
                let x = trackInset + trackWidth * CGFloat(min(1, max(0, sighting.start / durSecs)))
                PictureTextMarker(url: url, sighting: sighting, frame: frame, fps: fps, isLightMode: isLightMode, onSeek: onSeek)
                    .position(x: x, y: 13)
            }
        }
    }
}

/// One marker: hovering shows the frame and its text, clicking goes there.
private struct PictureTextMarker: View {
    let url: URL
    let sighting: PictureTextCheck.Sighting
    let frame: Int
    let fps: Double
    let isLightMode: Bool
    let onSeek: (Int) -> Void
    @State private var hovering = false
    @State private var preview = false

    var body: some View {
        Rectangle()
            .fill(StudioTheme.graphicsMarker(isLightMode))
            .frame(width: 5, height: 5)
            .rotationEffect(.degrees(45))
            .frame(width: 12, height: 14)
            .contentShape(Rectangle())
            .highPriorityGesture(TapGesture().onEnded { preview = false; onSeek(frame) })
            .onHover { inside in
                hovering = inside
                if !inside { preview = false; return }
                // A short wait: sweeping the pointer along the ruler doesn't open a preview at every marker.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    if hovering { preview = true }
                }
            }
            .popover(isPresented: $preview, arrowEdge: .bottom) {
                let palette = StudioPalette(isLightMode)
                VStack(alignment: .leading, spacing: 6) {
                    PictureTextThumb(url: url, seconds: sighting.start, fps: fps, isLightMode: isLightMode, until: sighting.end, width: 200)
                    Text(sighting.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.ui(size: 12, weight: .semibold))
                        .foregroundColor(palette.textMain)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(TimecodeFormatter.format(frameIndex: frame, fps: max(1, fps))) · click the marker to go there")
                        .font(.ui(size: 10))
                        .monospacedDigit()
                        .foregroundColor(palette.textMuted)
                }
                .padding(10)
                .frame(width: 220)
            }
    }
}
