import Foundation
import AppKit

@MainActor
public final class FileOpenManager: ObservableObject {
    public static let shared = FileOpenManager()
    
    @Published public var pendingURLs: [URL] = []
    
    private var queuedURLs: [URL] = []
    private var debounceTask: Task<Void, Never>?
    
    private init() {}
    
    public func handleOpenedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        
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
            self.queuedURLs.removeAll()
            if !batch.isEmpty {
                self.pendingURLs = batch
            }
        }
    }
}
