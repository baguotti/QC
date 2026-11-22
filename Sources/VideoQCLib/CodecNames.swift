import CoreMedia
import AudioToolbox

/// Names for the codecs QCpie recognises, shared by Inspect (short names) and Properties (ffprobe-style detail).
public enum CodecNames {
    public struct Video: Sendable {
        /// Inspect column: "ProRes 422 HQ".
        public let short: String
        /// ffprobe-style format: "prores".
        public let format: String
        public let long: String
        public let pixelFormat: String
    }

    public struct Audio: Sendable {
        public let short: String
        public let format: String
        public let long: String
    }

    public static func video(_ subType: FourCharCode) -> Video? {
        switch subType {
        case kCMVideoCodecType_H264:
            Video(short: "H.264 (AVC)", format: "h264", long: "H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10", pixelFormat: "nv12 (HW) / 8-bit 4:2:0")
        case kCMVideoCodecType_HEVC:
            Video(short: "H.265 (HEVC)", format: "hevc", long: "H.265 / HEVC (High Efficiency Video Coding)", pixelFormat: "nv12 / p010 (HW)")
        case kCMVideoCodecType_HEVCWithAlpha:
            Video(short: "HEVC + Alpha", format: "hevc", long: "H.265 / HEVC + Alpha Channel", pixelFormat: "yuva420p (HW + Alpha)")
        case kCMVideoCodecType_AppleProRes422HQ:
            Video(short: "ProRes 422 HQ", format: "prores", long: "Apple ProRes 422 HQ (apch)", pixelFormat: "yuv422p10le (10-bit)")
        case kCMVideoCodecType_AppleProRes422:
            Video(short: "ProRes 422", format: "prores", long: "Apple ProRes 422 (apcn)", pixelFormat: "yuv422p10le (10-bit)")
        case kCMVideoCodecType_AppleProRes422LT:
            Video(short: "ProRes 422 LT", format: "prores", long: "Apple ProRes 422 LT (apcs)", pixelFormat: "yuv422p10le (10-bit)")
        case kCMVideoCodecType_AppleProRes422Proxy:
            Video(short: "ProRes 422 Proxy", format: "prores", long: "Apple ProRes 422 Proxy (apco)", pixelFormat: "yuv422p10le (10-bit)")
        case kCMVideoCodecType_AppleProRes4444:
            Video(short: "ProRes 4444", format: "prores", long: "Apple ProRes 4444 (ap4h)", pixelFormat: "yuv444p10le / 12-bit")
        case kCMVideoCodecType_AppleProRes4444XQ:
            Video(short: "ProRes 4444 XQ", format: "prores", long: "Apple ProRes 4444 XQ (ap4x)", pixelFormat: "yuv444p12le (12-bit)")
        // Shown as their four-letter codes ("mp2v", "dvcp") before.
        case kCMVideoCodecType_MPEG2Video:
            Video(short: "MPEG-2", format: "mpeg2video", long: "MPEG-2 Video", pixelFormat: "8-bit 4:2:0 / 4:2:2")
        case kCMVideoCodecType_MPEG1Video:
            Video(short: "MPEG-1", format: "mpeg1video", long: "MPEG-1 Video", pixelFormat: "8-bit 4:2:0")
        case kCMVideoCodecType_MPEG4Video:
            Video(short: "MPEG-4 Part 2", format: "mpeg4", long: "MPEG-4 Part 2 Visual", pixelFormat: "8-bit 4:2:0")
        case kCMVideoCodecType_DVCNTSC, kCMVideoCodecType_DVCPAL, kCMVideoCodecType_DVCProPAL, kCMVideoCodecType_DVCPro50NTSC,
             kCMVideoCodecType_DVCPro50PAL, kCMVideoCodecType_DVCPROHD720p60, kCMVideoCodecType_DVCPROHD720p50,
             kCMVideoCodecType_DVCPROHD1080i60, kCMVideoCodecType_DVCPROHD1080i50, kCMVideoCodecType_DVCPROHD1080p30,
             kCMVideoCodecType_DVCPROHD1080p25:
            Video(short: "DV", format: "dvvideo", long: "DV / DVCPRO", pixelFormat: "8-bit 4:1:1 / 4:2:0 / 4:2:2")
        // AVI's MJPEG reads as OpenDML ("dmb1"); QuickTime's Motion JPEG A / B as "mjpa" / "mjpb".
        case kCMVideoCodecType_JPEG, kCMVideoCodecType_JPEG_OpenDML, 0x6D6A_7061, 0x6D6A_7062:
            Video(short: "Motion JPEG", format: "mjpeg", long: "Motion JPEG", pixelFormat: "8-bit 4:2:2")
        default:
            nil
        }
    }

