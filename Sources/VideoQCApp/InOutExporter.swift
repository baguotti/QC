import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import VideoQCLib

/// Writes a time range of a file to a new file, off the main thread: passthrough (original samples, no quality loss)
/// when the container allows it, else the highest-quality preset.
enum InOutExporter {
    struct Failed: LocalizedError {
        let errorDescription: String?
    }

    static func export(source: URL, range: CMTimeRange, to target: URL) async throws {
        let asset = AVURLAsset(url: source)
        let ext = target.pathExtension.lowercased()
        let type: AVFileType = ext == "m4a" ? .m4a : ext == "mp4" ? .mp4 : .mov
        let presets = type == .m4a ? [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A]
            : [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        // Written beside the target and moved over it only once complete: a failed export used to leave nothing where
        // the file being replaced had been.
        let temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(target.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        var lastError: Error?
        for preset in presets {
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type),
                  let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            try? FileManager.default.removeItem(at: temp)
            session.outputURL = temp
            session.outputFileType = type
            session.timeRange = range
            await session.export()
            if session.status == .completed {
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: target)
                }
                return
            }
            lastError = session.error
        }
        throw lastError ?? Failed(errorDescription: "This file can't be exported")
    }
}
