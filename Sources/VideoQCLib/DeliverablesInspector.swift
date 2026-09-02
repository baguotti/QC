import Foundation
@preconcurrency import AVFoundation
import CoreMedia

public struct DeliverablesInspector: Sendable {
    
    public init() {}
    
    // MARK: - Inspection Engine
    
    /// Inspects a single video file URL and extracts all delivery specifications
    public static func inspectFile(url: URL) async -> DeliverableAsset? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else { return nil }
            
            // 1. Dimensions & Transform
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let isTransposed = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
            
            let rawWidth = Int(naturalSize.width)
            let rawHeight = Int(naturalSize.height)
            let width = isTransposed ? rawHeight : rawWidth
            let height = isTransposed ? rawWidth : rawHeight
            let resolutionString = "\(width) x \(height)"
            let aspectRatioString = calculateAspectRatio(width: width, height: height)
            
            // 2. Framerate & Duration
            var fps = Double(try await videoTrack.load(.nominalFrameRate))
            if fps <= 0 { fps = 25.0 }
            
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            let totalFrames = Int(round(durationSeconds * fps))
            let timecode = TimecodeFormatter.format(frameIndex: totalFrames, fps: fps)
            let formattedDuration = String(format: "%.2fs", durationSeconds)
            
            // 3. File Size
            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
            let fileSizeBytes = Int64(resourceValues?.fileSize ?? 0)
            let formattedFileSize = formatFileSize(bytes: fileSizeBytes)
            
            // 4. Video Codec
            let videoCodec = await extractVideoCodec(track: videoTrack)
            
            // 5. Audio Info (Codec, Bitrate, Sub-Details, Full Config or NONE)
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let audioInfo = await extractAudioInfo(tracks: audioTracks)
            
            // 6. Container
            let container = url.pathExtension.uppercased()
            
            // 7. Filename vs Attributes Cross-Reference Validation
            let validation = validateFilename(
                fileName: url.lastPathComponent,
                durationSeconds: durationSeconds,
                aspectRatio: aspectRatioString,
                width: width,
                height: height
            )
            
