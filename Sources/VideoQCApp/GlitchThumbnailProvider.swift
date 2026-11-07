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
    private let maxCacheItems = 300

    /// How exactly a frame is asked for. Each has its own generator: a generator's tolerances apply to every request on
    /// it, so sharing one let a keyframe-tolerant request (poster, skim) loosen an exact one (a Line Check frame).
    private enum Precision: Hashable {
        case skim       // 0.25 s: hover skimming
        case keyframe   // 0.5 s: frame-0 posters
        case exact      // the frame itself
        case near       // 0.1 s: a file that refuses the exact time

        var tolerance: CMTime {
            switch self {
            case .skim: return CMTime(seconds: 0.25, preferredTimescale: 60000)
            case .keyframe: return CMTime(seconds: 0.5, preferredTimescale: 60000)
            case .exact: return .zero
            case .near: return CMTime(seconds: 0.1, preferredTimescale: 60000)
            }
        }
    }

    private struct GeneratorKey: Hashable {
        let url: URL
        let precision: Precision
        let width: Int
        let height: Int
    }

    /// One asset per file (opened once), generators per precision and size, least recently used evicted.
    private var assets: [URL: (asset: AVURLAsset, modified: Date?)] = [:]
    private var generators: [GeneratorKey: AVAssetImageGenerator] = [:]
    private var generatorOrder: [GeneratorKey] = []
    private let maxGenerators = 32

    /// Decodes run side by side (they used to queue behind one another on this actor: a hover's 40 skim frames held up
    /// every poster scrolled into view), a few at a time so the Player's hardware decoder isn't starved.
    private let maxConcurrentDecodes = 4
    private var runningDecodes = 0
    private var decodeWaiters: [CheckedContinuation<Void, Never>] = []
    
    public init() {}
    
    public func getThumbnail(
        for url: URL,
        frameIndex: Int,
        fps: Double,
        targetSize: CGSize = CGSize(width: 200, height: 112),
        fast: Bool = false,
        cache cacheResult: Bool = true
    ) async -> CGImage? {
        // The modification date is in the key: a file re-exported under the same name gets new thumbnails (read from
        // disk each time; URL resource values are cached per URL and would hide the change).
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
            await acquireDecodeSlot()
            guard !Task.isCancelled else { releaseDecodeSlot(); return nil }
            let maxSide = Int(max(targetSize.width, targetSize.height))
            let thumb = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxSide
                ]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            releaseDecodeSlot()
            if let thumb, cacheResult { storeInCache(key: key, image: thumb) }
            return thumb
        default:
            break
        }
        
        let safeFps = fps > 0 ? fps : 25.0
        let time = CMTime(seconds: (Double(frameIndex) + 0.5) / safeFps, preferredTimescale: 60000)
        let stdURL = url.standardizedFileURL
        // Frame 0 and skimming allow keyframe tolerance for near-instant decoding; then the exact frame, then near it.
        var attempts: [Precision] = [.exact, .near]
        if fast { attempts.insert(.skim, at: 0) } else if frameIndex == 0 { attempts.insert(.keyframe, at: 0) }

        await acquireDecodeSlot()
        defer { releaseDecodeSlot() }
        // A row scrolled past (or a skim the pointer left) while waiting: don't decode for it ahead of rows on screen.
        guard !Task.isCancelled else { return nil }
        for precision in attempts {
            let generator = self.generator(for: stdURL, modified: modified, precision: precision, size: targetSize)
            if let image = await decode(generator, at: time) {
                if cacheResult { storeInCache(key: key, image: image) }
                return image
            }
        }
        return nil
    }

    /// The asynchronous request: the actor is free for other requests while the frame decodes.
    private func decode(_ generator: AVAssetImageGenerator, at time: CMTime) async -> CGImage? {
        await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private func generator(for url: URL, modified: Date?, precision: Precision, size: CGSize) -> AVAssetImageGenerator {
        // A re-exported file (new modification date) gets a fresh asset and generators.
        if let entry = assets[url], entry.modified != modified {
            assets[url] = nil
            for key in generators.keys where key.url == url { generators[key] = nil }
            generatorOrder.removeAll { $0.url == url }
        }
        let key = GeneratorKey(url: url, precision: precision, width: Int(size.width), height: Int(size.height))
        if let existing = generators[key] {
            if let index = generatorOrder.firstIndex(of: key) { generatorOrder.remove(at: index) }
            generatorOrder.append(key)
            return existing
        }
        if generators.count >= maxGenerators, !generatorOrder.isEmpty {
            let evicted = generatorOrder.removeFirst()
            generators[evicted] = nil
            // The asset goes with its last generator.
            if !generators.keys.contains(where: { $0.url == evicted.url }) { assets[evicted.url] = nil }
        }
        let asset = assets[url]?.asset ?? AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        assets[url] = (asset, modified)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = precision.tolerance
        generator.requestedTimeToleranceAfter = precision.tolerance
        generators[key] = generator
        generatorOrder.append(key)
        return generator
    }

    private func acquireDecodeSlot() async {
        if runningDecodes < maxConcurrentDecodes {
            runningDecodes += 1
            return
        }
        await withCheckedContinuation { decodeWaiters.append($0) }
    }

    private func releaseDecodeSlot() {
        // The slot passes straight to the next waiter (the count stays), so it can't be taken in between.
        if decodeWaiters.isEmpty {
            runningDecodes -= 1
        } else {
            decodeWaiters.removeFirst().resume()
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
        assets.removeAll()
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
            // Three in flight (the provider decodes four at once: one stays free for posters scrolling into view), each
            // next one the nearest to where the pointer is now.
            let steps = Self.skimSteps
            func nearest(to target: Int) -> (step: Int, frame: Int)? {
                guard let step = missing.min(by: { abs($0 - target) < abs($1 - target) }) else { return nil }
                missing.remove(step)
                return (step, Int((Double(step) + 0.5) / Double(steps) * duration * fps))
            }
            await withTaskGroup(of: (Int, CGImage?).self) { group in
                for _ in 0..<3 {
                    guard let next = nearest(to: skimStep ?? 0) else { break }
                    group.addTask {
                        (next.step, await GlitchThumbnailProvider.shared.getThumbnail(for: url, frameIndex: next.frame, fps: fps,
                                                                                      targetSize: size, fast: true, cache: false))
                    }
                }
                for await (step, img) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let img {
                        skimFrames[step] = img
                        if skimStep == step { image = img }
                    }
                    if let next = nearest(to: skimStep ?? 0) {
                        group.addTask {
                            (next.step, await GlitchThumbnailProvider.shared.getThumbnail(for: url, frameIndex: next.frame, fps: fps,
                                                                                          targetSize: size, fast: true, cache: false))
                        }
                    }
                }
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
