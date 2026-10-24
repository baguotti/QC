import SwiftUI
import AppKit

/// Studio-themed compact modal for checking, downloading, and launching QCpie DMG updates.
struct UpdateModalView: View {
    @ObservedObject var updateManager: UpdateManager
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
    // Theme Palette
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    private var bgMain: Color { palette.bgMain }
    private var bgPanel: Color { palette.bgPanel }
    private var bgSubtle: Color { palette.bgSubtle }
    private var bgCardBody: Color { palette.bgCardBody }
    private var borderLine: Color { palette.borderLine }
    private var borderStrong: Color { palette.borderStrong }
    private var textMain: Color { palette.textMain }
    private var textMuted: Color { palette.textMuted }
    private var primaryBtnBg: Color { palette.primaryBtnBg }
    private var primaryBtnFg: Color { palette.primaryBtnFg }
    private var accentPositive: Color { palette.accentPositive }
    private var accentNegative: Color { palette.accentNegative }
    
    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(isPresented ? 0.65 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture {
                    switch updateManager.state {
                    case .downloading, .installing:
                        // Prevent accidental dismiss while downloading or installing
                        break
                    default:
                        dismissModal()
                    }
                }
            
            // Modal Card Container
            VStack(spacing: 0) {
                // Header Bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: StudioTheme.scaleFont(13)))
                            .foregroundColor(textMain)
                        Text("Software Update")
                            .font(.ui(size: 12, weight: .semibold))
                            .foregroundColor(textMain)
                        
                        Text("GitHub Releases")
                            .font(.ui(size: 9, weight: .semibold))
                            .foregroundColor(textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundColor(textMuted)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    Spacer()
                    
                    Button(action: { dismissModal() }) {
                        Text("Close (Esc)")
                            .font(.ui(size: 10, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(isBusyInstalling)
                    .opacity(isBusyInstalling ? 0.4 : 1.0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(bgPanel)
                
                Rectangle().fill(borderLine).frame(height: 1)
                
                // Modal Content Body
                VStack(alignment: .leading, spacing: 18) {
                    switch updateManager.state {
                    case .idle, .checking:
                        checkingView
                    case .upToDate:
                        upToDateView
                    case .updateAvailable(let version, let dmgURL, let webURL):
                        updateAvailableView(version: version, dmgURL: dmgURL, webURL: webURL)
                    case .downloading(let progress, let bytesWritten, let totalBytes):
                        downloadingView(progress: progress, bytesWritten: bytesWritten, totalBytes: totalBytes)
                    case .installing(let status):
                        installingView(status: status)
                    case .readyToInstall(let fileURL):
                        readyToInstallView(fileURL: fileURL)
                    case .failed(let message):
                        failedView(message: message)
                    }
                }
                .padding(20)
                .background(bgMain)
            }
            .frame(width: 540)
            .studioBox(background: bgMain, border: borderStrong)
            .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 10)
        }
        .allowsHitTesting(isPresented)
    }
    
    private var isBusyInstalling: Bool {
        if case .installing = updateManager.state {
            return true
        }
        return false
    }
    
    private func dismissModal() {
        if isBusyInstalling { return }
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
    
    // MARK: - Subviews for States
    
    private var checkingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(0.9)
                .padding(.top, 8)
            
            Text("Checking for updates...")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundColor(textMain)
            
            Text("Querying latest releases on github.com/baguotti/QC")
                .font(.ui(size: 11))
                .foregroundColor(textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
    
    private var upToDateView: some View {
        VStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(accentPositive)
                    .font(.system(size: StudioTheme.scaleFont(20)))
                Text("You are on the latest version")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(textMain)
            }
            
            Text("QCpie v\(AppVersionInfo.version) is currently up to date.")
                .font(.ui(size: 11))
                .foregroundColor(textMuted)
            
            Button(action: { isPresented = false }) {
                Text("Done")
                    .font(.ui(size: 11, weight: .semibold))
                    .frame(width: 120, height: 30)
                    .foregroundColor(primaryBtnFg)
                    .studioBox(background: primaryBtnBg, border: borderStrong)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
    
    private func updateAvailableView(version: String, dmgURL: URL?, webURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Version Available")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundColor(accentPositive)
                    
                    Text("QCpie v\(version)")
                        .font(.ui(size: 18, weight: .semibold))
                        .foregroundColor(textMain)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Currently Installed")
                        .font(.ui(size: 9, weight: .semibold))
                        .foregroundColor(textMuted)
                    Text("v\(AppVersionInfo.version)")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMuted)
                }
                .padding(8)
                .foregroundColor(textMuted)
                .studioBox(background: bgSubtle, border: borderLine)
            }
            
            Rectangle().fill(borderLine).frame(height: 1)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("One-Click Automatic Update")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(textMuted)
                
                Text("Clicking Update & Restart will automatically download, stage, and swap the application in /Applications, then restart QCpie seamlessly.")
                    .font(.ui(size: 11))
                    .foregroundColor(textMain)
                    .lineSpacing(4)
            }
            .padding(12)
            .studioBox(background: bgCardBody, border: borderLine)
            
            HStack(spacing: 10) {
                if dmgURL != nil {
                    Button(action: { updateManager.startOneClickUpdate() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: StudioTheme.scaleFont(11)))
                            Text("Update & Restart")
                                .font(.ui(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundColor(.white)
                        .studioBox(background: accentPositive, border: borderStrong)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { updateManager.downloadDMGManually() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: StudioTheme.scaleFont(10)))
                            Text("Manual DMG")
                                .font(.ui(size: 10, weight: .semibold))
                        }
                        .frame(width: 105, height: 34)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        if let webURL = updateManager.remoteWebURL {
                            NSWorkspace.shared.open(webURL)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: StudioTheme.scaleFont(11)))
                            Text("View GitHub Release")
                                .font(.ui(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundColor(primaryBtnFg)
                        .studioBox(background: primaryBtnBg, border: borderStrong)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: { isPresented = false }) {
                    Text("Later")
                        .font(.ui(size: 11, weight: .semibold))
                        .frame(width: 75, height: 34)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }
    
    private func downloadingView(progress: Double, bytesWritten: Int64, totalBytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("DOWNLOADING UPDATE // QCpie v\(updateManager.latestVersion)")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundColor(textMain)
                
                Spacer()
                
                Text("\(Int(progress * 100))%")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(accentPositive)
            }
            
            // Minimalist Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                        .fill(bgSubtle)
                        .overlay(RoundedRectangle(cornerRadius: StudioTheme.cornerRadius).stroke(borderLine, lineWidth: 1))
                    
                    RoundedRectangle(cornerRadius: StudioTheme.cornerRadius)
                        .fill(accentPositive)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progress))))
                }
            }
            .frame(height: 12)
            
            HStack {
                Text("\(formatBytes(bytesWritten)) / \(totalBytes > 0 ? formatBytes(totalBytes) : "...")")
                    .font(.ui(size: 10))
                    .foregroundColor(textMuted)
                
                Spacer()
                
                Button(action: { updateManager.cancelDownload() }) {
                    Text("Cancel")
                        .font(.ui(size: 10, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
    }
    
    private func installingView(status: String) -> some View {
        VStack(alignment: .center, spacing: 14) {
            ProgressView()
                .scaleEffect(1.0)
                .padding(.top, 8)
            
            VStack(spacing: 6) {
                Text("Installing update & restarting...")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(textMain)
                
                Text(status.isEmpty ? "Preparing application bundle..." : status)
                    .font(.ui(size: 11))
                    .foregroundColor(accentPositive)
            }
            
            Text("QCpie will close and relaunch automatically in a moment.")
                .font(.ui(size: 10))
                .foregroundColor(textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
    
    private func readyToInstallView(fileURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(accentPositive)
                    .font(.system(size: StudioTheme.scaleFont(18)))
                
                Text("Disk Image Downloaded & Mounted")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(textMain)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Final step to finish update:")
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundColor(textMuted)
                
                HStack(alignment: .top, spacing: 6) {
                    Text("1.")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMain)
                    Text("Click 'Quit QCpie to Replace' below so the running app can be updated.")
                        .font(.ui(size: 11))
                        .foregroundColor(textMain)
                }
                
                HStack(alignment: .top, spacing: 6) {
                    Text("2.")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(textMain)
                    Text("In the opened QCpie installer window in Finder, drag QCpie into Applications (click 'Replace').")
                        .font(.ui(size: 11))
                        .foregroundColor(textMain)
                }
            }
            .padding(12)
            .studioBox(background: bgCardBody, border: borderLine)
            
            HStack(spacing: 10) {
                Button(action: { updateManager.quitAppToReplace() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: StudioTheme.scaleFont(11)))
                        Text("Quit QCpie to Replace")
                            .font(.ui(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .foregroundColor(primaryBtnFg)
                    .studioBox(background: primaryBtnBg, border: borderStrong)
                }
                .buttonStyle(.plain)
                
                Button(action: { NSWorkspace.shared.open(fileURL) }) {
                    Text("Re-Open DMG")
                        .font(.ui(size: 10, weight: .semibold))
                        .frame(width: 100, height: 34)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
                
                Button(action: { isPresented = false }) {
                    Text("Close")
                        .font(.ui(size: 10, weight: .semibold))
                        .frame(width: 70, height: 34)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private func failedView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(accentNegative)
                    .font(.system(size: StudioTheme.scaleFont(16)))
                
                Text("Update Check Notice")
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundColor(textMain)
            }
            
            Text(message)
                .font(.ui(size: 11))
                .foregroundColor(textMuted)
                .padding(10)
                .studioBox(background: bgCardBody, border: borderLine)
            
            HStack(spacing: 10) {
                Button(action: { updateManager.checkForUpdates(userInitiated: true) }) {
                    Text("Try Again")
                        .font(.ui(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundColor(primaryBtnFg)
                        .studioBox(background: primaryBtnBg, border: borderStrong)
                }
                .buttonStyle(.plain)
                
                if let webURL = updateManager.remoteWebURL {
                    Button(action: { NSWorkspace.shared.open(webURL) }) {
                        Text("View on GitHub")
                            .font(.ui(size: 11, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundColor(textMain)
                            .studioBox(background: bgSubtle, border: borderLine)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                Button(action: { isPresented = false }) {
                    Text("Dismiss")
                        .font(.ui(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundColor(textMain)
                        .studioBox(background: bgSubtle, border: borderLine)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Helper Formatters
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
