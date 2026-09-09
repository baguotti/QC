import SwiftUI
import AppKit

struct ShortcutsModalView: View {
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
    // Dynamic Studio Theme Palette
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
                        Image(systemName: "command")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(palette.textMain)
                        Text("KEYBOARD SHORTCUTS // QCpie")
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
                
                // Content Body (Coming Soon Placeholder)
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "command")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(palette.textMuted)
                    
                    Text("COMING SOON")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(palette.textMain)
                        .tracking(1.5)
                    
                    Text("The keyboard shortcuts reference is currently being updated.")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(palette.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.bgMain)
            }
            .frame(width: 480, height: 260)
            .studioBox(background: palette.bgPanel, border: palette.borderStrong)
            .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
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
}
