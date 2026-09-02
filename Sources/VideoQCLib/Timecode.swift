import Foundation
import CoreMedia

public struct TimecodeFormatter: Sendable {
    
    /// Formats a frame number and frame rate into SMPTE timecode string (HH:MM:SS:FF)
    public static func format(frameIndex: Int, fps: Double, startFrameOffset: Int = 0) -> String {
        let nominalFps = max(1.0, fps)
        let roundedFps = Int(round(nominalFps))
        let effectiveFrame = frameIndex + startFrameOffset
        
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
        guard seconds >= 0, !seconds.isNaN else { return "00:00:00:00" }
        let frameIndex = Int(round(seconds * fps))
        return format(frameIndex: frameIndex, fps: fps, startFrameOffset: startFrameOffset)
    }
}
