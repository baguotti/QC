import SwiftUI
import VideoQCLib

// MARK: - Application Navigation Tabs

enum AppTab: Int, CaseIterable, Identifiable {
    case player = 0
    case specs = 1
    case lineFinder = 2
    case ingest = 3
    
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .player: return "PLAYER"
        case .specs: return "SPECS"
        case .lineFinder: return "LINE FINDER"
        case .ingest: return "INGEST"
        }
    }
    
    var iconName: String {
        switch self {
        case .player: return "play.fill"
        case .specs: return "doc.text"
        case .lineFinder: return "viewfinder"
        case .ingest: return "tray.and.arrow.down"
        }
    }
}

// MARK: - Dynamic Studio Palette & Styling Tokens

@MainActor
struct StudioTheme {
    /// Master corner radius controlling all boxes, buttons, cards, and input fields.
    /// Tweak this single value to adjust corner rounding across the entire app.
    nonisolated static let cornerRadius: CGFloat = 4.0
    
    static var buttonZoom: UIButtonZoomLevel { ThemeManager.shared.buttonZoom }
    static var buttonScale: CGFloat { ThemeManager.shared.buttonScaleFactor }
    static func scale(_ val: CGFloat) -> CGFloat { ThemeManager.shared.scale(val) }
    static func scaleFont(_ size: CGFloat) -> CGFloat { ThemeManager.shared.scaleFont(size) }
    
    static func bgMain(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.96) : Color(red: 0.04, green: 0.04, blue: 0.04)
    }
    
    static func bgPanel(_ isLight: Bool) -> Color {
        isLight ? Color.white : Color(red: 0.07, green: 0.07, blue: 0.07)
    }
    
    static func bgSubtle(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.92) : Color(white: 0.12)
    }
    
    static func bgCardHeader(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.94) : Color(white: 0.08)
    }
    
    static func bgCardSubtle(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.97) : Color(white: 0.05)
    }
    
    static func borderLine(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.82) : Color(white: 0.16)
    }
    
    static func borderStrong(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.65) : Color(white: 0.24)
    }
    
    static func textMain(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.06) : Color.white
    }
    
    static func textMuted(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.28) : Color(white: 0.50)
    }
    
    static func textSubtle(_ isLight: Bool) -> Color {
        isLight ? Color(white: 0.30) : Color(white: 0.65)
    }
    
    // MARK: - Dynamic Core Accents (Customizable via ThemeManager)
    // Slot A Master / Pass / Ready Accent
    static func positive(_ isLight: Bool) -> Color {
        ThemeManager.shared.currentTheme.slotaColor(isLight: isLight)
    }
    static var positive: Color {
        positive(UserDefaults.standard.bool(forKey: "isLightMode"))
    }
    
    // Warnings / Alerts Accent
    static func negative(_ isLight: Bool) -> Color {
        ThemeManager.shared.currentTheme.warnColor(isLight: isLight)
    }
    static var negative: Color {
        negative(UserDefaults.standard.bool(forKey: "isLightMode"))
    }
    
    // Slot B Accent (Reference Video / AB Compare)
    static func slotBAccent(_ isLight: Bool) -> Color {
        ThemeManager.shared.currentTheme.slotBColor(isLight: isLight)
    }
    static var slotBAccent: Color {
        slotBAccent(UserDefaults.standard.bool(forKey: "isLightMode"))
    }
    
    // Neutral Interactive Accent (Playhead / Timecode / Scrubber)
    static func accentBlue(_ isLight: Bool) -> Color {
        ThemeManager.shared.currentTheme.playColor(isLight: isLight)
    }
    static var accentBlue: Color {
        accentBlue(UserDefaults.standard.bool(forKey: "isLightMode"))
    }
    
    // Crosshair Cyan Accent (#1AF2D9 - identical to AB split screen divider)
    static let crosshairCyan = Color(red: 0.1, green: 0.95, blue: 0.85)
    
    static var alertRed: Color { negative }
    static var alertPositive: Color { positive }

    // Fixed Hardware / Status Indicators (Independent of active accent theme)
    static let droppedFrameGreen = Color(hex: "#00EE9B")
    static let droppedFrameRed = Color(hex: "#FF4365")
    
    static func primaryBtnBg(_ isLight: Bool) -> Color {
        isLight ? Color.black : Color.white
    }
    
    static func primaryBtnFg(_ isLight: Bool) -> Color {
        isLight ? Color.white : Color.black
    }
}

// MARK: - Standardized Studio Typography Tokens

public struct StudioFont {
    /// Micro status tags, sub-second pips, key badges (8pt)
    public static let micro = Font.system(size: 8, weight: .bold, design: .monospaced)
    
    /// Section eyebrows, tooltips, and secondary metadata (9pt)
    public static let caption = Font.system(size: 9, weight: .bold, design: .monospaced)
    
    /// Standard controls, buttons, table cells, inspector rows (10pt)
    public static let body = Font.system(size: 10, weight: .bold, design: .monospaced)
    public static let bodyMedium = Font.system(size: 10, weight: .medium, design: .monospaced)
    public static let bodyRegular = Font.system(size: 10, weight: .regular, design: .monospaced)
    
    /// Tab titles, prominent button labels, modal subheads (11pt)
    public static let subhead = Font.system(size: 11, weight: .bold, design: .monospaced)
    public static let subheadMedium = Font.system(size: 11, weight: .medium, design: .monospaced)
    
    /// Panel titles, asset filenames, card titles (12pt)
    public static let title = Font.system(size: 12, weight: .bold, design: .monospaced)
    
    /// Key metrics & frame index readouts (16pt)
    public static let metric = Font.system(size: 16, weight: .bold, design: .monospaced)
    
