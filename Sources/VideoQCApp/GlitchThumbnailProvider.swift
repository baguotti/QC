import SwiftUI
import AppKit
import AVFoundation
import VideoQCLib

// MARK: - Hardware-Accelerated Glitch Thumbnail Provider

public actor GlitchThumbnailProvider {
    public static let shared = GlitchThumbnailProvider()
    
    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private var generators: [URL: AVAssetImageGenerator] = [:]
    private let maxCacheItems = 300
    
    public init() {}
    
    public func getThumbnail(
        for url: URL,
        frameIndex: Int,
        fps: Double,
        targetSize: CGSize = CGSize(width: 320, height: 180)
    ) -> CGImage? {
        let key = "\(url.standardizedFileURL.path)_\(frameIndex)_\(Int(targetSize.width))x\(Int(targetSize.height))"
        if let cached = cache[key] {
            return cached
        }
        
        let gen: AVAssetImageGenerator
        let stdURL = url.standardizedFileURL
        if let existing = generators[stdURL] {
            gen = existing
        } else {
            let asset = AVURLAsset(url: stdURL)
            let newGen = AVAssetImageGenerator(asset: asset)
            newGen.appliesPreferredTrackTransform = true
            newGen.requestedTimeToleranceBefore = .zero
            newGen.requestedTimeToleranceAfter = .zero
            generators[stdURL] = newGen
            gen = newGen
        }
        
        gen.maximumSize = targetSize
        
        let safeFps = fps > 0 ? fps : 25.0
        // Exact frame center PTS so zero tolerance lands squarely inside target frame
        let seconds = (Double(frameIndex) + 0.5) / safeFps
        let time = CMTime(seconds: seconds, preferredTimescale: 60000)
        
        do {
            var actual = CMTime.zero
            let cgImage = try gen.copyCGImage(at: time, actualTime: &actual)
            storeInCache(key: key, image: cgImage)
            return cgImage
        } catch {
            // Fallback with 0.02s tolerance if PTS truncation occurs at file boundary
            let fallbackTol = CMTime(seconds: 0.02, preferredTimescale: 60000)
            gen.requestedTimeToleranceBefore = fallbackTol
            gen.requestedTimeToleranceAfter = fallbackTol
            defer {
                gen.requestedTimeToleranceBefore = .zero
                gen.requestedTimeToleranceAfter = .zero
            }
            if let fallbackImage = try? gen.copyCGImage(at: time, actualTime: nil) {
                storeInCache(key: key, image: fallbackImage)
                return fallbackImage
            }
            return nil
        }
    }
    
    private func storeInCache(key: String, image: CGImage) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > maxCacheItems {
                let evictKey = cacheOrder.removeFirst()
                cache.removeValue(forKey: evictKey)
            }
        }
        cache[key] = image
    }
    
    public func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        generators.removeAll()
    }
}

// MARK: - Glitch Thumbnail View with Edge Highlighting

public struct GlitchThumbnailView: View {
    public let fileURL: URL
    public let frameIndex: Int
    public let fps: Double
    public let timecode: String?
    public let edge: EdgeLocation?
    public let detectedColor: VideoQCLib.RGBColor?
    public var width: CGFloat = 72
    public var height: CGFloat = 40
    public var cornerRadius: CGFloat = 3.0
    
    @State private var image: CGImage? = nil
    @State private var isLoading: Bool = true
    @State private var showPreviewPopover: Bool = false
    
    public init(
        fileURL: URL,
        frameIndex: Int,
        fps: Double,
        timecode: String? = nil,
        edge: EdgeLocation? = nil,
        detectedColor: VideoQCLib.RGBColor? = nil,
        width: CGFloat = 72,
        height: CGFloat = 40,
        cornerRadius: CGFloat = 3.0
    ) {
        self.fileURL = fileURL
        self.frameIndex = frameIndex
        self.fps = fps
        self.timecode = timecode
        self.edge = edge
        self.detectedColor = detectedColor
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }
    
