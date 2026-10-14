import AppKit
import ImageIO
import VideoQCLib

/// The picture a non-video slot shows on its still frame layer: the decoded image, or an info card for audio.
enum MediaStills {
    static let audioCardSize = CGSize(width: 1920, height: 1080)

    /// Fully decoded (so the first display doesn't decode on the main thread), EXIF orientation applied.
    nonisolated static func decodeImage(at url: URL) -> (image: CGImage, format: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, DeliverablesInspector.imageFormatDescription(source: source, properties: props))
    }

    @MainActor
    static func audioCard(fileName: String, details: [String]) -> CGImage? {
        let size = audioCardSize
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(white: 0.11, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        var y = size.height / 2 + 150
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 150, weight: .light)
        if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                NSColor(white: 0.55, alpha: 1).set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: (size.width - symbol.size.width) / 2, y: y - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
        }
        y -= 190

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        func draw(_ text: String, font: NSFont, color: NSColor) {
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            let height = ceil(attributed.size().height)
            attributed.draw(in: NSRect(x: 160, y: y - height, width: size.width - 320, height: height))
            y -= height + 18
        }
        draw(fileName, font: .systemFont(ofSize: 56, weight: .semibold), color: NSColor(white: 0.92, alpha: 1))
        y -= 10
        for line in details where !line.isEmpty {
            draw(line, font: .monospacedSystemFont(ofSize: 34, weight: .medium), color: NSColor(white: 0.6, alpha: 1))
        }
        return rep.cgImage
    }
}
