import Foundation
import Testing
@testable import VideoQCLib

// QCpie keeps its URLs; their resource values are cached per object. Tags must be read fresh, or a tag added in Finder
// after QCpie looked at the file is erased when QCpie sets a colour tag.
@Suite("Finder tags") struct FinderTagTests {
    @Test func finderTagAddedLaterIsKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        defer { try? FileManager.default.removeItem(at: url) }
        _ = FinderTagManager.getTag(for: url)             // QCpie reads the file (caches its tags)
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(["Approved"] as NSArray, forKey: .tagNamesKey)   // Finder adds a tag
        FinderTagManager.setTag(.red, for: url)
        let tags = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        #expect(tags.contains("Approved") && tags.contains("Red"))
    }
}
