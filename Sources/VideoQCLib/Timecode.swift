import Foundation
import CoreMedia

public struct TimecodeFormatter: Sendable {
    
    /// Formats a frame number and frame rate into SMPTE timecode string (HH:MM:SS:FF)
    public static func format(frameIndex: Int, fps: Double, startFrameOffset: Int = 0) -> String {
        // Clamped: Int() traps on huge values, and a damaged file can report any rate or offset.
        let nominalFps = fps.isFinite ? min(max(1.0, fps), 1000) : 25.0
        let roundedFps = Int(round(nominalFps))
        let (sum, overflow) = frameIndex.addingReportingOverflow(startFrameOffset)
        let effectiveFrame = max(0, overflow ? Int.max : sum)
        
        let framesPerHour = roundedFps * 3600
        let framesPerMinute = roundedFps * 60
        
        let hours = effectiveFrame / framesPerHour
        let remainderAfterHours = effectiveFrame % framesPerHour
        
        let minutes = remainderAfterHours / framesPerMinute
        let remainderAfterMinutes = remainderAfterHours % framesPerMinute
        
        let seconds = remainderAfterMinutes / roundedFps
        let frames = remainderAfterMinutes % roundedFps
        
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }
    
    /// Formats CMTime into SMPTE timecode
    public static func format(time: CMTime, fps: Double, startFrameOffset: Int = 0) -> String {
        guard fps > 0 else { return "00:00:00:00" }
        let seconds = CMTimeGetSeconds(time)
        guard seconds >= 0, seconds.isFinite, fps.isFinite else { return "00:00:00:00" }
        let frames = round(seconds * fps)
        let frameIndex = frames < Double(Int.max / 2) ? Int(frames) : Int.max / 2
        return format(frameIndex: frameIndex, fps: fps, startFrameOffset: startFrameOffset)
    }
}

/// Frame rates as the Player counts frames, shared by everything that hands it frame numbers (scans, imported notes).
public enum FrameRate {
    private static let standard: [Double] = [
        24000.0 / 1001.0, 24, 25, 30000.0 / 1001.0, 30, 48000.0 / 1001.0, 48, 50, 60000.0 / 1001.0, 60,
        100, 120000.0 / 1001.0, 120
    ]

    /// The broadcast rate closest to `fps` when within `tolerance` (relative), else nil.
    public static func nearestStandard(_ fps: Double, within tolerance: Double) -> Double? {
        guard let best = standard.min(by: { abs($0 - fps) < abs($1 - fps) }), abs(best - fps) / best <= tolerance else { return nil }
        return best
    }

    /// A track's nominal (average) rate as frames are counted: variable-rate clips (phones, screen recordings) average a
    /// little off their real rate (30.25 for a 30 fps clip with one short gap), which drifts frame numbers ~15 a minute.
    public static func counting(nominal: Double) -> Double {
        guard nominal.isFinite, nominal > 0 else { return 25 }
        return nearestStandard(nominal, within: 0.01) ?? nominal
    }
}
