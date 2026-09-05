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
    
    // MARK: - Built-in Factory Presets
    
    public static let studioTeal = StudioThemeConfig(
        id: "preset-studio-teal",
        name: "Studio Teal (Default)",
        isPreset: true,
        greenHex: "#2E6F40",
        blueHex: "#4A7C9D",
        purpleHex: "#6C628D",
        redHex: "#B35454"
    )
    
    public static let studioBlue = StudioThemeConfig(
        id: "preset-studio-blue",
        name: "Studio Blue",
        isPreset: true,
        greenHex: "#2E6F40",
        blueHex: "#338FFA",
        purpleHex: "#715C83",
        redHex: "#A14746"
    )
    
    public static let cyberpunkNeon = StudioThemeConfig(
        id: "preset-cyberpunk",
        name: "Cyberpunk Neon",
        isPreset: true,
        greenHex: "#00E676",
        blueHex: "#00D2FF",
        purpleHex: "#D500F9",
        redHex: "#FF1744"
    )
    
    public static let amberWarmth = StudioThemeConfig(
        id: "preset-amber-warmth",
        name: "Amber Warmth",
        isPreset: true,
        greenHex: "#5A7D50",
        blueHex: "#D97706",
        purpleHex: "#84687C",
        redHex: "#BA4C4C"
    )
    
    public static let broadcastVivid = StudioThemeConfig(
        id: "preset-broadcast-vivid",
        name: "Broadcast Vivid",
        isPreset: true,
        greenHex: "#00C853",
        blueHex: "#0084FF",
        purpleHex: "#9A42E6",
        redHex: "#E62E2E"
    )
    
    public static let presets: [StudioThemeConfig] = [
        studioTeal,
        studioBlue,
        cyberpunkNeon,
        amberWarmth,
        broadcastVivid
    ]
}

// MARK: - Central Theme Manager

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    
    private let activeThemeKey = "QCpie_ActiveThemeID"
    private let currentThemeDataKey = "QCpie_CurrentThemeData"
    private let customThemesKey = "QCpie_CustomThemes"
    
    @Published public var currentTheme: StudioThemeConfig {
        didSet {
            saveCurrentTheme()
        }
    }
    
    @Published public var customThemes: [StudioThemeConfig] = [] {
        didSet {
            saveCustomThemes()
        }
    }
    
    public var allThemes: [StudioThemeConfig] {
        StudioThemeConfig.presets + customThemes
    }
    
    public init() {
        // 1. Load custom themes from UserDefaults
        var loadedCustomThemes: [StudioThemeConfig] = []
        if let data = UserDefaults.standard.data(forKey: customThemesKey),
           let decoded = try? JSONDecoder().decode([StudioThemeConfig].self, from: data) {
            loadedCustomThemes = decoded
        }
        self.customThemes = loadedCustomThemes
        
        // 2. Load active theme
        if let activeID = UserDefaults.standard.string(forKey: activeThemeKey),
           activeID == "preset-nordic-slate" || activeID == "preset-studio-teal" {
            // User had default Studio Teal or Nordic Slate; upgrade to new Studio Teal
            self.currentTheme = StudioThemeConfig.studioTeal
        } else if let data = UserDefaults.standard.data(forKey: currentThemeDataKey),
           let decoded = try? JSONDecoder().decode(StudioThemeConfig.self, from: data),
           decoded.id != "preset-nordic-slate" {
            self.currentTheme = decoded
        } else if let activeID = UserDefaults.standard.string(forKey: activeThemeKey),
                  let matched = (StudioThemeConfig.presets + loadedCustomThemes).first(where: { $0.id == activeID }) {
            self.currentTheme = matched
        } else {
            self.currentTheme = StudioThemeConfig.studioTeal
        }
    }
    
    // MARK: - Mutating Actions
    
    public func applyTheme(_ theme: StudioThemeConfig) {
        self.currentTheme = theme
    }
    
    public func updateColor(slot: AccentSlot, hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanHex.hasPrefix("#") {
            cleanHex = "#" + cleanHex
        }
        guard cleanHex.count == 7 else { return }
        
        var updated = currentTheme
        switch slot {
        case .green:
            updated.greenHex = cleanHex.uppercased()
        case .blue:
            updated.blueHex = cleanHex.uppercased()
        case .purple:
            updated.purpleHex = cleanHex.uppercased()
        case .red:
            updated.redHex = cleanHex.uppercased()
        }
        // If current theme was a factory preset, editing its colors turns it into a custom state
        if updated.isPreset {
            updated.id = "custom-\(UUID().uuidString.prefix(8))"
            updated.name = "\(currentTheme.name) (Customized)"
            updated.isPreset = false
        }
        self.currentTheme = updated
    }
    
    public func saveAsNewTheme(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let themeName = trimmed.isEmpty ? "Custom Theme \(customThemes.count + 1)" : trimmed
        
        let newTheme = StudioThemeConfig(
            id: "user-\(UUID().uuidString)",
            name: themeName,
            isPreset: false,
            greenHex: currentTheme.greenHex,
            blueHex: currentTheme.blueHex,
            purpleHex: currentTheme.purpleHex,
            redHex: currentTheme.redHex
        )
        
        customThemes.append(newTheme)
        currentTheme = newTheme
    }
    
    public func deleteCustomTheme(id: String) {
        customThemes.removeAll(where: { $0.id == id })
        if currentTheme.id == id {
            currentTheme = StudioThemeConfig.studioTeal
        }
    }
    
    public func resetToDefault() {
        self.currentTheme = StudioThemeConfig.studioTeal
    }
    
    // MARK: - Persistence
    
    private func saveCurrentTheme() {
        UserDefaults.standard.set(currentTheme.id, forKey: activeThemeKey)
        if let encoded = try? JSONEncoder().encode(currentTheme) {
            UserDefaults.standard.set(encoded, forKey: currentThemeDataKey)
        }
    }
    
    private func saveCustomThemes() {
        if let encoded = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(encoded, forKey: customThemesKey)
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
