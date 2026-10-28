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
    }

    @Test("Share, old Frame.io and non-Frame.io links are refused with a reason")
    func refused() {
        #expect(throws: FrameIOLink.Failure.shareLink) { try FrameIOLink.parse("https://next.frame.io/share/S1/view/A1") }
        #expect(throws: FrameIOLink.Failure.legacyLink) { try FrameIOLink.parse("https://app.frame.io/project/P1") }
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
}
