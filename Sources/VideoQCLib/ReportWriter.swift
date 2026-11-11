import Foundation

public struct ReportWriter: Sendable {
    
    // MARK: - Finder Tagging (Red Label for Flagged Files)
    
    /// Marks all flagged video files in macOS Finder with a Red label/tag. Returns the files actually tagged and the
    /// number that couldn't be (read-only drives and shares).
    @discardableResult
    public static func tagFlaggedFilesInFinder(results: [VideoQCResult]) -> (tagged: [URL], failed: Int) {
        var tagged: [URL] = [], failed = 0
        for result in results where result.isFlagged {
            if FinderTagManager.setTag(.red, for: result.fileURL) { tagged.append(result.fileURL) } else { failed += 1 }
        }
        return (tagged, failed)
    }
    
    // MARK: - Google Sheets / CSV Report Generator
    
    /// Generates a simple, Google Sheets compatible CSV document listing every file, lines found, timecodes, and locations
    public static func generateCSVReport(
        results: [VideoQCResult]
    ) -> String {
        var csv = "File Name,Lines Found,Timecode,Location,Duration,Detected Color\n"
        
        for result in results {
            let fileName = result.fileName
            if let readError = result.readError {
                csv += "\(QCUtilities.escapeCSV(fileName)),Unreadable,--,\(QCUtilities.escapeCSV(readError)),\(result.totalFrames) frames checked,--\n"
            }
            if result.glitchSegments.isEmpty && result.readError == nil {
                // Clean file
                csv += "\(QCUtilities.escapeCSV(fileName)),No,--,--,--,--\n"
            } else {
                let segments = result.glitchSegments
                for (idx, seg) in segments.enumerated() {
                    let displayName = segments.count > 1 ? "\(fileName) (Segment \(idx + 1))" : fileName
                    let linesFound = "Yes (\(segments.count) total)"
                    let timecode = seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) -> \(seg.endTimecode)"
                    let location: String
                    switch seg.edge {
                    case .top, .bottom, .left, .right:
                        location = "\(seg.edge.rawValue.capitalized) Edge (\(seg.avgThickness)px)\(seg.locationDetail.map { ", \($0)" } ?? "")\(seg.isOffColor ? " - off-colour" : "")"
                    case .splitHorizontal, .splitVertical:
                        location = "\(seg.edge.rawValue) (\(seg.avgThickness)px)\(seg.locationDetail.map { ", \($0)" } ?? "")"
                    }
                    let duration = "\(seg.frameCount) frame\(seg.frameCount == 1 ? "" : "s") (\(String(format: "%.2f", seg.durationSeconds))s)"
                    let color = seg.detectedColor.hexString.uppercased()
                    
                    csv += "\(QCUtilities.escapeCSV(displayName)),\(QCUtilities.escapeCSV(linesFound)),\(QCUtilities.escapeCSV(timecode)),\(QCUtilities.escapeCSV(location)),\(QCUtilities.escapeCSV(duration)),\(QCUtilities.escapeCSV(color))\n"
                }
            }
        }
        
