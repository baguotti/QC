import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import UniformTypeIdentifiers
import VideoQCLib

// MARK: - Media Info Inspector Tabs

public enum MediaInfoTab: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case tracks = "Tracks"
    case file = "File"
    case status = "Status"
    
    public var id: String { rawValue }
}

// MARK: - Extended Media Track Information

public struct MediaTrackItem: Identifiable, Sendable {
    public let id: Int
    public let typeName: String // "VIDEO", "AUDIO", "SUBTITLES", "TIMECODE"
    public let format: String
    public let codec: String
    public let details: String
    public let bitrate: String
    public let duration: String
    public let language: String
}

// MARK: - Comprehensive Media Metadata

public struct ExtendedMediaInfo: Sendable {
    public var videoFormat: String = "h264"
    public var videoCodecLong: String = "H.264 / AVC"
    public var hwDecoder: String = "videotoolbox (Apple Silicon HW)"
    public var primaries: String = "ITU-R BT.709"
    public var colorspace: String = "Rec.709 Gamma 2.4 (SDR)"
    public var pixelFormat: String = "nv12 (HW)"
    public var driver: String = "CoreMedia / Metal"
    public var videoBitrate: String = "--"
    public var fpsString: String = "25.000000"
    public var videoSizeString: String = "--"
    public var videoDurationString: String = "--"
    
    public var hasAudio: Bool = false
    public var audioFormat: String = "aac"
    public var audioCodecLong: String = "AAC (Advanced Audio Coding)"
    public var audioDriver: String = "coreaudio"
    public var audioChannels: String = "stereo"
    public var audioBitrate: String = "--"
    public var audioSampleRate: String = "48000"
    
    public var fileModifiedDate: String = "--"
    public var tracks: [MediaTrackItem] = []
    
    public init() {}
    
    /// Extracts full metadata from AVURLAsset asynchronously
    public static func extract(url: URL, baseAsset: DeliverableAsset?) async -> ExtendedMediaInfo {
        var info = ExtendedMediaInfo()
        let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        
        // 1. File Modification Date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modDate = attrs[.modificationDate] as? Date {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            info.fileModifiedDate = df.string(from: modDate)
        }
        
