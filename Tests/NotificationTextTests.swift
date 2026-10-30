import Testing
@testable import QCpie

@Suite("Notification wording")
struct NotificationTextTests {
    @Test("Transfers say how many went, and what didn't")
    func transfers() {
        let clean = NotificationText.upload(uploaded: 1, skipped: 0, failed: 0, destination: "KL › Selects")
        #expect(clean == .init(title: "Upload finished", subtitle: "KL › Selects", body: "1 file uploaded"))
        let mixed = NotificationText.upload(uploaded: 24, skipped: 1, failed: 2, destination: "KL")
        #expect(mixed.title == "Upload finished with errors")
        #expect(mixed.body == "24 files uploaded · 1 already there · 2 failed")
        #expect(NotificationText.download(downloaded: 3, failed: 0, destination: "~/Downloads").body == "3 files downloaded")
    }

    @Test("Scans count flagged clips")
    func scans() {
        #expect(NotificationText.scan(check: "Line Check", flagged: 0, total: 26)
                == .init(title: "Line Check finished", subtitle: "26 clips", body: "No issues found"))
        #expect(NotificationText.scan(check: "Full Check", flagged: 3, total: 26).body == "3 of 26 clips flagged")
    }

    @Test("Comments: one is quoted, several are counted, a mention leads")
    func comments() {
        let ana = NotificationText.Remark(author: "Ana", text: "Logo is soft\nat the end")
        let tom = NotificationText.Remark(author: "Tom", text: "@ric can you check the grade?")
        #expect(NotificationText.comments(clip: "Edit 7A.mov", comments: [ana], replies: [], me: "Ric")
                == .init(title: "New comment from Ana", subtitle: "Edit 7A.mov", body: "Logo is soft at the end"))
        #expect(NotificationText.comments(clip: "c", comments: [ana, ana], replies: [], me: nil)?.title == "2 new comments")
        #expect(NotificationText.comments(clip: "c", comments: [], replies: [ana], me: nil)?.title == "Ana replied")
        let mention = NotificationText.comments(clip: "c", comments: [ana], replies: [tom], me: "Ric")
        #expect(mention?.title == "Tom mentioned you")
        #expect(mention?.body == "Tom: @ric can you check the grade?")
        #expect(NotificationText.comments(clip: "c", comments: [], replies: [], me: "Ric") == nil)
    }

    @Test("Versions: one is named, several are counted")
    func versions() {
        #expect(NotificationText.versions([("Hero 7", "Hero 7_E2.1.mov")])
                == .init(title: "New version on Frame.io", subtitle: "Hero 7", body: "Hero 7_E2.1.mov"))
        let many = NotificationText.versions([("A", "a"), ("B", "b"), ("C", "c"), ("D", "d")])
        #expect(many?.title == "4 new versions on Frame.io")
        #expect(many?.body == "A, B, C and more")
        #expect(NotificationText.versions([]) == nil)
    }
}
