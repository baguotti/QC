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
}
