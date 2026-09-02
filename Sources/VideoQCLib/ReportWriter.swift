import Foundation

public struct ReportWriter: Sendable {
    
    // MARK: - Finder Tagging (Red Label for Flagged Files)
    
    /// Marks all flagged video files in macOS Finder with a Red label/tag
    public static func tagFlaggedFilesInFinder(results: [VideoQCResult]) {
        for result in results {
            if result.isFlagged {
                let nsURL = result.fileURL as NSURL
                // 1. Set Finder Tag Name "Red"
                try? nsURL.setResourceValue(["Red"] as NSArray, forKey: .tagNamesKey)
                // 2. Set Finder Color Label Number (6 = Red)
                var mutableURL = result.fileURL
                var resourceValues = URLResourceValues()
                resourceValues.labelNumber = 6
                try? mutableURL.setResourceValues(resourceValues)
            }
        }
    }
    
    // MARK: - Minimalist Studio HTML Report Generator
    
    /// Generates a sleek, minimal, Helvetica-styled Swiss/editorial QC report (no emojis, stark palette)
    public static func generateHTMLReport(
        folderURL: URL,
        config: QCConfig,
        results: [VideoQCResult],
        scanDate: Date = Date()
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy.MM.dd // HH:mm:ss"
        let dateString = dateFormatter.string(from: scanDate)
        
        let flaggedVideos = results.filter { $0.isFlagged }
        let cleanVideos = results.filter { !$0.isFlagged }
        let totalSegments = flaggedVideos.reduce(0) { $0 + $1.glitchSegments.count }
        
        let targetHex = config.targetHex.uppercased()
        let tolPercent = Int(config.tolerance * 100)
        
        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>QC // \(folderURL.lastPathComponent.uppercased())</title>
            <style>
                @import url('https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@400;600;700;800;900&family=JetBrains+Mono:wght@400;500;700&display=swap');

                :root {
                    --bg: #0a0a0a;
                    --panel: #111111;
                    --panel-hover: #161616;
                    --border: #222222;
                    --border-strong: #333333;
                    --text: #ffffff;
                    --text-secondary: #888888;
                    --text-muted: #555555;
                    --red: #ff3333;
                    --red-muted: rgba(255, 51, 51, 0.12);
                    --font-heading: 'Barlow Condensed', 'Helvetica Neue', 'Helvetica', -apple-system, sans-serif;
                    --font-mono: 'JetBrains Mono', 'SF Mono', 'Menlo', monospace;
                }

                * { box-sizing: border-box; margin: 0; padding: 0; }

                body {
                    background-color: var(--bg);
                    color: var(--text);
                    font-family: var(--font-heading);
                    text-transform: uppercase;
                    padding: 48px 32px;
                    line-height: 1.2;
                    -webkit-font-smoothing: antialiased;
                }

                .container {
                    max-width: 1180px;
                    margin: 0 auto;
                }

                /* Header Masthead */
                .masthead {
                    display: flex;
                    justify-content: space-between;
                    align-items: flex-end;
                    border-bottom: 2px solid var(--text);
                    padding-bottom: 24px;
                    margin-bottom: 32px;
                }

                .title-block h1 {
                    font-size: 56px;
                    font-weight: 900;
                    letter-spacing: -0.02em;
                    line-height: 0.95;
                }

                .title-block .subtitle {
                    font-size: 14px;
                    font-weight: 600;
                    letter-spacing: 0.15em;
                    color: var(--text-secondary);
                    margin-top: 8px;
                }

                .status-badge {
                    font-size: 16px;
                    font-weight: 800;
                    letter-spacing: 0.1em;
                    padding: 8px 16px;
                    border: 1px solid var(--border-strong);
                }

                .status-flagged {
                    background: var(--red);
                    color: #000000;
                    border-color: var(--red);
                }

                .status-passed {
                    background: var(--text);
                    color: #000000;
                    border-color: var(--text);
                }

                /* Metadata Grid */
                .meta-strip {
                    display: grid;
                    grid-template-columns: repeat(4, 1fr);
                    border: 1px solid var(--border);
                    background: var(--panel);
                    margin-bottom: 36px;
                }

                .meta-cell {
                    padding: 16px 20px;
                    border-right: 1px solid var(--border);
                }
                .meta-cell:last-child { border-right: none; }

                .meta-label {
                    font-size: 11px;
                    font-weight: 700;
                    letter-spacing: 0.15em;
                    color: var(--text-muted);
                    margin-bottom: 6px;
                }

                .meta-value {
                    font-size: 18px;
                    font-weight: 700;
                    font-family: var(--font-heading);
                    letter-spacing: 0.02em;
                    display: flex;
                    align-items: center;
                    gap: 8px;
                }

                .color-sq {
                    display: inline-block;
                    width: 12px;
                    height: 12px;
                    border: 1px solid rgba(255,255,255,0.4);
                }

                /* Numbers Summary */
                .stats-strip {
                    display: grid;
                    grid-template-columns: repeat(4, 1fr);
                    gap: 16px;
                    margin-bottom: 48px;
                }

                .stat-box {
                    border-top: 1px solid var(--border-strong);
                    padding-top: 12px;
                }

                .stat-box .num {
                    font-size: 44px;
                    font-weight: 900;
                    letter-spacing: -0.02em;
                    line-height: 1;
                }

                .stat-box .label {
                    font-size: 12px;
                    font-weight: 700;
                    letter-spacing: 0.15em;
                    color: var(--text-secondary);
                    margin-top: 6px;
                }

                .stat-box.highlight .num { color: var(--red); }

                /* Section Titles */
                .section-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: baseline;
                    border-bottom: 1px solid var(--border-strong);
                    padding-bottom: 10px;
                    margin-bottom: 20px;
                }

