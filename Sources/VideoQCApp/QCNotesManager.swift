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
    
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var notesCountCache: [URL: Int] = [:]
    
    /// Updates the in-memory cache for a file's note count.
    public nonisolated static func updateCachedCount(_ count: Int, for mediaURL: URL) {
        cacheLock.lock()
        notesCountCache[mediaURL.standardizedFileURL] = count
        cacheLock.unlock()
    }
    
    /// Checks whether notes companion sidecar file exists on disk for a media file.
    public nonisolated static func hasNotes(for mediaURL: URL) -> Bool {
        let count = notesCount(for: mediaURL)
        return count > 0
    }
    
    /// Cached count only (never touches disk), for view bodies; `nil` until loaded or prewarmed.
    public nonisolated static func cachedNotesCount(for mediaURL: URL) -> Int? {
        let stdURL = mediaURL.standardizedFileURL
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return notesCountCache[stdURL]
    }
    
    /// Returns the number of notes recorded in the companion sidecar file (cached for UI performance).
    public nonisolated static func notesCount(for mediaURL: URL) -> Int {
        let stdURL = mediaURL.standardizedFileURL
        cacheLock.lock()
        if let cached = notesCountCache[stdURL] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        
        let hidden = sidecarURL(for: mediaURL)
        let visible = visibleSidecarURL(for: mediaURL)
        let targetURL: URL? = FileManager.default.fileExists(atPath: hidden.path) ? hidden : (FileManager.default.fileExists(atPath: visible.path) ? visible : nil)
        guard let url = targetURL, let data = try? Data(contentsOf: url) else {
            cacheLock.lock()
            notesCountCache[stdURL] = 0
            cacheLock.unlock()
            return 0
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let count = (try? dec.decode(QCNotesDocument.self, from: data))?.notes.count ?? 0
        
        cacheLock.lock()
        notesCountCache[stdURL] = count
        cacheLock.unlock()
        return count
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
            QCNotesManager.updateCachedCount(0, for: mediaURL)
            return []
        }
        
        guard let url = targetURL else {
            QCNotesManager.updateCachedCount(0, for: mediaURL)
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let doc = try decoder.decode(QCNotesDocument.self, from: data)
            let notes = doc.notes.sorted { $0.frameIndex < $1.frameIndex }
            QCNotesManager.updateCachedCount(notes.count, for: mediaURL)
            return notes
        } catch {
            QCNotesManager.updateCachedCount(0, for: mediaURL)
            return []
        }
    }
    
    /// Frame rate recorded in the sidecar, so a sync rewrite keeps it.
    public func storedFps(for mediaURL: URL) -> Double? {
        let hiddenURL = QCNotesManager.sidecarURL(for: mediaURL)
        let visibleURL = QCNotesManager.visibleSidecarURL(for: mediaURL)
        let url = FileManager.default.fileExists(atPath: hiddenURL.path) ? hiddenURL : visibleURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? decoder.decode(QCNotesDocument.self, from: data))?.fps
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
            QCNotesManager.updateCachedCount(0, for: mediaURL)
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
            QCNotesManager.updateCachedCount(sortedNotes.count, for: mediaURL)
            
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
    
    // MARK: - Portable .qcnotes Export / Import

    /// Writes a visible, portable `.qcnotes` document (same format as the hidden sidecar) to a user-chosen location.
    public nonisolated static func exportDocument(notes: [QCFileNote], mediaFileName: String, fps: Double, to url: URL) throws {
        let doc = QCNotesDocument(
            version: 1,
            mediaFileName: mediaFileName,
            fps: fps > 0 ? fps : 25.0,
            lastModified: Date(),
            notes: notes.sorted { $0.frameIndex < $1.frameIndex }
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(doc).write(to: url, options: .atomic)
    }

    public nonisolated static func importDocument(from url: URL) throws -> QCNotesDocument {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(QCNotesDocument.self, from: Data(contentsOf: url))
    }

    /// Merges imported notes into existing ones by note id: new notes are added; for a note present in both, the
    /// more recently edited text wins, replies are unioned and it stays resolved if either side resolved it.
    public nonisolated static func merge(existing: [QCFileNote], incoming: [QCFileNote]) -> (notes: [QCFileNote], added: Int, updated: Int) {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var added = 0
        var updated = 0
        for note in incoming {
            guard var current = byID[note.id] else {
                byID[note.id] = note
                added += 1
                continue
            }
            let before = current
            if (note.editedAt ?? note.createdAt) > (current.editedAt ?? current.createdAt) {
                current.text = note.text
                current.colorTag = note.colorTag
                current.editedAt = note.editedAt
            }
            current.isResolved = current.isResolved || note.isResolved
            let knownReplies = Set(current.replies.map(\.id))
            current.replies += note.replies.filter { !knownReplies.contains($0.id) }
            current.replies.sort { $0.createdAt < $1.createdAt }
            if current != before { updated += 1 }
            byID[note.id] = current
        }
        return (byID.values.sorted { $0.frameIndex < $1.frameIndex }, added, updated)
    }

    /// Sync merge against the notes both sides last agreed on (`base`): a note missing on one side that is in `base`
    /// was deleted there; a note changed on one side only takes that side; changed on both falls back to `merge`.
    public nonisolated static func threeWayMerge(local: [QCFileNote], remote: [QCFileNote], base: [QCFileNote]) -> [QCFileNote] {
        let baseByID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [QCFileNote] = []
        for id in Set(localByID.keys).union(remoteByID.keys) {
            let original = baseByID[id]
            switch (localByID[id], remoteByID[id]) {
            case let (l?, r?):
                if l == original { result.append(r) }
                else if r == original { result.append(l) }
                else { result.append(contentsOf: merge(existing: [l], incoming: [r]).notes) }
            case let (l?, nil):
                if original == nil { result.append(l) }
            case let (nil, r?):
                if original == nil { result.append(r) }
            case (nil, nil):
                break
            }
        }
        return result.sorted { ($0.frameIndex, $0.createdAt) < ($1.frameIndex, $1.createdAt) }
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
    
    /// Final Cut Pro 7 XML (xmeml) that Premiere Pro imports via File > Import: a sequence named after the clip,
    /// with the clip on V1 and every note as a sequence marker (also as clip markers, so they travel with the clip).
    public nonisolated static func generatePremiereXML(notes: [QCFileNote], mediaName: String, mediaURL: URL,
                                                       fps: Double, width: Int, height: Int, totalFrames: Int,
                                                       audioChannels: Int = 0, audioSampleRate: Int = 48000) -> String {
        let sorted = notes.sorted { $0.frameIndex < $1.frameIndex }
        let safeFps = fps > 0 ? fps : 25.0
        let timebase = Int(safeFps.rounded())
        let ntsc = abs(safeFps - Double(timebase)) > 0.01 ? "TRUE" : "FALSE"
        let rate = "<rate><timebase>\(timebase)</timebase><ntsc>\(ntsc)</ntsc></rate>"
        let duration = max(1, totalFrames)
        let name = xmlEscape(mediaName)
        let pathURL = xmlEscape(mediaURL.absoluteString)

        let markers = sorted.map { note -> String in
            let frame = min(max(0, note.frameIndex), duration - 1)
            let title = note.author.isEmpty ? "QC Note" : note.author
            return "<marker><name>\(xmlEscape(title))</name><comment>\(xmlEscape(note.text))</comment><in>\(frame)</in><out>-1</out><pproColor>\(premiereMarkerColor(note.colorTag))</pproColor></marker>"
        }.joined(separator: "\n")
        // Audio: one linked clip on A1 (mono, or stereo for 2+ channels), sharing the video clip's file.
        let audioCharacteristics = "<samplecharacteristics><depth>16</depth><samplerate>\(audioSampleRate)</samplerate></samplecharacteristics>"
        let hasAudio = audioChannels > 0
        let links = hasAudio
            ? "<link><linkclipref>qcpie-clipitem</linkclipref><mediatype>video</mediatype><trackindex>1</trackindex><clipindex>1</clipindex></link><link><linkclipref>qcpie-audioitem</linkclipref><mediatype>audio</mediatype><trackindex>1</trackindex><clipindex>1</clipindex><groupindex>1</groupindex></link>"
            : ""
        let fileAudio = hasAudio ? "<audio>\(audioCharacteristics)<channelcount>\(audioChannels)</channelcount></audio>" : ""
        let audioSection = hasAudio ? """
        <audio>
        <numOutputChannels>2</numOutputChannels>
        <format>\(audioCharacteristics)</format>
        <track>
        <clipitem id="qcpie-audioitem" premiereChannelType="\(audioChannels == 1 ? "mono" : "stereo")">
        <name>\(name)</name>
        <duration>\(duration)</duration>
        \(rate)
        <start>0</start><end>\(duration)</end><in>0</in><out>\(duration)</out>
        <file id="qcpie-file"/>
        <sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>
        \(links)
        </clipitem>
        </track>
        </audio>
        """ : ""
        // Without these Premiere assumes a non-square (D1/DV) pixel aspect ratio for the sequence.
        let pixelFormat = "<width>\(width)</width><height>\(height)</height><anamorphic>FALSE</anamorphic><pixelaspectratio>square</pixelaspectratio><fielddominance>none</fielddominance>"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4">
        <sequence id="qcpie-sequence">
        <name>QCpie Notes - \(name)</name>
        <duration>\(duration)</duration>
        \(rate)
        <timecode>\(rate)<string>00:00:00:00</string><frame>0</frame><displayformat>NDF</displayformat></timecode>
        <media><video>
        <format><samplecharacteristics>\(rate)\(pixelFormat)</samplecharacteristics></format>
        <track>
        <clipitem id="qcpie-clipitem">
        <name>\(name)</name>
        <duration>\(duration)</duration>
        \(rate)
        <start>0</start><end>\(duration)</end><in>0</in><out>\(duration)</out>
        <file id="qcpie-file">
        <name>\(name)</name>
        <pathurl>\(pathURL)</pathurl>
        \(rate)
        <duration>\(duration)</duration>
        <media><video><samplecharacteristics>\(rate)\(pixelFormat)</samplecharacteristics></video>\(fileAudio)</media>
        </file>
        \(links)
        \(markers)
        </clipitem>
        </track>
        </video>
        \(audioSection)
        </media>
        </sequence>
        </xmeml>
        """
    }

    /// Premiere marker colours (`pproColor`, packed 0xAABBGGRR). Premiere has no purple: it maps to magenta.
    private nonisolated static func premiereMarkerColor(_ tag: String) -> UInt32 {
        switch tag {
        case "yellow": return 4281049552
        case "green": return 4281828977
        case "purple": return 4289825711
        case "red": return 4281740498
        default: return 4292277273 // cyan
        }
    }
    
    private nonisolated static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    
    /// Generates a standard DaVinci Resolve Marker EDL (CMX 3600) import file.
    public nonisolated static func generateResolveEDL(notes: [QCFileNote], mediaName: String) -> String {
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
}
