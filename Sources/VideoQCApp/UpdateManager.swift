import Foundation
import VideoQCLib
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
        case downloading
        case installing(status: String)
        case readyToInstall(fileURL: URL)
        /// Downloaded in the background: installs when QCpie quits, or now on Restart.
        case staged(version: String)
        case failed(String)
    }
    
    @Published public private(set) var state: UpdateState = .idle {
        didSet { if case .failed(let message) = state, state != oldValue { Log.update.error(message) } }
    }
    @Published public var showModal: Bool = false
    @Published public private(set) var latestVersion: String = ""
    @Published public private(set) var remoteWebURL: URL? = nil
    @Published public private(set) var remoteDMGURL: URL? = nil
    @Published public private(set) var hasUpdate: Bool = false
    @Published public private(set) var lastCheckDate: Date? = nil
    /// Download progress lives apart from `state`: `ContentView` observes this manager, so per-chunk updates here would
    /// redraw the whole window. Only the update card reads it (through `ObservingView`).
    public let download = UpdateDownloadProgress()
    
    // MARK: - Internal Download Handling
    
    private var downloadTask: URLSessionDownloadTask?
    private var isManualDownload: Bool = false
    /// Started by a background check: the update is prepared silently and installed when QCpie quits.
    private var isBackgroundDownload = false
    private var stagedUpdate: (app: URL, workDir: URL)?
    private var swapLaunched = false
    private var periodicCheck: Timer?
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Check for Updates
    
    /// Checks the GitHub API for the latest release.
    /// - Parameter userInitiated: If true, opens the modal immediately to show status (checking, up-to-date, or update available). If false, runs silently in background.
    public func checkForUpdates(userInitiated: Bool = false) {
        // An update already downloading or installing: show it. A check replaced its state, and the finished download
        // then found the state it expects gone.
        switch state {
        case .downloading, .installing, .readyToInstall, .staged:
            if userInitiated { showModal = true }
            return
        default: break
        }
        if userInitiated {
            showModal = true
            state = .checking
        }
        
        // QCpie stays open for days: checked again every 4 hours.
        if periodicCheck == nil {
            periodicCheck = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in
                Task { @MainActor in UpdateManager.shared.checkForUpdates(userInitiated: false) }
            }
        }
        Task {
            await performCheck(userInitiated: userInitiated)
        }
    }
    
    private func performCheck(userInitiated: Bool) async {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(AppConfig.githubRepoOwner)/\(AppConfig.githubRepoName)/releases/latest") else {
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
            
            // QCpie.dmg by name: releases also carry the Premiere plugin's files, and GitHub lists assets alphabetically.
            if let name = Self.appDiskImage(among: release.assets.map(\.name)),
               let dmgAsset = release.assets.first(where: { $0.name == name }),
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
                } else if self.remoteDMGURL != nil {
                    self.isManualDownload = false
                    self.isBackgroundDownload = true
                    self.startDownload()
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
    
    /// The release asset that is the app: `QCpie.dmg`, else a disk image that isn't the Premiere plugin's.
    nonisolated static func appDiskImage(among names: [String]) -> String? {
        names.first { $0 == "QCpie.dmg" } ?? names.first { $0.lowercased().hasSuffix(".dmg") && !$0.hasPrefix("LineFinder") }
    }

    // MARK: - Start Download & Auto-Update
    
    /// Begins 1-click automatic update: downloads DMG, extracts in background, replaces app in /Applications, and relaunches.
    public func startOneClickUpdate() {
        isBackgroundDownload = false
        if stagedUpdate != nil { restartIntoStagedUpdate(); return }
        if case .downloading = state, !isManualDownload { return }   // the background download installs when it's done
        isManualDownload = false
        startDownload()
    }
    
    /// Manual DMG download: downloads DMG to ~/Downloads and opens it in Finder for manual handling.
    public func downloadDMGManually() {
        isManualDownload = true
        isBackgroundDownload = false
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
        
        download.reset()
        state = .downloading
        downloadTask?.cancel()
        downloadTask = urlSession.downloadTask(with: dmgURL)
        downloadTask?.resume()
    }
    
    /// Cancels active download
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isManualDownload = false
        isBackgroundDownload = false
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
        let background = isBackgroundDownload
        Task.detached(priority: background ? .background : .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let localDMG = workDir.appendingPathComponent("update.dmg")
                try FileManager.default.moveItem(at: dmgURL, to: localDMG)
                let staged = try Self.stageUpdate(dmgURL: localDMG, workDir: workDir, onStatusUpdate: { status in
                    guard !background else { return }
                    Task { @MainActor in UpdateManager.shared.state = .installing(status: status) }
                })
                await MainActor.run {
                    let manager = UpdateManager.shared
                    manager.stagedUpdate = (staged, workDir)
                    // "Update and Restart" pressed while the background download ran: install now.
                    if manager.isBackgroundDownload {
                        manager.state = .staged(version: manager.latestVersion)
                        Log.update.notice("QCpie \(manager.latestVersion) is ready: it installs when QCpie quits")
                    } else {
                        manager.restartIntoStagedUpdate()
                    }
                }
            } catch {
                await MainActor.run {
                    UpdateManager.shared.state = .failed("Installation failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: workDir)
                try? FileManager.default.removeItem(at: dmgURL)
            }
        }
    }

    /// Quits and opens the new version now (the quit questions first: staying keeps the update for the next quit).
    public func restartIntoStagedUpdate() {
        guard let staged = stagedUpdate else { startOneClickUpdate(); return }
        state = .installing(status: "Restarting QCpie...")
        Task {
            guard let stopTransfers = AppDelegate.askToQuit() else {
                state = .staged(version: latestVersion)
                return
            }
            if stopTransfers {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    AppDelegate.stopTransfers { done.resume() }
                }
            }
            do {
                try Self.launchSwap(stagedApp: staged.app, workDir: staged.workDir, relaunch: true)
            } catch {
                state = .failed("Installation failed: \(error.localizedDescription)")
                return
            }
            swapLaunched = true
            AppDelegate.quitConfirmed = true
            NSApplication.shared.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
        }
    }

    /// Called as QCpie quits: a downloaded update replaces the app once it has exited (not opened again).
    public func installStagedUpdateOnQuit() {
        guard let staged = stagedUpdate, !swapLaunched else { return }
        swapLaunched = true
        do {
            try Self.launchSwap(stagedApp: staged.app, workDir: staged.workDir, relaunch: false)
            Log.update.notice("Installing QCpie \(latestVersion) as QCpie quits")
        } catch {
            Log.update.error("Couldn't install the update on quit: \(error.localizedDescription)")
        }
    }

    /// Mounts the disk image, copies QCpie out of it and writes the swap scripts: the app to install.
    nonisolated private static func stageUpdate(
        dmgURL: URL,
        workDir: URL,
        onStatusUpdate: @escaping @Sendable (String) -> Void
    ) throws -> URL {
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
        
        // Only QCpie replaces QCpie: a wrong asset (another app's disk image) must not overwrite it.
        guard Bundle(url: sourceAppURL)?.bundleIdentifier == "com.studio.qcpie" else {
            unmountDMG()
            throw AutoUpdateError.appNotFound
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
        
        let scriptContent = """
        #!/bin/sh
        OLD_PID="$1"
        STAGED_APP="$2"
        TARGET_APP="$3"
        WORK_DIR="$4"
        RELAUNCH="$5"

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

        # 2. Swap the new app into place (swap.sh keeps the old app until the new one is in place); with admin rights
        #    when /Applications isn't writable. A failure or a cancelled prompt leaves the old QCpie, relaunched below.
        if ! /bin/sh "$WORK_DIR/swap.sh" "$STAGED_APP" "$TARGET_APP" 2>/dev/null; then
            osascript -e 'on run argv' \
                -e 'do shell script "/bin/sh " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) with administrator privileges' \
                -e 'end run' "$WORK_DIR/swap.sh" "$STAGED_APP" "$TARGET_APP" >/dev/null 2>&1 || true
        fi

        # 3. Strip quarantine attribute if present
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

        # 4. Clean up temporary staging
        rm -rf "$WORK_DIR" 2>/dev/null || true

        # 5. Launch the updated application (or the untouched old one when the swap failed), unless QCpie was quit
        [ "$RELAUNCH" = "1" ] && /usr/bin/open "$TARGET_APP"
        exit 0
        """
        
        // The new copy is complete beside the old app before the old one moves, and the old one is deleted only once the
        // new one is in place (put back if that fails): an update never leaves /Applications without QCpie.
        let swapContent = """
        #!/bin/sh
        STAGED="$1"
        TARGET="$2"
        NEW="$TARGET.new"
        OLD="$TARGET.old"
        rm -rf "$NEW" "$OLD"
        /usr/bin/ditto "$STAGED" "$NEW" || { rm -rf "$NEW"; exit 1; }
        if [ -e "$TARGET" ]; then
            mv "$TARGET" "$OLD" || { rm -rf "$NEW"; exit 1; }
        fi
        if ! mv "$NEW" "$TARGET"; then
            [ -e "$OLD" ] && mv "$OLD" "$TARGET"
            rm -rf "$NEW"
            exit 1
        fi
        rm -rf "$OLD"
        exit 0
        """

        do {
            try swapContent.write(to: workDir.appendingPathComponent("swap.sh"), atomically: true, encoding: .utf8)
            try scriptContent.write(to: workDir.appendingPathComponent("relaunch.sh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workDir.appendingPathComponent("relaunch.sh").path)
        } catch {
            throw AutoUpdateError.scriptCreationFailed(error.localizedDescription)
        }
        return stagedAppURL
    }

    /// Starts the script that waits for QCpie to exit, swaps the new app in and, with `relaunch`, opens it.
    nonisolated private static func launchSwap(stagedApp: URL, workDir: URL, relaunch: Bool) throws {
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
        let launchProcess = Process()
        launchProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        launchProcess.arguments = [
            "-c",
            "/usr/bin/nohup /bin/sh \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" >/dev/null 2>&1 &",
            "launcher",
            workDir.appendingPathComponent("relaunch.sh").path,
            "\(ProcessInfo.processInfo.processIdentifier)",
            stagedApp.path,
            targetAppPath,
            workDir.path,
            relaunch ? "1" : "0"
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
    }
    
    // MARK: - Version Comparison
    
    /// Compares two semantic version strings (e.g. "0.2.3" vs "0.2.2").
    public func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        // Each part's leading digits: "0-beta1" is 0, not 01 (all its digits read 0.20.0-beta1 as 0.20.1).
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0 } }
        let v1Components = parts(v1), v2Components = parts(v2)
        
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
            // A progress report delivered after the download finished must not undo "installing" / "ready".
            guard case .downloading = self.state else { return }
            self.download.update(fraction: progress, written: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }
    
    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // An error page (GitHub down, asset removed) is downloaded like the file: it failed to mount as "the update".
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status != 200 {
            Task { @MainActor in self.state = .failed("Download failed: GitHub returned HTTP status \(status).") }
            return
        }
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
            return "The download doesn't contain QCpie. Download it from GitHub instead."
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

/// Bytes and fraction of the update download, published at most every 1 % or 0.2 s.
@MainActor
public final class UpdateDownloadProgress: ObservableObject {
    @Published public private(set) var fraction: Double = 0
    @Published public private(set) var written: Int64 = 0
    @Published public private(set) var total: Int64 = 0
    private var lastPublished: CFAbsoluteTime = 0

    func reset() {
        fraction = 0; written = 0; total = 0; lastPublished = 0
    }

    func update(fraction newFraction: Double, written newWritten: Int64, total newTotal: Int64) {
        let now = CFAbsoluteTimeGetCurrent()
        guard newFraction >= 1 || newFraction - fraction >= 0.01 || now - lastPublished >= 0.2 else { return }
        lastPublished = now
        fraction = newFraction; written = newWritten; total = newTotal
    }
}
