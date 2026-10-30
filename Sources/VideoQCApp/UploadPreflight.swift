import Foundation
import VideoQCLib

/// Checks run before an upload starts (`UploadQueue.start`). Each flags queue rows worth a second look:
/// - **Duplicate names**: a file named like one already in the target folder but a different size (same name *and*
///   size is the same file: the engine skips it as "already there"). Frame.io would keep both.
/// - **Still being written**: its size or modification time changed over a moment (an export in progress), or it has
///   a partial-download name (`.part`, `.crdownload`, …).
/// - **Odd files**: no extension, hidden or temporary, or neither media nor a usual deliverable sidecar.
/// Only rows uploaded straight into the target folder are checked for duplicates (with Keep Subfolders, rows inside
/// subfolders would need those folders listed too). Image sequences are checked for being written only.
enum UploadPreflight {
    struct Row: Sendable {
        let path: String
        let name: String
        let files: [URL]
        let sizes: [Int64]
        /// Goes straight into the target folder (not into a kept subfolder).
        let topLevel: Bool
    }

    struct Report: Equatable, Sendable {
        var duplicates: [String] = []
        var writing: [String] = []
        var odd: [String] = []
        var flagged: Set<String> { Set(duplicates + writing + odd) }
        var isEmpty: Bool { flagged.isEmpty }
    }

    /// Partial and temporary files left by browsers, transfer tools and exporters.
    static let partialExtensions: Set<String> = ["part", "partial", "crdownload", "download", "opdownload", "tmp", "temp",
                                                 "filepart", "!ut", "swp", "lock"]
    /// Not media, but usual next to it in a delivery.
    static let sidecarExtensions: Set<String> = ["pdf", "srt", "vtt", "scc", "stl", "ttml", "dfxp", "xml", "fcpxml", "edl",
                                                 "aaf", "omf", "ale", "csv", "txt", "rtf", "doc", "docx", "xls", "xlsx",
                                                 "cube", "zip", "json", "drp", "prproj"]

    static func isPartial(_ name: String) -> Bool {
        partialExtensions.contains((name as NSString).pathExtension.lowercased()) || name.hasPrefix("~$")
    }

    static func isOdd(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if name.hasPrefix(".") || ext.isEmpty || isPartial(name) { return true }
        return QCUtilities.mediaKind(of: URL(fileURLWithPath: name)) == nil && !sidecarExtensions.contains(ext)
    }

    /// Rows going straight into the folder whose name is already there with a different size. `existing`: name →
    /// sizes of the files in the target folder (a stack: its current version).
    static func duplicates(_ rows: [Row], existing: [String: Set<Int64>]) -> [String] {
        rows.filter { row in
            guard row.topLevel, row.files.count == 1, let sizes = existing[row.name] else { return false }
            return !sizes.contains(row.sizes.first ?? -1)
        }.map(\.path)
    }

    /// The target folder's files by name (stacks by their current version's name and size).
    static func existing(_ items: [FrameIO.Item]) -> [String: Set<Int64>] {
        var names: [String: Set<Int64>] = [:]
        for item in items where !item.isFolder {
            let name = item.isVersionStack ? (item.headVersion?.name ?? item.title) : item.title
            names[name, default: []].insert(item.displaySize ?? -1)
        }
        return names
    }

    /// Rows with a file whose size or modification time changes over `wait`, or with a partial-download name.
    static func stillWriting(_ rows: [Row], wait: Duration = .milliseconds(1500)) async -> [String] {
        func stamp(_ url: URL) -> (Int64, Date)? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return ((attributes[.size] as? NSNumber)?.int64Value ?? 0, attributes[.modificationDate] as? Date ?? .distantPast)
        }
        // A sequence's last frames are the ones still arriving.
        let watched = rows.map { row in (row, row.files.suffix(3).map { ($0, stamp($0)) }) }
        try? await Task.sleep(for: wait)
        return watched.filter { row, files in
            row.files.contains { isPartial($0.lastPathComponent) }
                || files.contains { url, before in
                    let after = stamp(url)
                    return before?.0 != after?.0 || before?.1 != after?.1
                }
        }.map(\.0.path)
    }

    static func odd(_ rows: [Row]) -> [String] {
        rows.filter { row in row.files.count == 1 && isOdd(row.name) }.map(\.path)
    }

    /// The confirmation: what was found and where, naming a few files of each kind.
    static func summary(_ report: Report, names: [String: String], folder: String) -> (title: String, detail: String) {
        func list(_ paths: [String]) -> String {
            let shown = paths.prefix(3).compactMap { names[$0] }.joined(separator: ", ")
            return paths.count > 3 ? "\(shown) and \(paths.count - 3) more" : shown
        }
        func count(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
        var lines: [String] = []
        if !report.duplicates.isEmpty {
            lines.append("\(count(report.duplicates.count)) named like a different file already in \(folder): Frame.io will keep both (\(list(report.duplicates))).")
        }
        if !report.writing.isEmpty {
            lines.append("\(count(report.writing.count)) still being written (\(list(report.writing))).")
        }
        if !report.odd.isEmpty {
            lines.append("\(count(report.odd.count)) not a media file or deliverable (\(list(report.odd))).")
        }
        let total = report.flagged.count
        return ("\(total == 1 ? "1 file needs" : "\(total) files need") a look before uploading", lines.joined(separator: "\n\n"))
    }
}
