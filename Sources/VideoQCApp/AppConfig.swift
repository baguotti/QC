import Foundation

/// Centralized Application Configuration and Constants
public struct AppConfig {
    /// Public Web3Forms API Access Key for automated in-app feedback delivery
    public static let web3FormsAccessKey = "edc9392e-0f56-4fef-b67a-c3e277924813"
    
    /// Target support email for feedback submissions
    public static let supportEmail = "fusetti.riccardo@gmail.com"
    
    /// GitHub Repository Owner
    public static let githubRepoOwner = "baguotti"
    
    /// GitHub Repository Name
    public static let githubRepoName = "QC"
    
    /// Base GitHub API releases URL
    public static var githubReleasesAPIURL: URL? {
        URL(string: "https://api.github.com/repos/\(githubRepoOwner)/\(githubRepoName)/releases/latest")
    }
    
    /// Web URL for releases
    public static var githubReleasesWebURL: URL {
        URL(string: "https://github.com/\(githubRepoOwner)/\(githubRepoName)/releases") ?? URL(fileURLWithPath: "/")
    }
}
