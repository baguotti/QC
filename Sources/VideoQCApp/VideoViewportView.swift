import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import ImageIO

public struct VideoViewportView: NSViewRepresentable {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool
    var allowScrollZoom: Bool
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    
    public init(
        engine: PlayerEngine,
        isLightMode: Bool,
        allowScrollZoom: Bool = true,
        onSingleClick: (() -> Void)? = nil,
        onDoubleClick: (() -> Void)? = nil
    ) {
        self.engine = engine
        self.isLightMode = isLightMode
        self.allowScrollZoom = allowScrollZoom
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
    }
    
    public func makeNSView(context: Context) -> PlayerContainerNSView {
        let view = PlayerContainerNSView()
        view.setup(engine: engine)
        view.allowScrollZoom = allowScrollZoom
        view.onSingleClick = onSingleClick
        view.onDoubleClick = onDoubleClick
        return view
    }
    
    public func updateNSView(_ nsView: PlayerContainerNSView, context: Context) {
        nsView.allowScrollZoom = allowScrollZoom
        nsView.onSingleClick = onSingleClick
        nsView.onDoubleClick = onDoubleClick
        nsView.update(engine: engine, isLightMode: isLightMode)
    }
}

public final class PlayerContainerNSView: NSView {
    public var allowScrollZoom: Bool = true
    public var onSingleClick: (() -> Void)? = nil
    public var onDoubleClick: (() -> Void)? = nil
    
    // Core Layers
    private let canvasLayer = CALayer()
    
    // ARCHITECTURAL MANDATE (DO NOT REMOVE OR BYPASS):
    // stillFrameLayerA & stillFrameLayerB backed by uncompressed CGImage textures MUST be used
    // whenever playback is paused (!isPlaying && !isScrubbing).
    // Apple's AVPlayerLayer compositor automatically downsamples video textures during interactive
    // panning (motion proxying), washing out 1px edge lines into white. CALayer.contents is immune
    // to CoreMedia motion downsampling. See AGENTS.md for full specification.
    
    // Slot B (Underneath in comparison modes)
    private let playerLayerB = AVPlayerLayer()
    private let stillFrameLayerB = CALayer()
    
    // Slot A (Master / Top layer)
    private let playerLayerA = AVPlayerLayer()
    private let stillFrameLayerA = CALayer()
    private let maskLayerA = CAShapeLayer()
    private let stillMaskLayerA = CAShapeLayer()
    
    // Split Divider & Handle
    private let splitDividerLayer = CALayer()
    private let splitHandleLayer = CALayer()
    private let splitHandleGripLayer = CAShapeLayer()
    
    // Center Crosshair Guides, Title Safe Guides & TikTok Safe Area Overlays (Slots A & B)
    private let crosshairLayerA = CAShapeLayer()
    private let crosshairLayerB = CAShapeLayer()
    private let titleSafeLayerA = CAShapeLayer()
    private let titleSafeLayerB = CAShapeLayer()
    private let tikTokOverlayLayerA = CALayer()
    private let tikTokOverlayLayerB = CALayer()
    
    private weak var engine: PlayerEngine?
    private var isDraggingSplit: Bool = false
    private var dragStartLocation: NSPoint? = nil
    private var initialPanOffset: CGSize = .zero
    
    // Performance state cache to prevent 60Hz re-allocations during playback
    private var lastBoundsSize: CGSize = .zero
    private var lastZoomScale: CGFloat = -1
    private var lastPanOffset: CGSize = CGSize(width: -999, height: -999)
    private var lastIsFitZoom: Bool = false
    private var lastCompareMode: CompareMode? = nil
    private var lastSplitPosition: CGFloat = -1
    private var lastIsBlink: Bool = false
    private var lastShowCrosshair: Bool = false
    private var lastShowTitleSafe: Bool = false
    private var lastSafeAreaMode: SafeAreaMode = .off
    private var lastIsNineBySixteen: Bool = false
    private var lastSlotAURL: URL? = nil
    private var lastSlotBURL: URL? = nil
    private var lastExposureEV: Double = 0.0
    private var lastCanvasBoundsSize: CGSize = CGSize(width: -1, height: -1)
    private var lastAspectA: CGFloat = -1
    private var lastAspectB: CGFloat = -1
    private var lastFrameASize: CGSize = CGSize(width: -1, height: -1)
    private var lastFrameBSize: CGSize = CGSize(width: -1, height: -1)
    
    // Still frame inspection caching to eliminate AVPlayerLayer motion-downsampling
    private var lastCapturedTimeA: CMTime? = nil
    private var lastCapturedTimeB: CMTime? = nil
    private var rawStillFrameA: CGImage? = nil
    private var rawStillFrameB: CGImage? = nil
    private var isCapturingStillA: Bool = false
    private var isCapturingStillB: Bool = false
    
