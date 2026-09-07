import Foundation
import VideoQCLib

/// Manages loading, saving, and exporting timecoded review notes to lightweight sidecar files.
public actor QCNotesManager {
    public static let shared = QCNotesManager()
    
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()
    
    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
    
    /// Returns the primary hidden companion `.<filename>.<ext>.qcnotes` sidecar URL in the same directory.
    public nonisolated static func sidecarURL(for mediaURL: URL) -> URL {
        let dir = mediaURL.deletingLastPathComponent()
        let hiddenName = "." + mediaURL.lastPathComponent + ".qcnotes"
        return dir.appendingPathComponent(hiddenName)
    }
    
    /// Returns the visible fallback URL `<filename>.<ext>.qcnotes` for backwards-compatibility.
    public nonisolated static func visibleSidecarURL(for mediaURL: URL) -> URL {
        mediaURL.appendingPathExtension("qcnotes")
    }
    
    /// Loads notes from the companion sidecar file if present (checks hidden file first, falls back to visible).
    public func loadNotes(for mediaURL: URL) -> [QCFileNote] {
        let hiddenURL = QCNotesManager.sidecarURL(for: mediaURL)
        let visibleURL = QCNotesManager.visibleSidecarURL(for: mediaURL)
        
        let targetURL: URL?
        if FileManager.default.fileExists(atPath: hiddenURL.path) {
            targetURL = hiddenURL
        } else if FileManager.default.fileExists(atPath: visibleURL.path) {
            targetURL = visibleURL
        } else {
            return []
        }
        
        guard let url = targetURL else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let doc = try decoder.decode(QCNotesDocument.self, from: data)
            return doc.notes.sorted { $0.frameIndex < $1.frameIndex }
        } catch {
            return []
        }
    }
    
    /// Saves notes atomically to the hidden companion `.<filename>.<ext>.qcnotes` sidecar file.
    @discardableResult
    public func saveNotes(_ notes: [QCFileNote], for mediaURL: URL, fps: Double) -> Bool {
        let hiddenURL = QCNotesManager.sidecarURL(for: mediaURL)
        let visibleURL = QCNotesManager.visibleSidecarURL(for: mediaURL)
        let sortedNotes = notes.sorted { $0.frameIndex < $1.frameIndex }
        
        // If notes are completely empty, clean up both hidden and visible sidecar files
        if sortedNotes.isEmpty {
            if FileManager.default.fileExists(atPath: hiddenURL.path) {
                try? FileManager.default.removeItem(at: hiddenURL)
            }
            if FileManager.default.fileExists(atPath: visibleURL.path) {
                try? FileManager.default.removeItem(at: visibleURL)
            }
            return true
        }
        
        let doc = QCNotesDocument(
            version: 1,
            mediaFileName: mediaURL.lastPathComponent,
            fps: fps > 0 ? fps : 25.0,
            lastModified: Date(),
            notes: sortedNotes
        )
        
        do {
            let data = try encoder.encode(doc)
            try data.write(to: hiddenURL, options: .atomic)
            
            // Set macOS Finder isHidden attribute as an additional guarantee
            var resourceValues = URLResourceValues()
            resourceValues.isHidden = true
            var mutableURL = hiddenURL
            try? mutableURL.setResourceValues(resourceValues)
            
            // Clean up legacy visible file if it existed
            if FileManager.default.fileExists(atPath: visibleURL.path) {
                try? FileManager.default.removeItem(at: visibleURL)
            }
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - Export Utilities
    
    /// Generates a clean Markdown checklist ready to paste into Slack, Teams, or Email.
    public nonisolated static func generateMarkdown(notes: [QCFileNote], mediaName: String) -> String {
        let sorted = notes.sorted { $0.frameIndex < $1.frameIndex }
        var lines: [String] = []
        lines.append("## QC Review Notes // \(mediaName)")
        lines.append("Total Notes: \(sorted.count)")
        lines.append("")
        
        if sorted.isEmpty {
            lines.append("_No review notes logged._")
            return lines.joined(separator: "\n")
        }
        
        for note in sorted {
            let check = note.isResolved ? "[x]" : "[ ]"
            lines.append("- \(check) **\(note.timecode)** (\(note.author)): \(note.text)")
        }
        return lines.joined(separator: "\n")
    }
    
    /// Generates a standard Adobe Premiere Pro Markers CSV import file.
    public nonisolated static func generatePremiereCSV(notes: [QCFileNote], mediaName: String, fps: Double) -> String {
        let sorted = notes.sorted { $0.frameIndex < $1.frameIndex }
        var lines: [String] = []
        lines.append("Marker Name,Description,In,Out,Duration,Marker Type")
        
        for note in sorted {
            let safeAuthor = escapeCSV(note.author)
            let safeText = escapeCSV(note.text)
            let tc = note.timecode
            lines.append("\(safeAuthor),\(safeText),\(tc),\(tc),00:00:00:00,Comment")
        }
        return lines.joined(separator: "\n")
    }
    
    /// Generates a standard DaVinci Resolve Marker EDL (CMX 3600) import file.
    public nonisolated static func generateResolveEDL(notes: [QCFileNote], mediaName: String, fps: Double) -> String {
        let sorted = notes.sorted { $0.frameIndex < $1.frameIndex }
        var lines: [String] = []
        lines.append("TITLE: QCpie Notes - \(mediaName)")
        lines.append("FCM: NON-DROP FRAME")
        lines.append("")
        
        for (index, note) in sorted.enumerated() {
            let eventNum = String(format: "%03d", index + 1)
            let tc = note.timecode
            let color = note.colorTag.capitalized
            lines.append("\(eventNum)  AX       V     C        \(tc) \(tc) \(tc) \(tc)")
            lines.append("* FROM CLIP NAME: \(mediaName)")
            lines.append("* LOC: \(tc) \(color) \(note.author): \(note.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
    
    private nonisolated static func escapeCSV(_ str: String) -> String {
        if str.contains(",") || str.contains("\"") || str.contains("\n") {
            let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return str
    }
}
