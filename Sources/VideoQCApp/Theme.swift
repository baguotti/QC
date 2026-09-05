import SwiftUI

// MARK: - Application Navigation Tabs

enum AppTab: Int, CaseIterable, Identifiable {
    case lineScanner = 0
    case player = 1
    case deliverables = 2
    case batchRenamer = 3
    
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .lineScanner: return "01 // LINE SCANNER"
        case .player: return "02 // PLAYER"
        case .deliverables: return "03 // DELIVERABLES SPECS"
        case .batchRenamer: return "04 // BATCH RENAMER"
        }
    }
}

// MARK: - Dynamic Studio Palette & Styling Tokens

struct StudioTheme {
    /// Master corner radius controlling all boxes, buttons, cards, and input fields.
    /// Tweak this single value to adjust corner rounding across the entire app.
    static let cornerRadius: CGFloat = 4.0
    
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
        isLight ? Color(white: 0.65) : Color(white: 0.35)
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
    
    // MARK: - Exclusive Color Accents (Only 2 Accents)
    // Positive Accent: #2E6F40 (Forest Green)
    static let positive = Color(red: 46 / 255.0, green: 111 / 255.0, blue: 64 / 255.0)
    // Negative Accent: #a14746 (Muted Brick Red)
    static let negative = Color(red: 161 / 255.0, green: 71 / 255.0, blue: 70 / 255.0)
    // Slot B Accent: #715C83 (Muted Purple)
    static let slotBAccent = Color(red: 0x71 / 255.0, green: 0x5C / 255.0, blue: 0x83 / 255.0)
    
    static var alertRed: Color { negative }
    static var alertPositive: Color { positive }
    
    @available(*, deprecated, message: "Use StudioTheme.alertRed directly without isLight argument")
    static func alertRed(_ isLight: Bool) -> Color {
        negative
    }
    
    @available(*, deprecated, message: "Use StudioTheme.alertPositive directly without isLight argument")
    static func alertPositive(_ isLight: Bool) -> Color {
        positive
    }
    
    static func primaryBtnBg(_ isLight: Bool) -> Color {
        isLight ? Color.black : Color.white
    }
    
    static func primaryBtnFg(_ isLight: Bool) -> Color {
        isLight ? Color.white : Color.black
    }
}

// MARK: - Convenient Theme Palette Bundle

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
    public var borderLine: Color { StudioTheme.borderLine(isLight) }
    public var borderStrong: Color { StudioTheme.borderStrong(isLight) }
    public var textMain: Color { StudioTheme.textMain(isLight) }
    public var textMuted: Color { StudioTheme.textMuted(isLight) }
    public var textSubtle: Color { StudioTheme.textSubtle(isLight) }
    public var primaryBtnBg: Color { StudioTheme.primaryBtnBg(isLight) }
    public var primaryBtnFg: Color { StudioTheme.primaryBtnFg(isLight) }
    public var positive: Color { StudioTheme.positive }
    public var negative: Color { StudioTheme.negative }
    public var alertRed: Color { StudioTheme.negative }
}

extension Color {
    static let studioPositive = StudioTheme.positive
    static let studioNegative = StudioTheme.negative
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

// MARK: - Interactive Element Explanation Modifier

struct StudioExplanationModifier: ViewModifier {
    let explanation: String
    @Binding var binding: String
    
    func body(content: Content) -> some View {
        content
            .help(explanation)
            .onHover { isHovered in
                if isHovered {
                    binding = explanation
                } else if binding == explanation {
                    binding = ""
                }
            }
    }
}

extension View {
    func explain(_ text: String, binding: Binding<String>) -> some View {
        self.modifier(StudioExplanationModifier(explanation: text, binding: binding))
    }
    
    @ViewBuilder
    func explain(_ text: String, binding: Binding<String>?) -> some View {
        if let binding = binding {
            self.modifier(StudioExplanationModifier(explanation: text, binding: binding))
        } else {
            self.help(text)
        }
    }
    
    /// Applies the rounded studio box background and border using master corner radius
    func studioBox(background: Color, border: Color, radius: CGFloat = StudioTheme.cornerRadius, width: CGFloat = 1) -> some View {
        self
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(border, lineWidth: width))
    }
    
    /// Applies the rounded studio stroke border using master corner radius
    func studioBorder(_ color: Color, radius: CGFloat = StudioTheme.cornerRadius, width: CGFloat = 1) -> some View {
        self
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(color, lineWidth: width))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

