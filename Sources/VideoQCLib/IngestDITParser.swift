import Foundation

public struct IngestDITParser: Sendable {
    
    public init() {}
    
    // MARK: - Delimiter Detection & Line Splitting
    
    public static func parse(content: String) -> [IngestDITRecord] {
        let lines = splitLines(content)
        guard let headerLine = lines.first, !headerLine.isEmpty else { return [] }
        
        let delimiter = detectDelimiter(line: headerLine)
        let headers = parseRow(headerLine, delimiter: delimiter)
        guard !headers.isEmpty else { return [] }
        
        // Find filename column index
        let fileColIdx = findFileNameColumnIndex(headers: headers)
        
        var records: [IngestDITRecord] = []
        for line in lines.dropFirst() {
            let row = parseRow(line, delimiter: delimiter)
            guard !row.isEmpty else { continue }
            
            // Build dictionary
            var fields: [String: String] = [:]
            for (idx, header) in headers.enumerated() {
                if idx < row.count {
                    let val = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty {
                        fields[header] = val
                    }
                }
            }
            
            // Determine filename
            let fileName: String
            if let idx = fileColIdx, idx < row.count, !row[idx].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fileName = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let firstNonEmpty = row.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                fileName = firstNonEmpty.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                continue
            }
            
            records.append(IngestDITRecord(fileName: fileName, fields: fields))
        }
        
