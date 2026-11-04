import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import VideoQCLib

// MARK: - Hardware-Accelerated Glitch Thumbnail Provider

public actor GlitchThumbnailProvider {
    public static let shared = GlitchThumbnailProvider()
    
    private var cache: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private var generators: [URL: (generator: AVAssetImageGenerator, modified: Date?)] = [:]
    private var generatorOrder: [URL] = [] // least recently used first
    private let maxCacheItems = 300
    /// Off for skim frames: the view keeps them for the hover, and 40 per thumbnail would push the posters out of this
    /// first-in-first-out cache (they'd then decode again on every scroll back).
    private var storing = true
    
    public init() {}
    
    public func getThumbnail(
        for url: URL,
        frameIndex: Int,
        fps: Double,
        targetSize: CGSize = CGSize(width: 200, height: 112),
        fast: Bool = false,
        cache cacheResult: Bool = true
    ) -> CGImage? {
        // The modification date is in the key: a file re-exported under the same name gets new thumbnails (read from
        // disk each time; URL resource values are cached per URL and would hide the change).
        storing = cacheResult
        defer { storing = true }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = "\(url.standardizedFileURL.path)_\(modified?.timeIntervalSince1970 ?? 0)_\(frameIndex)_\(Int(targetSize.width))x\(Int(targetSize.height))"
        if let cached = cache[key] {
            return cached
        }
        switch QCUtilities.mediaKind(of: url) {
        case .audio:
            return nil
        case .image:
            // Uses the file's embedded thumbnail when it has one (JPEG/HEIC), so large stills stay cheap.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(targetSize.width, targetSize.height))
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            storeInCache(key: key, image: thumb)
            return thumb
        default:
            break
        }
        
        let gen: AVAssetImageGenerator
        let stdURL = url.standardizedFileURL
        if let existing = generators[stdURL], existing.modified == modified {
            gen = existing.generator
            if let index = generatorOrder.firstIndex(of: stdURL) {
                generatorOrder.remove(at: index)
            }
            generatorOrder.append(stdURL)
        } else {
            if generators[stdURL] != nil {
                generatorOrder.removeAll { $0 == stdURL }
            } else if generators.count >= 16, !generatorOrder.isEmpty {
                generators.removeValue(forKey: generatorOrder.removeFirst())
            }
            let asset = AVURLAsset(url: stdURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let newGen = AVAssetImageGenerator(asset: asset)
            newGen.appliesPreferredTrackTransform = true
            generators[stdURL] = (newGen, modified)
            generatorOrder.append(stdURL)
            gen = newGen
        }
        
        gen.maximumSize = targetSize
        
        let safeFps = fps > 0 ? fps : 25.0
        let seconds = (Double(frameIndex) + 0.5) / safeFps
        let time = CMTime(seconds: seconds, preferredTimescale: 60000)
        
        // Frame 0 and skimming allow keyframe tolerance for near-instant decoding.
        if frameIndex == 0 || fast {
            let keyframeTol = CMTime(seconds: fast ? 0.25 : 0.5, preferredTimescale: 60000)
            gen.requestedTimeToleranceBefore = keyframeTol
            gen.requestedTimeToleranceAfter = keyframeTol
            if let cgImage = try? gen.copyCGImage(at: time, actualTime: nil) {
                storeInCache(key: key, image: cgImage)
                return cgImage
            }
        }
        
        // Accurate seek for frame-specific glitch reviews
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        
        do {
            var actual = CMTime.zero
            let cgImage = try gen.copyCGImage(at: time, actualTime: &actual)
            storeInCache(key: key, image: cgImage)
            return cgImage
        } catch {
            let fallbackTol = CMTime(seconds: 0.1, preferredTimescale: 60000)
            gen.requestedTimeToleranceBefore = fallbackTol
            gen.requestedTimeToleranceAfter = fallbackTol
            if let fallbackImage = try? gen.copyCGImage(at: time, actualTime: nil) {
                storeInCache(key: key, image: fallbackImage)
                return fallbackImage
            }
            return nil
        }
    }
    
    private func storeInCache(key: String, image: CGImage) {
        guard storing else { return }
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
        generatorOrder.removeAll()
    }
}

// MARK: - Glitch Thumbnail View with Edge Highlighting

public struct GlitchThumbnailView: View {
    /// Redraws the row when its list redraws for a new accent (`ThemeManager.revision`).
    var themeRevision = ThemeManager.shared.revision
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
                            .font(.system(size: 10))   // design-ok: drawn on the thumbnail tile, sized to the image, not the UI
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
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control).stroke(Color(white: 0.3), lineWidth: 1))
            }
            
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    HStack(spacing: 6) {
                        if let tc = timecode {
                            Text(tc)
                                .font(.system(size: 10, weight: .heavy, design: .monospaced))   // design-ok: drawn on the thumbnail tile, sized to the image, not the UI
                                .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.4))
                        }
                        Text("FRAME \(frameIndex)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))   // design-ok: drawn on the thumbnail tile, sized to the image, not the UI
                            .foregroundColor(Color(white: 0.7))
                        
                        if let edge = edge {
                            Text("•")
                                .foregroundColor(Color(white: 0.5))
                            Text("\(edge.rawValue.uppercased()) EDGE")
                                .font(.system(size: 9, weight: .black, design: .monospaced))   // design-ok: drawn on the thumbnail tile, sized to the image, not the UI
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
                            .font(.ui(size: 10, weight: .semibold))
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
    /// Redraws the row when its list redraws for a new accent (`ThemeManager.revision`).
    var themeRevision = ThemeManager.shared.revision
    public let fileURL: URL
    public var width: CGFloat = 50
    public var height: CGFloat = 29
    public var cornerRadius: CGFloat = 2.5
    public var badgeText: String? = nil
    public var badgeColor: Color = Color.clear
    /// Skimming (Inspect's thumbnails): the clip's length and rate; moving the mouse across scrubs it. 0 = off.
    public var skimDuration: Double = 0
    public var skimFPS: Double = 25
    
    @State private var image: CGImage? = nil
    @State private var isLoading: Bool = true
    /// Frame 0, shown when the mouse leaves.
    @State private var poster: CGImage? = nil
    /// The skim position (one of `skimSteps`) and the mouse's x, nil while the mouse is elsewhere.
    @State private var skimStep: Int? = nil
    @State private var skimX: CGFloat = 0
    /// Frames fetched for this hover (dropped when the mouse leaves) and the task fetching them.
    @State private var skimFrames: [Int: CGImage] = [:]
    @State private var skimTask: Task<Void, Never>? = nil
    private static let skimSteps = 40
    
    public init(
        fileURL: URL,
        width: CGFloat = 50,
        height: CGFloat = 29,
        cornerRadius: CGFloat = 2.5,
        badgeText: String? = nil,
        badgeColor: Color = Color.clear,
        skimDuration: Double = 0,
        skimFPS: Double = 25
    ) {
        self.fileURL = fileURL
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.badgeText = badgeText
        self.badgeColor = badgeColor
        self.skimDuration = skimDuration
        self.skimFPS = skimFPS
    }
    
    public var body: some View {
        ZStack(alignment: .center) {
            if let img = image {
                let imgW = CGFloat(img.width)
                let imgH = CGFloat(max(1, img.height))
                let aspect = imgW / imgH
                let slotAspect = width / max(1, height)
                
                let fitWidth: CGFloat = aspect > slotAspect ? width : max(1, round(height * aspect))
                let fitHeight: CGFloat = aspect > slotAspect ? max(1, round(width / aspect)) : height
                
                ZStack(alignment: .topLeading) {
                    Image(decorative: img, scale: 1.0, orientation: .up)
                        .resizable()
                        .frame(width: fitWidth, height: fitHeight)
                    
                    if let badge = badgeText {
                        Text(badge)
                            .font(.system(size: 7.5, weight: .black, design: .monospaced))   // design-ok: drawn on the thumbnail tile, sized to the image, not the UI
                            .foregroundColor(.white)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(badgeColor)
                            .clipShape(RoundedRectangle(cornerRadius: 1.5))
                            .padding(2)
                    }
                }
                .frame(width: fitWidth, height: fitHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color(white: 0.22), lineWidth: 1)
                )
            } else {
                ZStack {
                    Color(white: 0.12)
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.35)
                    } else {
                        Image(systemName: QCUtilities.mediaKind(of: fileURL) == .audio ? "waveform" : "video")
                            .font(.system(size: 9))   // design-ok: drawn on the thumbnail tile, sized to the image, not the UI
                            .foregroundColor(Color(white: 0.35))
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(Color(white: 0.22), lineWidth: 1)
                )
            }
        }
        .frame(width: width, height: height, alignment: .center)
        .overlay(alignment: .bottomLeading) {
            if skimStep != nil {
                Rectangle()
                    .fill(StudioTheme.accentBlue)
                    .frame(width: 2, height: height)
                    .offset(x: min(max(0, skimX - 1), width - 2))   // follows the mouse, not the steps
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            guard skimDuration > 0 else { return }
            switch phase {
            case .active(let point):
                skimX = point.x
                let step = min(Self.skimSteps - 1, max(0, Int(point.x / max(1, width) * CGFloat(Self.skimSteps))))
                guard step != skimStep else { return }
                skimStep = step
                if let frame = skimFrames[step] { image = frame }
                if skimTask == nil { startSkimming() }   // after a short dwell: sweeping across the list fetches nothing
            case .ended:
                skimTask?.cancel()
                skimTask = nil
                skimStep = nil
                skimFrames = [:]
                if let poster { image = poster }
            }
        }
        .task(id: "\(fileURL.path)|\(Self.pixelBucket(width))") {
            // Requested at about the drawn size (×2 for Retina) so big thumbnails stay sharp, in steps: dragging the
            // size slider (or resizing the preview window) only fetches again when a step is crossed, not per point.
            let targetSize = Self.targetSize(width: width, height: height)
            if let img = await GlitchThumbnailProvider.shared.getThumbnail(
                for: fileURL,
                frameIndex: 0,
                fps: skimFPS > 0 ? skimFPS : 25.0,
                targetSize: targetSize
            ) {
                guard !Task.isCancelled else { return }
                poster = img
                if skimStep == nil { image = img }
            }
            self.isLoading = false
        }
    }
}

