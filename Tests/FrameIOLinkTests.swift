import Foundation
import Testing
@testable import QCpie

@Suite("Pasted Frame.io links")
struct FrameIOLinkTests {
    @Test("Project, folder and file links parse; query strings are ignored")
    func parse() throws {
        #expect(try FrameIOLink.parse("https://next.frame.io/project/P1") == FrameIOLink(project: "P1"))
        #expect(try FrameIOLink.parse("https://next.frame.io/project/P1/F1?view=grid") == FrameIOLink(project: "P1", folder: "F1"))
        #expect(try FrameIOLink.parse("  https://next.frame.io/project/P1/view/A1?a=b#c\n") == FrameIOLink(project: "P1", asset: "A1"))
        // The current app is served on app.frame.io too, with the same paths (only other app.frame.io paths are old).
        #expect(try FrameIOLink.parse("https://app.frame.io/project/P1/F1") == FrameIOLink(project: "P1", folder: "F1"))
    }

    @Test("Share, old Frame.io and non-Frame.io links are refused with a reason")
    func refused() {
        #expect(throws: FrameIOLink.Failure.shareLink) { try FrameIOLink.parse("https://next.frame.io/share/S1/view/A1") }
        #expect(throws: FrameIOLink.Failure.legacyLink) { try FrameIOLink.parse("https://app.frame.io/player/A1") }
        #expect(throws: FrameIOLink.Failure.notALink) { try FrameIOLink.parse("https://example.com/project/P1") }
        #expect(throws: FrameIOLink.Failure.notALink) { try FrameIOLink.parse("/Volumes/Server/clip.mov") }
    }

    @Test("Only Frame.io links trigger the paste")
    func detection() {
        #expect(FrameIOLink.looksLikeLink("https://next.frame.io/project/P1"))
        #expect(FrameIOLink.looksLikeLink("https://f.io/AbCd"))
        #expect(!FrameIOLink.looksLikeLink("CK_HOME26"))
        #expect(!FrameIOLink.looksLikeLink("https://notframe.io.example.com/x"))
    }

    // Plan cells hold whatever someone typed: only Frame.io web pages open from them.
    @Test func onlyFrameIOPagesOpen() {
        #expect(FrameIOLink.webURL(" https://next.frame.io/project/p/view/f ") != nil)
        #expect(FrameIOLink.webURL("https://f.io/abc") != nil)
        #expect(FrameIOLink.webURL("file:///Applications/Calculator.app") == nil)
        #expect(FrameIOLink.webURL("http://next.frame.io/project/p") == nil)
        #expect(FrameIOLink.webURL("https://frame.io.evil.com/x") == nil)
        #expect(FrameIOLink.webURL("zoommtg://join") == nil)
        #expect(FrameIOLink.webURL("") == nil)
    }
}
