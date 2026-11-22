import Foundation
import SwiftUI
import Testing
@testable import QCpie

// Notes come from collaborators (sync, Frame.io comments): their links mustn't hand anything to other apps.
@Suite("Note links") struct NoteLinkTests {
    private func links(_ text: String) -> [DetectedNoteLink] {
        NoteLinkParser.buildAttributedString(text: text, isResolved: false, accentColor: .blue, textMuted: .gray, textMain: .black).links
    }

    @Test func webAndMailLinksOpen() {
        #expect(links("see https://example.com/a").map(\.label) == ["example.com"])
        #expect(links("write to mailto:x@y.z").count == 1)
    }

    @Test func otherSchemesStayText() {
        #expect(links("vnc://10.0.0.1 or zoommtg://join?x=1 or ssh://host").isEmpty)
    }

    @Test func pathsAreRevealed() {
        #expect(links("look at /Volumes/Media/Cut 1.mov").contains { if case .filePath = $0 { return true }; return false })
    }
}
