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
    
    public func hex(for slot: AccentSlot) -> String {
        switch slot {
        case .green: return greenHex
        case .blue: return blueHex
        case .purple: return purpleHex
        case .red: return redHex
        }
    }
    
    public func color(for slot: AccentSlot) -> Color {
        switch slot {
        case .green: return greenColor
        case .blue: return blueColor
        case .purple: return purpleColor
        case .red: return redColor
        }
    }
    
    public mutating func setColorHex(_ hex: String, for slot: AccentSlot) {
        switch slot {
        case .green: greenHex = hex
        case .blue: blueHex = hex
        case .purple: purpleHex = hex
        case .red: redHex = hex
        }
    }
    
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

// MARK: - UI Button Zoom Level

public enum UIButtonZoomLevel: Int, CaseIterable, Identifiable, Codable, Sendable {
    case small = 0
    case medium = 1
    case large = 2
    
    public var id: Int { rawValue }
    
    public var title: String {
        switch self {
        case .small: return "SMALL"
        case .medium: return "MEDIUM"
        case .large: return "LARGE"
        }
    }
    
    public var subtitle: String {
        switch self {
        case .small: return "Compact studio layout (Default)"
        case .medium: return "Balanced & comfortable"
        case .large: return "Prominent high-visibility"
        }
    }
    
    public var scaleFactor: CGFloat {
        switch self {
        case .small: return 1.0
        case .medium: return 1.2
        case .large: return 1.4
        }
    }
}

