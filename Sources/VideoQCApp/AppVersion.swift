import Foundation

/// Application Version and Git Repository Metadata
public struct AppVersionInfo {
    public static let version = "0.1.0"
    public static let gitCommit = "066bace"
    public static let repoURLString = "https://github.com/baguotti/QC"
    
    public static var commitURL: URL {
        URL(string: "\(repoURLString)/commit/\(gitCommit)") ?? URL(string: repoURLString)!
    }
}
