import SwiftUI
import AppKit

struct ThemeSettingsModalView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
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
                
                // Content Body
                VStack(alignment: .leading, spacing: 18) {
                    // Section 1: Light / Dark Theme Mode
                    appearanceModeSection
                    
                    // Section 2: Accent Palettes (Muted & Vivid)
                    paletteSection
                    
                    // Section 3: Live UI Element Preview
                    previewSection
                }
                .padding(20)
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
            .frame(width: 600)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.45), radius: 28, x: 0, y: 14)
        }
        .allowsHitTesting(isPresented)
    }
    
    private func dismissModal() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
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
    
    // MARK: - Section 2: Accent Palettes (Muted & Vivid)
    
    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("02 // ACCENT PALETTE (MUTED & VIVID)")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .tracking(0.5)
            
            HStack(spacing: 10) {
                // Muted Theme Card
                themeCard(
                    theme: StudioThemeConfig.muted,
                    subtitle: "Understated, eye-friendly studio tones (Default)"
                )
                
                // Vivid Theme Card
                themeCard(
                    theme: StudioThemeConfig.vivid,
                    subtitle: "High-contrast broadcast & punchy alerts"
                )
            }
        }
    }
    
    private func themeCard(theme: StudioThemeConfig, subtitle: String) -> some View {
        let isSelected = themeManager.currentTheme.id == theme.id ||
            (theme.id == StudioThemeConfig.muted.id && themeManager.currentTheme.id != StudioThemeConfig.vivid.id)
        
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                themeManager.applyTheme(theme)
            }
        }) {
            HStack(spacing: 10) {
                // 4 Color Pill Dots (2x2 Grid)
                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        Circle().fill(theme.greenColor).frame(width: 7, height: 7)
                        Circle().fill(theme.blueColor).frame(width: 7, height: 7)
                    }
                    HStack(spacing: 3) {
                        Circle().fill(theme.purpleColor).frame(width: 7, height: 7)
                        Circle().fill(theme.redColor).frame(width: 7, height: 7)
                    }
                }
                .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name.uppercased())
                        .font(.system(size: 10, weight: isSelected ? .black : .bold, design: .monospaced))
                        .foregroundColor(isSelected ? palette.textMain : palette.textMuted)
                    
                    Text(subtitle)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(palette.textSubtle)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundColor(theme.blueColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? palette.bgSubtle : palette.bgPanel)
            .overlay(
                RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                    .stroke(isSelected ? theme.blueColor : palette.borderLine, lineWidth: isSelected ? 1.5 : 1)
            )
            .cornerRadius(StudioTheme.cornerRadius)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Section 3: Live UI Element Preview
    
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("03 // LIVE ACCENT HARMONY PREVIEW")
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
