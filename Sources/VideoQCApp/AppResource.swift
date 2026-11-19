import Foundation

/// A bundled resource, or (running the bare `.build/debug/QCpie` from the repo root) the copy in `Resources/`.
enum AppResource {
    static func url(_ name: String, _ ext: String, subdirectory: String? = nil) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) { return url }
        let relative = [subdirectory, "\(name).\(ext)"].compactMap { $0 }.joined(separator: "/")
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/\(relative)")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }
}
