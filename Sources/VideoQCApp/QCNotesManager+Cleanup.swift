import Foundation
import VideoQCLib

/// Finding and removing notes sidecars whose clip is gone (deleted, or renamed: renaming orphans its notes).
extension QCNotesManager {
    /// Sidecars under `folder` (hidden `.<name>.qcnotes`, or the older visible `<name>.qcnotes`) whose `<name>` no longer
    /// sits next to them. Only files that decode as notes for exactly that name count, so exports (`<clip> - QC Notes.qcnotes`)
    /// and unreadable files are never touched.
    nonisolated static func orphanedSidecars(in folder: URL, isCancelled: () -> Bool = { false }) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [],
                                         options: [.skipsPackageDescendants]) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var orphans: [URL] = []
        for case let url as URL in walker {
            if isCancelled() { return [] }
            guard let mediaName = mediaName(ofSidecar: url.lastPathComponent) else { continue }
            let media = url.deletingLastPathComponent().appendingPathComponent(mediaName)
            guard !fm.fileExists(atPath: media.path),
                  let data = try? Data(contentsOf: url),
                  let doc = try? decoder.decode(QCNotesDocument.self, from: data),
                  doc.mediaFileName == mediaName else { continue }
            orphans.append(url)
        }
        return orphans
    }

    /// `Clip.mov` for `.Clip.mov.qcnotes` or `Clip.mov.qcnotes`; nil for anything else, AppleDouble `._` companions included.
    nonisolated static func mediaName(ofSidecar fileName: String) -> String? {
        guard !fileName.hasPrefix("._"), fileName.hasSuffix(".qcnotes") else { return nil }
        let name = String(fileName.dropFirst(fileName.hasPrefix(".") ? 1 : 0).dropLast(".qcnotes".count))
        return name.isEmpty || name.hasPrefix(".") ? nil : name
    }

    /// Moves each sidecar (and its `._` companion, written by SMB servers) to the Trash, or deletes it where the volume
    /// has none (network shares). Returns how many sidecars were removed.
    nonisolated static func removeSidecars(_ urls: [URL]) -> Int {
        let fm = FileManager.default
        var removed = 0
        for url in urls {
            let companion = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
            for file in [url, companion] where fm.fileExists(atPath: file.path) {
                if (try? fm.trashItem(at: file, resultingItemURL: nil)) != nil { continue }
                Log.notes.attempt("Deleting orphaned notes \(file.lastPathComponent)") { try fm.removeItem(at: file) }
            }
            if !fm.fileExists(atPath: url.path) { removed += 1 }
        }
        Log.notes.notice("Removed \(removed) of \(urls.count) orphaned notes files")
        return removed
    }
}