extension AssetThumbnailView {
    /// Fetches every skim position while the mouse is over the thumbnail, nearest to the mouse first, so moving across
    /// it shows frames already fetched (smooth) instead of waiting on each step. Frames are at the drawn size (not ×2:
    /// they're glimpses) and dropped when the mouse leaves.
    fileprivate func startSkimming() {
        let url = fileURL, duration = skimDuration, fps = skimFPS > 0 ? skimFPS : 25
        let size = CGSize(width: max(120, width.rounded()), height: max(68, height.rounded()))
        skimTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var missing = Set(0..<Self.skimSteps)
            while !missing.isEmpty, !Task.isCancelled {
                let target = skimStep ?? 0
                let step = missing.min { abs($0 - target) < abs($1 - target) }!
                missing.remove(step)
                let frame = Int((Double(step) + 0.5) / Double(Self.skimSteps) * duration * fps)
                guard let img = await GlitchThumbnailProvider.shared.getThumbnail(for: url, frameIndex: frame, fps: fps,
                                                                                   targetSize: size, fast: true, cache: false),
                      !Task.isCancelled else { continue }
                skimFrames[step] = img
                if skimStep == step { image = img }
            }
        }
    }
}

extension AssetThumbnailView {
    /// Pixel widths thumbnails are fetched at (≥ 2× the drawn width, capped: a big preview window needs no more).
    private static let pixelSteps: [CGFloat] = [160, 240, 320, 480, 640, 960, 1280]

    static func pixelBucket(_ width: CGFloat) -> CGFloat {
        pixelSteps.first { $0 >= width * 2 } ?? pixelSteps.last!
    }

    static func targetSize(width: CGFloat, height: CGFloat) -> CGSize {
        let w = pixelBucket(width)
        return CGSize(width: w, height: max(90, (w * height / max(1, width)).rounded()))
    }
}
