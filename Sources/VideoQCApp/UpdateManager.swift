import Foundation
import AppKit
import Combine

/// Manages GitHub release checking, downloading, and DMG mounting for QCpie.
@MainActor
public final class UpdateManager: NSObject, ObservableObject {
    public static let shared = UpdateManager()
    
    // MARK: - Published State
    
    public enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, dmgURL: URL?, webURL: URL)
        case downloading(progress: Double, bytesWritten: Int64, totalBytes: Int64)
        case installing(status: String)
        case readyToInstall(fileURL: URL)
        case failed(String)
    }
    
    @Published public private(set) var state: UpdateState = .idle
    @Published public var showModal: Bool = false
    @Published public private(set) var latestVersion: String = ""
    @Published public private(set) var remoteWebURL: URL? = nil
    @Published public private(set) var remoteDMGURL: URL? = nil
    @Published public private(set) var hasUpdate: Bool = false
    @Published public private(set) var lastCheckDate: Date? = nil
    
    // MARK: - Internal Download Handling
    
    private var downloadTask: URLSessionDownloadTask?
    private var isManualDownload: Bool = false
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    
    private let repoOwner = AppConfig.githubRepoOwner
    private let repoName = AppConfig.githubRepoName
    
    private override init() {
        super.init()
    }
    
    // MARK: - Check for Updates
    
    /// Checks the GitHub API for the latest release.
    /// - Parameter userInitiated: If true, opens the modal immediately to show status (checking, up-to-date, or update available). If false, runs silently in background.
    public func checkForUpdates(userInitiated: Bool = false) {
        if userInitiated {
            showModal = true
            state = .checking
        }
        
        Task {
            await performCheck(userInitiated: userInitiated)
        }
    }
    
    private func performCheck(userInitiated: Bool) async {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            if userInitiated {
                state = .failed("Invalid repository API URL.")
            }
            return
        }
        
        var request = URLRequest(url: apiURL)
        request.setValue("QCpie-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            self.lastCheckDate = Date()
            
            guard let httpResponse = response as? HTTPURLResponse else {
                if userInitiated {
                    state = .failed("Invalid response from update server.")
                }
                return
            }
            
            // 404 means no releases exist on GitHub yet
            if httpResponse.statusCode == 404 {
                self.hasUpdate = false
                if userInitiated {
                    self.state = .upToDate
                } else {
                    self.state = .idle
                }
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                if userInitiated {
                    state = .failed("GitHub returned HTTP status \(httpResponse.statusCode).")
                }
                return
            }
            
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let cleanRemoteTag = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let currentVersion = AppVersionInfo.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            
            self.remoteWebURL = URL(string: release.htmlUrl)
            
            // Find DMG asset if available
            if let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
               let downloadURL = URL(string: dmgAsset.browserDownloadUrl) {
                self.remoteDMGURL = downloadURL
            } else {
                self.remoteDMGURL = nil
            }
            
            if isVersion(cleanRemoteTag, newerThan: currentVersion) {
                self.hasUpdate = true
                self.latestVersion = cleanRemoteTag
                self.state = .updateAvailable(
                    version: cleanRemoteTag,
                    dmgURL: self.remoteDMGURL,
                    webURL: self.remoteWebURL ?? AppConfig.githubReleasesWebURL
                )
                if userInitiated {
                    self.showModal = true
                }
            } else {
                self.hasUpdate = false
                if userInitiated {
                    self.state = .upToDate
                } else {
                    self.state = .idle
                }
            }
        } catch {
            if userInitiated {
                state = .failed("Unable to check for updates: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Start Download & Auto-Update
    
    /// Begins 1-click automatic update: downloads DMG, extracts in background, replaces app in /Applications, and relaunches.
    public func startOneClickUpdate() {
        isManualDownload = false
        startDownload()
    }
    
    /// Manual DMG download: downloads DMG to ~/Downloads and opens it in Finder for manual handling.
    public func downloadDMGManually() {
        isManualDownload = true
        startDownload()
    }
    
    /// Begins downloading the DMG installer directly.
    public func startDownload() {
        guard let dmgURL = remoteDMGURL else {
            // If no DMG asset attached, open the release in browser
            if let webURL = remoteWebURL {
                NSWorkspace.shared.open(webURL)
            }
            return
        }
        
        state = .downloading(progress: 0.0, bytesWritten: 0, totalBytes: 0)
        downloadTask?.cancel()
        downloadTask = urlSession.downloadTask(with: dmgURL)
        downloadTask?.resume()
    }
    
    /// Cancels active download
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isManualDownload = false
        if hasUpdate {
            state = .updateAvailable(
                version: latestVersion,
                dmgURL: remoteDMGURL,
                webURL: remoteWebURL ?? AppConfig.githubReleasesWebURL
            )
        } else {
            state = .idle
        }
    }
    
    /// Quits QCpie so that user can replace the app in /Applications without "File In Use" errors (manual flow).
    public func quitAppToReplace() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Download Finished Handling
    
    private func handleDownloadFinished(tempDMGURL: URL) {
        if isManualDownload {
            let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let destinationURL = downloadsFolder.appendingPathComponent("QCpie-Update.dmg")
            do {
                try? FileManager.default.removeItem(at: destinationURL)
                try FileManager.default.moveItem(at: tempDMGURL, to: destinationURL)
                self.state = .readyToInstall(fileURL: destinationURL)
                NSWorkspace.shared.open(destinationURL)
            } catch {
                self.state = .failed("Failed to save downloaded update: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: tempDMGURL)
            }
        } else {
            self.state = .installing(status: "Extracting update...")
            self.startAutoInstall(dmgURL: tempDMGURL)
        }
    }
    
    private func startAutoInstall(dmgURL: URL) {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("qcpie_update_\(UUID().uuidString)", isDirectory: true)
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let localDMG = workDir.appendingPathComponent("update.dmg")
                try FileManager.default.moveItem(at: dmgURL, to: localDMG)
                
                try await Self.performAutoInstallAndRelaunch(
                    dmgURL: localDMG,
                    workDir: workDir,
                    onStatusUpdate: { status in
                        Task { @MainActor in
                            UpdateManager.shared.state = .installing(status: status)
                        }
                    }
                )
            } catch {
                await MainActor.run {
                    UpdateManager.shared.state = .failed("Installation failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: workDir)
                try? FileManager.default.removeItem(at: dmgURL)
            }
        }
    }
    
    nonisolated private static func performAutoInstallAndRelaunch(
        dmgURL: URL,
        workDir: URL,
        onStatusUpdate: @escaping @Sendable (String) -> Void
    ) async throws {
        onStatusUpdate("Mounting disk image...")
        
        let mntDir = workDir.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mntDir, withIntermediateDirectories: true)
        
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = [
            "attach",
            dmgURL.path,
            "-nobrowse",
            "-readonly",
            "-noautoopen",
            "-mountpoint",
            mntDir.path,
            "-quiet"
        ]
        let attachErrPipe = Pipe()
        attach.standardError = attachErrPipe
        try attach.run()
        attach.waitUntilExit()
        
        if attach.terminationStatus != 0 {
            let data = attachErrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit code \(attach.terminationStatus)"
            throw AutoUpdateError.mountFailed(msg)
        }
        
        let unmountDMG: @Sendable () -> Void = {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mntDir.path, "-quiet", "-force"]
            try? detach.run()
            detach.waitUntilExit()
        }
        
        let defaultAppURL = mntDir.appendingPathComponent("QCpie.app")
        let sourceAppURL: URL
        if FileManager.default.fileExists(atPath: defaultAppURL.path) {
            sourceAppURL = defaultAppURL
        } else {
            let contents = (try? FileManager.default.contentsOfDirectory(at: mntDir, includingPropertiesForKeys: nil)) ?? []
            if let found = contents.first(where: { $0.pathExtension == "app" }) {
                sourceAppURL = found
            } else {
                unmountDMG()
                throw AutoUpdateError.appNotFound
            }
        }
        
        onStatusUpdate("Staging application bundle...")
        let stagedDir = workDir.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let stagedAppURL = stagedDir.appendingPathComponent("QCpie.app")
        
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [sourceAppURL.path, stagedAppURL.path]
        let dittoErrPipe = Pipe()
        ditto.standardError = dittoErrPipe
        try ditto.run()
        ditto.waitUntilExit()
        
        // Unmount disk image now that bundle is safely copied to staging
        unmountDMG()
        
        if ditto.terminationStatus != 0 {
            let data = dittoErrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit code \(ditto.terminationStatus)"
            throw AutoUpdateError.stagingFailed(msg)
        }
        
        // Remove downloaded DMG to reclaim disk space immediately
        try? FileManager.default.removeItem(at: dmgURL)
        
        let currentAppPath = Bundle.main.bundleURL.path
        let targetAppPath: String
        if currentAppPath.contains("AppTranslocation") ||
            currentAppPath.contains("/Downloads/") ||
            currentAppPath.contains("/.build/") ||
            !currentAppPath.hasSuffix(".app") {
            targetAppPath = "/Applications/QCpie.app"
        } else {
            targetAppPath = currentAppPath
        }
        
        onStatusUpdate("Restarting QCpie...")
        
        let scriptURL = workDir.appendingPathComponent("relaunch.sh")
        let scriptContent = """
        #!/bin/sh
        OLD_PID="$1"
        STAGED_APP="$2"
        TARGET_APP="$3"
        WORK_DIR="$4"

        # 1. Wait until old QCpie process fully exits (up to 15s)
        COUNT=0
        while kill -0 "$OLD_PID" 2>/dev/null; do
            sleep 0.1
            COUNT=$((COUNT + 1))
            if [ $COUNT -gt 150 ]; then
                kill -9 "$OLD_PID" 2>/dev/null || true
                break
            fi
        done

        # 2. Atomically swap the new app into place
        SWAP_SUCCESS=0
        if rm -rf "$TARGET_APP" 2>/dev/null && /usr/bin/ditto "$STAGED_APP" "$TARGET_APP" 2>/dev/null; then
            SWAP_SUCCESS=1
        else
            osascript -e "do shell script \\"rm -rf '$TARGET_APP' && /usr/bin/ditto '$STAGED_APP' '$TARGET_APP'\\" with administrator privileges" 2>/dev/null
            if [ $? -eq 0 ]; then
                SWAP_SUCCESS=1
            fi
        fi

        # 3. Strip quarantine attribute if present
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

        # 4. Clean up temporary staging
        rm -rf "$WORK_DIR" 2>/dev/null || true

        # 5. Launch the updated application
        if [ $SWAP_SUCCESS -eq 1 ]; then
            /usr/bin/open "$TARGET_APP"
        fi
        """
        
        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw AutoUpdateError.scriptCreationFailed(error.localizedDescription)
        }
        
        let oldPID = ProcessInfo.processInfo.processIdentifier
        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        launchProcess.arguments = [
            "-c",
            "/usr/bin/nohup /bin/sh \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" >/dev/null 2>&1 &",
            "launcher",
            scriptURL.path,
            "\(oldPID)",
            stagedAppURL.path,
            targetAppPath,
            workDir.path
        ]
        let launchErrPipe = Pipe()
        launchProcess.standardError = launchErrPipe
        try launchProcess.run()
        launchProcess.waitUntilExit()
        
        if launchProcess.terminationStatus != 0 {
            let data = launchErrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit code \(launchProcess.terminationStatus)"
            throw AutoUpdateError.processLaunchFailed(msg)
        }
        
        await MainActor.run {
            NSApplication.shared.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                exit(0)
            }
        }
    }
    
    // MARK: - Version Comparison
    
    /// Compares two semantic version strings (e.g. "0.2.3" vs "0.2.2").
    public func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let v1Components = v1.split(separator: ".").compactMap { Int($0.filter { $0.isNumber }) }
        let v2Components = v2.split(separator: ".").compactMap { Int($0.filter { $0.isNumber }) }
        
        let maxCount = max(v1Components.count, v2Components.count)
        for i in 0..<maxCount {
            let num1 = i < v1Components.count ? v1Components[i] : 0
            let num2 = i < v2Components.count ? v2Components[i] : 0
            if num1 > num2 { return true }
            if num1 < num2 { return false }
        }
        return false
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateManager: URLSessionDownloadDelegate {
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0
        
        Task { @MainActor in
            self.state = .downloading(
                progress: progress,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        }
    }
    
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let tempStagingURL = FileManager.default.temporaryDirectory.appendingPathComponent("qcpie_download_\(UUID().uuidString).dmg")
        do {
            try FileManager.default.moveItem(at: location, to: tempStagingURL)
            Task { @MainActor in
                self.handleDownloadFinished(tempDMGURL: tempStagingURL)
            }
        } catch {
            Task { @MainActor in
                self.state = .failed("Failed to stage downloaded update: \(error.localizedDescription)")
            }
        }
    }
    
    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error as? URLError, error.code == .cancelled {
            return
        }
        if let error = error {
            Task { @MainActor in
                self.state = .failed("Download failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Auto Update Errors

private enum AutoUpdateError: LocalizedError {
    case mountFailed(String)
    case appNotFound
    case stagingFailed(String)
    case scriptCreationFailed(String)
    case processLaunchFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .mountFailed(let detail):
            return "Failed to mount installer disk image: \(detail)"
        case .appNotFound:
            return "Application bundle not found inside disk image."
        case .stagingFailed(let detail):
            return "Failed to extract application bundle: \(detail)"
        case .scriptCreationFailed(let detail):
            return "Failed to prepare installation script: \(detail)"
        case .processLaunchFailed(let detail):
            return "Failed to launch updater process: \(detail)"
        }
    }
}

// MARK: - GitHub API Data Models

private struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    let assets: [GitHubAsset]
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
}

private struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String
    let size: Int
    
    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }
}