                .section-header h2 {
                    font-size: 22px;
                    font-weight: 800;
                    letter-spacing: 0.08em;
                }

                .section-header .count {
                    font-size: 14px;
                    font-weight: 600;
                    color: var(--text-secondary);
                    font-family: var(--font-mono);
                }

                /* File Cards */
                .card {
                    background: var(--panel);
                    border: 1px solid var(--border);
                    margin-bottom: 24px;
                }

                .card.flagged {
                    border-left: 4px solid var(--red);
                }

                .card-header {
                    padding: 16px 20px;
                    border-bottom: 1px solid var(--border);
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                }

                .card-header .title {
                    font-size: 20px;
                    font-weight: 800;
                    letter-spacing: 0.02em;
                }

                .card-header .meta {
                    font-size: 12px;
                    font-weight: 600;
                    color: var(--text-secondary);
                    letter-spacing: 0.1em;
                    margin-top: 4px;
                }

                .finder-tag {
                    font-size: 11px;
                    font-weight: 700;
                    letter-spacing: 0.1em;
                    padding: 4px 10px;
                    border: 1px solid var(--red);
                    color: var(--red);
                }

                /* Glitch Table */
                table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 13px;
                }

                th {
                    background: #0d0d0d;
                    color: var(--text-muted);
                    font-size: 11px;
                    font-weight: 700;
                    letter-spacing: 0.12em;
                    padding: 12px 20px;
                    text-align: left;
                    border-bottom: 1px solid var(--border);
                }

                td {
                    padding: 14px 20px;
                    border-bottom: 1px solid var(--border);
                    font-weight: 600;
                }

                tr:last-child td { border-bottom: none; }

                .tc-text {
                    font-family: var(--font-mono);
                    font-weight: 700;
                    font-size: 13px;
                    letter-spacing: 0.05em;
                }

                .edge-box {
                    font-weight: 800;
                    letter-spacing: 0.05em;
                }

                .dur-box {
                    font-family: var(--font-mono);
                    color: var(--text-secondary);
                    font-size: 12px;
                }

                /* Clean Grid */
                .clean-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
                    gap: 1px;
                    background: var(--border);
                    border: 1px solid var(--border);
                    margin-bottom: 48px;
                }

                .clean-cell {
                    background: var(--panel);
                    padding: 12px 16px;
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    font-size: 13px;
                    font-weight: 700;
                    letter-spacing: 0.02em;
                }

                .clean-cell .check {
                    color: var(--text-muted);
                    font-family: var(--font-mono);
                    font-size: 11px;
                }

                /* Footer */
                footer {
                    border-top: 1px solid var(--border);
                    padding-top: 24px;
                    display: flex;
                    justify-content: space-between;
                    font-size: 11px;
                    color: var(--text-muted);
                    letter-spacing: 0.1em;
                }
            </style>
        </head>
        <body>
            <div class="container">
                
                <!-- Masthead -->
                <div class="masthead">
                    <div class="title-block">
                        <h1>DELIVERY QC REPORT</h1>
                        <div class="subtitle">EDGE LINE DETECTION AUDIT // \(folderURL.lastPathComponent.uppercased())</div>
                    </div>
                    <div>
                        \(flaggedVideos.isEmpty ? "<div class='status-badge status-passed'>STATUS // PASSED</div>" : "<div class='status-badge status-flagged'>STATUS // \(flaggedVideos.count) FLAGGED</div>")
                    </div>
                </div>

                <!-- Meta Info Strip -->
                <div class="meta-strip">
                    <div class="meta-cell">
                        <div class="meta-label">TARGET FOLDER</div>
                        <div class="meta-value">\(folderURL.lastPathComponent.uppercased())</div>
                    </div>
                    <div class="meta-cell">
                        <div class="meta-label">TARGET COLOR</div>
                        <div class="meta-value">
                            <span class="color-sq" style="background:\(targetHex)"></span>
                            \(targetHex) (\(tolPercent)%)
                        </div>
                    </div>
                    <div class="meta-cell">
                        <div class="meta-label">EDGE MARGIN</div>
                        <div class="meta-value">\(config.edgeDepth) PX</div>
                    </div>
                    <div class="meta-cell">
                        <div class="meta-label">TIMESTAMP</div>
                        <div class="meta-value" style="font-size:14px; font-family:var(--font-mono)">\(dateString)</div>
                    </div>
                </div>

                <!-- Stats Numbers -->
                <div class="stats-strip">
                    <div class="stat-box">
                        <div class="num">\(String(format: "%02d", results.count))</div>
                        <div class="label">TOTAL SCANNED</div>
                    </div>
                    <div class="stat-box \(flaggedVideos.isEmpty ? "" : "highlight")">
                        <div class="num">\(String(format: "%02d", flaggedVideos.count))</div>
                        <div class="label">FLAGGED DEFECTS</div>
                    </div>
                    <div class="stat-box">
                        <div class="num">\(String(format: "%02d", cleanVideos.count))</div>
                        <div class="label">CLEAN PASSED</div>
                    </div>
                    <div class="stat-box">
                        <div class="num">\(String(format: "%02d", totalSegments))</div>
                        <div class="label">GLITCH SEGMENTS</div>
                    </div>
                </div>
        """
        
        // Flagged Videos Section
        if !flaggedVideos.isEmpty {
            html += """
                <div class="section-header">
                    <h2>FLAGGED DELIVERIES</h2>
                    <div class="count">[\(String(format: "%02d", flaggedVideos.count)) FILES]</div>
                </div>
            """
            
            for video in flaggedVideos {
                let segments = video.glitchSegments
                html += """
                <div class="card flagged">
                    <div class="card-header">
                        <div>
                            <div class="title">\(video.fileName.uppercased())</div>
                            <div class="meta">\(video.resolution) // \(String(format: "%.2f", video.fps)) FPS // \(video.totalFrames) FRAMES</div>
                        </div>
                        <div class="finder-tag">FINDER RED TAG APPLIED</div>
                    </div>
                    <table>
                        <thead>
                            <tr>
                                <th>#</th>
                                <th>LOCATION</th>
                                <th>TIMECODE RANGE</th>
                                <th>DURATION</th>
                                <th>FRAMES</th>
                                <th>COLOR</th>
                            </tr>
                        </thead>
                        <tbody>
                """
                
                for (idx, seg) in segments.enumerated() {
                    let tcDisplay = seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) &rarr; \(seg.endTimecode)"
                    let frameDisplay = seg.startFrame == seg.endFrame ? "\(seg.startFrame)" : "\(seg.startFrame) - \(seg.endFrame)"
                    let durationDisplay = seg.frameCount == 1 ? "1 FRAME (0.04S)" : "\(seg.frameCount) FRAMES (\(String(format: "%.2f", seg.durationSeconds))S)"
                    let colorHex = seg.detectedColor.hexString.uppercased()
                    
                    html += """
                            <tr>
                                <td style="color:var(--text-muted); font-family:var(--font-mono)">\(String(format: "%02d", idx + 1))</td>
                                <td class="edge-box">\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX)</td>
                                <td class="tc-text">\(tcDisplay)</td>
                                <td class="dur-box">\(durationDisplay)</td>
                                <td class="dur-box">[\(frameDisplay)]</td>
                                <td><span class="color-sq" style="background:\(colorHex)"></span> <span style="font-family:var(--font-mono); font-size:12px">\(colorHex)</span></td>
                            </tr>
                    """
                }
                
                html += """
                        </tbody>
                    </table>
                </div>
                """
            }
        }
        
        // Clean Videos Section
        html += """
                <div class="section-header" style="margin-top: 40px;">
                    <h2>PASSED DELIVERIES</h2>
                    <div class="count">[\(String(format: "%02d", cleanVideos.count)) FILES]</div>
                </div>
                <div class="clean-grid">
        """
        
        if cleanVideos.isEmpty {
            html += "<div class='clean-cell' style='color:var(--text-muted)'>NONE</div>"
        } else {
            for clean in cleanVideos {
                html += """
                <div class="clean-cell">
                    <span>\(clean.fileName.uppercased())</span>
                    <span class="check">[PASSED]</span>
                </div>
                """
            }
        }
        
        html += """
                </div>

                <footer>
                    <div>VIDEO QC ENGINE // APPLE SILICON NATIVE</div>
                    <div>AUTOMATED POST-PRODUCTION AUDIT</div>
                </footer>
            </div>
        </body>
        </html>
        """
        
        return html
    }
    
    // MARK: - Plain Text Report Generator (Clean & Minimal)
    
    public static func generateTextReport(
        folderURL: URL,
        config: QCConfig,
        results: [VideoQCResult],
        scanDate: Date = Date()
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy.MM.dd // HH:mm:ss"
        let dateString = dateFormatter.string(from: scanDate)
        
        let flaggedVideos = results.filter { $0.isFlagged }
        let cleanVideos = results.filter { !$0.isFlagged }
        let totalErrors = flaggedVideos.reduce(0) { $0 + $1.errorFrames.count }
        
        var report = ""
        report += "================================================================================\n"
        report += "QC // DELIVERY REPORT\n"
        report += "================================================================================\n"
        report += "DATE: \(dateString)\n"
        var configDetails = "TARGET COLOR: \(config.targetHex.uppercased()) (TOLERANCE: \(Int(config.tolerance * 100))% | MARGIN: \(config.edgeDepth)PX"
        if config.isBlackDetection {
            configDetails += " | BLACK MODE: \(config.enableExposureBoost ? "\(Int(config.exposureMultiplier))X GAIN" : "OFF")"
        }
        configDetails += ")\n"
        report += configDetails
        report += "FOLDER: \(folderURL.path)\n"
        report += "TOTAL SCANNED: \(results.count)\n"
        report += "FLAGGED: \(flaggedVideos.count) [FINDER RED TAG APPLIED]\n"
        report += "PASSED: \(cleanVideos.count)\n"
        report += "TOTAL ERROR FRAMES: \(totalErrors)\n"
        report += "================================================================================\n\n"
        
        if flaggedVideos.isEmpty {
            report += "STATUS // ALL FILES PASSED QC (NO EDGE LINES DETECTED)\n\n"
        } else {
            report += "--------------------------------------------------------------------------------\n"
            report += "FLAGGED DELIVERIES (\(flaggedVideos.count))\n"
            report += "--------------------------------------------------------------------------------\n\n"
            
            for flagged in flaggedVideos {
                report += "[FLAGGED] \(flagged.fileName.uppercased())\n"
                report += "  PATH: \(flagged.fileURL.path)\n"
                report += "  SPEC: \(flagged.resolution) // \(String(format: "%.2f", flagged.fps)) FPS // \(flagged.totalFrames) FRAMES\n"
                report += "  GLITCH OCCURRENCES: \(flagged.glitchSegments.count) (\(flagged.errorFrames.count) FRAMES TOTAL)\n"
                report += "  ------------------------------------------------------------------------------\n"
                report += "  #   TIMECODE RANGE                DURATION          LOCATION          COLOR\n"
                report += "  ------------------------------------------------------------------------------\n"
                
                for (idx, seg) in flagged.glitchSegments.enumerated() {
                    let num = String(format: "%02d", idx + 1)
                    let tcRange = seg.startTimecode == seg.endTimecode ? seg.startTimecode : "\(seg.startTimecode) -> \(seg.endTimecode)"
                    let tcPadded = tcRange.padding(toLength: 29, withPad: " ", startingAt: 0)
                    let durStr = "\(seg.frameCount) FRAMES (\(String(format: "%.2f", seg.durationSeconds))S)".padding(toLength: 18, withPad: " ", startingAt: 0)
                    let edgeStr = "\(seg.edge.rawValue.uppercased()) (\(seg.avgThickness)PX)".padding(toLength: 18, withPad: " ", startingAt: 0)
                    let color = seg.detectedColor.hexString.uppercased()
                    report += "  \(num)  \(tcPadded)\(durStr)\(edgeStr)\(color)\n"
                }
                report += "  ------------------------------------------------------------------------------\n\n"
            }
        }
        
        report += "================================================================================\n"
        report += "PASSED DELIVERIES (\(cleanVideos.count))\n"
        report += "================================================================================\n"
        if cleanVideos.isEmpty {
            report += "  [NONE]\n"
        } else {
            for clean in cleanVideos {
                report += "  [PASSED] \(clean.fileName.uppercased())\n"
            }
        }
        report += "================================================================================\n"
        
        return report
    }
    
    // MARK: - Save Reports
    
    /// Saves both .html and .txt reports and applies Red Finder tags to flagged videos
    @discardableResult
    public static func saveReport(
        folderURL: URL,
        config: QCConfig,
        results: [VideoQCResult]
    ) -> URL? {
        // 1. Tag flagged files with Red label in Finder
        tagFlaggedFilesInFinder(results: results)
        
        let fileDateFormatter = DateFormatter()
        fileDateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = fileDateFormatter.string(from: Date())
        
        // 2. Save HTML Report (Primary Swiss/Editorial Report)
        let htmlReportText = generateHTMLReport(folderURL: folderURL, config: config, results: results)
        let htmlFileName = "QC_Report_\(timestamp).html"
        let htmlFileURL = folderURL.appendingPathComponent(htmlFileName)
        try? htmlReportText.write(to: htmlFileURL, atomically: true, encoding: .utf8)
        
        // 3. Save TXT Report
        let txtReportText = generateTextReport(folderURL: folderURL, config: config, results: results)
        let txtFileName = "QC_Report_\(timestamp).txt"
        let txtFileURL = folderURL.appendingPathComponent(txtFileName)
        try? txtReportText.write(to: txtFileURL, atomically: true, encoding: .utf8)
        
        return htmlFileURL
    }
}
