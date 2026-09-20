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
    
    // 4 Primary Application Accents (Dark Mode / Default)
    public var slotaHex: String   // Slot A Master / Passing QC / Ready
    public var playHex: String    // Neutral Interactive / Playhead / Timecode / Scrubber
    public var slotBHex: String   // Slot B Reference / AB Split & Diff Compare
    public var warnHex: String    // Glitches / Flagged Issues / Warnings
    
    // Optional Light Mode Overrides (e.g. for custom high-contrast light styles)
    public var lightSlotaHex: String?
    public var lightPlayHex: String?
    public var lightSlotBHex: String?
    public var lightWarnHex: String?
    
    // Semantic & Convenience Aliases
    public var slotAHex: String { get { slotaHex } set { slotaHex = newValue } }
    public var slobBHex: String { get { slotBHex } set { slotBHex = newValue } }
    public var slotbHex: String { get { slotBHex } set { slotBHex = newValue } }
    
    public var lightSlotAHex: String? { get { lightSlotaHex } set { lightSlotaHex = newValue } }
    public var lightSlobBHex: String? { get { lightSlotBHex } set { lightSlotBHex = newValue } }
    public var lightSlotbHex: String? { get { lightSlotBHex } set { lightSlotBHex = newValue } }
    
    // Backwards-compatible aliases
    public var greenHex: String { get { slotaHex } set { slotaHex = newValue } }
    public var blueHex: String { get { playHex } set { playHex = newValue } }
    public var purpleHex: String { get { slotBHex } set { slotBHex = newValue } }
    public var redHex: String { get { warnHex } set { warnHex = newValue } }
    
    public var lightGreenHex: String? { get { lightSlotaHex } set { lightSlotaHex = newValue } }
    public var lightBlueHex: String? { get { lightPlayHex } set { lightPlayHex = newValue } }
    public var lightPurpleHex: String? { get { lightSlotBHex } set { lightSlotBHex = newValue } }
    public var lightRedHex: String? { get { lightWarnHex } set { lightWarnHex = newValue } }
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        isPreset: Bool = false,
        slotaHex: String,
        playHex: String,
        slotBHex: String,
        warnHex: String,
        lightSlotaHex: String? = nil,
        lightPlayHex: String? = nil,
        lightSlotBHex: String? = nil,
        lightWarnHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isPreset = isPreset
        self.slotaHex = slotaHex
        self.playHex = playHex
        self.slotBHex = slotBHex
        self.warnHex = warnHex
        self.lightSlotaHex = lightSlotaHex
        self.lightPlayHex = lightPlayHex
        self.lightSlotBHex = lightSlotBHex
        self.lightWarnHex = lightWarnHex
    }
    
    // Legacy initializer overload
    public init(
        id: String = UUID().uuidString,
        name: String,
        isPreset: Bool = false,
        greenHex: String,
        blueHex: String,
        purpleHex: String,
        redHex: String,
        lightGreenHex: String? = nil,
        lightBlueHex: String? = nil,
        lightPurpleHex: String? = nil,
        lightRedHex: String? = nil
    ) {
        self.init(
            id: id,
            name: name,
            isPreset: isPreset,
            slotaHex: greenHex,
            playHex: blueHex,
            slotBHex: purpleHex,
            warnHex: redHex,
            lightSlotaHex: lightGreenHex,
            lightPlayHex: lightBlueHex,
            lightSlotBHex: lightPurpleHex,
            lightWarnHex: lightRedHex
        )
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, isPreset
        case slotaHex, playHex, slotBHex, warnHex
        case lightSlotaHex, lightPlayHex, lightSlotBHex, lightWarnHex
        // Legacy keys for backwards-compatibility
        case greenHex, blueHex, purpleHex, redHex
        case lightGreenHex, lightBlueHex, lightPurpleHex, lightRedHex
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.isPreset = try container.decodeIfPresent(Bool.self, forKey: .isPreset) ?? false
        
        self.slotaHex = try container.decodeIfPresent(String.self, forKey: .slotaHex)
            ?? container.decodeIfPresent(String.self, forKey: .greenHex)
            ?? "#2E6F40"
        self.playHex = try container.decodeIfPresent(String.self, forKey: .playHex)
            ?? container.decodeIfPresent(String.self, forKey: .blueHex)
            ?? "#4A7C9D"
        self.slotBHex = try container.decodeIfPresent(String.self, forKey: .slotBHex)
            ?? container.decodeIfPresent(String.self, forKey: .purpleHex)
            ?? "#6C628D"
        self.warnHex = try container.decodeIfPresent(String.self, forKey: .warnHex)
            ?? container.decodeIfPresent(String.self, forKey: .redHex)
            ?? "#B35454"
            
        self.lightSlotaHex = try container.decodeIfPresent(String.self, forKey: .lightSlotaHex)
            ?? container.decodeIfPresent(String.self, forKey: .lightGreenHex)
        self.lightPlayHex = try container.decodeIfPresent(String.self, forKey: .lightPlayHex)
            ?? container.decodeIfPresent(String.self, forKey: .lightBlueHex)
        self.lightSlotBHex = try container.decodeIfPresent(String.self, forKey: .lightSlotBHex)
            ?? container.decodeIfPresent(String.self, forKey: .lightPurpleHex)
        self.lightWarnHex = try container.decodeIfPresent(String.self, forKey: .lightWarnHex)
            ?? container.decodeIfPresent(String.self, forKey: .lightRedHex)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isPreset, forKey: .isPreset)
        try container.encode(slotaHex, forKey: .slotaHex)
        try container.encode(playHex, forKey: .playHex)
        try container.encode(slotBHex, forKey: .slotBHex)
        try container.encode(warnHex, forKey: .warnHex)
        try container.encodeIfPresent(lightSlotaHex, forKey: .lightSlotaHex)
        try container.encodeIfPresent(lightPlayHex, forKey: .lightPlayHex)
        try container.encodeIfPresent(lightSlotBHex, forKey: .lightSlotBHex)
        try container.encodeIfPresent(lightWarnHex, forKey: .lightWarnHex)
    }
    
    public func slotaHex(isLight: Bool) -> String {
        (isLight ? lightSlotaHex : nil) ?? slotaHex
    }
    public func playHex(isLight: Bool) -> String {
        (isLight ? lightPlayHex : nil) ?? playHex
    }
    public func slotBHex(isLight: Bool) -> String {
        (isLight ? lightSlotBHex : nil) ?? slotBHex
    }
    public func warnHex(isLight: Bool) -> String {
        (isLight ? lightWarnHex : nil) ?? warnHex
    }
    
    public func slotaColor(isLight: Bool) -> Color { Color(hex: slotaHex(isLight: isLight)) }
    public func playColor(isLight: Bool) -> Color { Color(hex: playHex(isLight: isLight)) }
    public func slotBColor(isLight: Bool) -> Color { Color(hex: slotBHex(isLight: isLight)) }
    public func warnColor(isLight: Bool) -> Color { Color(hex: warnHex(isLight: isLight)) }
    
    public var slotaColor: Color { slotaColor(isLight: UserDefaults.standard.bool(forKey: "isLightMode")) }
    public var playColor: Color { playColor(isLight: UserDefaults.standard.bool(forKey: "isLightMode")) }
    public var slotBColor: Color { slotBColor(isLight: UserDefaults.standard.bool(forKey: "isLightMode")) }
    public var warnColor: Color { warnColor(isLight: UserDefaults.standard.bool(forKey: "isLightMode")) }
    
    public var slotAColor: Color { slotaColor }
    
    public func slotaNSColor(isLight: Bool) -> NSColor { NSColor(slotaColor(isLight: isLight)) }
    public func playNSColor(isLight: Bool) -> NSColor { NSColor(playColor(isLight: isLight)) }
    public func slotBNSColor(isLight: Bool) -> NSColor { NSColor(slotBColor(isLight: isLight)) }
    public func warnNSColor(isLight: Bool) -> NSColor { NSColor(warnColor(isLight: isLight)) }
    
    public var slotaNSColor: NSColor { slotaNSColor(isLight: UserDefaults.standard.bool(forKey: "isLightMode")) }
    public var playNSColor: NSColor { playNSColor(isLight: UserDefaults.standard.bool(forKey: "isLightMode")) }
    public var slotBNSColor: NSColor { slotBNSColor(isLight: UserDefaults.standard.bool(forKey: "isLightMode")) }
    public var warnNSColor: NSColor { warnNSColor(isLight: UserDefaults.standard.bool(forKey: "isLightMode")) }
    
    public var slotANSColor: NSColor { slotaNSColor }
    
    // Backwards-compatible methods
    public func greenHex(isLight: Bool) -> String { slotaHex(isLight: isLight) }
    public func blueHex(isLight: Bool) -> String { playHex(isLight: isLight) }
    public func purpleHex(isLight: Bool) -> String { slotBHex(isLight: isLight) }
    public func redHex(isLight: Bool) -> String { warnHex(isLight: isLight) }
    
    public func greenColor(isLight: Bool) -> Color { slotaColor(isLight: isLight) }
    public func blueColor(isLight: Bool) -> Color { playColor(isLight: isLight) }
    public func purpleColor(isLight: Bool) -> Color { slotBColor(isLight: isLight) }
    public func redColor(isLight: Bool) -> Color { warnColor(isLight: isLight) }
    
    public var greenColor: Color { slotaColor }
    public var blueColor: Color { playColor }
    public var purpleColor: Color { slotBColor }
    public var redColor: Color { warnColor }
    
    public var greenNSColor: NSColor { slotaNSColor }
    public var blueNSColor: NSColor { playNSColor }
    public var purpleNSColor: NSColor { slotBNSColor }
    public var redNSColor: NSColor { warnNSColor }
    
    public func hex(for slot: AccentSlot, isLight: Bool = UserDefaults.standard.bool(forKey: "isLightMode")) -> String {
        switch slot {
        case .slota: return slotaHex(isLight: isLight)
        case .play: return playHex(isLight: isLight)
        case .slotB: return slotBHex(isLight: isLight)
        case .warn: return warnHex(isLight: isLight)
        }
    }
    
    public func color(for slot: AccentSlot, isLight: Bool = UserDefaults.standard.bool(forKey: "isLightMode")) -> Color {
        switch slot {
        case .slota: return slotaColor(isLight: isLight)
        case .play: return playColor(isLight: isLight)
        case .slotB: return slotBColor(isLight: isLight)
        case .warn: return warnColor(isLight: isLight)
        }
    }
    
    public mutating func setColorHex(_ hex: String, for slot: AccentSlot) {
        switch slot {
        case .slota:
            slotaHex = hex
            lightSlotaHex = nil
        case .play:
            playHex = hex
            lightPlayHex = nil
        case .slotB:
            slotBHex = hex
            lightSlotBHex = nil
        case .warn:
            warnHex = hex
            lightWarnHex = nil
        }
    }
    
    public func luminance(for slot: AccentSlot, isLight: Bool = UserDefaults.standard.bool(forKey: "isLightMode")) -> Double {
        let cleanHex = hex(for: slot, isLight: isLight).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let r, g, b: Double
        if cleanHex.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        } else {
            r = 0.3; g = 0.5; b = 0.6
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    
    public func contrastTextColor(for slot: AccentSlot, isLight: Bool = UserDefaults.standard.bool(forKey: "isLightMode")) -> Color {
        luminance(for: slot, isLight: isLight) > 0.65 ? Color.black : Color.white
    }
    
    // MARK: - Built-in Factory Presets
    
    public static let muted = StudioThemeConfig(
        id: "preset-muted",
        name: "Muted",
        isPreset: true,
        slotaHex: "#2E6F40",
        playHex: "#4A7C9D",
        slotBHex: "#6C628D",
        warnHex: "#B35454"
    )
    
    public static let vivid = StudioThemeConfig(
        id: "preset-vivid",
        name: "Vivid",
        isPreset: true,
        slotaHex: "#46EEA2",
        playHex: "#6b91ff",
        slotBHex: "#a96bff",
        warnHex: "#ff4365"
    )
    
    public static let warm = StudioThemeConfig(
        id: "preset-warm",
        name: "Warm",
        isPreset: true,
        slotaHex: "#4E8C56",
        playHex: "#E5A82E",
        slotBHex: "#825785",
        warnHex: "#CC5238"
    )
    
    // Backwards-compatible aliases
    public static let warmAmber = warm
    public static let studioTeal = muted
    public static let broadcastVivid = vivid
    
    public static let presets: [StudioThemeConfig] = [
        muted,
        vivid,
        warm
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
    public static let maxTotalPresets: Int = 14
    
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
            if let matchedPreset = StudioThemeConfig.presets.first(where: { $0.id == activeID }) {
                self.currentTheme = matchedPreset
            } else if activeID == "preset-broadcast-vivid" {
                self.currentTheme = StudioThemeConfig.vivid
            } else if activeID == "preset-studio-teal" {
                self.currentTheme = StudioThemeConfig.muted
            } else if activeID == "preset-warm-amber" {
                self.currentTheme = StudioThemeConfig.warm
            } else if let matchedUserPreset = loadedUserPresets.first(where: { $0.id == activeID }) {
                self.currentTheme = matchedUserPreset
            } else if let data = UserDefaults.standard.data(forKey: currentThemeDataKey),
                      let decoded = try? JSONDecoder().decode(StudioThemeConfig.self, from: data) {
                if let matched = StudioThemeConfig.presets.first(where: { $0.id == decoded.id }) {
                    self.currentTheme = matched
                } else if decoded.id == "preset-warm-amber" {
                    self.currentTheme = StudioThemeConfig.warm
                } else {
                    self.currentTheme = decoded
                }
            } else {
                self.currentTheme = StudioThemeConfig.muted
            }
        } else if let data = UserDefaults.standard.data(forKey: currentThemeDataKey),
                  let decoded = try? JSONDecoder().decode(StudioThemeConfig.self, from: data) {
            if let matched = StudioThemeConfig.presets.first(where: { $0.id == decoded.id }) {
                self.currentTheme = matched
            } else if decoded.id == "preset-broadcast-vivid" {
                self.currentTheme = StudioThemeConfig.vivid
            } else if decoded.id == "preset-studio-teal" {
                self.currentTheme = StudioThemeConfig.muted
            } else if decoded.id == "preset-warm-amber" {
                self.currentTheme = StudioThemeConfig.warm
            } else if let matchedUserPreset = loadedUserPresets.first(where: { $0.id == decoded.id }) {
                self.currentTheme = matchedUserPreset
            } else {
                self.currentTheme = decoded
            }
        } else {
            self.currentTheme = StudioThemeConfig.muted
        }
        
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
            }
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
        return saved.slotaHex.uppercased() != currentTheme.slotaHex.uppercased() ||
               saved.playHex.uppercased() != currentTheme.playHex.uppercased() ||
               saved.slotBHex.uppercased() != currentTheme.slotBHex.uppercased() ||
               saved.warnHex.uppercased() != currentTheme.warnHex.uppercased()
    }
    
    /// Updates the active user preset in-place with current colors.
    @discardableResult
    public func updateCurrentPreset() -> Bool {
        guard let idx = userPresets.firstIndex(where: { $0.id == currentTheme.id }) else {
            return false
        }
        userPresets[idx].slotaHex = currentTheme.slotaHex
        userPresets[idx].playHex = currentTheme.playHex
        userPresets[idx].slotBHex = currentTheme.slotBHex
        userPresets[idx].warnHex = currentTheme.warnHex
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
            slotaHex: currentTheme.slotaHex,
            playHex: currentTheme.playHex,
            slotBHex: currentTheme.slotBHex,
            warnHex: currentTheme.warnHex
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

public enum AccentSlot: String, CaseIterable, Identifiable, Sendable {
    case slota = "Slot A (Master / Pass)"
    case play = "Playhead (Timeline / Interactive)"
    case slotB = "Slot B (Reference / Compare)"
    case warn = "Warnings (Glitches / Alerts)"
    
    // Backwards-compatible aliases
    public static let green = slota
    public static let blue = play
    public static let purple = slotB
    public static let red = warn
    public static let slobB = slotB
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .slota: return "01 // SLOT A / MASTER"
        case .play: return "02 // TIMECODE / PLAYHEAD"
        case .slotB: return "03 // SLOT B / COMPARE"
        case .warn: return "04 // GLITCHES / WARNINGS"
        }
    }
    
    public var roleDescription: String {
        switch self {
        case .slota:
            return "Master video slot badges, pass indicators, ready status."
        case .play:
            return "Active tabs, playhead chevron, timecode, scrubbers."
        case .slotB:
            return "Slot B reference video, A/B split screen and diff mode."
        case .warn:
            return "Detected line glitches, QC failures, warning banners."
        }
    }
}
