import Foundation
import Testing
@testable import QCpie

/// Every UserDefaults key in the sources is classified in `SettingsTransfer`: a setting (exported and reset), kept
/// (exported only) or state. A new key fails here until it is put in one of the lists.
@MainActor @Suite struct SettingsKeysTests {
    @Test func everyDefaultsKeyIsClassified() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"(?:forKey: |@AppStorage\(|Key = )"([A-Za-z0-9_.]+)""#)
        var keys = Set<String>()
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            where line.contains("UserDefaults") || line.contains("@AppStorage") || line.contains("Key = \"") {
                let text = String(line)
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
                }
            }
        }
        #expect(keys.count > 80)   // the scan found the sources
        let unclassified = keys.filter {
            !SettingsTransfer.isSetting($0) && !SettingsTransfer.favouriteKeys.contains($0) && !SettingsTransfer.stateKeys.contains($0)
        }
        #expect(unclassified.isEmpty, "Add to SettingsTransfer.extraKeys, favouriteKeys or stateKeys: \(unclassified.sorted())")
        // One list each.
        #expect(SettingsTransfer.stateKeys.filter { SettingsTransfer.isSetting($0) || SettingsTransfer.favouriteKeys.contains($0) }.isEmpty)
    }
}
