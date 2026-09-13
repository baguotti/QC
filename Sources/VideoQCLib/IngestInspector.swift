import Foundation
@preconcurrency import AVFoundation
import CoreMedia

public struct IngestInspector: Sendable {
    
    public init() {}
    
    /// Inspects a video file quickly and safely from container headers without sample decoding
    public static func inspectMedia(url: URL) async -> IngestMediaMetadata? {
        let asset = AVURLAsset(url: url)
        
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else { return nil }
            
            // 1. Dimensions & Transform
            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
            let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            let isTransposed = abs(transform.b) == 1.0 && abs(transform.c) == 1.0
            
            let rawW = (naturalSize.width.isFinite && naturalSize.width > 0) ? Int(naturalSize.width) : 0
            let rawH = (naturalSize.height.isFinite && naturalSize.height > 0) ? Int(naturalSize.height) : 0
            let width = isTransposed ? rawH : rawW
            let height = isTransposed ? rawW : rawH
            let resolutionString = (width > 0 && height > 0) ? "\(width) x \(height)" : "--"
            let aspectRatioString = DeliverablesInspector.calculateAspectRatio(width: width, height: height)
            
            // 2. Framerate & Duration
            let rawFPS = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 24.0)
            let fps = (rawFPS.isFinite && rawFPS > 0) ? rawFPS : 24.0
            
            let duration = (try? await asset.load(.duration)) ?? .zero
            let rawDurationSecs = CMTimeGetSeconds(duration)
            let durationSeconds = (rawDurationSecs.isFinite && rawDurationSecs >= 0) ? rawDurationSecs : 0.0
            let totalFrames = Int(max(0.0, min(Double(Int.max - 1), round(durationSeconds * fps))))
            let timecode = TimecodeFormatter.format(frameIndex: totalFrames, fps: fps)
            let formattedDuration = String(format: "%.2fs", durationSeconds)
            
            // 3. Video Codec
            let videoCodec = await DeliverablesInspector.extractVideoCodec(track: videoTrack)
            
            // 4. Audio Info (headers only, zero PCM sample decoding)
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            let audioInfo = await DeliverablesInspector.extractAudioInfo(tracks: audioTracks)
            
            // 5. Camera Info
            let cameraMakeModel = await DeliverablesInspector.extractCameraMakeModel(asset: asset)
            
            // 6. Creation Date & Container
            let (creationDate, formattedCreationDate) = await DeliverablesInspector.extractCreationDate(url: url, asset: asset)
            let container = url.pathExtension.uppercased()
            
            return IngestMediaMetadata(
                width: width,
                height: height,
                resolutionString: resolutionString,
                aspectRatioString: aspectRatioString,
                fps: fps,
                durationSeconds: durationSeconds,
                formattedDuration: formattedDuration,
                totalFrames: totalFrames,
                timecode: timecode,
                videoCodec: videoCodec,
                audioCodec: audioInfo.codec,
                audioConfig: audioInfo.fullDesc,
                cameraMakeModel: cameraMakeModel,
                container: container,
                creationDate: creationDate,
                formattedCreationDate: formattedCreationDate
            )
        } catch {
            return nil
        }
    }
}
