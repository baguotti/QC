import Foundation
import AppKit

@MainActor
public final class FileOpenManager: ObservableObject {
    public static let shared = FileOpenManager()
    
    @Published public var pendingURLs: [URL] = []
    public var isInitialLaunchBatch: Bool = false
    public var isAppAlreadyRunning: Bool = false
    
    private var queuedURLs: [URL] = []
    private var queuedIsInitial: Bool = false
    private var debounceTask: Task<Void, Never>?
    
    private init() {}
    
    public func handleOpenedFiles(_ urls: [URL], isInitialLaunch: Bool? = nil) {
        guard !urls.isEmpty else { return }
        
        let initial = isInitialLaunch ?? (!isAppAlreadyRunning)
        if initial {
            queuedIsInitial = true
        }
        
        var existingPaths = Set(queuedURLs.map { $0.standardizedFileURL.path })
        for url in urls {
            let path = url.standardizedFileURL.path
            if !existingPaths.contains(path) {
                existingPaths.insert(path)
                queuedURLs.append(url)
            }
        }
        
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let batch = self.queuedURLs
            let wasInitial = self.queuedIsInitial
            self.queuedURLs.removeAll()
            self.queuedIsInitial = false
            if !batch.isEmpty {
                self.isInitialLaunchBatch = wasInitial
                self.pendingURLs = batch
            }
        }
    }
}
