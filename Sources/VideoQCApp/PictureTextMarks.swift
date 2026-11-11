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
}

/// A small pink diamond on the ruler at the start of each text graphic of the clip on screen; clicking one goes to
/// that frame. At most five per clip.
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
                Rectangle()
                    .fill(StudioTheme.graphicsMarker(isLightMode))
                    .frame(width: 5, height: 5)
                    .rotationEffect(.degrees(45))
                    .frame(width: 12, height: 14)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { onSeek(frame) })
                    .help("Text graphic “\(sighting.text.replacingOccurrences(of: "\n", with: " "))” at \(TimecodeFormatter.format(frameIndex: frame, fps: max(1, fps))). Click to go there.")
                    .position(x: x, y: 13)
            }
        }
    }
}
