import Foundation
import Testing
@testable import QCpie

@Suite("Frame.io preview")
struct FrameIOPreviewTests {
    @Test("Proxy links decode; one that comes as download_url only still streams")
    func links() throws {
        let json = """
        {"id": "F1", "type": "file", "name": "Clip.mov", "media_links": {
          "efficient": {"download_url": "https://stream-download.frame.io/manifest/hls?token=x"},
          "video_h264_180": {"url": "https://assets.frame.io/encode/F1/video_h264_180.mp4", "download_url": "https://x/y"},
          "high_quality": {"download_url": "https://assets.frame.io/image/F1/full.png"},
          "original": {"download_url": "https://assets.frame.io/uploads/F1/o", "inline_url": null},
          "thumbnail_high_quality": {"url": "https://assets.frame.io/thumb.jpg"}}, "media_type": "audio/x-wav"}
        """
        let item = try JSONDecoder().decode(FrameIO.Item.self, from: Data(json.utf8))
        #expect(item.mediaLinks?.efficient?.stream?.host == "stream-download.frame.io")
        #expect(item.mediaLinks?.videoH264180?.stream?.lastPathComponent == "video_h264_180.mp4")
        #expect(item.mediaLinks?.thumbnailHighQuality?.url == "https://assets.frame.io/thumb.jpg")
        #expect(item.mediaType == "audio/x-wav")
        #expect(item.mediaLinks?.highQuality?.stream?.lastPathComponent == "full.png")
        #expect(item.mediaLinks?.original?.downloadURL == "https://assets.frame.io/uploads/F1/o")
        #expect(item.mediaLinks?.original?.inlineURL == nil)
    }

    @MainActor @Test("Files and stacks preview; folders and projects don't")
    func previewable() throws {
        func item(_ type: String?) throws -> FrameIO.Item {
            var json: [String: Any] = ["id": "X"]
            if let type { json["type"] = type }
            return try JSONDecoder().decode(FrameIO.Item.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(FrameIOPreview.canPreview(try item("file")))
        #expect(FrameIOPreview.canPreview(try item("version_stack")))
        #expect(!FrameIOPreview.canPreview(try item("folder")))
        #expect(!FrameIOPreview.canPreview(try item(nil)))
    }
}
