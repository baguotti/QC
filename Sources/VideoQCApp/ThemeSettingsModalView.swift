import SwiftUI
import AppKit

struct ThemeSettingsModalView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    // Inline creation state
    @State private var isNamingNewTheme: Bool = false
    @State private var newThemeName: String = ""
    
    // Local editable hex values to keep text fields snappy while editing
    @State private var greenHexInput: String = ""
    @State private var blueHexInput: String = ""
    @State private var purpleHexInput: String = ""
    @State private var redHexInput: String = ""
    
    var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(0.65)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    isPresented = false
                }
            
            // Modal Card Container
            VStack(spacing: 0) {
                // Header Bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(themeManager.currentTheme.blueColor)
                        Text("APPEARANCE & ACCENT COLORS // QCpie")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(palette.textMain)
                    }
                    
                    Spacer()
                    
                    Button(action: { isPresented = false }) {
                        Text("CLOSE (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(palette.bgPanel)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Content Body
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Section 1: Presets & Saved Themes
                        presetsSection
                        
                        // Section 2: Live UI Element Preview
                        previewSection
                        
                        // Section 3: 4 Core Accents Customizer
                        colorCustomizerSection
                    }
                    .padding(20)
                }
                .background(palette.bgMain)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Footer Action Bar
                HStack {
                    Button(action: {
                        themeManager.resetToDefault()
                        syncHexInputs()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .bold))
                            Text("RESET TO DEFAULT")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .foregroundColor(palette.textMuted)
                        .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    if isNamingNewTheme {
                        HStack(spacing: 6) {
                            TextField("Theme Name", text: $newThemeName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(width: 160)
                                .studioBox(background: palette.bgPanel, border: palette.borderStrong)
                            
                            Button(action: {
                                themeManager.saveAsNewTheme(name: newThemeName)
                                newThemeName = ""
                                isNamingNewTheme = false
                            }) {
                                Text("SAVE")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .foregroundColor(Color.white)
                                    .background(themeManager.currentTheme.greenColor)
                                    .cornerRadius(StudioTheme.cornerRadius)
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                isNamingNewTheme = false
                                newThemeName = ""
                            }) {
                                Text("CANCEL")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .foregroundColor(palette.textMuted)
                                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Button(action: {
                            newThemeName = "\(themeManager.currentTheme.name) Copy"
                            isNamingNewTheme = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.square.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("SAVE AS NEW THEME...")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button(action: { isPresented = false }) {
                        Text("DONE")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.primaryBtnFg)
                            .background(palette.primaryBtnBg)
                            .cornerRadius(StudioTheme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(palette.bgPanel)
            }
            .frame(width: 780, height: 620)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.45), radius: 28, x: 0, y: 14)
        }
        .onAppear {
            syncHexInputs()
        }
    }
    
    // MARK: - Section 1: Presets & Saved Themes
    
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("01 // THEME PRESETS & SAVED PALETTES")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMuted)
                    .tracking(0.5)
                
                Spacer()
                
                Text("\(themeManager.allThemes.count) THEMES AVAILABLE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
            }
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(themeManager.allThemes) { theme in
                    let isSelected = theme.id == themeManager.currentTheme.id
                    
                    Button(action: {
                        themeManager.applyTheme(theme)
                        syncHexInputs()
                    }) {
                        HStack(spacing: 8) {
                            // 4 Color Pill Dots
                            HStack(spacing: 3) {
                                Circle().fill(theme.greenColor).frame(width: 8, height: 8)
                                Circle().fill(theme.blueColor).frame(width: 8, height: 8)
                                Circle().fill(theme.purpleColor).frame(width: 8, height: 8)
                                Circle().fill(theme.redColor).frame(width: 8, height: 8)
                            }
                            
                            VStack(alignment: .leading, spacing: 1) {
                                Text(theme.name)
                                    .font(.system(size: 10, weight: isSelected ? .black : .bold, design: .monospaced))
                                    .foregroundColor(isSelected ? palette.textMain : palette.textMuted)
                                    .lineLimit(1)
                                
                                Text(theme.isPreset ? "FACTORY PRESET" : "CUSTOM THEME")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundColor(palette.textSubtle)
                            }
                            
                            Spacer()
                            
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .black))
                                    .foregroundColor(theme.blueColor)
                            } else if !theme.isPreset {
                                Button(action: {
                                    themeManager.deleteCustomTheme(id: theme.id)
                                    syncHexInputs()
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(palette.textSubtle)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(isSelected ? palette.bgSubtle : palette.bgPanel)
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                                .stroke(isSelected ? theme.blueColor : palette.borderLine, lineWidth: isSelected ? 1.5 : 1)
                        )
                        .cornerRadius(StudioTheme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - Section 2: Live UI Element Preview
    
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("02 // LIVE ACCENT HARMONY PREVIEW")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .tracking(0.5)
            
            VStack(spacing: 8) {
                // Mock Navigation Bar / Active Tab Line
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("02 // PLAYER")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(palette.textMain)
                        Rectangle()
                            .fill(themeManager.currentTheme.blueColor)
                            .frame(width: 84, height: 2)
                    }
                    
                    Text("01 // LINE SCANNER")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                    
                    Text("03 // SPECS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                    
                    Spacer()
                    
                    // Engine Ready Status Pill
                    HStack(spacing: 5) {
                        Circle()
                            .fill(themeManager.currentTheme.greenColor)
                            .frame(width: 6, height: 6)
                        Text("READY")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.greenColor)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Mock Player / QC Badges Row
                HStack(spacing: 10) {
                    // Slot A Pill (Green)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(themeManager.currentTheme.greenColor)
                            .frame(width: 8, height: 8)
                        Text("SLOT A: MASTER")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.greenColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeManager.currentTheme.greenColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                            .stroke(themeManager.currentTheme.greenColor.opacity(0.4), lineWidth: 1)
                    )
                    
                    // Slot B Pill (Purple)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(themeManager.currentTheme.purpleColor)
                            .frame(width: 8, height: 8)
                        Text("SLOT B: REFERENCE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.purpleColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeManager.currentTheme.purpleColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                            .stroke(themeManager.currentTheme.purpleColor.opacity(0.4), lineWidth: 1)
                    )
                    
                    Spacer()
                    
                    // Timecode Display (Blue/Teal)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(themeManager.currentTheme.blueColor)
                        Text("01:23:45:18")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.blueColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    
                    // Glitch Alert Pill (Red)
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(themeManager.currentTheme.redColor)
                        Text("3 GLITCHES")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.redColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeManager.currentTheme.redColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                            .stroke(themeManager.currentTheme.redColor.opacity(0.4), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .background(palette.bgPanel)
            .studioBox(background: palette.bgPanel, border: palette.borderLine)
        }
    }
    
    // MARK: - Section 3: 4 Core Accents Customizer
    
    private var colorCustomizerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("03 // CUSTOMIZE 4 CORE ACCENT COLORS")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .tracking(0.5)
            
            VStack(spacing: 8) {
                accentEditorRow(
                    slot: .green,
                    title: "GREEN ACCENT",
                    role: "Slot A Master Video, Passing QC results, Engine Ready status",
                    hexBinding: $greenHexInput,
                    currentColor: themeManager.currentTheme.greenColor,
                    onColorPicked: { newColor in
                        let hex = NSColor(newColor).hexString
                        themeManager.updateColor(slot: .green, hex: hex)
                        greenHexInput = hex
                    }
                )
                
                accentEditorRow(
                    slot: .blue,
                    title: "TEAL / BLUE ACCENT",
                    role: "Active tab indicator, timeline playhead, timecode, transport controls",
                    hexBinding: $blueHexInput,
                    currentColor: themeManager.currentTheme.blueColor,
                    onColorPicked: { newColor in
                        let hex = NSColor(newColor).hexString
                        themeManager.updateColor(slot: .blue, hex: hex)
                        blueHexInput = hex
                    }
                )
                
                accentEditorRow(
                    slot: .purple,
                    title: "PURPLE ACCENT",
                    role: "Slot B Reference Video, A/B split screen & difference mode, specs",
                    hexBinding: $purpleHexInput,
                    currentColor: themeManager.currentTheme.purpleColor,
                    onColorPicked: { newColor in
                        let hex = NSColor(newColor).hexString
                        themeManager.updateColor(slot: .purple, hex: hex)
                        purpleHexInput = hex
                    }
                )
                
                accentEditorRow(
                    slot: .red,
                    title: "RED ACCENT",
                    role: "Detected line glitches, failed QC checks, alert warning banners",
                    hexBinding: $redHexInput,
                    currentColor: themeManager.currentTheme.redColor,
                    onColorPicked: { newColor in
                        let hex = NSColor(newColor).hexString
                        themeManager.updateColor(slot: .red, hex: hex)
                        redHexInput = hex
                    }
                )
            }
        }
    }
    
    private func accentEditorRow(
        slot: AccentSlot,
        title: String,
        role: String,
        hexBinding: Binding<String>,
        currentColor: Color,
        onColorPicked: @escaping (Color) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            // Color Swatch with Native ColorPicker
            ColorPicker("", selection: Binding(
                get: { currentColor },
                set: { onColorPicked($0) }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 26, height: 26)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMain)
                Text(role)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(palette.textSubtle)
            }
            
            Spacer()
            
            // Hex text input
            HStack(spacing: 4) {
                Text("#")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
                
                TextField("HEX", text: hexBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(currentColor)
                    .frame(width: 64)
                    .onSubmit {
                        themeManager.updateColor(slot: slot, hex: hexBinding.wrappedValue)
                        syncHexInputs()
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.bgPanel)
        .studioBox(background: palette.bgPanel, border: palette.borderLine)
    }
    
    private func syncHexInputs() {
        greenHexInput = themeManager.currentTheme.greenHex.replacingOccurrences(of: "#", with: "")
        blueHexInput = themeManager.currentTheme.blueHex.replacingOccurrences(of: "#", with: "")
        purpleHexInput = themeManager.currentTheme.purpleHex.replacingOccurrences(of: "#", with: "")
        redHexInput = themeManager.currentTheme.redHex.replacingOccurrences(of: "#", with: "")
    }
}