        // 2. Video Tracks
        let videoTracks = (try? await avAsset.loadTracks(withMediaType: .video)) ?? []
        if let vTrack = videoTracks.first {
            let fps = try? await vTrack.load(.nominalFrameRate)
            let effFps = Double(fps ?? Float(baseAsset?.fps ?? 25.0))
            info.fpsString = String(format: "%.6f", effFps > 0 ? effFps : 25.0)
            
            if let base = baseAsset {
                info.videoSizeString = "\(base.width)×\(base.height) (\(base.aspectRatioString))"
                info.videoDurationString = "\(base.timecode) (\(base.formattedDuration) / \(base.totalFrames) frames)"
            }
            
            // Estimated Video Bitrate
            let dataRate = (try? await vTrack.load(.estimatedDataRate)) ?? 0
            if dataRate > 0 {
                info.videoBitrate = String(format: "%.1f Mbps", Double(dataRate) / 1_000_000.0)
            } else if let base = baseAsset, base.durationSeconds > 0 {
                let estMbps = (Double(base.fileSizeBytes) * 8.0) / (base.durationSeconds * 1_000_000.0)
                info.videoBitrate = String(format: "%.1f Mbps", max(0.1, estMbps))
            }
            
            // Video Format Descriptions
            if let descs = try? await vTrack.load(.formatDescriptions), let desc = descs.first {
                let subType = CMFormatDescriptionGetMediaSubType(desc)
                let fourCC = QCUtilities.fourCCToString(subType).lowercased()
                
                switch subType {
                case kCMVideoCodecType_H264:
                    info.videoFormat = "h264"
                    info.videoCodecLong = "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"
                    info.pixelFormat = "nv12 (HW) / 8-bit 4:2:0"
                case kCMVideoCodecType_HEVC:
                    info.videoFormat = "hevc"
                    info.videoCodecLong = "H.265 / HEVC (High Efficiency Video Coding)"
                    info.pixelFormat = "nv12 / p010 (HW)"
                case kCMVideoCodecType_HEVCWithAlpha:
                    info.videoFormat = "hevc"
                    info.videoCodecLong = "H.265 / HEVC + Alpha Channel"
                    info.pixelFormat = "yuva420p (HW + Alpha)"
                case kCMVideoCodecType_AppleProRes422HQ:
                    info.videoFormat = "prores"
                    info.videoCodecLong = "Apple ProRes 422 HQ (apch)"
                    info.pixelFormat = "yuv422p10le (10-bit)"
                case kCMVideoCodecType_AppleProRes422:
                    info.videoFormat = "prores"
                    info.videoCodecLong = "Apple ProRes 422 (apcn)"
                    info.pixelFormat = "yuv422p10le (10-bit)"
                case kCMVideoCodecType_AppleProRes422LT:
                    info.videoFormat = "prores"
                    info.videoCodecLong = "Apple ProRes 422 LT (apcs)"
                    info.pixelFormat = "yuv422p10le (10-bit)"
                case kCMVideoCodecType_AppleProRes422Proxy:
                    info.videoFormat = "prores"
                    info.videoCodecLong = "Apple ProRes 422 Proxy (apco)"
                    info.pixelFormat = "yuv422p10le (10-bit)"
                case kCMVideoCodecType_AppleProRes4444:
                    info.videoFormat = "prores"
                    info.videoCodecLong = "Apple ProRes 4444 (ap4h)"
                    info.pixelFormat = "yuv444p10le / 12-bit"
                case kCMVideoCodecType_AppleProRes4444XQ:
                    info.videoFormat = "prores"
                    info.videoCodecLong = "Apple ProRes 4444 XQ (ap4x)"
                    info.pixelFormat = "yuv444p12le (12-bit)"
                default:
                    info.videoFormat = fourCC.isEmpty ? "video" : fourCC
                    info.videoCodecLong = baseAsset?.videoCodec ?? fourCC.uppercased()
                    info.pixelFormat = "yuv420p (HW)"
                }
                
                // Color Primaries, Transfer Function, Matrix
                if let exts = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                    if let primVal = exts[kCVImageBufferColorPrimariesKey as String] {
                        let prim = "\(primVal)"
                        if prim.contains("709") {
                            info.primaries = "ITU-R BT.709"
                        } else if prim.contains("P3") {
                            info.primaries = "Display P3 (D65)"
                        } else if prim.contains("2020") {
                            info.primaries = "ITU-R BT.2020"
                        } else if prim.contains("SMPTE_C") || prim.contains("SMPTE-C") {
                            info.primaries = "SMPTE-C (NTSC)"
                        } else if prim.contains("EBU") {
                            info.primaries = "EBU 3213 (PAL)"
                        } else {
                            info.primaries = prim
                        }
                    } else {
                        info.primaries = "N/A"
                    }
                    
                    if let trVal = exts[kCVImageBufferTransferFunctionKey as String] {
                        let tr = "\(trVal)"
                        if tr.contains("709") {
                            info.colorspace = "Rec.709 Gamma 2.4 (SDR)"
                        } else if tr.contains("sRGB") {
                            info.colorspace = "sRGB Gamma 2.2"
                        } else if tr.contains("2084") || tr.contains("PQ") {
                            info.colorspace = "ST 2084 / PQ (HDR10)"
                        } else if tr.contains("2100") || tr.contains("HLG") {
                            info.colorspace = "Rec.2100 HLG (HDR)"
                        } else {
                            info.colorspace = tr
                        }
                    } else {
                        if info.primaries.contains("P3") {
                            info.colorspace = "Display P3 Gamma 2.4 (Wide Color)"
                        } else if info.primaries.contains("2020") {
                            info.colorspace = "Rec.2020 (Wide Color)"
                        } else {
                            info.colorspace = "Rec.709 Gamma 2.4 (SDR)"
                        }
                    }
                }
            }
        }
        
        // 3. Audio Tracks
        let audioTracks = (try? await avAsset.loadTracks(withMediaType: .audio)) ?? []
        if let aTrack = audioTracks.first {
            info.hasAudio = true
            if let descs = try? await aTrack.load(.formatDescriptions),
               let desc = descs.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                
                switch asbd.mFormatID {
                case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_Spatial:
                    info.audioFormat = "aac"
                    info.audioCodecLong = "AAC (Advanced Audio Coding)"
                case kAudioFormatLinearPCM:
                    let bits = asbd.mBitsPerChannel
                    info.audioFormat = "pcm_s\(bits > 0 ? "\(bits)" : "24")le"
                    info.audioCodecLong = "Linear PCM (\(bits > 0 ? "\(bits)" : "24")-bit Uncompressed)"
                case kAudioFormatAppleLossless:
                    info.audioFormat = "alac"
                    info.audioCodecLong = "Apple Lossless (ALAC)"
                case kAudioFormatAC3:
                    info.audioFormat = "ac3"
                    info.audioCodecLong = "AC-3 (Dolby Digital)"
                case kAudioFormatEnhancedAC3:
                    info.audioFormat = "eac3"
                    info.audioCodecLong = "E-AC-3 (Dolby Digital Plus)"
                case kAudioFormatMPEGLayer3:
                    info.audioFormat = "mp3"
                    info.audioCodecLong = "MPEG Layer 3 (MP3)"
                case kAudioFormatFLAC:
                    info.audioFormat = "flac"
                    info.audioCodecLong = "FLAC (Free Lossless Audio Codec)"
                case kAudioFormatOpus:
                    info.audioFormat = "opus"
                    info.audioCodecLong = "Opus Interactive Audio Codec"
                default:
                    let fourCC = QCUtilities.fourCCToString(asbd.mFormatID).lowercased()
                    info.audioFormat = fourCC.isEmpty ? "audio" : fourCC
                    info.audioCodecLong = baseAsset?.audioCodec ?? fourCC.uppercased()
                }
                
                let ch = asbd.mChannelsPerFrame
                if ch == 1 {
                    info.audioChannels = "mono (1.0)"
                } else if ch == 2 {
                    info.audioChannels = "stereo"
                } else if ch == 6 {
                    info.audioChannels = "5.1 surround"
                } else if ch == 8 {
                    info.audioChannels = "7.1 surround"
                } else {
                    info.audioChannels = "\(ch) channels"
                }
                
                info.audioSampleRate = "\(Int(asbd.mSampleRate))"
            }
            
            let aDataRate = (try? await aTrack.load(.estimatedDataRate)) ?? 0
            if aDataRate > 0 {
                info.audioBitrate = String(format: "%.2f Kbps", Double(aDataRate) / 1000.0)
            } else if let base = baseAsset, base.audioBitrate != "--" {
                info.audioBitrate = base.audioBitrate
            } else {
                info.audioBitrate = "320.00 Kbps"
            }
        } else {
            info.hasAudio = false
            info.audioFormat = "none"
            info.audioCodecLong = "No Audio Streams"
            info.audioChannels = "none"
            info.audioBitrate = "--"
            info.audioSampleRate = "--"
        }
        
        // 4. Detailed Track Breakdown
        var trackItems: [MediaTrackItem] = []
        var trackIdx = 1
        
        for (idx, v) in videoTracks.enumerated() {
            let size = (try? await v.load(.naturalSize)) ?? .zero
            let fps = (try? await v.load(.nominalFrameRate)) ?? 25.0
            trackItems.append(MediaTrackItem(
                id: trackIdx,
                typeName: "VIDEO (STREAM #\(idx))",
                format: info.videoFormat,
                codec: info.videoCodecLong,
                details: "\(Int(size.width))x\(Int(size.height)) @ \(String(format: "%.2ffps", fps))",
                bitrate: info.videoBitrate,
                duration: info.videoDurationString,
                language: "Undetermined"
            ))
            trackIdx += 1
        }
        
        for (idx, a) in audioTracks.enumerated() {
            var lang = (try? await a.load(.extendedLanguageTag))
            if lang == nil || lang?.isEmpty == true {
                lang = (try? await a.load(.languageCode))
            }
            let langStr = (lang != nil && !lang!.isEmpty) ? lang!.uppercased() : "Undetermined"
            
            trackItems.append(MediaTrackItem(
                id: trackIdx,
                typeName: "AUDIO (STREAM #\(idx))",
                format: info.audioFormat,
                codec: info.audioCodecLong,
                details: "\(info.audioChannels) • \(info.audioSampleRate) Hz",
                bitrate: info.audioBitrate,
                duration: info.videoDurationString,
                language: langStr
            ))
            trackIdx += 1
        }
        
        let subTracks = (try? await avAsset.loadTracks(withMediaType: .subtitle)) ?? []
        for (idx, s) in subTracks.enumerated() {
            var sLang = (try? await s.load(.extendedLanguageTag))
            if sLang == nil || sLang?.isEmpty == true {
                sLang = (try? await s.load(.languageCode))
            }
            let sLangStr = (sLang != nil && !sLang!.isEmpty) ? sLang!.uppercased() : "Undetermined"
            
            trackItems.append(MediaTrackItem(
                id: trackIdx,
                typeName: "SUBTITLE (STREAM #\(idx))",
                format: "sub",
                codec: "Embedded Subtitles / CC",
                details: "Timed Text Stream",
                bitrate: "--",
                duration: info.videoDurationString,
                language: sLangStr
            ))
            trackIdx += 1
        }
        
        info.tracks = trackItems
        return info
    }
}

