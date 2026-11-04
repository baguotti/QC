import Testing
@testable import VideoQCLib

@Suite("Folder containment")
struct PathContainmentTests {
    @Test("A folder contains its own files, not a sibling whose name starts the same")
    func boundaries() {
        #expect(QCUtilities.isPath("/Jobs/Job1/a.mov", inside: "/Jobs/Job1"))
        #expect(QCUtilities.isPath("/Jobs/Job1", inside: "/Jobs/Job1"))
        #expect(QCUtilities.isPath("/Jobs/Job1/a.mov", inside: "/Jobs/Job1/"))
        #expect(!QCUtilities.isPath("/Jobs/Job10/a.mov", inside: "/Jobs/Job1"))
        #expect(QCUtilities.isPath("/Jobs/a.mov", inside: "/"))
    }
}
