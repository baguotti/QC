import Foundation
import CoreGraphics

/// Launches a binary N times and reports the time until its main window is on screen.
/// Usage: timer <binary> <runs> <cwd>
let args = CommandLine.arguments
let runs = Int(args[2]) ?? 6
var times: [Double] = []
for _ in 0..<runs {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[1])
    p.currentDirectoryURL = URL(fileURLWithPath: args[3])
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let start = Date()
    try! p.run()
    var shown = Double.nan
    while Date().timeIntervalSince(start) < 10 {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        if windows.contains(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == p.processIdentifier
                && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 200
        }) {
            shown = Date().timeIntervalSince(start) * 1000
            break
        }
        usleep(2000)
    }
    times.append(shown)
    usleep(1_000_000)
    p.terminate()
    p.waitUntilExit()
    usleep(400_000)
}
// The first launch is cold (disk caches); the median of the rest is the warm figure.
let warm = times.dropFirst().sorted()
print(String(format: "%.0f", warm[warm.count / 2]), times.map { String(format: "%.0f", $0) }.joined(separator: " "))