            return DeliverableAsset(
                fileURL: url,
                fileName: url.lastPathComponent,
                fileSizeBytes: fileSizeBytes,
                formattedFileSize: formattedFileSize,
                width: width,
                height: height,
                resolutionString: resolutionString,
                aspectRatioString: aspectRatioString,
                durationSeconds: durationSeconds,
                formattedDuration: formattedDuration,
                totalFrames: totalFrames,
                timecode: timecode,
                fps: fps,
                videoCodec: videoCodec,
                audioCodec: audioInfo.codec,
                audioBitrate: audioInfo.bitrate,
                audioFormatDetail: audioInfo.subDetail,
                audioConfig: audioInfo.fullDesc,
                container: container,
                validation: validation
            )
        } catch {
            return nil
        }
    }
    
    /// Inspects a batch of video files in parallel
    public static func inspectBatch(urls: [URL]) async -> [DeliverableAsset] {
        var assets: [DeliverableAsset] = []
        for url in urls {
            if let asset = await inspectFile(url: url) {
                assets.append(asset)
            }
        }
        return assets
    }
    
    // MARK: - Cross-Reference Validation
    
    /// Validates filename against actual attributes (e.g. filename says 15sec but video is 25s, or says 9x16 but video is 16:9)
    public static func validateFilename(
        fileName: String,
        durationSeconds: Double,
        aspectRatio: String,
        width: Int,
        height: Int
    ) -> DeliverableValidation {
        var isDurationMismatch = false
        var expectedDurationSeconds: Double? = nil
        var durationMismatchDetail: String? = nil
        
        var isRatioMismatch = false
        var expectedRatioString: String? = nil
        var ratioMismatchDetail: String? = nil
        
        let lowerName = fileName.lowercased()
        
        // 1. Duration validation: matches e.g. "15sec", "15_sec", "15s", "15 s", "15seconds", "15-sec"
        let durationPattern = #"(?:^|[_\s\-\.])([0-9]{1,3})\s*(?:sec|secs|seconds|s)(?:$|[_\s\-\.])"#
        if let regex = try? NSRegularExpression(pattern: durationPattern, options: .caseInsensitive) {
            let nsString = lowerName as NSString
            let matches = regex.matches(in: lowerName, range: NSRange(location: 0, length: nsString.length))
            if let firstMatch = matches.first, firstMatch.numberOfRanges > 1 {
                let matchedNumberStr = nsString.substring(with: firstMatch.range(at: 1))
                if let secVal = Double(matchedNumberStr), secVal > 0 && secVal <= 600 {
                    expectedDurationSeconds = secVal
                    // Allow up to 1.5s tolerance for commercial frame rounding (e.g. 15.04s is 15s)
                    if abs(durationSeconds - secVal) > 1.5 {
                        isDurationMismatch = true
                        let formattedActual = String(format: "%.1fs", durationSeconds)
                        durationMismatchDetail = "NAME SAYS \(Int(secVal))S (ACTUAL: \(formattedActual))"
                    }
                }
            }
        }
        
        // 2. Aspect Ratio validation: matches 16x9, 9x16, 4x5, 5x4, 1x1, 4x3, 3x4, 21x9, square
        let ratioPattern = #"(?:^|[_\s\-\.])(16[x_]9|9[x_]16|4[x_]5|5[x_]4|1[x_]1|4[x_]3|3[x_]4|21[x_]9|square)(?:$|[_\s\-\.])"#
        if let regex = try? NSRegularExpression(pattern: ratioPattern, options: .caseInsensitive) {
            let nsString = lowerName as NSString
            let matches = regex.matches(in: lowerName, range: NSRange(location: 0, length: nsString.length))
            if let firstMatch = matches.first, firstMatch.numberOfRanges > 1 {
                let rawMatched = nsString.substring(with: firstMatch.range(at: 1))
                let normalizedExpected: String
                switch rawMatched {
                case "16x9", "16_9": normalizedExpected = "16:9"
                case "9x16", "9_16": normalizedExpected = "9:16"
                case "4x5", "4_5": normalizedExpected = "4:5"
                case "5x4", "5_4": normalizedExpected = "5:4"
                case "1x1", "1_1", "square": normalizedExpected = "1:1"
                case "4x3", "4_3": normalizedExpected = "4:3"
                case "3x4", "3_4": normalizedExpected = "3:4"
                case "21x9", "21_9": normalizedExpected = "21:9"
                default: normalizedExpected = rawMatched.replacingOccurrences(of: "_", with: ":").replacingOccurrences(of: "x", with: ":")
                }
                
                expectedRatioString = normalizedExpected
                if aspectRatio != normalizedExpected {
                    isRatioMismatch = true
                    ratioMismatchDetail = "NAME SAYS \(normalizedExpected) (ACTUAL: \(aspectRatio))"
                }
            }
        }
        
        return DeliverableValidation(
            isDurationMismatch: isDurationMismatch,
            expectedDurationSeconds: expectedDurationSeconds,
            durationMismatchDetail: durationMismatchDetail,
            isRatioMismatch: isRatioMismatch,
            expectedRatioString: expectedRatioString,
            ratioMismatchDetail: ratioMismatchDetail
        )
    }
    
    // MARK: - Format Helpers
    
    public static func calculateAspectRatio(width: Int, height: Int) -> String {
        guard width > 0 && height > 0 else { return "--" }
        
        let ratio = Double(width) / Double(height)
        
        // Common standard ratios check
        if abs(ratio - (16.0 / 9.0)) < 0.02 { return "16:9" }
        if abs(ratio - (9.0 / 16.0)) < 0.02 { return "9:16" }
        if abs(ratio - 1.0) < 0.02 { return "1:1" }
        if abs(ratio - (4.0 / 5.0)) < 0.02 { return "4:5" }
        if abs(ratio - (5.0 / 4.0)) < 0.02 { return "5:4" }
        if abs(ratio - (4.0 / 3.0)) < 0.02 { return "4:3" }
        if abs(ratio - (3.0 / 4.0)) < 0.02 { return "3:4" }
        if abs(ratio - (21.0 / 9.0)) < 0.05 { return "21:9" }
        if abs(ratio - 2.39) < 0.05 { return "2.39:1" }
        if abs(ratio - 1.85) < 0.05 { return "1.85:1" }
        
        // GCD fallback
        func gcd(_ a: Int, _ b: Int) -> Int {
            var a = a, b = b
            while b != 0 {
                let temp = b
                b = a % b
                a = temp
            }
            return a
        }
        let divisor = gcd(width, height)
        if divisor > 10 && (width / divisor) < 30 {
            return "\(width / divisor):\(height / divisor)"
        }
        
        return String(format: "%.2f:1", ratio)
    }
    
    public static func formatFileSize(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else if kb >= 1.0 {
            return String(format: "%.0f KB", kb)
        } else {
            return "\(bytes) B"
        }
    }
    
    private static func extractVideoCodec(track: AVAssetTrack) async -> String {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let desc = descriptions.first else {
            return "UNKNOWN"
        }
        
        let subType = CMFormatDescriptionGetMediaSubType(desc)
        switch subType {
        case kCMVideoCodecType_AppleProRes422HQ: return "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        case kCMVideoCodecType_AppleProRes422LT: return "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: return "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
        case kCMVideoCodecType_AppleProRes4444XQ: return "ProRes 4444 XQ"
        case kCMVideoCodecType_H264: return "H.264 (AVC)"
        case kCMVideoCodecType_HEVC: return "H.265 (HEVC)"
        case kCMVideoCodecType_HEVCWithAlpha: return "HEVC + Alpha"
        default:
            let fourCC = fourCCToString(subType)
            return fourCC.isEmpty ? "Video" : fourCC
        }
    }
    
    /// Extracts audio codec, bitrate, sample rate, and channels. If no audio is present, returns "NONE".
    public static func extractAudioInfo(tracks: [AVAssetTrack]) async -> (codec: String, bitrate: String, subDetail: String, fullDesc: String) {
        guard let audioTrack = tracks.first else {
            return (codec: "NONE", bitrate: "--", subDetail: "", fullDesc: "NONE")
        }
        
        guard let descriptions = try? await audioTrack.load(.formatDescriptions),
              let desc = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return (codec: "AUDIO", bitrate: "--", subDetail: "", fullDesc: "AUDIO")
        }
        
        // 1. Codec Identification
        let formatID = asbd.mFormatID
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        var codecName = ""
        
        switch formatID {
        case kAudioFormatLinearPCM:
            if bitsPerChannel > 0 {
                codecName = "PCM (\(bitsPerChannel)-bit)"
            } else {
                codecName = "Linear PCM"
            }
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_Spatial:
            codecName = "AAC"
        case kAudioFormatAppleLossless:
            codecName = "ALAC"
        case kAudioFormatAC3:
            codecName = "AC-3 (Dolby Digital)"
        case kAudioFormatEnhancedAC3:
            codecName = "E-AC-3"
        case kAudioFormatMPEGLayer3:
            codecName = "MP3"
        case kAudioFormatOpus:
            codecName = "Opus"
        case kAudioFormatFLAC:
            codecName = "FLAC"
        default:
            let fourCC = fourCCToString(formatID)
            codecName = fourCC.isEmpty ? "Audio" : fourCC
        }
        
        // 2. Sample Rate & Channels
        let channels = Int(asbd.mChannelsPerFrame)
        let sampleRate = Int(asbd.mSampleRate)
        let rateStr = sampleRate > 0 ? (sampleRate % 1000 == 0 ? "\(sampleRate / 1000)kHz" : String(format: "%.1fkHz", Double(sampleRate) / 1000.0)) : ""
        
        let channelStr: String
        if channels == 1 {
            channelStr = "Mono (1ch)"
        } else if channels == 2 {
            channelStr = "Stereo (2ch)"
        } else if channels == 6 {
            channelStr = "5.1 Surround"
        } else if channels == 8 {
            channelStr = "7.1 Surround"
        } else if channels > 0 {
            channelStr = "\(channels)ch"
        } else {
            channelStr = ""
        }
        
        // 3. Bitrate Calculation / Estimation
        var bitrateKbps: Int = 0
        let loadedRate = try? await audioTrack.load(.estimatedDataRate)
        let estimatedRate = Double(loadedRate ?? 0)
        
        if estimatedRate > 0 {
            bitrateKbps = Int(round(estimatedRate / 1000.0))
        } else if formatID == kAudioFormatLinearPCM && sampleRate > 0 && channels > 0 {
            let bits = bitsPerChannel > 0 ? bitsPerChannel : 16
            let calcRate = Double(sampleRate * channels * bits)
            bitrateKbps = Int(round(calcRate / 1000.0))
        }
        
        let bitrateStr: String
        if bitrateKbps > 0 {
            bitrateStr = "\(bitrateKbps) kbps"
        } else {
            bitrateStr = "--"
        }
        
        // 4. Sub-Details (only sample rate & channels, e.g. "48kHz • Stereo")
        var subParts: [String] = []
        if !rateStr.isEmpty { subParts.append(rateStr) }
        if !channelStr.isEmpty { subParts.append(channelStr) }
        let subDetail = subParts.joined(separator: " • ")
        
        // 5. Full combined description for CSV / tooltips
        var fullParts: [String] = [codecName]
        if bitrateStr != "--" { fullParts.append(bitrateStr) }
        if !subDetail.isEmpty { fullParts.append(subDetail) }
        let fullDesc = fullParts.joined(separator: " • ")
        
        return (codec: codecName, bitrate: bitrateStr, subDetail: subDetail, fullDesc: fullDesc)
    }
    
    private static func fourCCToString(_ fourCC: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((fourCC >> 24) & 0xff),
            UInt8((fourCC >> 16) & 0xff),
            UInt8((fourCC >> 8) & 0xff),
            UInt8(fourCC & 0xff)
        ]
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    
    // MARK: - CSV Generator
    
    public static func generateManifestCSV(assets: [DeliverableAsset]) -> String {
        var csv = "File Name,Status,Validation Notes,Timecode,Duration,Total Frames,Resolution,Aspect Ratio,FPS,File Size,Video Codec,Audio Codec,Audio Bitrate,Audio Details,Container\n"
        
        func escapeCSV(_ str: String) -> String {
            if str.contains(",") || str.contains("\"") || str.contains("\n") {
                let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            return str
        }
        
        for a in assets {
            let status = a.validation.hasAnyMismatch ? "MISMATCH FLAGGED" : "MATCHED"
            let notes = a.validation.summaryString
            csv += "\(escapeCSV(a.fileName)),\(escapeCSV(status)),\(escapeCSV(notes)),\(escapeCSV(a.timecode)),\(escapeCSV(a.formattedDuration)),\(a.totalFrames),\(escapeCSV(a.resolutionString)),\(escapeCSV(a.aspectRatioString)),\(String(format: "%.2f", a.fps)),\(escapeCSV(a.formattedFileSize)),\(escapeCSV(a.videoCodec)),\(escapeCSV(a.audioCodec)),\(escapeCSV(a.audioBitrate)),\(escapeCSV(a.audioConfig)),\(escapeCSV(a.container))\n"
        }
        
        return csv
    }
    
    // MARK: - HTML Specs Generator
    
    public static func generateManifestHTML(assets: [DeliverableAsset], folderName: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy.MM.dd // HH:mm:ss"
        let dateString = dateFormatter.string(from: Date())
        
        let totalSize = assets.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        let formattedTotalSize = formatFileSize(bytes: totalSize)
        let mismatchCount = assets.filter { $0.validation.hasAnyMismatch }.count
        let rawCSV = generateManifestCSV(assets: assets)
        
        var html = """
        <!DOCTYPE html>
        <html lang="en" data-theme="dark">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>DELIVERABLES SPECS // \(folderName.uppercased())</title>
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
                    --red-muted: rgba(255, 51, 51, 0.15);
                    --table-th-bg: #0d0d0d;
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
                    --red-muted: rgba(211, 47, 47, 0.12);
                    --table-th-bg: #f0f0f0;
                }

                * { box-sizing: border-box; margin: 0; padding: 0; }

                body {
                    background-color: var(--bg);
                    color: var(--text);
                    font-family: var(--font-heading);
                    text-transform: uppercase;
                    padding: 48px 32px;
                    line-height: 1.2;
                    transition: background-color 0.15s ease, color 0.15s ease;
                    -webkit-font-smoothing: antialiased;
                }

                .container { max-width: 1320px; margin: 0 auto; }

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

                .header-actions {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                }

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
                    letter-spacing: 0.08em;
                }
                .action-btn:hover { background: var(--border); }
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
                    letter-spacing: -0.02em;
                    line-height: 1;
                }

                .stat-box .label {
                    font-size: 11px;
                    font-weight: 700;
                    letter-spacing: 0.15em;
                    color: var(--text-secondary);
                    margin-top: 6px;
                }

                .stat-box.highlight .num { color: var(--red); }

                /* Table */
                .table-container {
                    background: var(--panel);
                    border: 1px solid var(--border);
                    margin-bottom: 48px;
                    overflow-x: auto;
                }

                table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 12px;
                }

                th {
                    background: var(--table-th-bg);
                    color: var(--text-muted);
                    font-size: 10px;
                    font-weight: 700;
                    letter-spacing: 0.12em;
                    padding: 12px 14px;
                    text-align: left;
                    border-bottom: 1px solid var(--border);
                    white-space: nowrap;
                }

                td {
                    padding: 12px 14px;
                    border-bottom: 1px solid var(--border);
                    font-weight: 600;
                    vertical-align: middle;
                }

                tr:last-child td { border-bottom: none; }
                tr.mismatch-row { background: var(--red-muted); }
                tr.mismatch-row td:first-child { border-left: 3px solid var(--red); }

                .fn-cell {
                    font-size: 13px;
                    font-weight: 800;
                    letter-spacing: 0.02em;
                    max-width: 260px;
                    overflow: hidden;
                    text-overflow: ellipsis;
                    white-space: nowrap;
                }

                .mono-cell {
                    font-family: var(--font-mono);
                    font-weight: 700;
                    letter-spacing: 0.05em;
                    white-space: nowrap;
                }

                .tag {
                    display: inline-block;
                    padding: 2px 6px;
                    border: 1px solid var(--border-strong);
                    font-family: var(--font-mono);
                    font-size: 10px;
                    font-weight: 700;
                    white-space: nowrap;
                }

                .tag-mismatch {
                    background: var(--red);
                    color: #ffffff;
                    border-color: var(--red);
                }

                .warning-pill {
                    font-size: 10px;
                    font-weight: 800;
                    font-family: var(--font-mono);
                    color: var(--red);
                    display: block;
                    margin-top: 3px;
                    white-space: nowrap;
                }

                .audio-detail-sub {
                    color: var(--text-secondary);
                    font-size: 10px;
                    font-family: var(--font-mono);
                    margin-top: 3px;
                    white-space: nowrap;
                }

                #toast {
                    position: fixed;
                    bottom: 24px;
                    right: 24px;
                    background: var(--text);
                    color: var(--bg);
                    padding: 12px 20px;
                    font-family: var(--font-mono);
                    font-size: 12px;
                    font-weight: 700;
                    display: none;
                    border: 1px solid var(--border-strong);
                    z-index: 1000;
                }

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
                <div class="masthead">
                    <div class="title-block">
                        <h1>DELIVERABLES SPECS</h1>
                        <div class="subtitle">ASSET SPECIFICATION AUDIT // \(folderName.uppercased())</div>
                    </div>
                    <div class="header-actions">
                        <button class="action-btn action-btn-primary" onclick="openGoogleSheets()">[ OPEN GOOGLE SHEETS ]</button>
                        <button class="action-btn" onclick="downloadCSV()">[ DOWNLOAD CSV ]</button>
                        <button class="action-btn" onclick="toggleTheme()">[ THEME: <span id="theme-text">DARK</span> ]</button>
                    </div>
                </div>

                <div class="stats-strip">
                    <div class="stat-box">
                        <div class="num">\(String(format: "%02d", assets.count))</div>
                        <div class="label">TOTAL DELIVERABLES</div>
                    </div>
                    <div class="stat-box \(mismatchCount > 0 ? "highlight" : "")">
                        <div class="num">\(String(format: "%02d", mismatchCount))</div>
                        <div class="label">NAME MISMATCHES</div>
                    </div>
                    <div class="stat-box">
                        <div class="num">\(formattedTotalSize)</div>
                        <div class="label">TOTAL BATCH SIZE</div>
                    </div>
                    <div class="stat-box">
                        <div class="num" style="font-size: 20px; padding-top: 14px; font-family: var(--font-mono)">\(dateString)</div>
                        <div class="label">AUDIT TIMESTAMP</div>
                    </div>
                </div>

                <div class="table-container">
                    <table>
                        <thead>
                            <tr>
                                <th>#</th>
                                <th>FILE NAME</th>
                                <th>STATUS</th>
                                <th>LENGTH / TC</th>
                                <th>RATIO & RESOLUTION</th>
                                <th>FPS</th>
                                <th>FILE SIZE</th>
                                <th>VIDEO</th>
                                <th>AUDIO (CODEC • BITRATE)</th>
                            </tr>
                        </thead>
                        <tbody>
        """
        
        for (idx, a) in assets.enumerated() {
            let rowClass = a.validation.hasAnyMismatch ? "class='mismatch-row'" : ""
            let statusTag = a.validation.hasAnyMismatch ? "<span class='tag tag-mismatch'>MISMATCH</span>" : "<span class='tag'>OK</span>"
            
            let audioDisplay: String
            if !a.hasAudio {
                audioDisplay = "<span style='color:var(--text-muted); font-family:var(--font-mono)'>NONE</span>"
            } else {
                let bitrateTag = a.audioBitrate != "--" ? "<span class='tag' style='margin-left:4px'>\(a.audioBitrate)</span>" : ""
                let subLine = !a.audioFormatDetail.isEmpty ? "<div class='audio-detail-sub'>\(a.audioFormatDetail)</div>" : ""
                audioDisplay = """
                <div style="display:flex; align-items:center;">
                    <span class="mono-cell">\(a.audioCodec)</span>\(bitrateTag)
                </div>\(subLine)
                """
            }
            
            html += """
                            <tr \(rowClass)>
                                <td style="color:var(--text-muted); font-family:var(--font-mono)">\(String(format: "%02d", idx + 1))</td>
                                <td class="fn-cell" title="\(a.fileName.uppercased())">
                                    \(a.fileName.uppercased())
                                </td>
                                <td>
                                    \(statusTag)
                                </td>
                                <td class="mono-cell">
                                    \(a.timecode) <span style="color:var(--text-muted); font-size:11px">(\(a.formattedDuration))</span>
                                    \(a.validation.isDurationMismatch ? "<span class='warning-pill'>\(a.validation.durationMismatchDetail ?? "")</span>" : "")
                                </td>
                                <td>
                                    <span class="tag \(a.validation.isRatioMismatch ? "tag-mismatch" : "")">\(a.aspectRatioString)</span> 
                                    <span class="mono-cell" style="font-size:11px; margin-left:4px">\(a.resolutionString)</span>
                                    \(a.validation.isRatioMismatch ? "<span class='warning-pill'>\(a.validation.ratioMismatchDetail ?? "")</span>" : "")
                                </td>
                                <td class="mono-cell">\(String(format: "%.2f", a.fps)) FPS</td>
                                <td class="mono-cell">\(a.formattedFileSize)</td>
                                <td>\(a.videoCodec)</td>
                                <td>\(audioDisplay)</td>
                            </tr>
            """
        }
        
        html += """
                        </tbody>
                    </table>
                </div>

                <footer>
                    <div>THE LINEFINDER 5000 // DELIVERABLES ENGINE</div>
                    <div>AUTOMATED POST-PRODUCTION SPEC AUDIT</div>
                </footer>
            </div>

            <div id="toast"></div>

            <script>
                const csvData = `\(rawCSV.replacingOccurrences(of: "`", with: "\\`").replacingOccurrences(of: "${", with: "\\${"))`;

                function toggleTheme() {
                    const current = document.documentElement.getAttribute('data-theme') || 'dark';
                    const next = current === 'dark' ? 'light' : 'dark';
                    document.documentElement.setAttribute('data-theme', next);
                    document.getElementById('theme-text').innerText = next.toUpperCase();
                }

                function showToast(msg) {
                    const t = document.getElementById('toast');
                    t.innerText = msg;
                    t.style.display = 'block';
                    setTimeout(() => { t.style.display = 'none'; }, 4000);
                }

                function downloadCSV() {
                    const blob = new Blob([csvData], { type: 'text/csv;charset=utf-8;' });
                    const link = document.createElement('a');
                    link.href = URL.createObjectURL(blob);
                    link.download = "Deliverables_Specs.csv";
                    document.body.appendChild(link);
                    link.click();
                    document.body.removeChild(link);
                    showToast('CSV DOWNLOADED // Deliverables_Specs.csv');
                }

                function openGoogleSheets() {
                    navigator.clipboard.writeText(csvData).then(() => {
                        window.open('https://sheets.new', '_blank');
                        showToast('CSV COPIED // OPENING GOOGLE SHEETS (PASTE WITH CMD+V)');
                    }).catch(() => {
                        downloadCSV();
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