    /// Compressed formats only: Linear PCM depends on the bit depth and flags, so callers name it themselves.
    public static func audio(_ formatID: AudioFormatID) -> Audio? {
        switch formatID {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_Spatial:
            Audio(short: "AAC", format: "aac", long: "AAC (Advanced Audio Coding)")
        case kAudioFormatAppleLossless:
            Audio(short: "ALAC", format: "alac", long: "Apple Lossless (ALAC)")
        case kAudioFormatAC3:
            Audio(short: "AC-3 (Dolby Digital)", format: "ac3", long: "AC-3 (Dolby Digital)")
        case kAudioFormatEnhancedAC3:
            Audio(short: "E-AC-3", format: "eac3", long: "E-AC-3 (Dolby Digital Plus)")
        case kAudioFormatMPEGLayer3:
            Audio(short: "MP3", format: "mp3", long: "MPEG Layer 3 (MP3)")
        case kAudioFormatFLAC:
            Audio(short: "FLAC", format: "flac", long: "FLAC (Free Lossless Audio Codec)")
        case kAudioFormatOpus:
            Audio(short: "Opus", format: "opus", long: "Opus Interactive Audio Codec")
        default:
            nil
        }
    }

    /// Inspect's name for a video codec as ffprobe reports it (`codec_name`, `profile`), in the style of `video(_:)`.
    public static func ffmpegVideo(_ name: String, profile: String) -> String {
        let p = profile.trimmingCharacters(in: .whitespaces)
        switch name {
        case "h264": return "H.264 (AVC)"
        case "hevc": return "H.265 (HEVC)"
        case "prores":
            // ffprobe profiles: Proxy, LT, Standard, HQ, 4444, XQ (4444 XQ).
            switch p.lowercased() {
            case "proxy": return "ProRes 422 Proxy"
            case "lt": return "ProRes 422 LT"
            case "hq": return "ProRes 422 HQ"
            case "4444": return "ProRes 4444"
            case "xq", "4444 xq": return "ProRes 4444 XQ"
            default: return "ProRes 422"
            }
        case "dnxhd":
            // "DNXHD", "DNXHR LB" / "SQ" / "HQ" / "HQX" / "444".
            let upper = p.uppercased()
            if upper.hasPrefix("DNXHR") { return "DNxHR" + upper.dropFirst(5) }
            return "DNxHD"
        case "vp8": return "VP8"
        case "vp9": return "VP9"
        case "av1": return "AV1"
        case "mpeg1video": return "MPEG-1"
        case "mpeg2video": return "MPEG-2"
        case "mpeg4": return "MPEG-4 Part 2"
        case "msmpeg4v1", "msmpeg4v2", "msmpeg4v3": return "MS MPEG-4"
        case "h263": return "H.263"
        case "flv1": return "Sorenson Spark"
        case "wmv1", "wmv2", "wmv3": return "WMV"
        case "vc1": return "VC-1"
        case "dvvideo": return "DV"
        case "mjpeg": return "Motion JPEG"
        case "jpeg2000": return "JPEG 2000"
        case "theora": return "Theora"
        case "cfhd": return "CineForm"
        case "ffv1": return "FFV1"
        case "huffyuv", "ffvhuff": return "HuffYUV"
        case "utvideo": return "Ut Video"
        case "rawvideo", "v210", "v410", "r210": return "Uncompressed"
        case "hap": return "HAP"
        case "": return "Video"
        default: return name.uppercased()
        }
    }

    /// Inspect's name for an audio codec as ffprobe reports it; PCM with its bit depth, as `extractAudioInfo` writes it.
    public static func ffmpegAudio(_ name: String, bits: Int) -> String {
        if name.hasPrefix("pcm_") {
            if name.hasPrefix("pcm_f") { return "PCM (\(bits > 0 ? bits : name.contains("64") ? 64 : 32)-bit float)" }
            let fromName = name.dropFirst(5).filter(\.isNumber)
            let depth = bits > 0 ? bits : Int(fromName.prefix(2)) ?? 0
            return depth > 0 ? "PCM (\(depth)-bit)" : "Linear PCM"
        }
        switch name {
        case "aac", "aac_latm": return "AAC"
        case "alac": return "ALAC"
        case "ac3": return "AC-3 (Dolby Digital)"
        case "eac3": return "E-AC-3"
        case "truehd": return "Dolby TrueHD"
        case "dts": return "DTS"
        case "mp1": return "MP1"
        case "mp2": return "MP2"
        case "mp3": return "MP3"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "wmav1", "wmav2": return "WMA"
        case "wmapro": return "WMA Pro"
        case "wmalossless": return "WMA Lossless"
        case "amr_nb", "amr_wb": return "AMR"
        case "": return "Audio"
        default: return name.uppercased()
        }
    }
}