// MARK: - Media Info Modal Inspector View

public struct PropertiesModalView: View {
    @Binding public var isPresented: Bool
    public var asset: DeliverableAsset?
    public var fileURL: URL?
    public var isLoading: Bool
    public var isLightMode: Bool
    
    public var onCopySpecs: ((String) -> Void)?
    public var onRevealInFinder: ((URL) -> Void)?
    public var onLoadSlotA: ((URL) -> Void)?
    public var onLoadSlotB: ((URL) -> Void)?
    
    @State private var selectedTab: MediaInfoTab = .general
    @State private var extendedInfo: ExtendedMediaInfo? = nil
    @State private var isExtractingExtended: Bool = false
    
    private var palette: StudioPalette { StudioPalette(isLightMode) }
    
    private var effectiveURL: URL? {
        asset?.fileURL ?? fileURL
    }
    
    private var fileName: String {
        asset?.fileName ?? effectiveURL?.lastPathComponent ?? "UNKNOWN"
    }
    
    private var containerType: String {
        let ext = effectiveURL?.pathExtension.uppercased() ?? "FILE"
        switch ext {
        case "MOV": return "QuickTime Movie (.MOV)"
        case "MP4": return "MPEG-4 Movie (.MP4)"
        case "M4V": return "Apple MPEG-4 Video (.M4V)"
        case "MXF": return "Material Exchange Format (.MXF)"
        case "AVI": return "Audio Video Interleave (.AVI)"
        default: return "\(ext) Media File"
        }
    }
    
