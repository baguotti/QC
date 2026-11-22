import AppKit
import UniformTypeIdentifiers
import VideoQCLib

/// A transfer run as a file to keep or hand on: a CSV report (every file, how it was checked, its fingerprints), and
/// for downloads a Media Hash List (MHL 1.1, the hash list post-production tools such as Silverstack, ShotPut and
/// Hedge read) with each file's MD5 as read back from disk.
enum TransferReport {
    static func csv(_ run: UploadLogRun) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [["File", "Result", "Verification", "How", "Size (bytes)", "Started", "Finished", "Seconds", "MD5",
                      "Frame.io fingerprint (S3 ETag)", "Destination", "Local path", "Message"].joined(separator: ",")]
        for entry in run.entries {
            let result: String = switch entry.outcome {
            case .uploaded: run.kind == .download ? "Downloaded" : "Uploaded"
            case .skipped: "Already on Frame.io"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
            let check = entry.verification
            let how = [check?.method, check?.totalFiles.map { "\(check?.verifiedFiles ?? 0) of \($0) frames verified" }]
                .compactMap { $0 }.joined(separator: "; ")
            lines.append([entry.name, result, check?.label ?? "", how, String(entry.bytes), iso.string(from: entry.started),
                          iso.string(from: entry.finished), String(format: "%.1f", entry.duration), check?.md5 ?? "",
                          check?.etag ?? "", entry.destination, entry.localPath ?? "", entry.message ?? ""].map(QCUtilities.escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Downloaded files with an MD5, relative to the run's folder (MHL paths are relative to the list's own folder).
    static func hashedFiles(_ run: UploadLogRun) -> [(entry: UploadLogEntry, path: String, md5: String)] {
        let root = (run.destination as NSString).expandingTildeInPath
        return run.entries.compactMap { entry in
            guard run.kind == .download, entry.outcome == .uploaded, let md5 = entry.verification?.md5,
                  let local = entry.localPath, local.hasPrefix(root + "/") else { return nil }
            return (entry, String(local.dropFirst(root.count + 1)), md5)
        }
    }

    static func mhl(_ run: UploadLogRun) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime]
        let files = hashedFiles(run)
        // Files whose fingerprint couldn't be reproduced have an MD5 too: the log said every one was compared.
        let matched = files.filter { $0.entry.verification?.level == .verified }.count
        let log = "Downloaded from Frame.io; each MD5 read back from disk after download. "
            + (matched == files.count ? "Each matched Frame.io's stored fingerprint."
                                      : "\(matched) of \(files.count) matched Frame.io's stored fingerprint; the others were checked by size.")
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="1.1">
          <creatorinfo>
            <name>\(escape(NSFullUserName()))</name>
            <username>\(escape(NSUserName()))</username>
            <hostname>\(escape(ProcessInfo.processInfo.hostName))</hostname>
            <tool>QCpie \(AppVersionInfo.version)</tool>
            <startdate>\(utc.string(from: run.started))</startdate>
            <finishdate>\(utc.string(from: run.finished ?? Date()))</finishdate>
            <log>\(escape(log))</log>
          </creatorinfo>

        """
        for file in files {
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.entry.localPath ?? "")[.modificationDate] as? Date) ?? file.entry.finished
            xml += """
              <hash>
                <file>\(escape(file.path))</file>
                <size>\(file.entry.bytes)</size>
                <lastmodificationdate>\(utc.string(from: modified))</lastmodificationdate>
                <md5>\(file.md5)</md5>
                <hashdate>\(utc.string(from: file.entry.finished))</hashdate>
              </hash>

            """
        }
        return xml + "</hashlist>\n"
    }

    @MainActor
    static func exportCSV(_ run: UploadLogRun) {
        save(name: "\(fileStem(run)).csv", type: .commaSeparatedText,
             folder: run.kind == .download ? URL(fileURLWithPath: (run.destination as NSString).expandingTildeInPath) : nil) { csv(run) }
    }

    @MainActor
    static func exportMHL(_ run: UploadLogRun) {
        guard run.entries.contains(where: { $0.verification?.md5 != nil && $0.localPath != nil }) else {
            NSSound.beep()   // nothing downloaded with an MD5 (all failed, or logged before verification)
            return
        }
        // Saved in the run's folder by default: the list's paths are relative to it.
        save(name: "\(fileStem(run)).mhl", type: UTType(filenameExtension: "mhl") ?? .xml,
             folder: URL(fileURLWithPath: (run.destination as NSString).expandingTildeInPath)) { mhl(run) }
    }

    private static func fileStem(_ run: UploadLogRun) -> String {
        let stamp = run.started.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + "_"
            + run.started.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: "")
        return "QCpie \(run.kind == .download ? "download" : "upload") \(stamp)"
    }

    /// Asks where to save, then builds and writes the text off the main thread (the hash list reads each file's date,
    /// which can be slow on a network drive).
    @MainActor
    private static func save(name: String, type: UTType, folder: URL?, text: @escaping @Sendable () -> String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        if let folder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            do {
                try Data(text().utf8).write(to: target, options: .atomic)
            } catch {
                Log.upload.error("Couldn't save the transfer report to \(target.path): \(error.localizedDescription)")
                await MainActor.run { NSSound.beep() }
            }
        }
    }
}
