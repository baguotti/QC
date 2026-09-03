import SwiftUI
import AppKit

/// Studio-themed compact modal for checking, downloading, and launching QCpie DMG updates.
struct UpdateModalView: View {
    @ObservedObject var updateManager: UpdateManager
    @Binding var isPresented: Bool
    @AppStorage("isLightMode") private var isLightMode: Bool = false
    
    // Theme Tokens
    private var bgMain: Color { StudioTheme.bgMain(isLightMode) }
    private var bgPanel: Color { StudioTheme.bgPanel(isLightMode) }
    private var bgSubtle: Color { StudioTheme.bgSubtle(isLightMode) }
    private var bgCardBody: Color { StudioTheme.bgCardSubtle(isLightMode) }
    private var borderLine: Color { StudioTheme.borderLine(isLightMode) }
    private var borderStrong: Color { StudioTheme.borderStrong(isLightMode) }
    private var textMain: Color { StudioTheme.textMain(isLightMode) }
    private var textMuted: Color { StudioTheme.textMuted(isLightMode) }
    private var primaryBtnBg: Color { StudioTheme.primaryBtnBg(isLightMode) }
    private var primaryBtnFg: Color { StudioTheme.primaryBtnFg(isLightMode) }
    private var accentPositive: Color { StudioTheme.positive }
    private var accentNegative: Color { StudioTheme.negative }
    
    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.65)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    if case .downloading = updateManager.state {
                        // Prevent accidental dismiss while downloading
                    } else {
                        isPresented = false
                    }
                }
            
            // Modal Card Container
            VStack(spacing: 0) {
                // Header Bar
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(textMain)
                        Text("SOFTWARE UPDATE // QCpie")
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .foregroundColor(textMain)
                        
                        Text("GITHUB RELEASES")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(textMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(bgSubtle)
                            .border(borderLine, width: 1)
                    }
                    Spacer()
                    
                    Button(action: { isPresented = false }) {
                        Text("CLOSE (ESC)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
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
            .border(borderStrong, width: 1)
            .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 10)
        }
    }
    
    // MARK: - Subviews for States
    
    private var checkingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(0.9)
                .padding(.top, 8)
            
            Text("CHECKING FOR UPDATES...")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(textMain)
            
            Text("Querying latest releases on github.com/baguotti/QC")
                .font(.system(size: 11, design: .monospaced))
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
                    .font(.system(size: 20))
                Text("YOU ARE ON THE LATEST VERSION")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(textMain)
            }
            
            Text("QCpie v\(AppVersionInfo.version) is currently up to date.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textMuted)
            
            Button(action: { isPresented = false }) {
                Text("DONE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 120, height: 30)
                    .background(primaryBtnBg)
                    .foregroundColor(primaryBtnFg)
                    .border(borderStrong, width: 1)
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
                    Text("NEW VERSION AVAILABLE")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(accentPositive)
                    
                    Text("QCpie v\(version)")
                        .font(.system(size: 18, weight: .black, design: .monospaced))
                        .foregroundColor(textMain)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text("CURRENTLY INSTALLED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                    Text("v\(AppVersionInfo.version)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMuted)
                }
                .padding(8)
                .background(bgSubtle)
                .border(borderLine, width: 1)
            }
            
            Rectangle().fill(borderLine).frame(height: 1)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("AUTOMATIC INSTALLER FETCH")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                
                Text("Clicking Update will automatically download the installer disk image (.dmg) to your Downloads folder and open it in Finder so you can replace the app in Applications.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(textMain)
                    .lineSpacing(4)
            }
            .padding(12)
            .background(bgCardBody)
            .border(borderLine, width: 1)
            
            HStack(spacing: 12) {
                Button(action: { updateManager.startDownload() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11))
                        Text(dmgURL != nil ? "UPDATE NOW (.DMG)" : "OPEN GITHUB RELEASE")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(accentPositive)
                    .foregroundColor(.white)
                    .border(borderStrong, width: 1)
                }
                .buttonStyle(.plain)
                
                Button(action: { isPresented = false }) {
                    Text("LATER")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 100, height: 34)
                        .background(bgSubtle)
                        .foregroundColor(textMain)
                        .border(borderLine, width: 1)
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
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(textMain)
                
                Spacer()
                
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(accentPositive)
            }
            
            // Minimalist Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(bgSubtle)
                        .border(borderLine, width: 1)
                    
                    Rectangle()
                        .fill(accentPositive)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progress))))
                }
            }
            .frame(height: 12)
            
            HStack {
                Text("\(formatBytes(bytesWritten)) / \(totalBytes > 0 ? formatBytes(totalBytes) : "...")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(textMuted)
                
                Spacer()
                
                Button(action: { updateManager.cancelDownload() }) {
                    Text("CANCEL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(bgSubtle)
                        .foregroundColor(textMain)
                        .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
    }
    
    private func readyToInstallView(fileURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(accentPositive)
                    .font(.system(size: 18))
                
                Text("DISK IMAGE DOWNLOADED & MOUNTED")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(textMain)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("FINAL STEP TO FINISH UPDATE:")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(textMuted)
                
                HStack(alignment: .top, spacing: 6) {
                    Text("1.")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMain)
                    Text("Click 'Quit QCpie to Replace' below so the running app can be updated.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textMain)
                }
                
                HStack(alignment: .top, spacing: 6) {
                    Text("2.")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(textMain)
                    Text("In the opened QCpie installer window in Finder, drag QCpie into Applications (click 'Replace').")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(textMain)
                }
            }
            .padding(12)
            .background(bgCardBody)
            .border(borderLine, width: 1)
            
            HStack(spacing: 10) {
                Button(action: { updateManager.quitAppToReplace() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: 11))
                        Text("QUIT QCPIE TO REPLACE")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(primaryBtnBg)
                    .foregroundColor(primaryBtnFg)
                    .border(borderStrong, width: 1)
                }
                .buttonStyle(.plain)
                
                Button(action: { NSWorkspace.shared.open(fileURL) }) {
                    Text("RE-OPEN DMG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(width: 100, height: 34)
                        .background(bgSubtle)
                        .foregroundColor(textMain)
                        .border(borderLine, width: 1)
                }
                .buttonStyle(.plain)
                
                Button(action: { isPresented = false }) {
                    Text("CLOSE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .frame(width: 70, height: 34)
                        .background(bgSubtle)
                        .foregroundColor(textMain)
                        .border(borderLine, width: 1)
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
                    .font(.system(size: 16))
                
                Text("UPDATE CHECK NOTICE")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(textMain)
            }
            
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textMuted)
                .padding(10)
                .background(bgCardBody)
                .border(borderLine, width: 1)
            
            HStack(spacing: 10) {
                Button(action: { updateManager.checkForUpdates(userInitiated: true) }) {
                    Text("TRY AGAIN")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(primaryBtnBg)
                        .foregroundColor(primaryBtnFg)
                        .border(borderStrong, width: 1)
                }
                .buttonStyle(.plain)
                
                if let webURL = updateManager.remoteWebURL {
                    Button(action: { NSWorkspace.shared.open(webURL) }) {
                        Text("VIEW ON GITHUB")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(bgSubtle)
                            .foregroundColor(textMain)
                            .border(borderLine, width: 1)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                Button(action: { isPresented = false }) {
                    Text("DISMISS")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(bgSubtle)
                        .foregroundColor(textMain)
                        .border(borderLine, width: 1)
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