        return records
    }
    
    private static func detectDelimiter(line: String) -> Character {
        let tabCount = line.filter { $0 == "\t" }.count
        let commaCount = line.filter { $0 == "," }.count
        let semicolonCount = line.filter { $0 == ";" }.count
        
        if tabCount > commaCount && tabCount > semicolonCount {
            return "\t"
        } else if semicolonCount > commaCount {
            return ";"
        }
        return ","
    }
    
    private static func findFileNameColumnIndex(headers: [String]) -> Int? {
        let candidates = ["clip name", "clip", "file name", "filename", "file", "clipname", "name", "shot", "reel / clip", "reel/clip", "source file"]
        for candidate in candidates {
            if let idx = headers.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate }) {
                return idx
            }
        }
        // Fallback: any header containing "file" or "clip"
        return headers.firstIndex(where: {
            let lower = $0.lowercased()
            return lower.contains("clip") || lower.contains("file")
        })
    }
    
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
    
    private static func parseRow(_ line: String, delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = line.makeIterator()
        
        while let char = iterator.next() {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == delimiter && !insideQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
    
    // MARK: - Cross-Referencing & Discrepancy Detection
    
    public static func crossReference(
        items: [IngestItem],
        ditRecords: [IngestDITRecord]
    ) -> [IngestFlag] {
        guard !ditRecords.isEmpty else { return [] }
        var flags: [IngestFlag] = []
        
        // Build map of disk items normalized by filename
        var diskItemsByBaseName: [String: IngestItem] = [:]
        for item in items {
            let fullName = item.fileName.lowercased()
            diskItemsByBaseName[fullName] = item
            let stripped = (item.fileName as NSString).deletingPathExtension.lowercased()
            if diskItemsByBaseName[stripped] == nil {
                diskItemsByBaseName[stripped] = item
            }
        }
        
        // Track matched disk items
        var matchedDiskPaths = Set<String>()
        
        // 1. Check all DIT records against disk
        for record in ditRecords {
            let recordLower = record.fileName.lowercased()
            let recordStripped = (record.fileName as NSString).deletingPathExtension.lowercased()
            
            let matchedItem = diskItemsByBaseName[recordLower] ?? diskItemsByBaseName[recordStripped]
            
            if let item = matchedItem {
                matchedDiskPaths.insert(item.fileURL.path)
                
                // Compare FPS if present in DIT
                if let ditFPSStr = record.fps, let media = item.mediaMetadata {
                    let cleaned = ditFPSStr.replacingOccurrences(of: "fps", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)
                    if let ditFPS = Double(cleaned) {
                        if abs(media.fps - ditFPS) > 0.1 {
                            flags.append(IngestFlag(
                                severity: .warning,
                                title: "FPS Mismatch",
                                detail: "DIT report lists \(ditFPSStr), but scanned file has \(String(format: "%.2f", media.fps)) FPS",
                                fileName: item.fileName
                            ))
                        }
                    }
                }
                
                // Compare Resolution if present in DIT
                if let ditResStr = record.resolution, let media = item.mediaMetadata {
                    let normalizedDITRes = ditResStr.replacingOccurrences(of: " ", with: "")
                        .replacingOccurrences(of: "X", with: "x")
                    let normalizedMediaRes = media.resolutionString.replacingOccurrences(of: " ", with: "")
                    if !normalizedDITRes.isEmpty && !normalizedDITRes.contains(normalizedMediaRes) && !normalizedMediaRes.contains(normalizedDITRes) {
                        flags.append(IngestFlag(
                            severity: .warning,
                            title: "Resolution Mismatch",
                            detail: "DIT report lists \(ditResStr), scanned media is \(media.resolutionString)",
                            fileName: item.fileName
                        ))
                    }
                }
                
                // Compare Codec if present in DIT
                if let ditCodec = record.codec, let media = item.mediaMetadata {
                    let dLower = ditCodec.lowercased()
                    let mLower = media.videoCodec.lowercased()
                    if !dLower.isEmpty && !mLower.contains(dLower) && !dLower.contains(mLower) {
                        flags.append(IngestFlag(
                            severity: .warning,
                            title: "Codec Discrepancy",
                            detail: "DIT report indicates \(ditCodec), scanned file contains \(media.videoCodec)",
                            fileName: item.fileName
                        ))
                    }
                }
            } else {
                // Record in DIT was not found on disk
                flags.append(IngestFlag(
                    severity: .critical,
                    title: "Missing From Disk",
                    detail: "Listed in DIT report but not found in scanned folder or subdirectories",
                    fileName: record.fileName
                ))
            }
        }
        
        // 2. Check for footage files on disk that are completely unlisted in the DIT report
        for item in items where item.fileCategory == .rawFootage || item.fileCategory == .transcode {
            if !matchedDiskPaths.contains(item.fileURL.path) {
                flags.append(IngestFlag(
                    severity: .info,
                    title: "Not Listed in DIT Report",
                    detail: "File exists on storage drive but does not appear in imported DIT documentation",
                    fileName: item.fileName
                ))
            }
        }
        
        return flags.sorted { $0.severity.sortOrder < $1.severity.sortOrder }
    }
    
    // MARK: - Export Manifest CSV
    
    public static func generateManifestCSV(manifest: IngestManifest, flags: [IngestFlag] = []) -> String {
        var csv = ""
        
        // Header Section
        csv += "QCPIE INGEST INTAKE REPORT\n"
        csv += "Job Name / Number,\(QCUtilities.escapeCSV(manifest.jobName))\n"
        csv += "Ingested By,\(QCUtilities.escapeCSV(manifest.ingestedBy))\n"
        
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        csv += "Date Ingested,\(QCUtilities.escapeCSV(df.string(from: manifest.dateIngested)))\n"
        csv += "Received Via,\(QCUtilities.escapeCSV(manifest.receivedVia))\n"
        csv += "Added to Client Drives,\(manifest.addedToClientDrives ? "YES" : "NO")\n"
        csv += "Is VFX Project,\(manifest.isVFXProject ? "YES" : "NO")\n"
        csv += "HD Source / Return To,\(QCUtilities.escapeCSV(manifest.hdSource))\n\n"
        
        // Elements Received Summary
        csv += "ELEMENTS RECEIVED\n"
        csv += "Raw Footage,\(manifest.hasRawFootage ? "YES" : "NO")\n"
        csv += "Transcodes,\(manifest.hasTranscodes ? "YES" : "NO")\n"
        csv += "Camera Reports,\(manifest.hasCameraReports ? "YES" : "NO")\n"
        csv += "Location Audio,\(manifest.hasLocationAudio ? "YES" : "NO")\n"
        csv += "Shooting LUTs,\(manifest.hasShootingLUTs ? "YES" : "NO")\n\n"
        
        // Technical Summary
        csv += "FOOTAGE TECHNICAL SUMMARY\n"
        csv += "Raw Media Codec,\(QCUtilities.escapeCSV(manifest.rawMediaCodec))\n"
        csv += "Transcode Codec,\(QCUtilities.escapeCSV(manifest.transcodeCodec))\n"
        csv += "Camera Used,\(QCUtilities.escapeCSV(manifest.cameraUsed))\n"
        csv += "Main Resolution,\(QCUtilities.escapeCSV(manifest.shootingResolution))\n"
        csv += "Project Timebase / FPS,\(QCUtilities.escapeCSV(manifest.mainFPS))\n"
        if !manifest.flagNotes.isEmpty {
            csv += "Ingest Notes,\(QCUtilities.escapeCSV(manifest.flagNotes))\n"
        }
        csv += "\n"
        
        // Discrepancy Flags (if any)
        if !flags.isEmpty {
            csv += "DISCREPANCY FLAGS & AUDIT\n"
            csv += "Severity,File Name,Issue,Details\n"
            for f in flags {
                csv += "\(f.severity.rawValue),\(QCUtilities.escapeCSV(f.fileName)),\(QCUtilities.escapeCSV(f.title)),\(QCUtilities.escapeCSV(f.detail))\n"
            }
            csv += "\n"
        }
        
        // Files Table
        csv += "SCANNED INTAKE ITEMS\n"
        csv += "Category,File Name,Relative Path,Size,Resolution,FPS,Duration,Timecode,Video Codec,Audio Spec,Creation Date\n"
        for item in manifest.items {
            let cat = item.fileCategory.rawValue
            let name = item.fileName
            let path = item.relativePath
            let size = item.formattedFileSize
            let res = item.mediaMetadata?.resolutionString ?? "--"
            let fps = item.mediaMetadata != nil ? String(format: "%.2f", item.mediaMetadata!.fps) : "--"
            let dur = item.mediaMetadata?.formattedDuration ?? "--"
            let tc = item.mediaMetadata?.timecode ?? "--"
            let vCodec = item.mediaMetadata?.videoCodec ?? "--"
            let aCodec = item.mediaMetadata != nil ? "\(item.mediaMetadata!.audioCodec) (\(item.mediaMetadata!.audioConfig))" : "--"
            let date = item.mediaMetadata?.formattedCreationDate ?? "--"
            
            csv += "\(QCUtilities.escapeCSV(cat)),\(QCUtilities.escapeCSV(name)),\(QCUtilities.escapeCSV(path)),\(QCUtilities.escapeCSV(size)),\(QCUtilities.escapeCSV(res)),\(QCUtilities.escapeCSV(fps)),\(QCUtilities.escapeCSV(dur)),\(QCUtilities.escapeCSV(tc)),\(QCUtilities.escapeCSV(vCodec)),\(QCUtilities.escapeCSV(aCodec)),\(QCUtilities.escapeCSV(date))\n"
        }
        
        return csv
    }
    
    // MARK: - Export Manifest HTML
    
    public static func generateManifestHTML(manifest: IngestManifest, flags: [IngestFlag] = []) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = df.string(from: manifest.dateIngested)
        
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>Ingest Intake Report - \(manifest.jobName.isEmpty ? "Footage Intake" : manifest.jobName)</title>
            <style>
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", Arial, sans-serif;
                    background-color: #0E0E10;
                    color: #E2E2E5;
                    padding: 36px 48px;
                    line-height: 1.5;
                }
                .container { max-width: 1280px; margin: 0 auto; }
                h1 { font-size: 26px; font-weight: 800; letter-spacing: -0.5px; margin-bottom: 6px; color: #FFFFFF; }
                .subtitle { font-size: 13px; font-family: monospace; color: #8A8A93; margin-bottom: 28px; }
                .grid-header {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                    gap: 16px;
                    background: #18181C;
                    border: 1px solid #2B2B33;
                    border-radius: 8px;
                    padding: 20px 24px;
                    margin-bottom: 24px;
                }
                .field-block { display: flex; flex-direction: column; gap: 4px; }
                .field-label { font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.8px; color: #8A8A93; }
                .field-value { font-size: 15px; font-weight: 600; color: #F0F0F3; font-family: monospace; }
                .checklist-grid {
                    display: grid;
                    grid-template-columns: repeat(5, 1fr);
                    gap: 12px;
                    margin-bottom: 24px;
                }
                .check-card {
                    background: #18181C;
                    border: 1px solid #2B2B33;
                    border-radius: 6px;
                    padding: 12px 14px;
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                }
                .check-card.active { border-color: #3B82F6; background: #182234; }
                .check-name { font-size: 12px; font-weight: 600; }
                .check-status { font-size: 11px; font-weight: 700; font-family: monospace; }
                .check-status.yes { color: #10B981; }
                .check-status.no { color: #6B7280; }
                .section-title {
                    font-size: 14px;
                    font-weight: 800;
                    letter-spacing: 1px;
                    text-transform: uppercase;
                    margin-top: 32px;
                    margin-bottom: 12px;
                    color: #FFFFFF;
                }
                .flags-card {
                    background: #241618;
                    border: 1px solid #7F1D1D;
                    border-radius: 6px;
                    padding: 16px;
                    margin-bottom: 24px;
                }
                .flag-row {
                    display: flex;
                    align-items: baseline;
                    gap: 12px;
                    padding: 8px 0;
                    border-bottom: 1px solid rgba(255,255,255,0.08);
                    font-size: 13px;
                }
                .flag-row:last-child { border-bottom: none; }
                .flag-badge {
                    font-size: 10px;
                    font-weight: 800;
                    padding: 2px 6px;
                    border-radius: 4px;
                    font-family: monospace;
                }
                .badge-critical { background: #DC2626; color: #FFF; }
                .badge-warning { background: #D97706; color: #FFF; }
                .badge-info { background: #3B82F6; color: #FFF; }
                table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 12px;
                    background: #18181C;
                    border: 1px solid #2B2B33;
                    border-radius: 6px;
                    overflow: hidden;
                }
                th {
                    background: #212127;
                    color: #9CA3AF;
                    text-align: left;
                    padding: 10px 14px;
                    font-weight: 700;
                    font-size: 10px;
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                    border-bottom: 1px solid #2B2B33;
                }
                td {
                    padding: 9px 14px;
                    border-bottom: 1px solid #25252D;
                    color: #D1D5DB;
                }
                tr:hover td { background: #202026; }
                .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
                .category-badge {
                    display: inline-block;
                    padding: 2px 7px;
                    font-size: 10px;
                    font-weight: 700;
                    border-radius: 4px;
                    background: #2B2B33;
                    color: #E2E2E5;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>INGEST INTAKE REPORT</h1>
                <div class="subtitle">Generated by QCpie &bull; \(dateStr)</div>
                
                <div class="grid-header">
                    <div class="field-block">
                        <div class="field-label">Job Name / Number</div>
                        <div class="field-value">\(manifest.jobName.isEmpty ? "--" : manifest.jobName)</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">Ingested By</div>
                        <div class="field-value">\(manifest.ingestedBy.isEmpty ? "--" : manifest.ingestedBy)</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">Received Via</div>
                        <div class="field-value">\(manifest.receivedVia)</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">Added to Client Drives</div>
                        <div class="field-value">\(manifest.addedToClientDrives ? "YES" : "NO")</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">VFX Project</div>
                        <div class="field-value">\(manifest.isVFXProject ? "YES" : "NO")</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">HD Source / Return To</div>
                        <div class="field-value">\(manifest.hdSource.isEmpty ? "--" : manifest.hdSource)</div>
                    </div>
                </div>
                
                <div class="section-title">Elements Received</div>
                <div class="checklist-grid">
                    <div class="check-card \(manifest.hasRawFootage ? "active" : "")">
                        <span class="check-name">Raw Footage</span>
                        <span class="check-status \(manifest.hasRawFootage ? "yes" : "no")">\(manifest.hasRawFootage ? "YES" : "NO")</span>
                    </div>
                    <div class="check-card \(manifest.hasTranscodes ? "active" : "")">
                        <span class="check-name">Transcodes</span>
                        <span class="check-status \(manifest.hasTranscodes ? "yes" : "no")">\(manifest.hasTranscodes ? "YES" : "NO")</span>
                    </div>
                    <div class="check-card \(manifest.hasCameraReports ? "active" : "")">
                        <span class="check-name">Camera Reports</span>
                        <span class="check-status \(manifest.hasCameraReports ? "yes" : "no")">\(manifest.hasCameraReports ? "YES" : "NO")</span>
                    </div>
                    <div class="check-card \(manifest.hasLocationAudio ? "active" : "")">
                        <span class="check-name">Location Audio</span>
                        <span class="check-status \(manifest.hasLocationAudio ? "yes" : "no")">\(manifest.hasLocationAudio ? "YES" : "NO")</span>
                    </div>
                    <div class="check-card \(manifest.hasShootingLUTs ? "active" : "")">
                        <span class="check-name">Shooting LUTs</span>
                        <span class="check-status \(manifest.hasShootingLUTs ? "yes" : "no")">\(manifest.hasShootingLUTs ? "YES" : "NO")</span>
                    </div>
                </div>
                
                <div class="grid-header">
                    <div class="field-block">
                        <div class="field-label">Camera Used</div>
                        <div class="field-value">\(manifest.cameraUsed.isEmpty ? "--" : manifest.cameraUsed)</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">Raw Media Codec</div>
                        <div class="field-value">\(manifest.rawMediaCodec.isEmpty ? "--" : manifest.rawMediaCodec)</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">Transcode Codec</div>
                        <div class="field-value">\(manifest.transcodeCodec.isEmpty ? "--" : manifest.transcodeCodec)</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">Shooting Resolution</div>
                        <div class="field-value">\(manifest.shootingResolution.isEmpty ? "--" : manifest.shootingResolution)</div>
                    </div>
                    <div class="field-block">
                        <div class="field-label">Project Timebase</div>
                        <div class="field-value">\(manifest.mainFPS.isEmpty ? "--" : manifest.mainFPS)</div>
                    </div>
                </div>
        """
        
        if !flags.isEmpty {
            html += """
                <div class="section-title">Discrepancy Flags (\(flags.count))</div>
                <div class="flags-card">
            """
            for f in flags {
                let badgeClass = f.severity == .critical ? "badge-critical" : (f.severity == .warning ? "badge-warning" : "badge-info")
                html += """
                    <div class="flag-row">
                        <span class="flag-badge \(badgeClass)">\(f.severity.rawValue)</span>
                        <strong class="mono" style="color: #FFF;">\(f.fileName)</strong>
                        <span style="color: #E2E2E5;">&bull; \(f.title): \(f.detail)</span>
                    </div>
                """
            }
            html += "</div>"
        }
        
        html += """
                <div class="section-title">Scanned Items (\(manifest.items.count))</div>
                <table>
                    <thead>
                        <tr>
                            <th>Category</th>
                            <th>File Name</th>
                            <th>Size</th>
                            <th>Resolution</th>
                            <th>FPS</th>
                            <th>Duration</th>
                            <th>Codec</th>
                            <th>Audio</th>
                        </tr>
                    </thead>
                    <tbody>
        """
        
        for item in manifest.items {
            let cat = item.fileCategory.rawValue
            let name = item.fileName
            let size = item.formattedFileSize
            let res = item.mediaMetadata?.resolutionString ?? "--"
            let fps = item.mediaMetadata != nil ? String(format: "%.2f", item.mediaMetadata!.fps) : "--"
            let dur = item.mediaMetadata?.formattedDuration ?? "--"
            let codec = item.mediaMetadata?.videoCodec ?? "--"
            let audio = item.mediaMetadata?.audioCodec ?? "--"
            
            html += """
                        <tr>
                            <td><span class="category-badge">\(cat)</span></td>
                            <td class="mono" style="font-weight: 600; color: #FFF;">\(name)</td>
                            <td class="mono">\(size)</td>
                            <td class="mono">\(res)</td>
                            <td class="mono">\(fps)</td>
                            <td class="mono">\(dur)</td>
                            <td class="mono">\(codec)</td>
                            <td class="mono">\(audio)</td>
                        </tr>
            """
        }
        
        html += """
                    </tbody>
                </table>
            </div>
        </body>
        </html>
        """
        
        return html
    }
}
