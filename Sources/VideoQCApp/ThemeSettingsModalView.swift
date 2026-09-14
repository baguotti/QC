import SwiftUI
import AppKit

struct ThemeSettingsModalView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
    @State private var isSavingPreset: Bool = false
    @State private var newPresetName: String = ""
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(isPresented ? 0.65 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture {
                    dismissModal()
                }
            
            // Modal Card Container
            VStack(spacing: 0) {
                // Header Bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(themeManager.currentTheme.blueColor)
                        Text("APPEARANCE & THEME // QCpie")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(palette.textMain)
                    }
                    
                    Spacer()
                    
                    Button(action: { dismissModal() }) {
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
                
                // Scrollable Content Body
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Section 1: Light / Dark Theme Mode
                        appearanceModeSection
                        
                        // Section 2: Accent Presets
                        presetsSection
                        
                        // Section 3: Customize Accent Colors (Per-Slot)
                        customColorsSection
                        
                        // Section 4: Button & UI Size (Zoom)
                        buttonZoomSection
                        
                        // Section 5: Live UI Element Preview
                        previewSection
                    }
                    .padding(20)
                }
                .frame(maxHeight: 540)
                .background(palette.bgMain)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Footer Action Bar
                HStack {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            themeManager.resetToDefault()
                            isLightMode = false
                        }
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
                    
                    Button(action: { dismissModal() }) {
                        Text("DONE")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .padding(.horizontal, 18)
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
            .frame(width: 640)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.45), radius: 28, x: 0, y: 14)
        }
        .allowsHitTesting(isPresented)
    }
    
    private func dismissModal() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
            isSavingPreset = false
        }
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
    
    // MARK: - Section 1: Appearance Mode (Light / Dark)
    
    private var appearanceModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("01 // APPEARANCE (LIGHT & DARK)")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .tracking(0.5)
            
            HStack(spacing: 10) {
                // Dark Mode Card
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isLightMode = false
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(!isLightMode ? themeManager.currentTheme.blueColor : palette.textMuted)
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DARK THEME")
                                .font(.system(size: 10, weight: !isLightMode ? .black : .bold, design: .monospaced))
                                .foregroundColor(!isLightMode ? palette.textMain : palette.textMuted)
                            
                            Text("Low-glare studio environment (Default)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(palette.textSubtle)
                        }
                        
                        Spacer()
                        
                        if !isLightMode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(themeManager.currentTheme.blueColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(!isLightMode ? palette.bgSubtle : palette.bgPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                            .stroke(!isLightMode ? themeManager.currentTheme.blueColor : palette.borderLine, lineWidth: !isLightMode ? 1.5 : 1)
                    )
                    .cornerRadius(StudioTheme.cornerRadius)
                }
                .buttonStyle(.plain)
                
                // Light Mode Card
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isLightMode = true
                    }
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.max.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(isLightMode ? themeManager.currentTheme.blueColor : palette.textMuted)
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LIGHT THEME")
                                .font(.system(size: 10, weight: isLightMode ? .black : .bold, design: .monospaced))
                                .foregroundColor(isLightMode ? palette.textMain : palette.textMuted)
                            
                            Text("High-ambient office & daylight inspection")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(palette.textSubtle)
                        }
                        
                        Spacer()
                        
                        if isLightMode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(themeManager.currentTheme.blueColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(isLightMode ? palette.bgSubtle : palette.bgPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                            .stroke(isLightMode ? themeManager.currentTheme.blueColor : palette.borderLine, lineWidth: isLightMode ? 1.5 : 1)
                    )
                    .cornerRadius(StudioTheme.cornerRadius)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Section 2: Accent Presets
    
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("02 // ACCENT PRESETS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMuted)
                    .tracking(0.5)
                
                Spacer()
                
                Text("(\(themeManager.allThemes.count)/\(ThemeManager.maxTotalPresets) TOTAL)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
            }
            
            // Preset Cards Grid (2 Columns)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                ForEach(themeManager.allThemes) { preset in
                    presetCard(preset: preset)
                }
            }
            
            // Save Preset Controls
            if isSavingPreset {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(palette.textSubtle)
                        TextField("PRESET NAME", text: $newPresetName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMain)
                            .onSubmit {
                                saveNewPreset()
                            }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .studioBox(background: palette.bgPanel, border: themeManager.currentTheme.blueColor)
                    
                    Button(action: {
                        saveNewPreset()
                    }) {
                        Text("SAVE")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.primaryBtnFg)
                            .background(palette.primaryBtnBg)
                            .cornerRadius(StudioTheme.cornerRadius)
                    }
                    .buttonStyle(.plain)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    
                    Button(action: {
                        isSavingPreset = false
                        newPresetName = ""
                    }) {
                        Text("CANCEL")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundColor(palette.textMuted)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 10) {
                    Button(action: {
                        newPresetName = "PRESET \(themeManager.userPresets.count + 1)"
                        isSavingPreset = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .bold))
                            Text("SAVE CURRENT AS PRESET")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundColor(themeManager.canSaveMorePresets ? palette.textMain : palette.textMuted.opacity(0.4))
                        .studioBox(
                            background: palette.bgSubtle,
                            border: themeManager.canSaveMorePresets ? palette.borderLine : palette.borderLine.opacity(0.3)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!themeManager.canSaveMorePresets)
                    
                    if !themeManager.canSaveMorePresets {
                        Text("PRESET LIMIT REACHED (10 TOTAL)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.redColor)
                    }
                    
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }
    
    private func saveNewPreset() {
        if themeManager.savePreset(name: newPresetName) {
            isSavingPreset = false
            newPresetName = ""
        }
    }
    
    private func presetCard(preset: StudioThemeConfig) -> some View {
        let isSelected = themeManager.currentTheme.id == preset.id
        
        return HStack(spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    themeManager.applyTheme(preset)
                }
            }) {
                HStack(spacing: 8) {
                    // 4 Color Pill Dots (2x2 Grid)
                    VStack(spacing: 2.5) {
                        HStack(spacing: 2.5) {
                            Circle().fill(preset.greenColor).frame(width: 6, height: 6)
                            Circle().fill(preset.blueColor).frame(width: 6, height: 6)
                        }
                        HStack(spacing: 2.5) {
                            Circle().fill(preset.purpleColor).frame(width: 6, height: 6)
                            Circle().fill(preset.redColor).frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 15)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.name.uppercased())
                            .font(.system(size: 9.5, weight: isSelected ? .black : .bold, design: .monospaced))
                            .foregroundColor(isSelected ? palette.textMain : palette.textMuted)
                            .lineLimit(1)
                        
                        Text(preset.isPreset ? "FACTORY PRESET" : "USER PRESET")
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .foregroundColor(palette.textSubtle)
                    }
                    
                    Spacer(minLength: 4)
                    
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(themeManager.currentTheme.blueColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Delete button for custom user presets
            if !preset.isPreset {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        themeManager.deletePreset(id: preset.id)
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(palette.textSubtle)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete preset")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? palette.bgSubtle : palette.bgPanel)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                .stroke(isSelected ? themeManager.currentTheme.blueColor : palette.borderLine, lineWidth: isSelected ? 1.5 : 1)
        )
        .cornerRadius(StudioTheme.cornerRadius)
    }
    
    // MARK: - Section 3: Customize Accent Colors (Per-Slot)
    
    private var customColorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("03 // CUSTOMIZE ACCENT COLORS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMuted)
                    .tracking(0.5)
                
                Spacer()
                
                Text("CLICK SWATCH OR EDIT HEX")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
            }
            
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                ForEach(AccentSlot.allCases) { slot in
                    AccentColorSlotCard(slot: slot, palette: palette, themeManager: themeManager)
                }
            }
        }
    }
    
    // MARK: - Section 4: Button & UI Size (Zoom)
    
    private var buttonZoomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("04 // BUTTON & UI SIZE")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMuted)
                    .tracking(0.5)
                
                Spacer()
                
                Text("SHORTCUTS: ⌘- / ⌘+")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
            }
            
            HStack(spacing: 10) {
                ForEach(UIButtonZoomLevel.allCases) { level in
                    buttonZoomCard(level: level)
                }
            }
        }
    }
    
    private func buttonZoomCard(level: UIButtonZoomLevel) -> some View {
        let isSelected = themeManager.buttonZoom == level
        
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                themeManager.buttonZoom = level
            }
        }) {
            HStack(spacing: 8) {
                // Size Icon Indicator
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? themeManager.currentTheme.blueColor : palette.borderLine, lineWidth: 1.2)
                        .frame(
                            width: 14 * (level.scaleFactor == 1.0 ? 0.8 : (level.scaleFactor == 1.2 ? 1.0 : 1.25)),
                            height: 14 * (level.scaleFactor == 1.0 ? 0.8 : (level.scaleFactor == 1.2 ? 1.0 : 1.25))
                        )
                }
                .frame(width: 18)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(level.title)
                            .font(.system(size: 10, weight: isSelected ? .black : .bold, design: .monospaced))
                            .foregroundColor(isSelected ? palette.textMain : palette.textMuted)
                        Text("(\(String(format: "%.1fx", level.scaleFactor)))")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? themeManager.currentTheme.blueColor : palette.textSubtle)
                    }
                    
                    Text(level.subtitle)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(palette.textSubtle)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(themeManager.currentTheme.blueColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isSelected ? palette.bgSubtle : palette.bgPanel)
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                    .stroke(isSelected ? themeManager.currentTheme.blueColor : palette.borderLine, lineWidth: isSelected ? 1.5 : 1)
            )
            .cornerRadius(StudioTheme.cornerRadius)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Section 5: Live UI Element Preview
    
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("05 // LIVE ACCENT HARMONY PREVIEW")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .tracking(0.5)
            
            VStack(spacing: 8) {
                // Mock Navigation Bar / Active Tab Line
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PLAYER")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(palette.textMain)
                        Rectangle()
                            .fill(themeManager.currentTheme.blueColor)
                            .frame(width: 52, height: 2)
                    }
                    
                    Text("SPECS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                    
                    Text("LINE FINDER")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(palette.textSubtle)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Mock Player / QC Badges Row
                HStack(spacing: 8) {
                    // Slot A Pill (Green)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(themeManager.currentTheme.greenColor)
                            .frame(width: 7, height: 7)
                        Text("SLOT A: MASTER")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.greenColor)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(themeManager.currentTheme.greenColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                            .stroke(themeManager.currentTheme.greenColor.opacity(0.4), lineWidth: 1)
                    )
                    
                    // Slot B Pill (Purple)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(themeManager.currentTheme.purpleColor)
                            .frame(width: 7, height: 7)
                        Text("SLOT B: REFERENCE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.purpleColor)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(themeManager.currentTheme.purpleColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                            .stroke(themeManager.currentTheme.purpleColor.opacity(0.4), lineWidth: 1)
                    )
                    
                    Spacer()
                    
                    // Timecode Display (Blue/Teal)
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(themeManager.currentTheme.blueColor)
                        Text("01:23:45:18")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.blueColor)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    
                    // Glitch Alert Pill (Red)
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(themeManager.currentTheme.redColor)
                        Text("3 GLITCHES")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.redColor)
                    }
                    .padding(.horizontal, 7)
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
}