        return csv
    }
    
    // MARK: - Google Sheets / TSV Report Generator (Clipboard)
    
    /// Generates a tab-separated values (TSV) report listing every file, lines found, timecodes, and locations, optimized for direct clipboard paste into Google Sheets
    public static func generateTSVReport(
        results: [VideoQCResult]
    ) -> String {
        var tsv = "File Name\tLines Found\tTimecode\tLocation\tDuration\tDetected Color\n"
        
        for result in results {
            let fileName = result.fileName
            if let readError = result.readError {
                tsv += "\(QCUtilities.escapeTSV(fileName))\tUnreadable\t--\t\(QCUtilities.escapeTSV(readError))\t\(result.totalFrames) frames checked\t--\n"
            }
            if result.glitchSegments.isEmpty && result.readError == nil {
                // Clean file
                tsv += "\(QCUtilities.escapeTSV(fileName))\tNo\t--\t--\t--\t--\n"
            } else {
                let segments = result.glitchSegments
                for (idx, seg) in segments.enumerated() {
                    let displayName = segments.count > 1 ? "\(fileName) (Segment \(idx + 1))" : fileName
                    let linesFound = "Yes (\(segments.count) total)"
                    let timecode = seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) -> \(seg.endTimecode)"
                    let location: String
                    switch seg.edge {
                    case .top, .bottom, .left, .right:
                        location = "\(seg.edge.rawValue.capitalized) Edge (\(seg.avgThickness)px)\(seg.locationDetail.map { ", \($0)" } ?? "")\(seg.isOffColor ? " - off-colour" : "")"
                    case .splitHorizontal, .splitVertical:
                        location = "\(seg.edge.rawValue) (\(seg.avgThickness)px)\(seg.locationDetail.map { ", \($0)" } ?? "")"
                    }
                    let duration = "\(seg.frameCount) frame\(seg.frameCount == 1 ? "" : "s") (\(String(format: "%.2f", seg.durationSeconds))s)"
                    let color = seg.detectedColor.hexString.uppercased()
                    
                    tsv += "\(QCUtilities.escapeTSV(displayName))\t\(QCUtilities.escapeTSV(linesFound))\t\(QCUtilities.escapeTSV(timecode))\t\(QCUtilities.escapeTSV(location))\t\(QCUtilities.escapeTSV(duration))\t\(QCUtilities.escapeTSV(color))\n"
                }
            }
        }
        
        return tsv
    }
    
    // MARK: - HTML Report

    /// The Line Check report: flagged files with their line segments, then the files that passed.
    public static func generateHTMLReport(
        folderURL: URL,
        config: QCConfig,
        results: [VideoQCResult],
        scanDate: Date = Date(),
        csvFileName: String? = nil,
        colors: ReportColors = .standard
    ) -> String {
        let esc = QCUtilities.escapeHTML
        let folderName = esc(folderURL.lastPathComponent)
        let flaggedVideos = results.filter { $0.isFlagged }
        let cleanVideos = results.filter { !$0.isFlagged }
        let totalSegments = flaggedVideos.reduce(0) { $0 + $1.glitchSegments.count }
        let targetHex = config.targetHex.uppercased()
        let targetLabel = config.anyColor
            ? "Any colour"
            : "<span class=\"swatch\" style=\"background:\(esc(targetHex))\"></span> <span class=\"mono\">\(esc(targetHex))</span> <span class=\"dim\">\(Int(config.sensitivity * 100))% sensitivity</span>"
        let verdict = flaggedVideos.isEmpty
            ? "<span class=\"tag ok big\">All Passed</span>"
            : "<span class=\"tag bad big\">\(flaggedVideos.count) Flagged</span>"
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

        var html = """
        <!DOCTYPE html>
        <html lang="en" data-theme="dark">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Line Check · \(folderName)</title>
            <style>
        \(ReportStyle.css(colors))
            </style>
        </head>
        <body>
            <div class="page">
                <div class="top">
                    <div>
                        <div class="brand">QCpie · Line Check</div>
                        <h1>\(folderName)</h1>
                        <div class="sub">\(ReportStyle.dateString(scanDate))</div>
                    </div>
                    \(ReportStyle.actions(extra: verdict))
                </div>

                <div class="stats">
                    <div class="stat"><div class="num">\(results.count)</div><div class="label">Files Checked</div></div>
                    <div class="stat\(flaggedVideos.isEmpty ? "" : " bad")"><div class="num">\(flaggedVideos.count)</div><div class="label">Flagged</div></div>
                    <div class="stat\(cleanVideos.isEmpty ? "" : " ok")"><div class="num">\(cleanVideos.count)</div><div class="label">Passed</div></div>
                    <div class="stat"><div class="num">\(totalSegments)</div><div class="label">Line Segments</div></div>
                </div>
                <div class="facts">
                    <div class="fact"><span class="k">Target colour</span><span class="v">\(targetLabel)</span></div>
                    <div class="fact"><span class="k">Edge margin</span><span class="v">\(config.edgeDepth) px\(config.scanFullScreen ? " · Full screen" : "")</span></div>
                </div>
        """

        if !flaggedVideos.isEmpty {
            html += """
                <div class="section"><h2>Flagged</h2><div class="count">\(plural(flaggedVideos.count, "file"))</div></div>
            """
            for video in flaggedVideos {
                html += """
                <div class="card flagged">
                    <div class="card-head">
                        <div>
                            <div class="name">\(esc(video.fileName))</div>
                            <div class="meta">\(esc(video.resolution)) · \(String(format: "%.2f", video.fps)) fps · \(video.totalFrames) frames</div>
                        </div>
                        <span class="tag bad">Red Finder tag</span>
                    </div>
                    <div class="scroll">
                    <table>
                        <thead><tr><th>#</th><th>Location</th><th>Timecode</th><th>Duration</th><th>Frames</th><th>Colour</th></tr></thead>
                        <tbody>
                """
                if let readError = video.readError {
                    html += """
                            <tr><td class="num-cell">–</td><td colspan="5"><span class="tag bad">Unreadable</span> \(esc(readError)) <span class="dim">· \(video.totalFrames) frames checked</span></td></tr>
                    """
                }
                for (idx, seg) in video.glitchSegments.enumerated() {
                    let tc = seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) → \(seg.endTimecode)"
                    let frames = seg.startFrame == seg.endFrame ? "\(seg.startFrame)" : "\(seg.startFrame)–\(seg.endFrame)"
                    let colorHex = seg.detectedColor.hexString.uppercased()
                    let detail = [seg.locationDetail, seg.isOffColor ? "off-colour" : nil].compactMap { $0 }.map(esc).joined(separator: " · ")
                    html += """
                            <tr>
                                <td class="num-cell">\(idx + 1)</td>
                                <td><span class="nowrap">\(esc(seg.edge.rawValue)) · \(seg.avgThickness) px</span>\(detail.isEmpty ? "" : "<span class=\"detail\">\(detail)</span>")</td>
                                <td class="mono nowrap">\(esc(tc))</td>
                                <td class="nowrap">\(plural(seg.frameCount, "frame")) <span class="dim">(\(String(format: "%.2f", seg.durationSeconds)) s)</span></td>
                                <td class="mono dim nowrap">\(frames)</td>
                                <td class="nowrap"><span class="swatch" style="background:\(esc(colorHex))"></span> <span class="mono">\(esc(colorHex))</span></td>
                            </tr>
                    """
                }
                html += """
                        </tbody>
                    </table>
                    </div>
                </div>
                """
            }
        }

        html += """
                <div class="section"><h2>Passed</h2><div class="count">\(plural(cleanVideos.count, "file"))</div></div>
                <div class="card"><div class="passed">
        """
        if cleanVideos.isEmpty {
            html += "<div class=\"cell dim\">None</div>"
        } else {
            for clean in cleanVideos {
                html += "<div class=\"cell\" title=\"\(esc(clean.fileName))\"><span class=\"dot\"></span>\(esc(clean.fileName))</div>\n"
            }
        }
        html += """
                </div></div>

                <footer><div>QCpie Line Check</div><div>\(ReportStyle.dateString(scanDate))</div></footer>
            </div>
            <div id="toast"></div>
        \(ReportStyle.script(csv: generateCSVReport(results: results), tsv: generateTSVReport(results: results),
                             csvFileName: csvFileName ?? "QC_Report.csv", what: "Report"))
        </body>
        </html>
        """
        return html
    }
}