// MARK: - Central Theme Manager

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()
    public static let maxTotalPresets: Int = 10
    
    private let activeThemeKey = "QCpie_ActiveThemeID"
    private let currentThemeDataKey = "QCpie_CurrentThemeData"
    private let userPresetsKey = "QCpie_UserThemePresets"
    private let buttonZoomKey = "QCpie_UIButtonZoomLevel"
    
    @Published public var currentTheme: StudioThemeConfig {
        didSet {
            saveCurrentTheme()
        }
    }
    
    @Published public var userPresets: [StudioThemeConfig] = [] {
        didSet {
            saveUserPresets()
        }
    }
    
    @Published public var buttonZoom: UIButtonZoomLevel {
        didSet {
            UserDefaults.standard.set(buttonZoom.rawValue, forKey: buttonZoomKey)
        }
    }
    
    public var buttonScaleFactor: CGFloat {
        buttonZoom.scaleFactor
    }
    
    public func scale(_ val: CGFloat) -> CGFloat {
        round(val * buttonScaleFactor)
    }
    
    public func scaleFont(_ size: CGFloat) -> CGFloat {
        round(size * buttonScaleFactor)
    }
    
    public var allThemes: [StudioThemeConfig] {
        StudioThemeConfig.presets + userPresets
    }
    
    public var canSaveMorePresets: Bool {
        allThemes.count < Self.maxTotalPresets
    }
    
    public init() {
        let savedZoom = UserDefaults.standard.integer(forKey: buttonZoomKey)
        self.buttonZoom = UIButtonZoomLevel(rawValue: savedZoom) ?? .small
        
        // Load custom user presets
        let loadedUserPresets: [StudioThemeConfig]
        if let data = UserDefaults.standard.data(forKey: userPresetsKey),
           let decoded = try? JSONDecoder().decode([StudioThemeConfig].self, from: data) {
            loadedUserPresets = decoded
        } else {
            loadedUserPresets = []
        }
        self.userPresets = loadedUserPresets
        
        let savedActiveID = UserDefaults.standard.string(forKey: activeThemeKey)
        
        if let activeID = savedActiveID {
            if activeID == "preset-vivid" || activeID == "preset-broadcast-vivid" {
                self.currentTheme = StudioThemeConfig.vivid
            } else if activeID == "preset-muted" || activeID == "preset-studio-teal" {
                self.currentTheme = StudioThemeConfig.muted
            } else if let matchedUserPreset = loadedUserPresets.first(where: { $0.id == activeID }) {
                self.currentTheme = matchedUserPreset
            } else if let data = UserDefaults.standard.data(forKey: currentThemeDataKey),
                      let decoded = try? JSONDecoder().decode(StudioThemeConfig.self, from: data) {
                self.currentTheme = decoded
            } else {
                self.currentTheme = StudioThemeConfig.muted
            }
        } else if let data = UserDefaults.standard.data(forKey: currentThemeDataKey),
                  let decoded = try? JSONDecoder().decode(StudioThemeConfig.self, from: data) {
            if decoded.id == "preset-vivid" || decoded.id == "preset-broadcast-vivid" {
                self.currentTheme = StudioThemeConfig.vivid
            } else if decoded.id == "preset-muted" || decoded.id == "preset-studio-teal" {
                self.currentTheme = StudioThemeConfig.muted
            } else if let matchedUserPreset = loadedUserPresets.first(where: { $0.id == decoded.id }) {
                self.currentTheme = matchedUserPreset
            } else {
                self.currentTheme = decoded
            }
        } else {
            self.currentTheme = StudioThemeConfig.muted
        }
    }
    
    // MARK: - Actions
    
    public func applyTheme(_ theme: StudioThemeConfig) {
        self.currentTheme = theme
    }
    
    public func cycleAccentTheme() {
        let themes = allThemes
        guard !themes.isEmpty else { return }
        if let idx = themes.firstIndex(where: { $0.id == currentTheme.id }) {
            let nextIdx = (idx + 1) % themes.count
            applyTheme(themes[nextIdx])
        } else {
            applyTheme(themes[0])
        }
    }
    
    public func updateAccentColor(slot: AccentSlot, hex: String) {
        var updated = currentTheme
        // If current theme is a factory preset, detach it as an active custom theme
        if updated.isPreset {
            updated.id = UUID().uuidString
            updated.name = "Custom"
            updated.isPreset = false
        }
        // If it is an existing user preset, retain its ID and name so the user can update it in-place
        updated.setColorHex(hex, for: slot)
        currentTheme = updated
    }
    
    public func updateAccentColor(slot: AccentSlot, color: Color) {
        let ns = NSColor(color)
        updateAccentColor(slot: slot, hex: ns.hexString)
    }
    
    /// Returns true if the active theme is a saved user preset.
    public var isCurrentThemeUserPreset: Bool {
        !currentTheme.isPreset && userPresets.contains(where: { $0.id == currentTheme.id })
    }
    
    /// Returns true if the active user preset has modified colors compared to its saved state.
    public var hasUnsavedChangesForCurrentPreset: Bool {
        guard let saved = userPresets.first(where: { $0.id == currentTheme.id }) else {
            return false
        }
        return saved.greenHex.uppercased() != currentTheme.greenHex.uppercased() ||
               saved.blueHex.uppercased() != currentTheme.blueHex.uppercased() ||
               saved.purpleHex.uppercased() != currentTheme.purpleHex.uppercased() ||
               saved.redHex.uppercased() != currentTheme.redHex.uppercased()
    }
    
    /// Updates the active user preset in-place with current colors.
    @discardableResult
    public func updateCurrentPreset() -> Bool {
        guard let idx = userPresets.firstIndex(where: { $0.id == currentTheme.id }) else {
            return false
        }
        userPresets[idx].greenHex = currentTheme.greenHex
        userPresets[idx].blueHex = currentTheme.blueHex
        userPresets[idx].purpleHex = currentTheme.purpleHex
        userPresets[idx].redHex = currentTheme.redHex
        saveUserPresets()
        saveCurrentTheme()
        return true
    }
    
    /// Discards unsaved color tweaks and restores the saved user preset.
    public func revertCurrentPreset() {
        guard let saved = userPresets.first(where: { $0.id == currentTheme.id }) else { return }
        currentTheme = saved
    }
    
    @discardableResult
    public func savePreset(name: String) -> Bool {
        guard canSaveMorePresets else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "PRESET \(userPresets.count + 1)" : trimmed
        let newPreset = StudioThemeConfig(
            id: UUID().uuidString,
            name: finalName,
            isPreset: false,
            greenHex: currentTheme.greenHex,
            blueHex: currentTheme.blueHex,
            purpleHex: currentTheme.purpleHex,
            redHex: currentTheme.redHex
        )
        userPresets.append(newPreset)
        currentTheme = newPreset
        return true
    }
    
    public func deletePreset(id: String) {
        userPresets.removeAll(where: { $0.id == id })
        if currentTheme.id == id {
            currentTheme = StudioThemeConfig.muted
        }
    }
    
    public func renamePreset(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = userPresets.firstIndex(where: { $0.id == id }) {
            userPresets[idx].name = trimmed
        }
        if currentTheme.id == id {
            currentTheme.name = trimmed
        }
    }
    
    @discardableResult
    public func increaseButtonZoom() -> Bool {
        guard let next = UIButtonZoomLevel(rawValue: buttonZoom.rawValue + 1) else { return false }
        buttonZoom = next
        return true
    }
    
    @discardableResult
    public func decreaseButtonZoom() -> Bool {
        guard let prev = UIButtonZoomLevel(rawValue: buttonZoom.rawValue - 1) else { return false }
        buttonZoom = prev
        return true
    }
    
    public func resetToDefault() {
        self.currentTheme = StudioThemeConfig.muted
        self.buttonZoom = .small
    }
    
    // MARK: - Persistence
    
    private func saveUserPresets() {
        if let encoded = try? JSONEncoder().encode(userPresets) {
            UserDefaults.standard.set(encoded, forKey: userPresetsKey)
        }
    }
    
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
        case .green: return "01 // SLOT A / PASS"
        case .blue: return "02 // TIMECODE / PLAYHEAD"
        case .purple: return "03 // SLOT B / COMPARE"
        case .red: return "04 // GLITCHES / ALERTS"
        }
    }
    
    public var roleDescription: String {
        switch self {
        case .green:
            return "Master video slot, pass badges, ready status."
        case .blue:
            return "Active tabs, playhead, timecode readouts, scrubbers."
        case .purple:
            return "Slot B reference video, A/B split screen and diff mode."
        case .red:
            return "Detected line glitches, QC failures, alert banners."
        }
    }
}