    /// Hero status headers & large announcements (24pt)
    public static let display = Font.system(size: 24, weight: .heavy, design: .default)
}

// MARK: - Convenient Theme Palette Bundle

@MainActor
public struct StudioPalette {
    public let isLight: Bool
    
    public init(_ isLight: Bool) {
        self.isLight = isLight
    }
    
    public var bgMain: Color { StudioTheme.bgMain(isLight) }
    public var bgPanel: Color { StudioTheme.bgPanel(isLight) }
    public var bgSubtle: Color { StudioTheme.bgSubtle(isLight) }
    public var bgCardHeader: Color { StudioTheme.bgCardHeader(isLight) }
    public var bgCardSubtle: Color { StudioTheme.bgCardSubtle(isLight) }
    public var bgCardBody: Color { StudioTheme.bgCardSubtle(isLight) }
    public var borderLine: Color { StudioTheme.borderLine(isLight) }
    public var borderStrong: Color { StudioTheme.borderStrong(isLight) }
    public var textMain: Color { StudioTheme.textMain(isLight) }
    public var textMuted: Color { StudioTheme.textMuted(isLight) }
    public var textSubtle: Color { StudioTheme.textSubtle(isLight) }
    public var primaryBtnBg: Color { StudioTheme.primaryBtnBg(isLight) }
    public var primaryBtnFg: Color { StudioTheme.primaryBtnFg(isLight) }
    public var positive: Color { StudioTheme.positive(isLight) }
    public var negative: Color { StudioTheme.negative(isLight) }
    public var alertRed: Color { StudioTheme.negative(isLight) }
    public var alertPositive: Color { StudioTheme.positive(isLight) }
    public var accentPositive: Color { StudioTheme.positive(isLight) }
    public var accentNegative: Color { StudioTheme.negative(isLight) }
    public var accentSlotB: Color { StudioTheme.slotBAccent(isLight) }
    public var accentBlue: Color { StudioTheme.accentBlue(isLight) }
    public var crosshairCyan: Color { StudioTheme.crosshairCyan }
    public var droppedFrameGreen: Color { StudioTheme.droppedFrameGreen }
    public var droppedFrameRed: Color { StudioTheme.droppedFrameRed }
}

@MainActor
extension Color {
    static var studioPositive: Color { StudioTheme.positive }
    static var studioNegative: Color { StudioTheme.negative }
    static var studioBlue: Color { StudioTheme.accentBlue }
    static var studioSlotB: Color { StudioTheme.slotBAccent }
    static let studioCrosshairCyan = StudioTheme.crosshairCyan
}

// MARK: - Minimal Borderless Transport Button Style

struct TransportIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TransportIconButtonBody(configuration: configuration)
    }
}

private struct TransportIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered: Bool = false
    
    var body: some View {
        configuration.label
            .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.6 : (isHovered ? 1.0 : 0.82)))
            .brightness(isEnabled && isHovered ? 0.05 : 0.0)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(isEnabled && isHovered ? 0.05 : 0.0))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                if isEnabled {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - Minimalist Studio Toggle Style

struct StudioToggleStyle: ToggleStyle {
    var isLight: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            HStack(spacing: 5) {
                Rectangle()
                    .fill(configuration.isOn ? (isLight ? Color.black : Color.white) : Color.clear)
                    .frame(width: 8, height: 8)
                    .border(isLight ? Color(white: 0.6) : Color(white: 0.4), width: 1)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Centralized Hover Explanation Coordinator

@MainActor
public final class HoverExplanationCoordinator: ObservableObject {
    public static let shared = HoverExplanationCoordinator()
    @Published public var text: String = ""
    
    public init() {}
    
    public func setExplanation(_ str: String) {
        if text != str {
            text = str
        }
    }
    
    public func clearExplanation(_ str: String) {
        if text == str {
            text = ""
        }
    }
}

// MARK: - Interactive Element Explanation Modifier

struct StudioExplanationModifier: ViewModifier {
    let explanation: String
    
    func body(content: Content) -> some View {
        content
            .help(explanation)
            .onHover { isHovered in
                if isHovered {
                    HoverExplanationCoordinator.shared.setExplanation(explanation)
                } else {
                    HoverExplanationCoordinator.shared.clearExplanation(explanation)
                }
            }
    }
}

extension View {
    func explain(_ text: String) -> some View {
        self.modifier(StudioExplanationModifier(explanation: text))
    }
    
    /// Applies the rounded studio box background and border using master corner radius
    func studioBox(background: Color, border: Color, radius: CGFloat = StudioTheme.cornerRadius, width: CGFloat = 1) -> some View {
        self
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(border, lineWidth: width))
    }
}

// MARK: - Muted Review Note Theme
public struct QCNoteTheme {
    public static func color(for tag: String) -> Color {
        switch tag.lowercased() {
        case "cyan":
            return Color(red: 0.35, green: 0.62, blue: 0.72)
        case "yellow":
            return Color(red: 0.82, green: 0.68, blue: 0.34)
        case "green":
            return Color(red: 0.42, green: 0.68, blue: 0.50)
        case "red":
            return Color(red: 0.80, green: 0.42, blue: 0.42)
        case "purple":
            return Color(red: 0.62, green: 0.50, blue: 0.75)
        default:
            return Color(red: 0.35, green: 0.62, blue: 0.72)
        }
    }
    
    /// User-selectable note colors. Red is intentionally excluded as it is reserved exclusively for automated Line QC findings.
    public static let availableColors: [(id: String, name: String, color: Color)] = [
        ("cyan", "Cyan", color(for: "cyan")),
        ("yellow", "Yellow", color(for: "yellow")),
        ("green", "Green", color(for: "green")),
        ("purple", "Purple", color(for: "purple"))
    ]
}

