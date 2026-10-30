import Foundation
import Testing
@testable import QCpie

@Suite("Pre-upload checks")
struct UploadPreflightTests {
    private func row(_ name: String, size: Int64 = 100, topLevel: Bool = true, files: [URL]? = nil) -> UploadPreflight.Row {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return .init(path: url.path, name: name, files: files ?? [url], sizes: [size], topLevel: topLevel)
    }

    @Test("Same name, different size is flagged; same name and size is the same file (skipped anyway)")
    func duplicates() {
        let existing = ["A.mov": Set<Int64>([100]), "B.mov": [200]]
        let rows = [row("A.mov", size: 100), row("B.mov", size: 300), row("C.mov"), row("B.mov", size: 300, topLevel: false)]
        #expect(UploadPreflight.duplicates(rows, existing: existing) == ["/tmp/B.mov"])
    }

    @Test("Odd files: no extension, hidden, partial, not media or a deliverable")
    func odd() {
        for name in ["README", ".DS_Store", "Edit.mov.part", "Export.mov.crdownload", "~$Notes.docx", "render.exe"] {
            #expect(UploadPreflight.isOdd(name), "\(name)")
        }
        for name in ["Edit 7A.mov", "Still.EXR", "Mix.wav", "Subs.srt", "Script.pdf", "Conform.xml"] {
            #expect(!UploadPreflight.isOdd(name), "\(name)")
        }
    }

    @Test("A file that grows during the check is still being written; a quiet one isn't")
    func writing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let quiet = folder.appendingPathComponent("Quiet.mov"), busy = folder.appendingPathComponent("Busy.mov")
        try Data(count: 10).write(to: quiet)
        try Data(count: 10).write(to: busy)
        let rows = [row("Quiet.mov", files: [quiet]), row("Busy.mov", files: [busy])]
        let grower = Task {
            try await Task.sleep(for: .milliseconds(100))
            let handle = try FileHandle(forWritingTo: busy)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(count: 1000))
            try handle.close()
        }
        let writing = await UploadPreflight.stillWriting(rows, wait: .milliseconds(400))
        try await grower.value
        #expect(writing == ["/tmp/Busy.mov"])
    }

    @Test("The confirmation names the files and the folder")
    func summary() {
        let report = UploadPreflight.Report(duplicates: ["/a"], writing: ["/b", "/c"], odd: [])
        let text = UploadPreflight.summary(report, names: ["/a": "A.mov", "/b": "B.mov", "/c": "C.mov"], folder: "“Selects”")
        #expect(text.title == "3 files need a look before uploading")
        #expect(text.detail.contains("1 file named like a different file already in “Selects”: Frame.io will keep both (A.mov)."))
        #expect(text.detail.contains("2 files still being written (B.mov, C.mov)."))
    }
}
