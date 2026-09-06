import SwiftUI
import AppKit

// MARK: - Hex Conversion Helpers

extension Color {
    init(hex: String) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, (int >> 8) & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, (int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

extension NSColor {
    var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = max(0, min(255, Int(round(srgb.redComponent * 255.0))))
        let g = max(0, min(255, Int(round(srgb.greenComponent * 255.0))))
        let b = max(0, min(255, Int(round(srgb.blueComponent * 255.0))))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Studio Theme Configuration

public struct StudioThemeConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isPreset: Bool
    
    // 4 Primary Application Accents
    public var greenHex: String   // Slot A Master / Passing QC / Ready
    public var blueHex: String    // Neutral Interactive / Playhead / Timecode / Scrubber
    public var purpleHex: String  // Slot B Reference / AB Split & Diff Compare
    public var redHex: String     // Glitches / Flagged Issues / Warnings
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        isPreset: Bool = false,
        greenHex: String,
        blueHex: String,
        purpleHex: String,
        redHex: String
    ) {
        self.id = id
        self.name = name
        self.isPreset = isPreset
        self.greenHex = greenHex
        self.blueHex = blueHex
        self.purpleHex = purpleHex
        self.redHex = redHex
    }
    
    public var greenColor: Color { Color(hex: greenHex) }
    public var blueColor: Color { Color(hex: blueHex) }
    public var purpleColor: Color { Color(hex: purpleHex) }
    public var redColor: Color { Color(hex: redHex) }
    
    public var greenNSColor: NSColor { NSColor(greenColor) }
    public var blueNSColor: NSColor { NSColor(blueColor) }
    public var purpleNSColor: NSColor { NSColor(purpleColor) }
    public var redNSColor: NSColor { NSColor(redColor) }
    
    // MARK: - Built-in Factory Presets (Muted & Vivid)
    
    public static let muted = StudioThemeConfig(
        id: "preset-muted",
        name: "Muted",
        isPreset: true,
        greenHex: "#2E6F40",
        blueHex: "#4A7C9D",
        purpleHex: "#6C628D",
        redHex: "#B35454"
    )
    
    public static let vivid = StudioThemeConfig(
        id: "preset-vivid",
        name: "Vivid",
        isPreset: true,
        greenHex: "#00C853",
        blueHex: "#0084FF",
        purpleHex: "#9A42E6",
        redHex: "#E62E2E"
    )
    
    // Backwards-compatible aliases
    public static let studioTeal = muted
    public static let broadcastVivid = vivid
    
    public static let presets: [StudioThemeConfig] = [
        muted,
        vivid
    ]
}

// MARK: - Central Theme Manager

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    
    private let activeThemeKey = "QCpie_ActiveThemeID"
    private let currentThemeDataKey = "QCpie_CurrentThemeData"
    
    @Published public var currentTheme: StudioThemeConfig {
        didSet {
            saveCurrentTheme()
        }
    }
    
    public var allThemes: [StudioThemeConfig] {
        StudioThemeConfig.presets
    }
    
    public init() {
        if let activeID = UserDefaults.standard.string(forKey: activeThemeKey) {
            if activeID == "preset-vivid" || activeID == "preset-broadcast-vivid" {
                self.currentTheme = StudioThemeConfig.vivid
            } else {
                self.currentTheme = StudioThemeConfig.muted
            }
        } else if let data = UserDefaults.standard.data(forKey: currentThemeDataKey),
                  let decoded = try? JSONDecoder().decode(StudioThemeConfig.self, from: data) {
            if decoded.id == "preset-vivid" || decoded.id == "preset-broadcast-vivid" {
                self.currentTheme = StudioThemeConfig.vivid
            } else {
                self.currentTheme = StudioThemeConfig.muted
            }
        } else {
            self.currentTheme = StudioThemeConfig.muted
        }
    }
    
    // MARK: - Actions
    
    public func applyTheme(_ theme: StudioThemeConfig) {
        self.currentTheme = theme
    }
    
    public func resetToDefault() {
        self.currentTheme = StudioThemeConfig.muted
    }
    
    // MARK: - Persistence
    
    private func saveCurrentTheme() {
        UserDefaults.standard.set(currentTheme.id, forKey: activeThemeKey)
        if let encoded = try? JSONEncoder().encode(currentTheme) {
            UserDefaults.standard.set(encoded, forKey: currentThemeDataKey)
        }
    }
}

// MARK: - Accent Slot Identifier

public enum AccentSlot: String, CaseIterable, Identifiable {
    case green = "Green (Pass / Slot A)"
    case blue = "Teal / Blue (Interactive / Player)"
    case purple = "Purple (Slot B / Specs)"
    case red = "Red (Glitches / Alerts)"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .green: return "01 // GREEN (SLOT A / PASS)"
        case .blue: return "02 // TEAL / BLUE (INTERACTIVE / TIME)"
        case .purple: return "03 // PURPLE (SLOT B / SPECS)"
        case .red: return "04 // RED (GLITCHES / WARNINGS)"
        }
    }
    
    public var roleDescription: String {
        switch self {
        case .green:
            return "Slot A master video, pass badges, ready status."
        case .blue:
            return "Active tab indicator, timeline playhead, timecode, scrubbers, loop."
        case .purple:
            return "Slot B reference video, A/B split screen & difference mode, specs."
        case .red:
            return "Detected line glitches, failed QC checks, alert banners."
        }
    }
}
