import Foundation
import Testing
@testable import QCpie

/// Keep subfolders with dragged items: the dragged folder and what's below it, never the folders above.
@Suite struct UploadPlacementTests {
    let file = URL(fileURLWithPath: "/Volumes/Work/Campaign/BATCH 1/E01/Sub/clip.mov")

    @Test func draggedFolderAndBelow() {
        #expect(UploadQueue.placement(file, roots: ["/Volumes/Work/Campaign/BATCH 1"]) == ["BATCH 1", "E01", "Sub"])
        #expect(UploadQueue.placement(file, roots: ["/Volumes/Work/Campaign/BATCH 1/E01/Sub"]) == ["Sub"])
        // A trailing slash and a nested root: the outermost dragged folder counts.
        #expect(UploadQueue.placement(file, roots: ["/Volumes/Work/Campaign/BATCH 1/", "/Volumes/Work/Campaign/BATCH 1/E01"]) == ["BATCH 1", "E01", "Sub"])
    }

    @Test func fileAloneOrOutsideGoesToTheTop() {
        #expect(UploadQueue.placement(file, roots: [file.path]).isEmpty)
        #expect(UploadQueue.placement(file, roots: ["/Volumes/Work/Other"]).isEmpty)
        // A sibling whose name starts the same isn't a parent.
        #expect(UploadQueue.placement(file, roots: ["/Volumes/Work/Campaign/BATCH"]).isEmpty)
    }
}