    private static var tikTokImage: CGImage? = {
        let name = "TikTokSafeAreaTemplateBlack"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return img
        }
        let appBundleResourceURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name).png")
        if FileManager.default.fileExists(atPath: appBundleResourceURL.path),
           let source = CGImageSourceCreateWithURL(appBundleResourceURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return img
        }
        let devPaths = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/\(name).png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("_icon/\(name).png"),
            URL(fileURLWithPath: "/Users/riccardofusetti/Documents/Coding/The LineFinder 5000/_icon/TikTokSafeAreaTemplateBlack.png")
        ]
        for url in devPaths {
            if FileManager.default.fileExists(atPath: url.path),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return img
            }
        }
        return nil
    }()
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        
        // Canvas Container Layer (anchored at center for clean scaling & translation)
        canvasLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        canvasLayer.backgroundColor = NSColor.clear.cgColor
        canvasLayer.masksToBounds = true
        canvasLayer.borderWidth = 0
        canvasLayer.shadowOpacity = 0
        layer?.addSublayer(canvasLayer)
        
        // Slot B: Player Video Layer (active during comparison playback)
        playerLayerB.videoGravity = .resize
        playerLayerB.magnificationFilter = .linear
        playerLayerB.minificationFilter = .linear
        playerLayerB.backgroundColor = NSColor.clear.cgColor
        playerLayerB.borderWidth = 0
        playerLayerB.shadowOpacity = 0
        playerLayerB.isHidden = true
        playerLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "filters": NSNull(), "magnificationFilter": NSNull(), "minificationFilter": NSNull()]
        canvasLayer.addSublayer(playerLayerB)
        
        // Still Frame Layer B (active when paused for 100% pixel-perfect inspection)
        stillFrameLayerB.contentsGravity = .resize
        stillFrameLayerB.magnificationFilter = .linear
        stillFrameLayerB.minificationFilter = .linear
        stillFrameLayerB.backgroundColor = NSColor.clear.cgColor
        stillFrameLayerB.borderWidth = 0
        stillFrameLayerB.shadowOpacity = 0
        stillFrameLayerB.isHidden = true
        stillFrameLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "filters": NSNull(), "magnificationFilter": NSNull(), "minificationFilter": NSNull()]
        canvasLayer.addSublayer(stillFrameLayerB)
        
        // Slot A: Player Video Layer (Master playback)
        playerLayerA.videoGravity = .resize
        playerLayerA.magnificationFilter = .linear
        playerLayerA.minificationFilter = .linear
        playerLayerA.backgroundColor = NSColor.clear.cgColor
        playerLayerA.borderWidth = 0
        playerLayerA.shadowOpacity = 0
        playerLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "filters": NSNull(), "magnificationFilter": NSNull(), "minificationFilter": NSNull()]
        canvasLayer.addSublayer(playerLayerA)
        
        // Still Frame Layer A (active when paused for 100% pixel-perfect inspection)
        stillFrameLayerA.contentsGravity = .resize
        stillFrameLayerA.magnificationFilter = .linear
        stillFrameLayerA.minificationFilter = .linear
        stillFrameLayerA.backgroundColor = NSColor.clear.cgColor
        stillFrameLayerA.borderWidth = 0
        stillFrameLayerA.shadowOpacity = 0
        stillFrameLayerA.isHidden = true
        stillFrameLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "filters": NSNull(), "magnificationFilter": NSNull(), "minificationFilter": NSNull()]
        canvasLayer.addSublayer(stillFrameLayerA)
        
        // Mask Layer for Layer A (disables implicit animation for instantaneous 120fps wipe tracking)
        maskLayerA.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "frame": NSNull()]
        stillMaskLayerA.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "frame": NSNull()]
        
        // Split Divider Line Layer
        splitDividerLayer.backgroundColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
        splitDividerLayer.isHidden = true
        splitDividerLayer.zPosition = 90
        splitDividerLayer.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        canvasLayer.addSublayer(splitDividerLayer)
        
        // Split Handle Layer (tactile machined pill handle)
        splitHandleLayer.backgroundColor = NSColor(white: 0.94, alpha: 0.98).cgColor
        splitHandleLayer.borderColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.85).cgColor
        splitHandleLayer.borderWidth = 1.0
        splitHandleLayer.shadowColor = NSColor.black.cgColor
        splitHandleLayer.shadowOpacity = 0.65
        splitHandleLayer.shadowOffset = .zero
        splitHandleLayer.shadowRadius = 4.0
        splitHandleLayer.zPosition = 95
        splitHandleLayer.isHidden = true
        splitHandleLayer.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        canvasLayer.addSublayer(splitHandleLayer)
        
        // Tactile micro-groove grip lines inside handle
        splitHandleGripLayer.strokeColor = NSColor(white: 0.25, alpha: 0.85).cgColor
        splitHandleGripLayer.fillColor = nil
        splitHandleGripLayer.lineWidth = 1.0
        splitHandleGripLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull()]
        splitHandleLayer.addSublayer(splitHandleGripLayer)
        
        // Film A Center Crosshair Guide (top-to-bottom centering guide in AB split screen cyan)
        crosshairLayerA.fillColor = nil
        crosshairLayerA.strokeColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
        crosshairLayerA.lineWidth = 1.0
        crosshairLayerA.shadowOpacity = 0
        crosshairLayerA.zPosition = 100
        crosshairLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
        canvasLayer.addSublayer(crosshairLayerA)
        
        // Film B Center Crosshair Guide
        crosshairLayerB.fillColor = nil
        crosshairLayerB.strokeColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
        crosshairLayerB.lineWidth = 1.0
        crosshairLayerB.shadowOpacity = 0
        crosshairLayerB.zPosition = 100
        crosshairLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
        canvasLayer.addSublayer(crosshairLayerB)
        
        // Film A Title Safe & Action Safe overlay (Action Safe 90% and Title Safe 80% in crisp broadcast white)
        titleSafeLayerA.fillColor = nil
        titleSafeLayerA.strokeColor = NSColor(white: 1.0, alpha: 0.9).cgColor
        titleSafeLayerA.lineWidth = 1.0
        titleSafeLayerA.shadowOpacity = 0
        titleSafeLayerA.zPosition = 101
        titleSafeLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
        canvasLayer.addSublayer(titleSafeLayerA)
        
        // Film B Title Safe & Action Safe overlay
        titleSafeLayerB.fillColor = nil
        titleSafeLayerB.strokeColor = NSColor(white: 1.0, alpha: 0.9).cgColor
        titleSafeLayerB.lineWidth = 1.0
        titleSafeLayerB.shadowOpacity = 0
        titleSafeLayerB.zPosition = 101
        titleSafeLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
        canvasLayer.addSublayer(titleSafeLayerB)
        
        // Film A TikTok Safe Area Template overlay (50% opacity, 9:16 only)
        tikTokOverlayLayerA.contentsGravity = .resize
        tikTokOverlayLayerA.opacity = 0.5
        tikTokOverlayLayerA.zPosition = 102
        tikTokOverlayLayerA.isHidden = true
        tikTokOverlayLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
        if let img = PlayerContainerNSView.tikTokImage {
            tikTokOverlayLayerA.contents = img
        }
        canvasLayer.addSublayer(tikTokOverlayLayerA)
        
        // Film B TikTok Safe Area Template overlay (50% opacity, 9:16 only)
        tikTokOverlayLayerB.contentsGravity = .resize
        tikTokOverlayLayerB.opacity = 0.5
        tikTokOverlayLayerB.zPosition = 102
        tikTokOverlayLayerB.isHidden = true
        tikTokOverlayLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull()]
        if let img = PlayerContainerNSView.tikTokImage {
            tikTokOverlayLayerB.contents = img
        }
        canvasLayer.addSublayer(tikTokOverlayLayerB)
        
        // Native trackpad pinch gesture for zoom in / zoom out
        let pinchGesture = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinchGesture)
        
        // Track mouse movement for custom cursor & split handle hovering
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func setup(engine: PlayerEngine) {
        self.engine = engine
        playerLayerA.player = engine.slotA.player
        playerLayerB.player = engine.slotB.player
    }
    
    public func update(engine: PlayerEngine, isLightMode: Bool) {
        self.engine = engine
        
        if playerLayerA.player != engine.slotA.player {
            playerLayerA.player = engine.slotA.player
        }
        if playerLayerB.player != engine.slotB.player {
            playerLayerB.player = engine.slotB.player
        }
        
        let urlAChanged = (engine.slotA.url != lastSlotAURL)
        let urlBChanged = (engine.slotB.url != lastSlotBURL)
        
        if urlAChanged || urlBChanged {
            lastSlotAURL = engine.slotA.url
            lastSlotBURL = engine.slotB.url
            lastCapturedTimeA = nil
            rawStillFrameA = nil
            lastCapturedTimeB = nil
            rawStillFrameB = nil
            
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillFrameLayerA.contents = nil
            stillFrameLayerA.isHidden = true
            stillFrameLayerB.contents = nil
            stillFrameLayerB.isHidden = true
            
            // Invalidate layout caches to force a full re-calculation
            lastBoundsSize = .zero
            lastCanvasBoundsSize = CGSize(width: -1, height: -1)
            lastAspectA = -1
            lastAspectB = -1
            lastCompareMode = nil
            lastFrameASize = CGSize(width: -1, height: -1)
            lastFrameBSize = CGSize(width: -1, height: -1)
            CATransaction.commit()
        }
        
        let canvasColor = isLightMode ? NSColor(white: 0.88, alpha: 1.0).cgColor : NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        layer?.backgroundColor = canvasColor
        
        layoutPlayerLayer()
        updateCompareLayers()
        updateExposure()
        updateMagnificationFilters()
        checkStillFrameDisplay()
    }
    
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window = newWindow {
            updateScale(for: window.backingScaleFactor)
        }
    }
    
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale(for: window?.backingScaleFactor ?? 2.0)
    }
    
    private func updateScale(for scale: CGFloat) {
        layer?.contentsScale = scale
        canvasLayer.contentsScale = scale
        playerLayerA.contentsScale = scale
        playerLayerB.contentsScale = scale
        stillFrameLayerA.contentsScale = scale
        stillFrameLayerB.contentsScale = scale
        crosshairLayerA.contentsScale = scale
        crosshairLayerB.contentsScale = scale
        titleSafeLayerA.contentsScale = scale
        titleSafeLayerB.contentsScale = scale
        tikTokOverlayLayerA.contentsScale = scale
        tikTokOverlayLayerB.contentsScale = scale
        splitHandleGripLayer.contentsScale = scale
    }
    
    public override func layout() {
        super.layout()
        layoutPlayerLayer()
        updateCompareLayers()
        updateExposure()
        updateMagnificationFilters()
        checkStillFrameDisplay()
    }
    
    // MARK: - Video Aspect Ratio & Layout
    
    private func getVideoAspectRatioA() -> CGFloat {
        if let item = playerLayerA.player?.currentItem, item.presentationSize.width > 0, item.presentationSize.height > 0 {
            return item.presentationSize.width / item.presentationSize.height
        }
        guard let engine = engine else { return 16.0 / 9.0 }
        let size = engine.slotA.videoSize
        if size.width > 0 && size.height > 0 {
            return size.width / size.height
        }
        return 16.0 / 9.0
    }
    
    private func getVideoAspectRatioB() -> CGFloat {
        if let item = playerLayerB.player?.currentItem, item.presentationSize.width > 0, item.presentationSize.height > 0 {
            return item.presentationSize.width / item.presentationSize.height
        }
        guard let engine = engine else { return getVideoAspectRatioA() }
        let size = engine.slotB.videoSize
        if size.width > 0 && size.height > 0 {
            return size.width / size.height
        }
        return getVideoAspectRatioA()
    }
    
    // MARK: - Subpixel & Display Alignment Helpers
    
    private func currentBackingScale() -> CGFloat {
        return window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }
    
    /// Snaps a point coordinate to exact physical display pixels (1.0 / scale)
    private func snapToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        return round(value * scale) / scale
    }
    
    /// Snaps a size to physical display pixels, ensuring physical pixel dimensions are even integers
    /// (necessary for YUV 4:2:0 hardware video decoders and eliminating CoreMedia letterboxing).
    private func snapToEvenPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let pixels = floor(value * scale)
        let evenPixels = floor(pixels / 2.0) * 2.0
        return max(2.0 / scale, evenPixels / scale)
    }
    
    private func getBaseFittedSize(in bounds: CGRect) -> CGSize {
        guard let engine = engine else { return bounds.size }
        let scale = currentBackingScale()
        let isSideBySideH = (engine.compareMode == .sideBySide && engine.slotB.url != nil)
        let isSideBySideV = (engine.compareMode == .sideBySideVertical && engine.slotB.url != nil)
        
        if isSideBySideH {
            let aspectA = max(0.01, getVideoAspectRatioA())
            let aspectB = max(0.01, getVideoAspectRatioB())
            let availW = max(1.0, bounds.width)
            let availH = max(1.0, bounds.height)
            let slotAvailW = max(1.0, (availW - 4.0) / 2.0)
            
            let scaleA = min(slotAvailW / aspectA, availH)
            let fitHeightA = snapToEvenPixels(scaleA, scale: scale)
            let fitWidthA = snapToEvenPixels(fitHeightA * aspectA, scale: scale)
            
            let scaleB = min(slotAvailW / aspectB, availH)
            let fitHeightB = snapToEvenPixels(scaleB, scale: scale)
            let fitWidthB = snapToEvenPixels(fitHeightB * aspectB, scale: scale)
            
            let canvasH = max(fitHeightA, fitHeightB)
            let canvasW = (max(fitWidthA, fitWidthB) * 2.0) + 4.0
            return CGSize(width: canvasW, height: canvasH)
        } else if isSideBySideV {
            let aspectA = max(0.01, getVideoAspectRatioA())
            let aspectB = max(0.01, getVideoAspectRatioB())
            let availW = max(1.0, bounds.width)
            let availH = max(1.0, bounds.height)
            let slotAvailH = max(1.0, (availH - 4.0) / 2.0)
            
            let scaleA = min(availW, slotAvailH * aspectA)
            let fitWidthA = snapToEvenPixels(scaleA, scale: scale)
            let fitHeightA = snapToEvenPixels(fitWidthA / aspectA, scale: scale)
            
            let scaleB = min(availW, slotAvailH * aspectB)
            let fitWidthB = snapToEvenPixels(scaleB, scale: scale)
            let fitHeightB = snapToEvenPixels(fitWidthB / aspectB, scale: scale)
            
            let canvasW = max(fitWidthA, fitWidthB)
            let canvasH = (max(fitHeightA, fitHeightB) * 2.0) + 4.0
            return CGSize(width: canvasW, height: canvasH)
        } else {
            let aspect = getVideoAspectRatioA()
            guard aspect > 0, bounds.width > 0, bounds.height > 0 else {
                return bounds.size
            }
            
            let boundsAspect = bounds.width / bounds.height
            if boundsAspect > aspect {
                let h = snapToEvenPixels(bounds.height, scale: scale)
                let w = snapToEvenPixels(h * aspect, scale: scale)
                return CGSize(width: w, height: h)
            } else {
                let w = snapToEvenPixels(bounds.width, scale: scale)
                let h = snapToEvenPixels(w / aspect, scale: scale)
                return CGSize(width: w, height: h)
            }
        }
    }
    
    private func layoutPlayerLayer() {
        guard let engine = engine else { return }
        let viewBounds = bounds
        guard viewBounds.width > 0 && viewBounds.height > 0 else { return }
        
        let scale = currentBackingScale()
        updateScale(for: scale)
        updateMagnificationFilters()
        
        let zoomScale: CGFloat = engine.isFitZoom ? 1.0 : engine.zoomScale
        let panOffset = engine.isFitZoom ? .zero : engine.panOffset
        let isFitZoom = engine.isFitZoom
        let showCrosshair = engine.showCenterCrosshair
        let safeAreaMode = engine.safeAreaMode
        let isNineBySixteen = engine.isNineBySixteen
        let baseSize = getBaseFittedSize(in: viewBounds)
        
        // Fast path: skip expensive layer transforms & path reallocations if unchanged
        if viewBounds.size == lastBoundsSize &&
           zoomScale == lastZoomScale &&
           panOffset == lastPanOffset &&
           isFitZoom == lastIsFitZoom &&
           showCrosshair == lastShowCrosshair &&
           safeAreaMode == lastSafeAreaMode &&
           isNineBySixteen == lastIsNineBySixteen &&
           canvasLayer.bounds.size == baseSize {
            return
        }
        
        lastBoundsSize = viewBounds.size
        lastZoomScale = zoomScale
        lastPanOffset = panOffset
        lastIsFitZoom = isFitZoom
        lastShowCrosshair = showCrosshair
        lastSafeAreaMode = safeAreaMode
        lastIsNineBySixteen = isNineBySixteen
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        if canvasLayer.bounds.size != baseSize {
            canvasLayer.bounds = CGRect(origin: .zero, size: baseSize)
        }
        let isSideBySide = (engine.compareMode == .sideBySide || engine.compareMode == .sideBySideVertical) && engine.slotB.url != nil
        if !isSideBySide {
            playerLayerA.frame = canvasLayer.bounds
            playerLayerB.frame = canvasLayer.bounds
            stillFrameLayerA.frame = canvasLayer.bounds
            stillFrameLayerB.frame = canvasLayer.bounds
        }
        
        // Pixel-aligned positioning:
        // Snap the raw top-left origin of canvasLayer to the physical display pixel grid,
        // then derive the layer position from the snapped origin. This guarantees that canvasLayer.frame.origin
        // is at whole display pixel boundaries, eliminating subpixel jitter between CALayer and AVPlayerLayer.
        let scaledW = baseSize.width * zoomScale
        let scaledH = baseSize.height * zoomScale
        let rawOriginX = viewBounds.midX - (scaledW / 2.0) + panOffset.width
        let rawOriginY = viewBounds.midY - (scaledH / 2.0) + panOffset.height
        let snappedOriginX = snapToPixel(rawOriginX, scale: scale)
        let snappedOriginY = snapToPixel(rawOriginY, scale: scale)
        let centerX = snappedOriginX + (scaledW / 2.0)
        let centerY = snappedOriginY + (scaledH / 2.0)
        
        canvasLayer.position = CGPoint(x: centerX, y: centerY)
        canvasLayer.setAffineTransform(CGAffineTransform(scaleX: zoomScale, y: zoomScale))
        
        updateGuideOverlays()
        
        CATransaction.commit()
    }
    
    // MARK: - Compare Modes Layer Compositing
    
    private func updateCompareLayers() {
        guard let engine = engine else { return }
        let w = canvasLayer.bounds.width
        let h = canvasLayer.bounds.height
        guard w > 0, h > 0 else { return }
        
        let isBlink = engine.isBlinkCompareB && engine.slotB.url != nil
        let mode = (engine.slotB.url == nil) ? CompareMode.single : engine.compareMode
        let splitPos = engine.splitPosition
        let aspectA = max(0.01, getVideoAspectRatioA())
        let aspectB = max(0.01, getVideoAspectRatioB())
        
        // Fast path: skip re-rendering layers only if ALL compare state, aspect ratios, and dimensions are strictly unchanged
        if mode == lastCompareMode &&
           splitPos == lastSplitPosition &&
           isBlink == lastIsBlink &&
           canvasLayer.bounds.size == lastCanvasBoundsSize &&
           abs(aspectA - lastAspectA) < 0.001 &&
           abs(aspectB - lastAspectB) < 0.001 {
            updateLayerVisibility()
            return
        }
        
        lastCompareMode = mode
        lastSplitPosition = splitPos
        lastIsBlink = isBlink
        lastCanvasBoundsSize = canvasLayer.bounds.size
        lastAspectA = aspectA
        lastAspectB = aspectB
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Blink compare: Rapidly show 100% Slot B when toggled
        if isBlink {
            playerLayerA.isHidden = true
            stillFrameLayerA.isHidden = true
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            if stillFrameLayerA.mask != nil {
                stillFrameLayerA.mask = nil
            }
            playerLayerA.compositingFilter = nil
            stillFrameLayerA.compositingFilter = nil
            playerLayerA.opacity = 1.0
            stillFrameLayerA.opacity = 1.0
            playerLayerA.zPosition = 0
            stillFrameLayerA.zPosition = 0
            
            playerLayerB.opacity = 1.0
            stillFrameLayerB.opacity = 1.0
            playerLayerB.zPosition = 0
            stillFrameLayerB.zPosition = 0
            // Fit Slot B in canvas bounds preserving its native aspect ratio
            let aspectB = max(0.01, getVideoAspectRatioB())
            let canvasAspect = w / h
            let frameB: CGRect
            if abs(canvasAspect - aspectB) / max(canvasAspect, aspectB) < 0.02 {
                frameB = canvasLayer.bounds
            } else {
                let scale = min(w / aspectB, h)
                let fitW = round(scale * aspectB)
                let fitH = round(scale)
                frameB = CGRect(x: round((w - fitW) / 2), y: round((h - fitH) / 2), width: fitW, height: fitH)
            }
            playerLayerB.frame = frameB
            stillFrameLayerB.frame = frameB
            
            splitDividerLayer.isHidden = true
            splitHandleLayer.isHidden = true
            updateLayerVisibility()
            CATransaction.commit()
            return
        }
        
        // Reset layer opacities and zPositions for non-overlay modes
        if mode != .overlay {
            playerLayerA.opacity = 1.0
            playerLayerB.opacity = 1.0
            stillFrameLayerA.opacity = 1.0
            stillFrameLayerB.opacity = 1.0
            playerLayerA.zPosition = 0
            playerLayerB.zPosition = 0
            stillFrameLayerA.zPosition = 0
            stillFrameLayerB.zPosition = 0
        }
        
        switch mode {
        case .single:
            playerLayerB.isHidden = true
            stillFrameLayerB.isHidden = true
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            if stillFrameLayerA.mask != nil {
                stillFrameLayerA.mask = nil
            }
            playerLayerA.compositingFilter = nil
            stillFrameLayerA.compositingFilter = nil
            playerLayerA.frame = canvasLayer.bounds
            stillFrameLayerA.frame = canvasLayer.bounds
            
            splitDividerLayer.isHidden = true
            splitHandleLayer.isHidden = true
            
        case .splitVertical:
            playerLayerA.compositingFilter = nil
            stillFrameLayerA.compositingFilter = nil
            playerLayerA.frame = canvasLayer.bounds
            playerLayerB.frame = canvasLayer.bounds
            stillFrameLayerA.frame = canvasLayer.bounds
            stillFrameLayerB.frame = canvasLayer.bounds
            
            let splitX = round(w * splitPos)
            let maskRect = CGRect(x: 0, y: 0, width: splitX, height: h)
            let maskPath = CGPath(rect: maskRect, transform: nil)
            
            maskLayerA.path = maskPath
            if playerLayerA.mask !== maskLayerA {
                playerLayerA.mask = maskLayerA
            }
            stillMaskLayerA.path = maskPath
            if stillFrameLayerA.mask !== stillMaskLayerA {
                stillFrameLayerA.mask = stillMaskLayerA
            }
            
            splitDividerLayer.isHidden = false
            splitDividerLayer.backgroundColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
            splitDividerLayer.frame = CGRect(x: splitX - 1, y: 0, width: 2, height: h)
            
            let handleW: CGFloat = 8
            let handleH: CGFloat = 44
            let handleX = round(splitX - (handleW / 2))
            let handleY = round((h - handleH) / 2)
            
            splitHandleLayer.isHidden = false
            splitHandleLayer.cornerRadius = 4
            splitHandleLayer.frame = CGRect(x: handleX, y: handleY, width: handleW, height: handleH)
            
            let gripPathV = CGMutablePath()
            let midX = handleW / 2
            let startY: CGFloat = 14
            let endY: CGFloat = 30
            gripPathV.move(to: CGPoint(x: midX - 2, y: startY))
            gripPathV.addLine(to: CGPoint(x: midX - 2, y: endY))
            gripPathV.move(to: CGPoint(x: midX, y: startY))
            gripPathV.addLine(to: CGPoint(x: midX, y: endY))
            gripPathV.move(to: CGPoint(x: midX + 2, y: startY))
            gripPathV.addLine(to: CGPoint(x: midX + 2, y: endY))
            
            splitHandleGripLayer.frame = CGRect(x: 0, y: 0, width: handleW, height: handleH)
            splitHandleGripLayer.path = gripPathV
            
        case .splitHorizontal:
            playerLayerA.compositingFilter = nil
            stillFrameLayerA.compositingFilter = nil
            playerLayerA.frame = canvasLayer.bounds
            playerLayerB.frame = canvasLayer.bounds
            stillFrameLayerA.frame = canvasLayer.bounds
            stillFrameLayerB.frame = canvasLayer.bounds
            
            // In AppKit, y=0 is at bottom. splitY from bottom.
            let splitY = round(h * splitPos)
            let maskRect = CGRect(x: 0, y: splitY, width: w, height: h - splitY)
            let maskPath = CGPath(rect: maskRect, transform: nil)
            
            maskLayerA.path = maskPath
            if playerLayerA.mask !== maskLayerA {
                playerLayerA.mask = maskLayerA
            }
            stillMaskLayerA.path = maskPath
            if stillFrameLayerA.mask !== stillMaskLayerA {
                stillFrameLayerA.mask = stillMaskLayerA
            }
            
            splitDividerLayer.isHidden = false
            splitDividerLayer.backgroundColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
            splitDividerLayer.frame = CGRect(x: 0, y: splitY - 1, width: w, height: 2)
            
            let handleW: CGFloat = 44
            let handleH: CGFloat = 8
            let handleX = round((w - handleW) / 2)
            let handleY = round(splitY - (handleH / 2))
            
            splitHandleLayer.isHidden = false
            splitHandleLayer.cornerRadius = 4
            splitHandleLayer.frame = CGRect(x: handleX, y: handleY, width: handleW, height: handleH)
            
            let gripPathH = CGMutablePath()
            let midY = handleH / 2
            let startX: CGFloat = 14
            let endX: CGFloat = 30
            gripPathH.move(to: CGPoint(x: startX, y: midY - 2))
            gripPathH.addLine(to: CGPoint(x: endX, y: midY - 2))
            gripPathH.move(to: CGPoint(x: startX, y: midY))
            gripPathH.addLine(to: CGPoint(x: endX, y: midY))
            gripPathH.move(to: CGPoint(x: startX, y: midY + 2))
            gripPathH.addLine(to: CGPoint(x: endX, y: midY + 2))
            
            splitHandleGripLayer.frame = CGRect(x: 0, y: 0, width: handleW, height: handleH)
            splitHandleGripLayer.path = gripPathH
            
        case .sideBySide:
            if playerLayerA.mask != nil { playerLayerA.mask = nil }
            if stillFrameLayerA.mask != nil { stillFrameLayerA.mask = nil }
            if playerLayerB.mask != nil { playerLayerB.mask = nil }
            if stillFrameLayerB.mask != nil { stillFrameLayerB.mask = nil }
            playerLayerA.compositingFilter = nil
            stillFrameLayerA.compositingFilter = nil
            playerLayerB.compositingFilter = nil
            stillFrameLayerB.compositingFilter = nil
            
            let scale = currentBackingScale()
            let halfW = snapToEvenPixels((w - 4) / 2, scale: scale)
            let aspectA = max(0.01, getVideoAspectRatioA())
            let aspectB = max(0.01, getVideoAspectRatioB())
            
            // Fit Slot A in left half (halfW, h)
            let scaleA = min(halfW / aspectA, h)
            let fitHeightA = snapToEvenPixels(scaleA, scale: scale)
            let fitWidthA = snapToEvenPixels(fitHeightA * aspectA, scale: scale)
            let yPosA = snapToPixel((h - fitHeightA) / 2, scale: scale)
            let xPosA = snapToPixel((halfW - fitWidthA) / 2, scale: scale)
            let frameA = CGRect(x: xPosA, y: yPosA, width: fitWidthA, height: fitHeightA)
            
            // Fit Slot B in right half (halfW, h)
            let scaleB = min(halfW / aspectB, h)
            let fitHeightB = snapToEvenPixels(scaleB, scale: scale)
            let fitWidthB = snapToEvenPixels(fitHeightB * aspectB, scale: scale)
            let yPosB = snapToPixel((h - fitHeightB) / 2, scale: scale)
            let xPosB = snapToPixel(w / 2 + 2 + (halfW - fitWidthB) / 2, scale: scale)
            let frameB = CGRect(x: xPosB, y: yPosB, width: fitWidthB, height: fitHeightB)
            
            playerLayerA.frame = frameA
            playerLayerB.frame = frameB
            stillFrameLayerA.frame = frameA
            stillFrameLayerB.frame = frameB
            
            splitDividerLayer.isHidden = false
            splitDividerLayer.backgroundColor = NSColor(white: 0.35, alpha: 0.7).cgColor
            splitDividerLayer.frame = CGRect(x: snapToPixel(w / 2 - 0.75, scale: scale), y: 0, width: 1.5, height: h)
            splitHandleLayer.isHidden = true
            
        case .sideBySideVertical:
            if playerLayerA.mask != nil { playerLayerA.mask = nil }
            if stillFrameLayerA.mask != nil { stillFrameLayerA.mask = nil }
            if playerLayerB.mask != nil { playerLayerB.mask = nil }
            if stillFrameLayerB.mask != nil { stillFrameLayerB.mask = nil }
            playerLayerA.compositingFilter = nil
            stillFrameLayerA.compositingFilter = nil
            playerLayerB.compositingFilter = nil
            stillFrameLayerB.compositingFilter = nil
            
            let scale = currentBackingScale()
            let halfH = snapToEvenPixels((h - 4) / 2, scale: scale)
            let aspectA = max(0.01, getVideoAspectRatioA())
            let aspectB = max(0.01, getVideoAspectRatioB())
            
            // In AppKit, y=0 is bottom (Slot B), y=h is top (Slot A)
            // Fit Slot A in top half (w, halfH)
            let scaleA = min(w, halfH * aspectA)
            let fitHeightA = snapToEvenPixels(scaleA / aspectA, scale: scale)
            let fitWidthA = snapToEvenPixels(scaleA, scale: scale)
            let xPosA = snapToPixel((w - fitWidthA) / 2, scale: scale)
            let yPosA = snapToPixel(h / 2 + 2 + (halfH - fitHeightA) / 2, scale: scale)
            let frameA = CGRect(x: xPosA, y: yPosA, width: fitWidthA, height: fitHeightA)
            
            // Fit Slot B in bottom half (w, halfH)
            let scaleB = min(w, halfH * aspectB)
            let fitHeightB = snapToEvenPixels(scaleB / aspectB, scale: scale)
            let fitWidthB = snapToEvenPixels(scaleB, scale: scale)
            let xPosB = snapToPixel((w - fitWidthB) / 2, scale: scale)
            let yPosB = snapToPixel((halfH - fitHeightB) / 2, scale: scale)
            let frameB = CGRect(x: xPosB, y: yPosB, width: fitWidthB, height: fitHeightB)
            
            playerLayerA.frame = frameA
            playerLayerB.frame = frameB
            stillFrameLayerA.frame = frameA
            stillFrameLayerB.frame = frameB
            
            splitDividerLayer.isHidden = false
            splitDividerLayer.backgroundColor = NSColor(white: 0.35, alpha: 0.7).cgColor
            splitDividerLayer.frame = CGRect(x: 0, y: round(h / 2 - 0.75), width: w, height: 1.5)
            splitHandleLayer.isHidden = true
            
        case .difference:
            // Pure GPU difference blend (|RGB_A - RGB_B|) directly between playerLayerA and playerLayerB
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            if stillFrameLayerA.mask != nil {
                stillFrameLayerA.mask = nil
            }
            playerLayerA.frame = canvasLayer.bounds
            playerLayerB.frame = canvasLayer.bounds
            stillFrameLayerA.frame = canvasLayer.bounds
            stillFrameLayerB.frame = canvasLayer.bounds
            
            playerLayerA.compositingFilter = "differenceBlendMode"
            stillFrameLayerA.compositingFilter = "differenceBlendMode"
            
            splitDividerLayer.isHidden = true
            splitHandleLayer.isHidden = true
            
        case .overlay:
            // 50% Opacity Overlay: Slot B reference is overlayed on top of Slot A at 50% opacity
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            if stillFrameLayerA.mask != nil {
                stillFrameLayerA.mask = nil
            }
            if playerLayerB.mask != nil {
                playerLayerB.mask = nil
            }
            if stillFrameLayerB.mask != nil {
                stillFrameLayerB.mask = nil
            }
            playerLayerA.compositingFilter = nil
            stillFrameLayerA.compositingFilter = nil
            playerLayerB.compositingFilter = nil
            stillFrameLayerB.compositingFilter = nil
            playerLayerA.frame = canvasLayer.bounds
            playerLayerB.frame = canvasLayer.bounds
            stillFrameLayerA.frame = canvasLayer.bounds
            stillFrameLayerB.frame = canvasLayer.bounds
            
            playerLayerB.zPosition = 1
            stillFrameLayerB.zPosition = 1
            playerLayerA.zPosition = 0
            stillFrameLayerA.zPosition = 0
            playerLayerB.opacity = 0.5
            stillFrameLayerB.opacity = 0.5
            playerLayerA.opacity = 1.0
            stillFrameLayerA.opacity = 1.0
            
            splitDividerLayer.isHidden = true
            splitHandleLayer.isHidden = true
        }
        
        updateGuideOverlays()
        updateLayerVisibility()
        CATransaction.commit()
    }
    
    // MARK: - Dynamic Texture Filtering
    
    private func updateMagnificationFilters() {
        guard let engine = engine else { return }
        // Dynamic texture filtering:
        // When inspecting pixel-level details at >= 175% zoom (e.g. 200%, 400%, 800%),
        // use .nearest so individual pixels display as crisp, discrete square blocks for line/pixel QC.
        // At normal viewing / fit zoom (< 175% or fit to window), use .linear so paused still
        // frames match live playback quality with smooth, anti-aliased graphics, text, and edges.
        let isZoomedInForQC = (!engine.isFitZoom && engine.zoomScale >= 1.75)
        let targetFilter: CALayerContentsFilter = isZoomedInForQC ? .nearest : .linear
        
        if stillFrameLayerA.magnificationFilter != targetFilter {
            stillFrameLayerA.magnificationFilter = targetFilter
        }
        if stillFrameLayerB.magnificationFilter != targetFilter {
            stillFrameLayerB.magnificationFilter = targetFilter
        }
        if playerLayerA.magnificationFilter != targetFilter {
            playerLayerA.magnificationFilter = targetFilter
        }
        if playerLayerB.magnificationFilter != targetFilter {
            playerLayerB.magnificationFilter = targetFilter
        }
    }
    
    // MARK: - Layer Visibility & Still Frame Inspection
    
    private func updateLayerVisibility() {
        guard let engine = engine else { return }
        let mode = (engine.slotB.url == nil) ? CompareMode.single : engine.compareMode
        let isBlink = engine.isBlinkCompareB && engine.slotB.url != nil
        let isPlayingOrScrubbing = engine.isPlaying || engine.isScrubbing || engine.isSeeking
        
        // Check if still frame A is truly ready AND matches current playhead timestamp (<0.03s tolerance)
        let currentTimeSecsA = CMTimeGetSeconds(engine.currentTime)
        let isStillReadyA: Bool
        if let lastA = lastCapturedTimeA, stillFrameLayerA.contents != nil {
            isStillReadyA = abs(CMTimeGetSeconds(lastA) - currentTimeSecsA) < 0.03
        } else {
            isStillReadyA = false
        }
        
        // Check if still frame B is truly ready AND matches current playhead timestamp
        let isStillReadyB: Bool
        if let lastB = lastCapturedTimeB, stillFrameLayerB.contents != nil {
            let timeSecsB = CMTimeGetSeconds(engine.slotB.player.currentTime())
            isStillReadyB = abs(CMTimeGetSeconds(lastB) - timeSecsB) < 0.03
        } else {
            isStillReadyB = false
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateMagnificationFilters()
        
        if isBlink {
            stillFrameLayerA.isHidden = true
            playerLayerA.isHidden = true
            if !isPlayingOrScrubbing && isStillReadyB {
                stillFrameLayerB.isHidden = false
                playerLayerB.isHidden = true
            } else {
                stillFrameLayerB.isHidden = true
                playerLayerB.isHidden = false
            }
            CATransaction.commit()
            return
        }
        
        // Slot A visibility:
        // Only present stillFrameLayerA when stationary AND it holds the verified current frame.
        // During seeks, scrubbing, or when a new frame is being extracted, playerLayerA displays the live frame seamlessly.
        if !isPlayingOrScrubbing && isStillReadyA {
            stillFrameLayerA.isHidden = false
            playerLayerA.isHidden = true
        } else {
            stillFrameLayerA.isHidden = true
            playerLayerA.isHidden = false
        }
        
        // Slot B visibility
        if mode == .single || engine.slotB.url == nil {
            stillFrameLayerB.isHidden = true
            playerLayerB.isHidden = true
        } else {
            if !isPlayingOrScrubbing && isStillReadyB {
                stillFrameLayerB.isHidden = false
                playerLayerB.isHidden = true
            } else {
                stillFrameLayerB.isHidden = true
                playerLayerB.isHidden = false
            }
        }
        
        CATransaction.commit()
    }
    
    private func checkStillFrameDisplay() {
        guard let engine = engine, engine.slotA.url != nil else { return }
        
        // If playing or actively scrubbing or seeking, show live AVPlayerLayers
        if engine.isPlaying || engine.isScrubbing || engine.isSeeking {
            // When actively playing, purge the cached still frame so stale textures can never flash
            if engine.isPlaying && stillFrameLayerA.contents != nil {
                stillFrameLayerA.contents = nil
                rawStillFrameA = nil
                lastCapturedTimeA = nil
                stillFrameLayerB.contents = nil
                rawStillFrameB = nil
                lastCapturedTimeB = nil
            }
            updateLayerVisibility()
            return
        }
        
        let timeA = engine.currentTime
        let timeSecsA = CMTimeGetSeconds(timeA)
        
        // Slot A still frame check
        if let lastA = lastCapturedTimeA, abs(CMTimeGetSeconds(lastA) - timeSecsA) < 0.03, stillFrameLayerA.contents != nil {
            updateLayerVisibility()
        } else if !isCapturingStillA {
            isCapturingStillA = true
            Task { [weak self] in
                guard let self = self, let curEngine = self.engine else { return }
                let img = await curEngine.captureCurrentFrame(for: .slotA, at: timeA)
                await MainActor.run {
                    self.isCapturingStillA = false
                    guard let curEngine = self.engine else { return }
                    if let img = img {
                        if !curEngine.isPlaying && !curEngine.isScrubbing && !curEngine.isSeeking && abs(CMTimeGetSeconds(curEngine.currentTime) - timeSecsA) < 0.04 {
                            self.lastCapturedTimeA = timeA
                            self.rawStillFrameA = img
                            let exposedImg = ExposureAdjuster.shared.applyExposure(to: img, ev: curEngine.exposureEV)
                            self.stillFrameLayerA.contents = exposedImg
                            self.updateLayerVisibility()
                        } else if !curEngine.isPlaying && !curEngine.isScrubbing && !curEngine.isSeeking {
                            self.checkStillFrameDisplay()
                        }
                    } else if !curEngine.isPlaying && !curEngine.isScrubbing && !curEngine.isSeeking {
                        // Retry shortly if asset was warming up
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                            self?.checkStillFrameDisplay()
                        }
                    }
                }
            }
        }
        
        // Slot B still frame check if active comparison
        if engine.slotB.url != nil && engine.compareMode != .single {
            let timeB = engine.slotB.player.currentTime()
            let timeSecsB = CMTimeGetSeconds(timeB)
            if let lastB = lastCapturedTimeB, abs(CMTimeGetSeconds(lastB) - timeSecsB) < 0.03, stillFrameLayerB.contents != nil {
                updateLayerVisibility()
            } else if !isCapturingStillB {
                isCapturingStillB = true
                Task { [weak self] in
                    guard let self = self, let curEngine = self.engine else { return }
                    let imgB = await curEngine.captureCurrentFrame(for: .slotB, at: timeB)
                    await MainActor.run {
                        self.isCapturingStillB = false
                        guard let curEngine = self.engine else { return }
                        if let imgB = imgB {
                            if !curEngine.isPlaying && !curEngine.isScrubbing && !curEngine.isSeeking {
                                self.lastCapturedTimeB = timeB
                                self.rawStillFrameB = imgB
                                let exposedImgB = ExposureAdjuster.shared.applyExposure(to: imgB, ev: curEngine.exposureEV)
                                self.stillFrameLayerB.contents = exposedImgB
                                self.updateLayerVisibility()
                            }
                        } else if !curEngine.isPlaying && !curEngine.isScrubbing && !curEngine.isSeeking {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                                self?.checkStillFrameDisplay()
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func buildCrosshairPath(size: CGSize) -> CGPath {
        let path = CGMutablePath()
        guard size.width > 0, size.height > 0 else { return path }
        let midX = round(size.width / 2.0)
        let midY = round(size.height / 2.0)
        
        path.move(to: CGPoint(x: midX, y: 0))
        path.addLine(to: CGPoint(x: midX, y: size.height))
        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: size.width, y: midY))
        return path
    }
    
    private func buildTitleSafePath(size: CGSize) -> CGPath? {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return nil }
        
        let path = CGMutablePath()
        
        // 1. Action Safe: 90% (5% margin from each border)
        let actionMarginX = w * 0.05
        let actionMarginY = h * 0.05
        let actionRect = CGRect(x: actionMarginX, y: actionMarginY, width: w * 0.90, height: h * 0.90)
        path.addRect(actionRect)
        
        // 2. Title Safe: 80% (10% margin from each border)
        let titleMarginX = w * 0.10
        let titleMarginY = h * 0.10
        let titleRect = CGRect(x: titleMarginX, y: titleMarginY, width: w * 0.80, height: h * 0.80)
        path.addRect(titleRect)
        
        // 3. Center tick marks on Action Safe edges (10px length)
        let midX = w / 2.0
        let midY = h / 2.0
        let tickLen: CGFloat = 10.0
        
        // Top tick
        path.move(to: CGPoint(x: midX, y: actionMarginY))
        path.addLine(to: CGPoint(x: midX, y: actionMarginY + tickLen))
        
        // Bottom tick
        path.move(to: CGPoint(x: midX, y: h - actionMarginY))
        path.addLine(to: CGPoint(x: midX, y: h - actionMarginY - tickLen))
        
        // Left tick
        path.move(to: CGPoint(x: actionMarginX, y: midY))
        path.addLine(to: CGPoint(x: actionMarginX + tickLen, y: midY))
        
        // Right tick
        path.move(to: CGPoint(x: w - actionMarginX, y: midY))
        path.addLine(to: CGPoint(x: w - actionMarginX - tickLen, y: midY))
        
        // 4. Subtle center cross tick (16px total)
        let centerCrossLen: CGFloat = 8.0
        path.move(to: CGPoint(x: midX - centerCrossLen, y: midY))
        path.addLine(to: CGPoint(x: midX + centerCrossLen, y: midY))
        path.move(to: CGPoint(x: midX, y: midY - centerCrossLen))
        path.addLine(to: CGPoint(x: midX, y: midY + centerCrossLen))
        
        return path
    }
    
    private func updateGuideOverlays() {
        guard let engine = engine else { return }
        
        let showCrosshair = engine.showCenterCrosshair
        let safeAreaMode = engine.safeAreaMode
        let zoomScale = engine.isFitZoom ? 1.0 : engine.zoomScale
        let lineWidth = 1.0 / max(0.01, zoomScale)
        let isBlink = engine.isBlinkCompareB && engine.slotB.url != nil
        let isSideBySide = (engine.compareMode == .sideBySide || engine.compareMode == .sideBySideVertical) && engine.slotB.url != nil
        
        if isBlink {
            // Rapidly blink compare: Slot B at 100% full canvas
            crosshairLayerA.isHidden = true
            titleSafeLayerA.isHidden = true
            tikTokOverlayLayerA.isHidden = true
            
            let frameB = canvasLayer.bounds
            crosshairLayerB.frame = frameB
            crosshairLayerB.lineWidth = lineWidth
            if crosshairLayerB.path == nil || frameB.size != lastFrameBSize {
                crosshairLayerB.path = buildCrosshairPath(size: frameB.size)
            }
            crosshairLayerB.isHidden = !showCrosshair
            
            titleSafeLayerB.frame = frameB
            titleSafeLayerB.lineWidth = lineWidth
            if titleSafeLayerB.path == nil || frameB.size != lastFrameBSize {
                titleSafeLayerB.path = buildTitleSafePath(size: frameB.size)
            }
            
            tikTokOverlayLayerB.frame = frameB
            switch safeAreaMode {
            case .off:
                titleSafeLayerB.isHidden = true
                tikTokOverlayLayerB.isHidden = true
            case .standard:
                titleSafeLayerB.isHidden = false
                tikTokOverlayLayerB.isHidden = true
            case .tikTok:
                if engine.slotB.isNineBySixteen {
                    if tikTokOverlayLayerB.contents == nil {
                        tikTokOverlayLayerB.contents = PlayerContainerNSView.tikTokImage
                    }
                    titleSafeLayerB.isHidden = true
                    tikTokOverlayLayerB.isHidden = false
                } else {
                    titleSafeLayerB.isHidden = false
                    tikTokOverlayLayerB.isHidden = true
                }
            }
            lastFrameBSize = frameB.size
            return
        }
        
        let frameA = isSideBySide ? playerLayerA.frame : canvasLayer.bounds
        let frameB = isSideBySide ? playerLayerB.frame : .zero
        
        // --- FILM A GUIDES ---
        crosshairLayerA.frame = frameA
        crosshairLayerA.lineWidth = lineWidth
        if crosshairLayerA.path == nil || frameA.size != lastFrameASize {
            crosshairLayerA.path = buildCrosshairPath(size: frameA.size)
        }
        crosshairLayerA.isHidden = !showCrosshair
        
        titleSafeLayerA.frame = frameA
        titleSafeLayerA.lineWidth = lineWidth
        if titleSafeLayerA.path == nil || frameA.size != lastFrameASize {
            titleSafeLayerA.path = buildTitleSafePath(size: frameA.size)
        }
        
        tikTokOverlayLayerA.frame = frameA
        
        switch safeAreaMode {
        case .off:
            titleSafeLayerA.isHidden = true
            tikTokOverlayLayerA.isHidden = true
        case .standard:
            titleSafeLayerA.isHidden = false
            tikTokOverlayLayerA.isHidden = true
        case .tikTok:
            if engine.slotA.isNineBySixteen {
                if tikTokOverlayLayerA.contents == nil {
                    tikTokOverlayLayerA.contents = PlayerContainerNSView.tikTokImage
                }
                titleSafeLayerA.isHidden = true
                tikTokOverlayLayerA.isHidden = false
            } else {
                titleSafeLayerA.isHidden = false
                tikTokOverlayLayerA.isHidden = true
            }
        }
        
        // --- FILM B GUIDES ---
        if isSideBySide && frameB.width > 0 && frameB.height > 0 {
            crosshairLayerB.frame = frameB
            crosshairLayerB.lineWidth = lineWidth
            if crosshairLayerB.path == nil || frameB.size != lastFrameBSize {
                crosshairLayerB.path = buildCrosshairPath(size: frameB.size)
            }
            crosshairLayerB.isHidden = !showCrosshair
            
            titleSafeLayerB.frame = frameB
            titleSafeLayerB.lineWidth = lineWidth
            if titleSafeLayerB.path == nil || frameB.size != lastFrameBSize {
                titleSafeLayerB.path = buildTitleSafePath(size: frameB.size)
            }
            
            tikTokOverlayLayerB.frame = frameB
            
            switch safeAreaMode {
            case .off:
                titleSafeLayerB.isHidden = true
                tikTokOverlayLayerB.isHidden = true
            case .standard:
                titleSafeLayerB.isHidden = false
                tikTokOverlayLayerB.isHidden = true
            case .tikTok:
                if engine.slotB.isNineBySixteen {
                    if tikTokOverlayLayerB.contents == nil {
                        tikTokOverlayLayerB.contents = PlayerContainerNSView.tikTokImage
                    }
                    titleSafeLayerB.isHidden = true
                    tikTokOverlayLayerB.isHidden = false
                } else {
                    titleSafeLayerB.isHidden = false
                    tikTokOverlayLayerB.isHidden = true
                }
            }
        } else {
            crosshairLayerB.isHidden = true
            titleSafeLayerB.isHidden = true
            tikTokOverlayLayerB.isHidden = true
        }
        
        lastFrameASize = frameA.size
        lastFrameBSize = frameB.size
    }
    
    // MARK: - Exposure Adjustment (After Effects Style EV Filter)
    
    private func updateExposure() {
        guard let engine = engine else { return }
        let ev = engine.exposureEV
        if abs(ev - lastExposureEV) < 0.001 { return }
        lastExposureEV = ev
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Ensure no legacy layer filters are lingering (playback is handled by AVVideoComposition)
        playerLayerA.filters = nil
        playerLayerB.filters = nil
        stillFrameLayerA.filters = nil
        stillFrameLayerB.filters = nil
        
        // Re-bake cached still frames on GPU with new EV (~3ms execution)
        if let rawA = rawStillFrameA {
            let exposedA = ExposureAdjuster.shared.applyExposure(to: rawA, ev: ev)
            stillFrameLayerA.contents = exposedA
        }
        if let rawB = rawStillFrameB {
            let exposedB = ExposureAdjuster.shared.applyExposure(to: rawB, ev: ev)
            stillFrameLayerB.contents = exposedB
        }
        
        CATransaction.commit()
    }
    
    // MARK: - Interactive Split Wipe Drag & Canvas Pan
    
    private func pointInCanvas(from windowPoint: NSPoint) -> CGPoint {
        let viewPoint = convert(windowPoint, from: nil)
        return layer?.convert(viewPoint, to: canvasLayer) ?? viewPoint
    }
    
    private func isNearSplitDivider(windowPoint: NSPoint) -> Bool {
        guard let engine = engine, engine.slotB.url != nil, engine.compareMode != .single else { return false }
        guard engine.hasMatchingAspectRatios else { return false }
        let pt = pointInCanvas(from: windowPoint)
        let w = canvasLayer.bounds.width
        let h = canvasLayer.bounds.height
        guard pt.x >= -10 && pt.x <= w + 10 && pt.y >= -10 && pt.y <= h + 10 else { return false }
        
        if engine.compareMode == .splitVertical {
            let splitX = w * engine.splitPosition
            return abs(pt.x - splitX) <= 16
        } else if engine.compareMode == .splitHorizontal {
            let splitY = h * engine.splitPosition
            return abs(pt.y - splitY) <= 16
        }
        return false
    }
    
    public override var acceptsFirstResponder: Bool { true }
    
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let engine = engine else {
            super.mouseDown(with: event)
            return
        }
        
        if isNearSplitDivider(windowPoint: event.locationInWindow) {
            isDraggingSplit = true
            if engine.compareMode == .splitVertical {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.resizeUpDown.set()
            }
            return
        }
        
        if !engine.isFitZoom {
            dragStartLocation = event.locationInWindow
            initialPanOffset = engine.panOffset
            NSCursor.closedHand.set()
        } else {
            super.mouseDown(with: event)
        }
    }
    
    public override func mouseDragged(with event: NSEvent) {
        guard let engine = engine else {
            super.mouseDragged(with: event)
            return
        }
        
        if isDraggingSplit {
            let pt = pointInCanvas(from: event.locationInWindow)
            let w = canvasLayer.bounds.width
            let h = canvasLayer.bounds.height
            guard w > 0, h > 0 else { return }
            
            if engine.compareMode == .splitVertical {
                let newPos = max(0.02, min(0.98, pt.x / w))
                engine.splitPosition = newPos
                updateCompareLayers()
            } else if engine.compareMode == .splitHorizontal {
                let newPos = max(0.02, min(0.98, pt.y / h))
                engine.splitPosition = newPos
                updateCompareLayers()
            }
            return
        }
        
        guard let start = dragStartLocation, !engine.isFitZoom else {
            super.mouseDragged(with: event)
            return
        }
        
        let current = event.locationInWindow
        let deltaX = current.x - start.x
        let deltaY = current.y - start.y
        
        let newPan = CGSize(
            width: initialPanOffset.width + deltaX,
            height: initialPanOffset.height + deltaY
        )
        
        engine.panOffset = newPan
        layoutPlayerLayer()
    }
    
    public override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            if let onDoubleClick = onDoubleClick {
                onDoubleClick()
            } else if let engine = engine {
                if engine.isFitZoom {
                    engine.setZoomLevel(1.0)
                } else {
                    engine.setZoomFit()
                }
            }
            return
        }
        
        let wasDragging = isDraggingSplit || (dragStartLocation != nil)
        isDraggingSplit = false
        if dragStartLocation != nil {
            dragStartLocation = nil
        }
        updateCursor()
        checkStillFrameDisplay()
        
        if event.clickCount == 1 && !wasDragging {
            onSingleClick?()
        }
    }
    
    // MARK: - Pinch Gesture & Scroll Wheel
    
    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        guard allowScrollZoom, let engine = engine else { return }
        if gesture.state == .changed {
            let factor = 1.0 + (gesture.magnification * 0.5)
            let newScale = min(10.0, max(0.05, engine.zoomScale * factor))
            engine.isFitZoom = false
            engine.zoomScale = newScale
            gesture.magnification = 0
            layoutPlayerLayer()
        }
    }
    
    public override func scrollWheel(with event: NSEvent) {
        guard allowScrollZoom, let engine = engine else {
            super.scrollWheel(with: event)
            return
        }
        
        let delta = event.scrollingDeltaY
        if abs(delta) > 0.001 {
            let rate: CGFloat = event.hasPreciseScrollingDeltas ? 0.003 : 0.007
            let step = min(0.08, max(-0.08, delta * rate))
            let factor: CGFloat = 1.0 + step
            let newScale = min(10.0, max(0.05, engine.zoomScale * factor))
            
            engine.isFitZoom = false
            engine.zoomScale = newScale
            layoutPlayerLayer()
            return
        }
        
        if !engine.isFitZoom && abs(event.scrollingDeltaX) > 0.001 {
            engine.panOffset = CGSize(
                width: engine.panOffset.width + event.scrollingDeltaX,
                height: engine.panOffset.height
            )
            layoutPlayerLayer()
            return
        }
        
        super.scrollWheel(with: event)
    }
    
    // MARK: - Cursor Management
    
    public override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }
    
    public override func mouseMoved(with event: NSEvent) {
        updateCursor(at: event.locationInWindow)
    }
    
    private func updateCursor(at windowPoint: NSPoint? = nil) {
        guard let engine = engine else { return }
        
        if let pt = windowPoint, isNearSplitDivider(windowPoint: pt) {
            if engine.compareMode == .splitVertical {
                NSCursor.resizeLeftRight.set()
                return
            } else if engine.compareMode == .splitHorizontal {
                NSCursor.resizeUpDown.set()
                return
            }
        }
        
        if !engine.isFitZoom {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
