import SwiftUI
import AppKit

/// Window-style modal with a source list on the left and a detail pane on the right (Premiere Pro preferences,
/// Apple Help): used by User Settings and the User Guide.
struct SidebarModalShell<Sidebar: View, Detail: View>: View {
    @Binding var isPresented: Bool
    let title: String
    var width: CGFloat = 720
    var height: CGFloat = 500
    var sidebarWidth: CGFloat = 180
    var footnote: String? = nil
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail
    @AppStorage("isLightMode") private var isLightMode: Bool = false

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        ZStack {
            Color.black.opacity(isPresented ? 0.55 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                Text(title)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundColor(palette.textMain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(palette.bgCardHeader)

                Rectangle().fill(palette.borderLine).frame(height: 1)

                HStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            sidebar
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: sidebarWidth)
                    .background(palette.bgCardSubtle)

                    Rectangle().fill(palette.borderLine).frame(width: 1)

                    ScrollView(.vertical, showsIndicators: true) {
                        detail
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .background(palette.bgPanel)
                }

                Rectangle().fill(palette.borderLine).frame(height: 1)

                HStack {
                    if let footnote {
                        Text(footnote)
                            .font(.ui(size: 11))
                            .foregroundColor(palette.textMuted)
                    }
                    Spacer()
                    Button(action: { dismiss() }) {
                        Text("Done")
                            .font(.ui(size: 12, weight: .medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 5)
                            .foregroundColor(palette.primaryBtnFg)
                            .background(palette.primaryBtnBg)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.bgCardHeader)
            }
            .frame(width: width, height: height)
            .background(palette.bgPanel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.borderStrong, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.45), radius: 28, x: 0, y: 14)

            Button("") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(isPresented)
    }

    private func dismiss() {
        withAnimation(Motion.fade) { isPresented = false }
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
}

/// A selectable source-list row (sidebar).
struct SidebarRow: View {
    let title: String
    var icon: String? = nil
    var indent: Bool = false
    let isSelected: Bool
    let isLightMode: Bool
    let action: () -> Void

    private var palette: StudioPalette { StudioPalette(isLightMode) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: StudioTheme.scaleFont(11)))
                        .frame(width: 14)
                        .foregroundColor(isSelected ? .white : palette.textMuted)
                }
                Text(title)
                    .font(.ui(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .white : palette.textMain)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, indent ? 18 : 8)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? palette.accentBlue : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
