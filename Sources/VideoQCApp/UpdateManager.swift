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
    
    // MARK: - Start Download
    
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
    
    /// Quits QCpie so that user can replace the app in /Applications without "File In Use" errors.
    public func quitAppToReplace() {
        NSApplication.shared.terminate(nil)
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
        // Prepare target destination in ~/Downloads
        let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        
        let destinationURL = downloadsFolder.appendingPathComponent("QCpie-Update.dmg")
        
        do {
            // Remove previous file if exists
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            
            Task { @MainActor in
                self.state = .readyToInstall(fileURL: destinationURL)
                // Automatically open and mount the downloaded DMG
                NSWorkspace.shared.open(destinationURL)
            }
        } catch {
            Task { @MainActor in
                self.state = .failed("Failed to save downloaded update: \(error.localizedDescription)")
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