    public var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black)
            
            if let img = image {
                Image(decorative: img, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
                    .overlay {
                        if let edge = edge {
                            edgeGlitchOverlay(for: edge, color: detectedColor)
                        }
                    }
            } else {
                ZStack {
                    Color(white: 0.10)
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 10))
                            .foregroundColor(Color(white: 0.35))
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
        .popover(isPresented: $showPreviewPopover, arrowEdge: .trailing) {
            enlargedPreviewView
        }
        .contextMenu {
            Button("Preview Frame") {
                showPreviewPopover = true
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        }
        .task(id: "\(fileURL.path)_\(frameIndex)") {
            isLoading = true
            let targetSize = CGSize(width: max(160, width * 2.5), height: max(90, height * 2.5))
            if let img = await GlitchThumbnailProvider.shared.getThumbnail(
                for: fileURL,
                frameIndex: frameIndex,
                fps: fps,
                targetSize: targetSize
            ) {
                self.image = img
            }
            self.isLoading = false
        }
    }
    
    @ViewBuilder
    private var enlargedPreviewView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let img = image {
                ZStack {
                    Color.black
                    Image(decorative: img, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            if let edge = edge {
                                edgeGlitchOverlay(for: edge, color: detectedColor, lineWidth: 3)
                            }
                        }
                }
                .frame(width: 360, height: 202)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.3), lineWidth: 1))
            }
            
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        if let tc = timecode {
                            Text(tc)
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.4))
                        }
                        Text("FRAME \(frameIndex)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.7))
                        
                        if let edge = edge {
                            Text("•")
                                .foregroundColor(Color(white: 0.5))
                            Text("\(edge.rawValue.uppercased()) EDGE")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(Color(red: 0.95, green: 0.3, blue: 0.3))
                        }
                    }
                }
                Spacer()
                
                if let c = detectedColor {
                    HStack(spacing: 4) {
                        Rectangle()
                            .fill(Color(red: Double(c.r)/255, green: Double(c.g)/255, blue: Double(c.b)/255))
                            .frame(width: 10, height: 10)
                            .border(Color.white.opacity(0.4), width: 1)
                        Text(c.hexString.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        .frame(width: 384)
    }
    
    @ViewBuilder
    private func edgeGlitchOverlay(for edge: EdgeLocation, color: VideoQCLib.RGBColor?, lineWidth: CGFloat = 2) -> some View {
        let lineColor: Color = {
            if let c = color {
                let lum = (Double(c.r) * 0.299 + Double(c.g) * 0.587 + Double(c.b) * 0.114)
                if lum < 40 {
                    return Color.red
                }
                return Color(red: Double(c.r)/255, green: Double(c.g)/255, blue: Double(c.b)/255)
            }
            return Color.red
        }()
        
        GeometryReader { geo in
            switch edge {
            case .top:
                Rectangle()
                    .fill(lineColor)
                    .frame(height: lineWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .shadow(color: lineColor.opacity(0.9), radius: 2)
            case .bottom:
                Rectangle()
                    .fill(lineColor)
                    .frame(height: lineWidth)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .shadow(color: lineColor.opacity(0.9), radius: 2)
            case .left:
                Rectangle()
                    .fill(lineColor)
                    .frame(width: lineWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: lineColor.opacity(0.9), radius: 2)
            case .right:
                Rectangle()
                    .fill(lineColor)
                    .frame(width: lineWidth)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .shadow(color: lineColor.opacity(0.9), radius: 2)
            case .splitHorizontal:
                Rectangle()
                    .fill(lineColor)
                    .frame(height: lineWidth)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .shadow(color: lineColor.opacity(0.9), radius: 2)
            case .splitVertical:
                Rectangle()
                    .fill(lineColor)
                    .frame(width: lineWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .shadow(color: lineColor.opacity(0.9), radius: 2)
            }
        }
    }
}

// MARK: - General Asset Video Thumbnail View

public struct AssetThumbnailView: View {
    public let fileURL: URL
    public var width: CGFloat = 50
    public var height: CGFloat = 29
    public var cornerRadius: CGFloat = 2.5
    public var badgeText: String? = nil
    public var badgeColor: Color = Color.clear
    
    @State private var image: CGImage? = nil
    @State private var isLoading: Bool = true
    
    public init(
        fileURL: URL,
        width: CGFloat = 50,
        height: CGFloat = 29,
        cornerRadius: CGFloat = 2.5,
        badgeText: String? = nil,
        badgeColor: Color = Color.clear
    ) {
        self.fileURL = fileURL
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.badgeText = badgeText
        self.badgeColor = badgeColor
    }
    
    public var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.black)
            
            if let img = image {
                Image(decorative: img, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            } else {
                ZStack {
                    Color(white: 0.12)
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.35)
                    } else {
                        Image(systemName: "video")
                            .font(.system(size: 9))
                            .foregroundColor(Color(white: 0.35))
                    }
                }
            }
            
            if let badge = badgeText {
                Text(badge)
                    .font(.system(size: 7.5, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(badgeColor)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    .padding(2)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color(white: 0.22), lineWidth: 1)
        )
        .task(id: fileURL.path) {
            isLoading = true
            let targetSize = CGSize(width: max(140, width * 2.5), height: max(80, height * 2.5))
            if let img = await GlitchThumbnailProvider.shared.getThumbnail(
                for: fileURL,
                frameIndex: 0,
                fps: 25.0,
                targetSize: targetSize
            ) {
                self.image = img
            }
            self.isLoading = false
        }
    }
}