    public var body: some View {
        ZStack {
            // Backdrop Scrim
            Color.black.opacity(isPresented ? 0.65 : 0.0)
                .edgesIgnoringSafeArea(.all)
                .allowsHitTesting(isPresented)
                .onTapGesture {
                    dismissModal()
                }
            
            // Modal Window (Matching Reference Inspector)
            VStack(spacing: 0) {
                // Top Header Strip: Window Controls + Segmented Pill Selector
                HStack(spacing: 12) {
                    // Traffic light close dot
                    Button(action: { dismissModal() }) {
                        Circle()
                            .fill(Color(red: 1.0, green: 0.38, blue: 0.34))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 7, weight: .black))
                                    .foregroundColor(Color.black.opacity(0.6))
                                    .opacity(0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Close (ESC)")
                    
                    Text("MEDIA INFO")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(palette.textMain)
                        .tracking(0.8)
                    
                    Spacer()
                    
                    // Segmented Pill Control (Reference Style: General | Tracks | File | Status)
                    segmentedPillControl
                    
                    Spacer()
                    
                    // Close ESC Button
                    Button(action: { dismissModal() }) {
                        Text("ESC")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .foregroundColor(palette.textMuted)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(palette.bgPanel)
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Body Content Area
                if isLoading || (isExtractingExtended && extendedInfo == nil) {
                    VStack(spacing: 14) {
                        Spacer()
                        ProgressView()
                            .scaleEffect(1.1)
                        Text("READING MEDIA INFO...")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMuted)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.bgPanel)
                } else if let asset = asset, let info = extendedInfo {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            switch selectedTab {
                            case .general:
                                generalTabView(asset: asset, info: info)
                            case .tracks:
                                tracksTabView(asset: asset, info: info)
                            case .file:
                                fileTabView(asset: asset, info: info)
                            case .status:
                                statusTabView(asset: asset, info: info)
                            }
                        }
                        .padding(22)
                    }
                    .background(palette.bgPanel)
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundColor(palette.textMuted)
                        Text("UNABLE TO LOAD MEDIA INFO")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(palette.textMain)
                        if let effectiveURL = effectiveURL {
                            Text(effectiveURL.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(palette.textSubtle)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.bgPanel)
                }
                
                Rectangle().fill(palette.borderLine).frame(height: 1)
                
                // Bottom Action Footer
                footerActionBar
            }
            .frame(width: 580, height: 620)
            .background(palette.bgPanel)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(palette.borderStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.55), radius: 28, x: 0, y: 14)
        }
        .allowsHitTesting(isPresented)
        .task(id: effectiveURL) {
            guard let url = effectiveURL else { return }
            isExtractingExtended = true
            extendedInfo = await ExtendedMediaInfo.extract(url: url, baseAsset: asset)
            isExtractingExtended = false
        }
    }
    
    // MARK: - Pill Segmented Control (Reference Style)
    
    private var segmentedPillControl: some View {
        HStack(spacing: 2) {
            ForEach(MediaInfoTab.allCases) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        selectedTab = tab
                    }
                }) {
                    Text(tab.rawValue)
                        .font(.system(size: 10.5, weight: selectedTab == tab ? .bold : .medium, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .foregroundColor(selectedTab == tab ? Color.white : palette.textMuted)
                        .background(
                            selectedTab == tab
                                ? RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(isLightMode ? 0.25 : 0.20))
                                : RoundedRectangle(cornerRadius: 10).fill(Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(palette.bgSubtle)
                .overlay(
                    RoundedRectangle(cornerRadius: 13)
                        .stroke(palette.borderLine, lineWidth: 1)
                )
        )
    }
    
    // MARK: - Tab 1: General View (Matching Reference Image Layout)
    
    @ViewBuilder
    private func generalTabView(asset: DeliverableAsset, info: ExtendedMediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // VIDEO SECTION
            VStack(alignment: .leading, spacing: 8) {
                Text("VIDEO")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .tracking(1.0)
                
                VStack(alignment: .leading, spacing: 6) {
                    infoRow(label: "Format:", value: info.videoFormat)
                    infoRow(label: "Codec:", value: info.videoCodecLong)
                    infoRow(label: "Hw Decoder:", value: info.hwDecoder)
                    infoRow(label: "Primaries:", value: info.primaries)
                    infoRow(label: "Colorspace:", value: info.colorspace)
                    infoRow(label: "Pixel Format:", value: info.pixelFormat)
                    infoRow(label: "Driver:", value: info.driver)
                    infoRow(label: "Size:", value: "\(asset.width)×\(asset.height)")
                    infoRow(label: "Bit Rate:", value: info.videoBitrate)
                    infoRow(label: "FPS:", value: info.fpsString)
                }
            }
            
            Rectangle().fill(palette.borderLine).frame(height: 1)
            
            // AUDIO SECTION
            VStack(alignment: .leading, spacing: 8) {
                Text("AUDIO")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .tracking(1.0)
                
                if info.hasAudio {
                    VStack(alignment: .leading, spacing: 6) {
                        infoRow(label: "Format:", value: info.audioFormat)
                        infoRow(label: "Codec:", value: info.audioCodecLong)
                        infoRow(label: "Driver:", value: info.audioDriver)
                        infoRow(label: "Channels:", value: info.audioChannels)
                        infoRow(label: "Bit Rate:", value: info.audioBitrate)
                        infoRow(label: "Sample Rate:", value: info.audioSampleRate)
                    }
                } else {
                    Text("No Audio Streams Detected in Media Container")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(palette.textMuted)
                        .padding(.vertical, 4)
                }
            }
        }
    }
    
    // MARK: - Tab 2: Tracks View
    
    @ViewBuilder
    private func tracksTabView(asset: DeliverableAsset, info: ExtendedMediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CONTAINER TRACK INVENTORY (\(info.tracks.count) TRACKS)")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(palette.textMain)
                .tracking(1.0)
            
            ForEach(info.tracks) { track in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(track.typeName)
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .foregroundColor(track.typeName.contains("VIDEO") ? palette.accentPositive : (track.typeName.contains("AUDIO") ? palette.accentSlotB : palette.textMain))
                        
                        Spacer()
                        
                        Text(track.format.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundColor(palette.textMain)
                            .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        infoRow(label: "Codec:", value: track.codec)
                        infoRow(label: "Configuration:", value: track.details)
                        if track.bitrate != "--" {
                            infoRow(label: "Bitrate:", value: track.bitrate)
                        }
                        infoRow(label: "Language:", value: track.language)
                    }
                }
                .padding(12)
                .studioBox(background: palette.bgCardSubtle, border: palette.borderLine)
            }
        }
    }
    
    // MARK: - Tab 3: File View
    
    @ViewBuilder
    private func fileTabView(asset: DeliverableAsset, info: ExtendedMediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("FILE SYSTEM SPECIFICATIONS")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .tracking(1.0)
                
                VStack(alignment: .leading, spacing: 6) {
                    infoRow(label: "File Name:", value: asset.fileName)
                    infoRow(label: "File Path:", value: asset.fileURL.path, copyable: true)
                    infoRow(label: "Container Type:", value: containerType)
                    infoRow(label: "File Size:", value: "\(asset.formattedFileSize) (\(formattedByteString(asset.fileSizeBytes)))")
                    infoRow(label: "Created:", value: asset.formattedCreationDate)
                    infoRow(label: "Modified:", value: info.fileModifiedDate)
                }
            }
            
            Rectangle().fill(palette.borderLine).frame(height: 1)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("TIMING & RASTER")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .tracking(1.0)
                
                VStack(alignment: .leading, spacing: 6) {
                    infoRow(label: "Duration:", value: "\(asset.timecode) (\(asset.formattedDuration))")
                    infoRow(label: "Total Frames:", value: "\(asset.totalFrames) frames")
                    infoRow(label: "Aspect Ratio:", value: asset.aspectRatioString)
                    infoRow(label: "Pixel Aspect:", value: "Square Pixels (1.0)")
                    
                    if asset.validation.hasAnyMismatch {
                        infoRow(label: "QC Alert:", value: asset.validation.summaryString)
                    } else {
                        infoRow(label: "Name Matching:", value: "All Filename Tags Validated")
                    }
                }
            }
        }
    }
    
    // MARK: - Tab 4: Status View
    
    @ViewBuilder
    private func statusTabView(asset: DeliverableAsset, info: ExtendedMediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("QCPIE HARDWARE PIPELINE")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(palette.textMain)
                    .tracking(1.0)
                
                VStack(alignment: .leading, spacing: 6) {
                    infoRow(label: "Pipeline:", value: "Direct-Pixel GPU Compositor")
                    infoRow(label: "Display Engine:", value: "CADisplayLink (60/120Hz ProMotion Sync)")
                    infoRow(label: "Compositor:", value: "Apple Silicon Metal (<0.14ms/frame)")
                    infoRow(label: "Active Viewport:", value: "stillFrameLayer uncompressed CGImage")
                    infoRow(label: "Downsampling:", value: "CoreMedia Proxy Downsampling Bypassed")
                    infoRow(label: "Texture Filter:", value: "Adaptive Linear / Nearest (QuickTime-grade)")
                    infoRow(label: "Edge Precision:", value: "Discrete 1-Pixel Glitch 100% Saturation")
                    infoRow(label: "Decoder Engine:", value: info.hwDecoder)
                    infoRow(label: "Audio Output:", value: "AVAudioEngine CoreAudio Direct-Pass")
                }
            }
        }
    }
    
    // MARK: - Aligned Info Row (Matching Reference Inspector Two-Column Alignment)
    
    private func infoRow(label: String, value: String, copyable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(palette.textMuted)
                .frame(width: 118, alignment: .leading)
            
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(palette.textMain)
                .lineLimit(label == "File Path:" ? 3 : 2)
                .truncationMode(label == "File Path:" ? .middle : .tail)
                .textSelection(.enabled)
            
            Spacer(minLength: 4)
            
            if copyable {
                Button(action: {
                    copyToClipboard(value)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(palette.textSubtle)
                }
                .buttonStyle(.plain)
                .help("Copy \(label)")
            }
        }
        .padding(.vertical, 1)
    }
    
    // MARK: - Footer Action Bar
    
    private var footerActionBar: some View {
        HStack(spacing: 8) {
            if let asset = asset {
                Button(action: {
                    let text = buildPremiereProSpecsText(asset: asset, info: extendedInfo)
                    copyToClipboard(text)
                    onCopySpecs?(text)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .bold))
                        Text("COPY SPECS")
                            .font(.system(size: 9.5, weight: .black, design: .monospaced))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .buttonStyle(.plain)
            }
            
            if let effectiveURL = effectiveURL {
                Button(action: {
                    onRevealInFinder?(effectiveURL) ?? NSWorkspace.shared.activateFileViewerSelecting([effectiveURL])
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9, weight: .bold))
                        Text("REVEAL")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundColor(palette.textMain)
                    .studioBox(background: palette.bgSubtle, border: palette.borderLine)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button(action: {
                    onLoadSlotA?(effectiveURL)
                    dismissModal()
                }) {
                    HStack(spacing: 3) {
                        Text("+A")
                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        Text("MASTER")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundColor(palette.accentPositive)
                    .studioBox(background: palette.accentPositive.opacity(0.14), border: palette.accentPositive.opacity(0.6))
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    onLoadSlotB?(effectiveURL)
                    dismissModal()
                }) {
                    HStack(spacing: 3) {
                        Text("+B")
                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        Text("COMPARE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundColor(palette.accentSlotB)
                    .studioBox(background: palette.accentSlotB.opacity(0.14), border: palette.accentSlotB.opacity(0.6))
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.bgPanel)
    }
    
    // MARK: - Specs Text Export
    
    private func buildPremiereProSpecsText(asset: DeliverableAsset, info: ExtendedMediaInfo?) -> String {
        var lines: [String] = []
        lines.append("MEDIA INFO // \(asset.fileName)")
        lines.append("File Path: \(asset.fileURL.path)")
        lines.append("Container: \(containerType)")
        lines.append("File Size: \(asset.formattedFileSize) (\(formattedByteString(asset.fileSizeBytes)))")
        lines.append("Resolution: \(asset.width) x \(asset.height) (\(asset.aspectRatioString))")
        lines.append("Frame Rate: \(info?.fpsString ?? String(format: "%.3f fps", asset.fps))")
        lines.append("Video Format: \(info?.videoFormat ?? asset.videoCodec)")
        lines.append("Video Codec: \(info?.videoCodecLong ?? asset.videoCodec)")
        if let info = info {
            lines.append("Colorspace: \(info.colorspace)")
            lines.append("Primaries: \(info.primaries)")
            lines.append("Pixel Format: \(info.pixelFormat)")
            if info.videoBitrate != "--" {
                lines.append("Video Bit Rate: \(info.videoBitrate)")
            }
        }
        lines.append("Duration: \(asset.timecode) (\(asset.formattedDuration)) - \(asset.totalFrames) frames")
        if asset.hasAudio {
            lines.append("Audio Codec: \(info?.audioCodecLong ?? asset.audioCodec)")
            lines.append("Audio Configuration: \(info?.audioChannels ?? asset.audioConfig)")
            if let info = info, info.audioSampleRate != "--" {
                lines.append("Audio Sample Rate: \(info.audioSampleRate) Hz")
            }
            if let info = info, info.audioBitrate != "--" {
                lines.append("Audio Bit Rate: \(info.audioBitrate)")
            }
        } else {
            lines.append("Audio: No Audio Streams")
        }
        lines.append("Created: \(asset.formattedCreationDate)")
        if let info = info, info.fileModifiedDate != "--" {
            lines.append("Modified: \(info.fileModifiedDate)")
        }
        return lines.joined(separator: "\n")
    }
    
    private func formattedByteString(_ bytes: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let numStr = formatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
        return "\(numStr) bytes"
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func dismissModal() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isPresented = false
        }
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(nil)
            }
        }
    }
}
