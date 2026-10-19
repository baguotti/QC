import SwiftUI
import VideoQCLib

extension MediaKind {
    static let allCases: [MediaKind] = [.video, .image, .audio]

    var symbolName: String {
        switch self {
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        }
    }

    var label: String {
        switch self {
        case .video: return "Videos"
        case .image: return "Images"
        case .audio: return "Audio"
        }
    }

    var bit: Int {
        switch self {
        case .video: return 1
        case .image: return 2
        case .audio: return 4
        }
    }
}

/// Which media kinds the queue and Specs lists show (bit mask, shared and remembered).
enum MediaKindFilter {
    static let storageKey = "mediaKindFilter"
    static let all = 7

    /// An image sequence read as one clip plays like a video, so it filters as one.
    static func kind(of url: URL) -> MediaKind? {
        ImageSequenceStore.shared.sequence(for: url) != nil ? .video : QCUtilities.mediaKind(of: url)
    }
    
    /// Kinds present in a list, as a mask.
    static func presentMask(of urls: [URL]) -> Int {
        var mask = 0
        for url in urls {
            mask |= kind(of: url)?.bit ?? 0
            if mask == all { break }
        }
        return mask
    }

    /// A filter that would hide every kind present shows everything (e.g. a remembered filter on a new folder).
    static func effectiveMask(_ mask: Int, present: Int) -> Int {
        mask & present == 0 ? all : mask
    }

    static func allows(_ url: URL, mask: Int) -> Bool {
        mask == all || (kind(of: url).map { mask & $0.bit != 0 } ?? true)
    }
}

/// Icon toggles next to the filter field, shown only when the list mixes kinds. The last visible kind can't be turned off.
struct MediaKindFilterChips: View {
    @Binding var mask: Int
    let present: Int
    let isLightMode: Bool

    var body: some View {
        let effective = MediaKindFilter.effectiveMask(mask, present: present)
        HStack(spacing: 2) {
            ForEach(MediaKind.allCases.filter { present & $0.bit != 0 }, id: \.bit) { kind in
                let isOn = effective & kind.bit != 0
                Button(action: {
                    let toggled = effective ^ kind.bit
                    if toggled & present != 0 { mask = toggled }
                }) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .frame(width: 20, height: 16)
                        .foregroundColor(isOn ? StudioTheme.textMain(isLightMode) : StudioTheme.textMuted(isLightMode).opacity(0.5))
                        .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? StudioTheme.accentBlue(isLightMode).opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .explain("\(isOn ? "Hide" : "Show") \(kind.label.lowercased())")
            }
        }
    }
}