// MARK: - Accent Color Slot Card

private struct AccentColorSlotCard: View {
    let slot: AccentSlot
    let palette: StudioPalette
    @ObservedObject var themeManager: ThemeManager
    @State private var hexInput: String = ""
    
    var body: some View {
        HStack(spacing: 8) {
            // Role info
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .lineLimit(1)
                Text(slot.roleDescription)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundColor(palette.textSubtle)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 4)
            
            // Hex text field
            HStack(spacing: 2) {
                Text("#")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textSubtle)
                
                TextField("000000", text: $hexInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .frame(width: 48)
                    .onSubmit {
                        applyHex()
                    }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
            
            // Native Color Picker
            ColorPicker(
                "",
                selection: Binding<Color>(
                    get: { themeManager.currentTheme.color(for: slot) },
                    set: { newColor in
                        themeManager.updateAccentColor(slot: slot, color: newColor)
                        syncHex()
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 20, height: 20)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.bgPanel)
        .overlay(
            RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                .stroke(palette.borderLine, lineWidth: 1)
        )
        .cornerRadius(StudioTheme.cornerRadius)
        .onAppear {
            syncHex()
        }
        .onChange(of: themeManager.currentTheme) { _, _ in
            syncHex()
        }
    }
    
    private func syncHex() {
        let fullHex = themeManager.currentTheme.hex(for: slot)
        let clean = fullHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        if hexInput.uppercased() != clean {
            hexInput = clean
        }
    }
    
    private func applyHex() {
        let clean = hexInput.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        guard clean.count == 6, clean.allSatisfy({ $0.isHexDigit }) else {
            syncHex()
            return
        }
        themeManager.updateAccentColor(slot: slot, hex: "#\(clean)")
        hexInput = clean
    }
}
