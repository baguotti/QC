import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Vision
import CoreImage

public actor LogoSubtitleScanner {
    
    public struct TextScanProgress: Sendable {
        public let currentFileIndex: Int
        public let totalFiles: Int
        public let currentFileName: String
        public let currentFrame: Int
        public let totalFramesInFile: Int
        public let fps: Double
        public let recentTextSnippet: String
        public let flaggedVideosCount: Int
    }
    
    private var isCancelled = false
    
    public init() {}
    
    public func cancel() {
        self.isCancelled = true
    }
    
    // MARK: - Batch Processing
    
    public func scanBatch(
        videoURLs: [URL],
        config: TextQCConfig,
        progressHandler: @Sendable @escaping (TextScanProgress) -> Void
    ) async -> [VideoTextQCResult] {
        self.isCancelled = false
        var results: [VideoTextQCResult] = []
        var flaggedCount = 0
        
        for (index, url) in videoURLs.enumerated() {
            if isCancelled { break }
            
            let fileIndex = index + 1
            let fileName = url.lastPathComponent
            let currentFlagged = flaggedCount
            
            let result = await scanSingleVideo(url: url, config: config) { currentFrame, totalFrames, currentFps, snippet in
                let progress = TextScanProgress(
                    currentFileIndex: fileIndex,
                    totalFiles: videoURLs.count,
                    currentFileName: fileName,
                    currentFrame: currentFrame,
                    totalFramesInFile: totalFrames,
                    fps: currentFps,
                    recentTextSnippet: snippet,
                    flaggedVideosCount: currentFlagged
                )
                progressHandler(progress)
            }
            
            if let result = result {
                if result.isFlagged {
                    flaggedCount += 1
                    if result.isCleanViolation && config.strictCleanEnforcement {
                        ReportWriter.setRedTag(for: url)
                    }
                }
                results.append(result)
            }
        }
        
        return results
    }
    
    // MARK: - Single Video Scanner
    
    public func scanSingleVideo(
        url: URL,
        config: TextQCConfig,
        frameProgress: @Sendable @escaping (Int, Int, Double, String) -> Void
    ) async -> VideoTextQCResult? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else { return nil }
            
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            guard durationSeconds > 0 else { return nil }
            
            var nominalFps = Double(try await track.load(.nominalFrameRate))
            if nominalFps <= 0 { nominalFps = 25.0 }
            let totalFrames = Int(round(durationSeconds * nominalFps))
            
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let isTransposed = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
            let width = Int(isTransposed ? naturalSize.height : naturalSize.width)
            let height = Int(isTransposed ? naturalSize.width : naturalSize.height)
            let resolution = "\(width)x\(height)"
            
            // Frame stepping for OCR (e.g., sample every 0.33s for high speed and full coverage)
            let sampleStepFrames = max(1, Int(round(nominalFps / max(1.0, config.sampleRateFps))))
            
            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            trackOutput.alwaysCopiesSampleData = false
            reader.add(trackOutput)
            
            guard reader.startReading() else { return nil }
            
            var frameIdx = 0
            var rawDetections: [(frame: Int, timecode: String, text: [TextDetection], logos: [LogoDetection])] = []
            
            let startTime = CFAbsoluteTimeGetCurrent()
            var recentSnippet = ""
            
            while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                if isCancelled {
                    reader.cancelReading()
                    break
                }
                
                defer { frameIdx += 1 }
                
                // Only analyze sample step frames
                guard frameIdx % sampleStepFrames == 0 else { continue }
                
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                
                let tc = TimecodeFormatter.format(frameIndex: frameIdx, fps: nominalFps)
                
                // 1. Text Recognition
                var textDetections: [TextDetection] = []
                if config.detectSubtitles {
                    textDetections = analyzeFrameForText(pixelBuffer: imageBuffer, region: config.region)
                    if let firstText = textDetections.first?.text {
                        recentSnippet = firstText
                    }
                }
                
                // 2. Logo / Graphic Bug Detection
                var logoDetections: [LogoDetection] = []
                if config.detectLogos {
                    logoDetections = analyzeFrameForLogos(pixelBuffer: imageBuffer)
                }
                
                if !textDetections.isEmpty || !logoDetections.isEmpty {
                    rawDetections.append((frame: frameIdx, timecode: tc, text: textDetections, logos: logoDetections))
                }
                
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let processedFps = elapsed > 0 ? Double(frameIdx) / elapsed : 0.0
                frameProgress(frameIdx, totalFrames, processedFps, recentSnippet)
            }
            
            // Group continuous detections into segments
            let (subSegments, logoSegments) = groupDetections(
                raw: rawDetections,
                fps: nominalFps,
                sampleStepFrames: sampleStepFrames
            )
            
            // Filename Classification & Validation
            let lowerName = url.lastPathComponent.lowercased()
            let isCleanName = lowerName.contains("clean") || lowerName.contains("textless") || lowerName.contains("no_sub") || lowerName.contains("unsubbed")
            let isSubbedName = lowerName.contains("sub") || lowerName.contains("subbed") || lowerName.contains("subtitled") || lowerName.contains("caption")
            
            let expectedContent: VideoExpectedContent
            if isCleanName {
                expectedContent = .cleanFeed
            } else if isSubbedName {
                expectedContent = .subtitled
            } else {
                expectedContent = .unspecified
            }
            
            var isCleanViolation = false
            var isMissingExpectedSubs = false
            var statusSummary = "CLEAN / NO TEXT"
            
            if isCleanName && (!subSegments.isEmpty || !logoSegments.isEmpty) {
                isCleanViolation = true
                let count = subSegments.count + logoSegments.count
                statusSummary = "VIOLATION: NAMED 'CLEAN' BUT CONTAINS \(count) TEXT/LOGO SEGMENT(S)"
            } else if isSubbedName && subSegments.isEmpty {
                isMissingExpectedSubs = true
                statusSummary = "WARNING: NAMED 'SUBTITLED' BUT NO ON-SCREEN TEXT DETECTED"
            } else if !subSegments.isEmpty {
                statusSummary = "\(subSegments.count) SUBTITLE SEGMENT(S) DETECTED"
            } else if !logoSegments.isEmpty {
                statusSummary = "\(logoSegments.count) LOGO/GRAPHIC(S) DETECTED"
            }
            
            return VideoTextQCResult(
                fileURL: url,
                fileName: url.lastPathComponent,
                totalFrames: totalFrames,
                durationSeconds: durationSeconds,
                fps: nominalFps,
                resolution: resolution,
                subtitleSegments: subSegments,
                logoSegments: logoSegments,
                expectedContent: expectedContent,
                isCleanViolation: isCleanViolation,
                isMissingExpectedSubs: isMissingExpectedSubs,
                statusSummary: statusSummary
            )
        } catch {
            return nil
        }
    }
    
    // MARK: - Vision OCR Text Analysis
    
    private nonisolated func analyzeFrameForText(pixelBuffer: CVPixelBuffer, region: SubtitleRegion) -> [TextDetection] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "it-IT", "fr-FR", "es-ES", "de-DE"]
        
        // Region of Interest (Normalized 0.0 - 1.0 from bottom-left origin in Vision)
        switch region {
        case .lowerThird:
            request.regionOfInterest = CGRect(x: 0.05, y: 0.02, width: 0.90, height: 0.35)
        case .center:
            request.regionOfInterest = CGRect(x: 0.10, y: 0.30, width: 0.80, height: 0.40)
        case .fullFrame:
            request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results else { return [] }
            
            var detections: [TextDetection] = []
            for obs in observations {
                guard let topCandidate = obs.topCandidates(1).first else { continue }
                let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 2 && topCandidate.confidence >= 0.4 else { continue }
                
                let y = obs.boundingBox.origin.y
                let location = y < 0.35 ? "Lower Third" : (y > 0.65 ? "Top" : "Center")
                
                detections.append(TextDetection(
                    text: text,
                    confidence: topCandidate.confidence,
                    boundingBox: obs.boundingBox,
                    location: location
                ))
            }
            return detections
        } catch {
            return []
        }
    }
    
    // MARK: - Logo & Graphic Bug Detection
    
    private nonisolated func analyzeFrameForLogos(pixelBuffer: CVPixelBuffer) -> [LogoDetection] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        var detections: [LogoDetection] = []
        
        // Check 4 Corner Regions (width: 15%, height: 15%) for solid high-contrast white or black graphics
        let cornerW = max(20, Int(Double(width) * 0.15))
        let cornerH = max(20, Int(Double(height) * 0.15))
        
        let corners: [(name: String, startX: Int, startY: Int)] = [
            ("Top-Left Corner", 10, 10),
            ("Top-Right Corner", width - cornerW - 10, 10),
            ("Bottom-Left Corner", 10, height - cornerH - 10),
            ("Bottom-Right Corner", width - cornerW - 10, height - cornerH - 10)
        ]
        
        for c in corners {
            guard c.startX >= 0 && c.startY >= 0 && (c.startX + cornerW) <= width && (c.startY + cornerH) <= height else { continue }
            
            var whitePixels = 0
            var blackPixels = 0
            let totalSampled = (cornerW / 2) * (cornerH / 2)
            
            for y in stride(from: c.startY, to: c.startY + cornerH, by: 2) {
                let rowOffset = y * bytesPerRow
                for x in stride(from: c.startX, to: c.startX + cornerW, by: 2) {
                    let pixelOffset = rowOffset + (x * 4)
                    let b = buffer[pixelOffset]
                    let g = buffer[pixelOffset + 1]
                    let r = buffer[pixelOffset + 2]
                    
                    if r > 240 && g > 240 && b > 240 {
                        whitePixels += 1
                    } else if r < 15 && g < 15 && b < 15 {
                        blackPixels += 1
                    }
                }
            }
            
            let whiteRatio = Double(whitePixels) / Double(totalSampled)
            let blackRatio = Double(blackPixels) / Double(totalSampled)
            
            if whiteRatio > 0.20 && whiteRatio < 0.85 {
                detections.append(LogoDetection(
                    typeDescription: "High-Contrast White Graphic / Logo",
                    location: c.name,
                    boundingBox: CGRect(x: Double(c.startX)/Double(width), y: Double(c.startY)/Double(height), width: Double(cornerW)/Double(width), height: Double(cornerH)/Double(height))
                ))
            } else if blackRatio > 0.20 && blackRatio < 0.85 {
                detections.append(LogoDetection(
                    typeDescription: "High-Contrast Black Graphic / Bug",
                    location: c.name,
                    boundingBox: CGRect(x: Double(c.startX)/Double(width), y: Double(c.startY)/Double(height), width: Double(cornerW)/Double(width), height: Double(cornerH)/Double(height))
                ))
            }
        }
        
        return detections
    }
    
    // MARK: - Grouping Engine
    
    private nonisolated func groupDetections(
        raw: [(frame: Int, timecode: String, text: [TextDetection], logos: [LogoDetection])],
        fps: Double,
        sampleStepFrames: Int
    ) -> (subtitles: [SubtitleSegment], logos: [LogoSegment]) {
        var subSegments: [SubtitleSegment] = []
        var logoSegments: [LogoSegment] = []
        
        guard !raw.isEmpty else { return ([], []) }
        
        // 1. Group Subtitles
        var currentSubStart: (frame: Int, tc: String, text: String, location: String)? = nil
        var currentSubLastFrame: Int = 0
        var currentSubLastTC: String = ""
        
        for item in raw {
            if let firstText = item.text.first {
                if let current = currentSubStart {
                    let frameGap = item.frame - currentSubLastFrame
                    if frameGap <= sampleStepFrames * 3 {
                        // Extend current segment
                        currentSubLastFrame = item.frame
                        currentSubLastTC = item.timecode
                    } else {
                        // Close previous segment
                        let count = currentSubLastFrame - current.frame + 1
                        let dur = Double(count) / fps
                        subSegments.append(SubtitleSegment(
                            startFrame: current.frame,
                            endFrame: currentSubLastFrame,
                            startTimecode: current.tc,
                            endTimecode: currentSubLastTC,
                            text: current.text,
                            location: current.location,
                            durationSeconds: dur,
                            frameCount: count
                        ))
                        currentSubStart = (frame: item.frame, tc: item.timecode, text: firstText.text, location: firstText.location)
                        currentSubLastFrame = item.frame
                        currentSubLastTC = item.timecode
                    }
                } else {
                    currentSubStart = (frame: item.frame, tc: item.timecode, text: firstText.text, location: firstText.location)
                    currentSubLastFrame = item.frame
                    currentSubLastTC = item.timecode
                }
            }
        }
        
        if let current = currentSubStart {
            let count = currentSubLastFrame - current.frame + 1
            let dur = Double(count) / fps
            subSegments.append(SubtitleSegment(
                startFrame: current.frame,
                endFrame: currentSubLastFrame,
                startTimecode: current.tc,
                endTimecode: currentSubLastTC,
                text: current.text,
                location: current.location,
                durationSeconds: dur,
                frameCount: count
            ))
        }
        
        // 2. Group Logos (persistent across at least 2 sample intervals)
        var currentLogoStart: (frame: Int, tc: String, desc: String, loc: String)? = nil
        var currentLogoLastFrame: Int = 0
        var currentLogoLastTC: String = ""
        var currentLogoHits: Int = 0
        
        for item in raw {
            if let firstLogo = item.logos.first {
                if let current = currentLogoStart {
                    let frameGap = item.frame - currentLogoLastFrame
                    if frameGap <= sampleStepFrames * 3 && current.loc == firstLogo.location {
                        currentLogoLastFrame = item.frame
                        currentLogoLastTC = item.timecode
                        currentLogoHits += 1
                    } else {
                        if currentLogoHits >= 2 {
                            let count = currentLogoLastFrame - current.frame + 1
                            let dur = Double(count) / fps
                            logoSegments.append(LogoSegment(
                                startFrame: current.frame,
                                endFrame: currentLogoLastFrame,
                                startTimecode: current.tc,
                                endTimecode: currentLogoLastTC,
                                description: current.desc,
                                location: current.loc,
                                durationSeconds: dur,
                                frameCount: count
                            ))
                        }
                        currentLogoStart = (frame: item.frame, tc: item.timecode, desc: firstLogo.typeDescription, loc: firstLogo.location)
                        currentLogoLastFrame = item.frame
                        currentLogoLastTC = item.timecode
                        currentLogoHits = 1
                    }
                } else {
                    currentLogoStart = (frame: item.frame, tc: item.timecode, desc: firstLogo.typeDescription, loc: firstLogo.location)
                    currentLogoLastFrame = item.frame
                    currentLogoLastTC = item.timecode
                    currentLogoHits = 1
                }
            }
        }
        
        if let current = currentLogoStart, currentLogoHits >= 2 {
            let count = currentLogoLastFrame - current.frame + 1
            let dur = Double(count) / fps
            logoSegments.append(LogoSegment(
                startFrame: current.frame,
                endFrame: currentLogoLastFrame,
                startTimecode: current.tc,
                endTimecode: currentLogoLastTC,
                description: current.desc,
                location: current.loc,
                durationSeconds: dur,
                frameCount: count
            ))
        }
        
        return (subtitles: subSegments, logos: logoSegments)
    }
    
    // MARK: - CSV & HTML Reports
    
    public static func generateTextQCCSV(results: [VideoTextQCResult]) -> String {
        var csv = "File Name,Status,Expected Content,Subtitle Count,Logo Count,First Detected Text,Timecode Range\n"
        
        func escapeCSV(_ str: String) -> String {
            if str.contains(",") || str.contains("\"") || str.contains("\n") {
                let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            return str
        }
        
        for r in results {
            let status = r.isCleanViolation ? "CLEAN VIOLATION" : (r.isFlagged ? "FLAGGED" : "PASSED")
            let firstText = r.subtitleSegments.first?.text ?? (r.logoSegments.first?.description ?? "--")
            let tcRange = r.subtitleSegments.first.map { "\($0.startTimecode) -> \($0.endTimecode)" } ?? "--"
            csv += "\(escapeCSV(r.fileName)),\(escapeCSV(status)),\(escapeCSV(r.expectedContent.rawValue)),\(r.subtitleSegments.count),\(r.logoSegments.count),\(escapeCSV(firstText)),\(escapeCSV(tcRange))\n"
        }
        
        return csv
    }
    
    public static func generateTextQCHTML(results: [VideoTextQCResult], folderName: String) -> String {
        let violations = results.filter { $0.isCleanViolation }
        let rawCSV = generateTextQCCSV(results: results)
        
        var html = """
        <!DOCTYPE html>
        <html lang="en" data-theme="dark">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>TEXT & LOGO AUDIT REPORT // \(folderName.uppercased())</title>
            <style>
                @import url('https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@400;600;700;800;900&family=JetBrains+Mono:wght@400;500;700&display=swap');

                :root {
                    --bg: #0a0a0a;
                    --panel: #111111;
                    --border: #222222;
                    --border-strong: #333333;
                    --text: #ffffff;
                    --text-secondary: #888888;
                    --text-muted: #555555;
                    --red: #ff3333;
                    --red-bg: rgba(255, 51, 51, 0.12);
                    --font-heading: 'Barlow Condensed', 'Helvetica Neue', 'Helvetica', -apple-system, sans-serif;
                    --font-mono: 'JetBrains Mono', 'SF Mono', 'Menlo', monospace;
                }

                [data-theme="light"] {
                    --bg: #f8f8f8;
                    --panel: #ffffff;
                    --border: #e0e0e0;
                    --border-strong: #cccccc;
                    --text: #0a0a0a;
                    --text-secondary: #555555;
                    --text-muted: #888888;
                    --red: #d32f2f;
                    --red-bg: rgba(211, 47, 47, 0.08);
                }

                * { box-sizing: border-box; margin: 0; padding: 0; }

                body {
                    background-color: var(--bg);
                    color: var(--text);
                    font-family: var(--font-heading);
                    text-transform: uppercase;
                    padding: 48px 32px;
                    line-height: 1.2;
                }

                .container { max-width: 1240px; margin: 0 auto; }

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

                .header-actions { display: flex; gap: 10px; }
                .action-btn {
                    background: var(--panel);
                    color: var(--text);
                    border: 1px solid var(--border-strong);
                    padding: 8px 14px;
                    font-family: var(--font-mono);
                    font-size: 11px;
                    font-weight: 700;
                    cursor: pointer;
                    text-transform: uppercase;
                }
                .action-btn-primary { background: var(--text); color: var(--bg); border-color: var(--text); }

                /* Stats Strip */
                .stats-strip {
                    display: grid;
                    grid-template-columns: repeat(4, 1fr);
                    gap: 16px;
                    margin-bottom: 36px;
                }

                .stat-box {
                    border-top: 1px solid var(--border-strong);
                    padding-top: 12px;
                }

                .stat-box .num {
                    font-size: 38px;
                    font-weight: 900;
                    line-height: 1;
                }

                .stat-box.highlight .num { color: var(--red); }

                .stat-box .label {
                    font-size: 11px;
                    font-weight: 700;
                    letter-spacing: 0.15em;
                    color: var(--text-secondary);
                    margin-top: 6px;
                }

                /* Cards */
                .card {
                    background: var(--panel);
                    border: 1px solid var(--border);
                    margin-bottom: 24px;
                }

                .card.violation {
                    border-left: 4px solid var(--red);
                    background: var(--red-bg);
                }

                .card-header {
                    padding: 16px 20px;
                    border-bottom: 1px solid var(--border);
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                }

                .card-header .fn {
                    font-size: 18px;
                    font-weight: 800;
                    letter-spacing: 0.02em;
                }

                .badge-violation {
                    background: var(--red);
                    color: white;
                    padding: 4px 8px;
                    font-family: var(--font-mono);
                    font-size: 10px;
                    font-weight: 800;
                }

                table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 12px;
                }

                th {
                    background: rgba(0,0,0,0.2);
                    color: var(--text-muted);
                    font-size: 10px;
                    font-weight: 700;
                    padding: 10px 16px;
                    text-align: left;
                    border-bottom: 1px solid var(--border);
                }

                td {
                    padding: 12px 16px;
                    border-bottom: 1px solid var(--border);
                    font-weight: 600;
                }

                tr:last-child td { border-bottom: none; }
                .mono { font-family: var(--font-mono); }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="masthead">
                    <div class="title-block">
                        <h1>LOGO & SUBTITLE AUDIT</h1>
                        <div class="subtitle">ON-SCREEN TEXT & CLEAN-FEED COMPLIANCE // \(folderName.uppercased())</div>
                    </div>
                    <div class="header-actions">
                        <button class="action-btn action-btn-primary" onclick="openGoogleSheets()">[ OPEN GOOGLE SHEETS ]</button>
                        <button class="action-btn" onclick="toggleTheme()">[ THEME ]</button>
                    </div>
                </div>

                <div class="stats-strip">
                    <div class="stat-box">
                        <div class="num">\(String(format: "%02d", results.count))</div>
                        <div class="label">SCANNED DELIVERIES</div>
                    </div>
                    <div class="stat-box \(violations.isEmpty ? "" : "highlight")">
                        <div class="num">\(String(format: "%02d", violations.count))</div>
                        <div class="label">CLEAN FEED VIOLATIONS</div>
                    </div>
                    <div class="stat-box">
                        <div class="num">\(String(format: "%02d", results.filter { $0.hasSubtitles }.count))</div>
                        <div class="label">SUBTITLED ASSETS</div>
                    </div>
                    <div class="stat-box">
                        <div class="num">\(String(format: "%02d", results.filter { $0.hasLogos }.count))</div>
                        <div class="label">LOGOS & BUGS DETECTED</div>
                    </div>
                </div>
        """
        
        for r in results {
            let isV = r.isCleanViolation
            html += """
                <div class="card \(isV ? "violation" : "")">
                    <div class="card-header">
                        <div>
                            <div class="fn">\(r.fileName.uppercased())</div>
                            <div style="font-size:11px; color:var(--text-secondary); margin-top:3px;" class="mono">
                                \(r.resolution) // \(String(format: "%.2f", r.fps)) FPS // EXPECTED: \(r.expectedContent.rawValue)
                            </div>
                        </div>
                        <div>
                            \(isV ? "<span class='badge-violation'>[ VIOLATION: NAMED CLEAN BUT HAS TEXT/LOGOS ]</span>" : (r.hasSubtitles ? "<span class='action-btn'>[ SUBTITLED ]</span>" : "<span class='action-btn'>[ CLEAN FEED ]</span>"))
                        </div>
                    </div>
            """
            
            if !r.subtitleSegments.isEmpty {
                html += """
                    <table>
                        <thead>
                            <tr>
                                <th>#</th>
                                <th>LOCATION</th>
                                <th>TIMECODE RANGE</th>
                                <th>DURATION</th>
                                <th>DETECTED OCR SUBTITLE TEXT</th>
                            </tr>
                        </thead>
                        <tbody>
                """
                for (sIdx, sub) in r.subtitleSegments.enumerated() {
                    html += """
                            <tr>
                                <td class="mono" style="color:var(--text-muted)">\(String(format: "%02d", sIdx + 1))</td>
                                <td>\(sub.location.uppercased())</td>
                                <td class="mono">\(sub.startTimecode) -> \(sub.endTimecode)</td>
                                <td class="mono">\(String(format: "%.2fs", sub.durationSeconds)) (\(sub.frameCount) F)</td>
                                <td style="font-style:italic; font-weight:700;">"\(sub.text.uppercased())"</td>
                            </tr>
                    """
                }
                html += """
                        </tbody>
                    </table>
                """
            }
            
            html += """
                </div>
            """
        }
        
        html += """
            </div>

            <script>
                const csvData = `\(rawCSV.replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "${", with: "\\${"))`;

                function toggleTheme() {
                    const current = document.documentElement.getAttribute('data-theme') || 'dark';
                    const next = current === 'dark' ? 'light' : 'dark';
                    document.documentElement.setAttribute('data-theme', next);
                }

                function openGoogleSheets() {
                    navigator.clipboard.writeText(csvData).then(() => {
                        window.open('https://sheets.new', '_blank');
                    }).catch(() => {
                        window.open('https://sheets.new', '_blank');
                    });
                }
            </script>
        </body>
        </html>
        """
        
        return html
    }
}
