import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import ImageIO
import VideoToolbox
import VideoQCLib

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
    
    private var displayLink: CADisplayLink?
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
    private var pendingCaptureTimeA: CMTime? = nil
    private var pendingCaptureTimeB: CMTime? = nil
    
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
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("_icon/\(name).png")
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
    
    private var lastScale: CGFloat = -1
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        
        // Canvas Container Layer (anchored at center for clean scaling & translation)
        canvasLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        canvasLayer.backgroundColor = NSColor.clear.cgColor
        canvasLayer.masksToBounds = false
        canvasLayer.borderWidth = 0
        canvasLayer.shadowOpacity = 0
        canvasLayer.magnificationFilter = .nearest
        canvasLayer.minificationFilter = .nearest
        layer?.addSublayer(canvasLayer)
        
        // Slot B: Player Video Layer (active during comparison playback)
        playerLayerB.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        playerLayerB.videoGravity = .resize
        playerLayerB.magnificationFilter = .nearest
        playerLayerB.minificationFilter = .nearest
        playerLayerB.backgroundColor = NSColor.clear.cgColor
        playerLayerB.borderWidth = 0
        playerLayerB.shadowOpacity = 0
        playerLayerB.isHidden = true
        playerLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "filters": NSNull(), "magnificationFilter": NSNull(), "minificationFilter": NSNull()]
        canvasLayer.addSublayer(playerLayerB)
        
        // Still Frame Layer B (active when paused for 100% pixel-perfect inspection)
        stillFrameLayerB.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stillFrameLayerB.contentsGravity = .resize
        stillFrameLayerB.magnificationFilter = .nearest
        stillFrameLayerB.minificationFilter = .nearest
        stillFrameLayerB.backgroundColor = NSColor.clear.cgColor
        stillFrameLayerB.borderWidth = 0
        stillFrameLayerB.shadowOpacity = 0
        stillFrameLayerB.isHidden = true
        stillFrameLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "filters": NSNull(), "magnificationFilter": NSNull(), "minificationFilter": NSNull()]
        canvasLayer.addSublayer(stillFrameLayerB)
        
        // Slot A: Player Video Layer (Master playback)
        playerLayerA.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        playerLayerA.videoGravity = .resize
        playerLayerA.magnificationFilter = .nearest
        playerLayerA.minificationFilter = .nearest
        playerLayerA.backgroundColor = NSColor.clear.cgColor
        playerLayerA.borderWidth = 0
        playerLayerA.shadowOpacity = 0
        playerLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "filters": NSNull(), "magnificationFilter": NSNull(), "minificationFilter": NSNull()]
        canvasLayer.addSublayer(playerLayerA)
        
        // Still Frame Layer A (active when paused for 100% pixel-perfect inspection)
        stillFrameLayerA.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stillFrameLayerA.contentsGravity = .resize
        stillFrameLayerA.magnificationFilter = .nearest
        stillFrameLayerA.minificationFilter = .nearest
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
        crosshairLayerA.isHidden = true
        crosshairLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
        canvasLayer.addSublayer(crosshairLayerA)
        
        // Film B Center Crosshair Guide
        crosshairLayerB.fillColor = nil
        crosshairLayerB.strokeColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
        crosshairLayerB.lineWidth = 1.0
        crosshairLayerB.shadowOpacity = 0
        crosshairLayerB.zPosition = 100
        crosshairLayerB.isHidden = true
        crosshairLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
        canvasLayer.addSublayer(crosshairLayerB)
        
        // Film A Title Safe & Action Safe overlay (Action Safe 90% and Title Safe 80% in crisp broadcast white)
        titleSafeLayerA.fillColor = nil
        titleSafeLayerA.strokeColor = NSColor(white: 1.0, alpha: 0.9).cgColor
        titleSafeLayerA.lineWidth = 1.0
        titleSafeLayerA.shadowOpacity = 0
        titleSafeLayerA.zPosition = 101
        titleSafeLayerA.isHidden = true
        titleSafeLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
        canvasLayer.addSublayer(titleSafeLayerA)
        
        // Film B Title Safe & Action Safe overlay
        titleSafeLayerB.fillColor = nil
        titleSafeLayerB.strokeColor = NSColor(white: 1.0, alpha: 0.9).cgColor
        titleSafeLayerB.lineWidth = 1.0
        titleSafeLayerB.shadowOpacity = 0
        titleSafeLayerB.zPosition = 101
        titleSafeLayerB.isHidden = true
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
        engine.onFrameDecoded = { [weak self] slot, time in
            self?.displayImmediateDecodedFrame(slot: slot, at: time)
        }
        setupDisplayLink()
    }
    
    public func update(engine: PlayerEngine, isLightMode: Bool) {
        let engineChanged = (self.engine !== engine)
        self.engine = engine
        if engineChanged {
            engine.onFrameDecoded = { [weak self] slot, time in
                self?.displayImmediateDecodedFrame(slot: slot, at: time)
            }
        }
        
        if playerLayerA.player != engine.slotA.player {
            playerLayerA.player = engine.slotA.player
        }
        if playerLayerB.player != engine.slotB.player {
            playerLayerB.player = engine.slotB.player
        }
        
        if engine.isPlaying {
            displayLink?.isPaused = false
        } else {
            displayLink?.isPaused = true
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
        canvasLayer.backgroundColor = NSColor.clear.cgColor
        
        layoutPlayerLayer()
        updateCompareLayers()
        updateExposure()
        updateMagnificationFilters()
        checkStillFrameDisplay()
    }
    
    public func displayImmediateDecodedFrame(slot: SlotTarget, at time: CMTime) {
        guard let engine = engine else { return }
        // During active scrubbing, AVPlayerLayer displays frames directly via hardware.
        // Avoid expensive CPU pixel buffer copying and CGImage conversion while scrubbing.
        if engine.isScrubbing { return }
        
        var imgToDisplay: CGImage? = nil
        var targetLayer: CALayer? = nil
        
        if slot == .slotA, let outputA = engine.slotA.videoOutput {
            var pbA = outputA.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            if pbA == nil {
                var displayTime = CMTime.zero
                pbA = outputA.copyPixelBuffer(forItemTime: engine.slotA.player.currentTime(), itemTimeForDisplay: &displayTime)
            }
            if let pb = pbA {
                var cgImageA: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cgImageA)
                if let img = cgImageA {
                    self.lastCapturedTimeA = time
                    self.rawStillFrameA = img
                    imgToDisplay = (engine.exposureEV != 0.0) ? ExposureAdjuster.shared.applyExposure(to: img, ev: engine.exposureEV) : img
                    targetLayer = stillFrameLayerA
                }
            }
        } else if slot == .slotB, (engine.compareMode != .single), let outputB = engine.slotB.videoOutput {
            var pbB = outputB.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            if pbB == nil {
                var displayTime = CMTime.zero
                pbB = outputB.copyPixelBuffer(forItemTime: engine.slotB.player.currentTime(), itemTimeForDisplay: &displayTime)
            }
            if let pb = pbB {
                var cgImageB: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cgImageB)
                if let imgB = cgImageB {
                    self.lastCapturedTimeB = time
                    self.rawStillFrameB = imgB
                    imgToDisplay = (engine.exposureEV != 0.0) ? ExposureAdjuster.shared.applyExposure(to: imgB, ev: engine.exposureEV) : imgB
                    targetLayer = stillFrameLayerB
                }
            }
        }
        
        if let img = imgToDisplay, let layer = targetLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = img
            layer.isHidden = false
            CATransaction.commit()
        }
    }
    
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window = newWindow {
            updateScale(for: window.backingScaleFactor)
            setupDisplayLink()
        } else {
            tearDownDisplayLink()
        }
    }
    
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupDisplayLink()
        }
    }
    
    private func setupDisplayLink() {
        guard displayLink == nil else { return }
        let link = self.displayLink(target: self, selector: #selector(onDisplayLinkTick))
        link.add(to: .main, forMode: .common)
        link.isPaused = !(engine?.isPlaying ?? false)
        self.displayLink = link
    }
    
    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func onDisplayLinkTick() {
        guard let engine = engine, engine.isPlaying else { return }
        renderPlaybackFrames()
    }
    
    private func renderPlaybackFrames() {
        guard let engine = engine, engine.isPlaying else { return }
        
        var newImgA: CGImage? = nil
        var newTimeA: CMTime? = nil
        var newImgB: CGImage? = nil
        var newTimeB: CMTime? = nil
        
        let masterTime = engine.slotA.player.currentTime()
        
        // Slot A frame extraction:
        if let outputA = engine.slotA.videoOutput {
            var displayTime = CMTime.zero
            if let pb = outputA.copyPixelBuffer(forItemTime: masterTime, itemTimeForDisplay: &displayTime) {
                var cgImageA: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cgImageA)
                if let img = cgImageA {
                    newImgA = (engine.exposureEV != 0.0) ? ExposureAdjuster.shared.applyExposure(to: img, ev: engine.exposureEV) : img
                    newTimeA = masterTime
                }
            }
        }
        
        // Slot B frame extraction (ONLY in active compare modes):
        if engine.compareMode != .single && engine.slotB.url != nil, let outputB = engine.slotB.videoOutput {
            let offsetSecs = Double(engine.slotB.slipOffsetFrames) / max(1.0, engine.slotB.fps)
            let masterSecs = CMTimeGetSeconds(masterTime)
            let targetSecsB = max(0.0, (masterSecs.isFinite && !masterSecs.isNaN ? masterSecs : 0.0) + offsetSecs)
            let targetTimeB = CMTime(seconds: targetSecsB, preferredTimescale: 60000)
            
            var displayTime = CMTime.zero
            if let pb = outputB.copyPixelBuffer(forItemTime: targetTimeB, itemTimeForDisplay: &displayTime) {
                var cgImageB: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cgImageB)
                if let imgB = cgImageB {
                    newImgB = (engine.exposureEV != 0.0) ? ExposureAdjuster.shared.applyExposure(to: imgB, ev: engine.exposureEV) : imgB
                    newTimeB = targetTimeB
                }
            }
        }
        
        // Commit both textures synchronously in a single atomic transaction
        if newImgA != nil || newImgB != nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let imgA = newImgA {
                self.lastCapturedTimeA = newTimeA
                self.rawStillFrameA = imgA
                self.stillFrameLayerA.contents = imgA
                self.stillFrameLayerA.isHidden = false
            }
            if let imgB = newImgB {
                self.lastCapturedTimeB = newTimeB
                self.rawStillFrameB = imgB
                self.stillFrameLayerB.contents = imgB
                self.stillFrameLayerB.isHidden = false
            }
            CATransaction.commit()
        }
    }
    
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale(for: window?.backingScaleFactor ?? 2.0)
    }
    
    private func updateScale(for scale: CGFloat) {
        guard scale != lastScale else { return }
        lastScale = scale
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
    
    private func getVideoPresentationSizeA() -> CGSize {
        if let item = playerLayerA.player?.currentItem, item.presentationSize.width > 0, item.presentationSize.height > 0 {
            return item.presentationSize
        }
        guard let engine = engine else { return CGSize(width: 1920, height: 1080) }
        let size = engine.slotA.videoSize
        if size.width > 0 && size.height > 0 {
            return size
        }
        return CGSize(width: 1920, height: 1080)
    }
    
    private func getVideoPresentationSizeB() -> CGSize {
        if let item = playerLayerB.player?.currentItem, item.presentationSize.width > 0, item.presentationSize.height > 0 {
            return item.presentationSize
        }
        guard let engine = engine else { return getVideoPresentationSizeA() }
        let size = engine.slotB.videoSize
        if size.width > 0 && size.height > 0 {
            return size
        }
        return getVideoPresentationSizeA()
    }
    
    private func getVideoAspectRatioA() -> CGFloat {
        let size = getVideoPresentationSizeA()
        return max(0.01, size.width / max(1.0, size.height))
    }
    
    private func getVideoAspectRatioB() -> CGFloat {
        let size = getVideoPresentationSizeB()
        return max(0.01, size.width / max(1.0, size.height))
    }
    
    /// Reduces video dimensions to a low-integer rational aspect ratio (num:den)
    /// to guarantee that bounds calculations step in whole physical display pixels with zero letterbox margin.
    private func getRationalAspect(width: Int, height: Int) -> (num: Int, den: Int) {
        guard width > 0, height > 0 else { return (16, 9) }
        let g = QCUtilities.gcd(width, height)
        let num = width / g
        let den = height / g
        if num <= 64 && den <= 64 {
            return (num, den)
        }
        let target = Double(width) / Double(height)
        var bestNum = num
        var bestDen = den
        var bestDiff = Double.infinity
        for d in 1...64 {
            let n = Int(round(Double(d) * target))
            let diff = abs(Double(n) / Double(d) - target)
            if diff < bestDiff {
                bestDiff = diff
                bestNum = n
                bestDen = d
                if diff < 1e-6 { break }
            }
        }
        return (bestNum, bestDen)
    }
    
    // MARK: - Subpixel & Display Alignment Helpers
    
    private func currentBackingScale() -> CGFloat {
        return window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }
    
    /// Snaps a point coordinate to exact physical display pixels (1.0 / scale)
    private func snapToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        return round(value * scale) / scale
    }
    
    /// Snaps a dimension to even physical display pixels ((Int(round(val * scale)) / 2) * 2 / scale)
    /// to guarantee that bounds and half-dimensions (w/2, h/2) never land on a 0.5 fractional subpixel.
    private func snapToEvenPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let pixels = round(value * scale)
        let evenPixels = (Int(pixels) / 2) * 2
        return CGFloat(evenPixels) / scale
    }
    
    private func getBaseFittedSize(in bounds: CGRect) -> CGSize {
        guard let engine = engine else { return bounds.size }
        let scale = currentBackingScale()
        let isSideBySideH = (engine.compareMode == .sideBySide && engine.slotB.url != nil)
        let isSideBySideV = (engine.compareMode == .sideBySideVertical && engine.slotB.url != nil)
        
        if isSideBySideH {
            let pSizeA = getVideoPresentationSizeA()
            let (numA, denA) = getRationalAspect(width: Int(round(pSizeA.width)), height: Int(round(pSizeA.height)))
            let pSizeB = getVideoPresentationSizeB()
            let (numB, denB) = getRationalAspect(width: Int(round(pSizeB.width)), height: Int(round(pSizeB.height)))
            let availW = max(1.0, bounds.width)
            let availH = max(1.0, bounds.height)
            let slotAvailW = max(1.0, (availW - 4.0) / 2.0)
            
            let maxPixelW = floor(slotAvailW * scale)
            let maxPixelH = floor(availH * scale)
            
            let stepsA = max(2.0, floor(min(maxPixelW / CGFloat(numA), maxPixelH / CGFloat(denA)) / 2.0) * 2.0)
            let fitWidthA = (stepsA * CGFloat(numA)) / scale
            let fitHeightA = (stepsA * CGFloat(denA)) / scale
            
            let stepsB = max(2.0, floor(min(maxPixelW / CGFloat(numB), maxPixelH / CGFloat(denB)) / 2.0) * 2.0)
            let fitWidthB = (stepsB * CGFloat(numB)) / scale
            let fitHeightB = (stepsB * CGFloat(denB)) / scale
            
            let canvasH = max(fitHeightA, fitHeightB)
            let canvasW = (max(fitWidthA, fitWidthB) * 2.0) + 4.0
            return CGSize(width: canvasW, height: canvasH)
        } else if isSideBySideV {
            let pSizeA = getVideoPresentationSizeA()
            let (numA, denA) = getRationalAspect(width: Int(round(pSizeA.width)), height: Int(round(pSizeA.height)))
            let pSizeB = getVideoPresentationSizeB()
            let (numB, denB) = getRationalAspect(width: Int(round(pSizeB.width)), height: Int(round(pSizeB.height)))
            let availW = max(1.0, bounds.width)
            let availH = max(1.0, bounds.height)
            let slotAvailH = max(1.0, (availH - 4.0) / 2.0)
            
            let maxPixelW = floor(availW * scale)
            let maxPixelH = floor(slotAvailH * scale)
            
            let stepsA = max(2.0, floor(min(maxPixelW / CGFloat(numA), maxPixelH / CGFloat(denA)) / 2.0) * 2.0)
            let fitWidthA = (stepsA * CGFloat(numA)) / scale
            let fitHeightA = (stepsA * CGFloat(denA)) / scale
            
            let stepsB = max(2.0, floor(min(maxPixelW / CGFloat(numB), maxPixelH / CGFloat(denB)) / 2.0) * 2.0)
            let fitWidthB = (stepsB * CGFloat(numB)) / scale
            let fitHeightB = (stepsB * CGFloat(denB)) / scale
            
            let canvasW = max(fitWidthA, fitWidthB)
            let canvasH = (max(fitHeightA, fitHeightB) * 2.0) + 4.0
            return CGSize(width: canvasW, height: canvasH)
        } else {
            let pSize = getVideoPresentationSizeA()
            guard pSize.width > 0, pSize.height > 0, bounds.width > 0, bounds.height > 0 else {
                return bounds.size
            }
            let (num, den) = getRationalAspect(width: Int(round(pSize.width)), height: Int(round(pSize.height)))
            let maxPixelW = floor(bounds.width * scale)
            let maxPixelH = floor(bounds.height * scale)
            let stepW = maxPixelW / CGFloat(num)
            let stepH = maxPixelH / CGFloat(den)
            let rawSteps = min(stepW, stepH)
            let evenSteps = max(2.0, floor(rawSteps / 2.0) * 2.0)
            let pixelW = evenSteps * CGFloat(num)
            let pixelH = evenSteps * CGFloat(den)
            return CGSize(width: pixelW / scale, height: pixelH / scale)
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
        // Snap the center of canvasLayer to physical display pixels to eliminate fractional-pixel blurring.
        let centerX = snapToPixel(viewBounds.midX + panOffset.width, scale: scale)
        let centerY = snapToPixel(viewBounds.midY + panOffset.height, scale: scale)
        
        canvasLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
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
            // Fit Slot B in canvas bounds preserving its native rational aspect ratio
            let pSizeB = getVideoPresentationSizeB()
            let (numB, denB) = getRationalAspect(width: Int(round(pSizeB.width)), height: Int(round(pSizeB.height)))
            let scaleVal = currentBackingScale()
            let maxPixelW = floor(w * scaleVal)
            let maxPixelH = floor(h * scaleVal)
            let steps = max(1.0, min(floor(maxPixelW / CGFloat(numB)), floor(maxPixelH / CGFloat(denB))))
            let pixelWB = steps * CGFloat(numB)
            let pixelHB = steps * CGFloat(denB)
            let fitW = pixelWB / scaleVal
            let fitH = pixelHB / scaleVal
            let originX = snapToPixel((w - fitW) / 2, scale: scaleVal)
            let originY = snapToPixel((h - fitH) / 2, scale: scaleVal)
            let frameB = CGRect(x: originX, y: originY, width: fitW, height: fitH)
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
            let pSizeA = getVideoPresentationSizeA()
            let (numA, denA) = getRationalAspect(width: Int(round(pSizeA.width)), height: Int(round(pSizeA.height)))
            let pSizeB = getVideoPresentationSizeB()
            let (numB, denB) = getRationalAspect(width: Int(round(pSizeB.width)), height: Int(round(pSizeB.height)))
            let halfW = snapToPixel((w - 4) / 2, scale: scale)
            let maxPixelHalfW = floor(halfW * scale)
            let maxPixelH = floor(h * scale)
            
            let stepsA = max(1.0, min(floor(maxPixelHalfW / CGFloat(numA)), floor(maxPixelH / CGFloat(denA))))
            let fitWidthA = (stepsA * CGFloat(numA)) / scale
            let fitHeightA = (stepsA * CGFloat(denA)) / scale
            let yPosA = snapToPixel((h - fitHeightA) / 2, scale: scale)
            let xPosA = snapToPixel((halfW - fitWidthA) / 2, scale: scale)
            let frameA = CGRect(x: xPosA, y: yPosA, width: fitWidthA, height: fitHeightA)
            
            let stepsB = max(1.0, min(floor(maxPixelHalfW / CGFloat(numB)), floor(maxPixelH / CGFloat(denB))))
            let fitWidthB = (stepsB * CGFloat(numB)) / scale
            let fitHeightB = (stepsB * CGFloat(denB)) / scale
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
            let pSizeA = getVideoPresentationSizeA()
            let (numA, denA) = getRationalAspect(width: Int(round(pSizeA.width)), height: Int(round(pSizeA.height)))
            let pSizeB = getVideoPresentationSizeB()
            let (numB, denB) = getRationalAspect(width: Int(round(pSizeB.width)), height: Int(round(pSizeB.height)))
            let halfH = snapToPixel((h - 4) / 2, scale: scale)
            let maxPixelW = floor(w * scale)
            let maxPixelHalfH = floor(halfH * scale)
            
            let stepsA = max(1.0, min(floor(maxPixelW / CGFloat(numA)), floor(maxPixelHalfH / CGFloat(denA))))
            let fitWidthA = (stepsA * CGFloat(numA)) / scale
            let fitHeightA = (stepsA * CGFloat(denA)) / scale
            let xPosA = snapToPixel((w - fitWidthA) / 2, scale: scale)
            let yPosA = snapToPixel(h / 2 + 2 + (halfH - fitHeightA) / 2, scale: scale)
            let frameA = CGRect(x: xPosA, y: yPosA, width: fitWidthA, height: fitHeightA)
            
            let stepsB = max(1.0, min(floor(maxPixelW / CGFloat(numB)), floor(maxPixelHalfH / CGFloat(denB))))
            let fitWidthB = (stepsB * CGFloat(numB)) / scale
            let fitHeightB = (stepsB * CGFloat(denB)) / scale
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
        guard let _ = engine else { return }
        // ARCHITECTURAL MANDATE (AGENTS.md Section 2):
        // All layers (canvasLayer, playerLayerA/B, stillFrameLayerA/B) MUST ALWAYS use .nearest
        // for BOTH magnificationFilter and minificationFilter.
        // Using .linear causes bilinear downsampling/interpolation that averages 1-pixel edge lines
        // into adjacent pixels, turning green lines white during 1x playback and timeline scrubbing.
        if canvasLayer.magnificationFilter != .nearest {
            canvasLayer.magnificationFilter = .nearest
        }
        if canvasLayer.minificationFilter != .nearest {
            canvasLayer.minificationFilter = .nearest
        }
        if stillFrameLayerA.magnificationFilter != .nearest {
            stillFrameLayerA.magnificationFilter = .nearest
        }
        if stillFrameLayerA.minificationFilter != .nearest {
            stillFrameLayerA.minificationFilter = .nearest
        }
        if stillFrameLayerB.magnificationFilter != .nearest {
            stillFrameLayerB.magnificationFilter = .nearest
        }
        if stillFrameLayerB.minificationFilter != .nearest {
            stillFrameLayerB.minificationFilter = .nearest
        }
        if playerLayerA.magnificationFilter != .nearest {
            playerLayerA.magnificationFilter = .nearest
        }
        if playerLayerA.minificationFilter != .nearest {
            playerLayerA.minificationFilter = .nearest
        }
        if playerLayerB.magnificationFilter != .nearest {
            playerLayerB.magnificationFilter = .nearest
        }
        if playerLayerB.minificationFilter != .nearest {
            playerLayerB.minificationFilter = .nearest
        }
    }
    
    // MARK: - Layer Visibility & Unified Direct-Pixel Inspection
    
    private func updateLayerVisibility() {
        guard let engine = engine else { return }
        let mode = (engine.slotB.url == nil) ? CompareMode.single : engine.compareMode
        let isBlink = engine.isBlinkCompareB && engine.slotB.url != nil
        let isScrubbing = engine.isScrubbing
        
        let targetStillHiddenA: Bool
        let targetStillHiddenB: Bool
        let targetPlayerHiddenA: Bool
        let targetPlayerHiddenB: Bool
        
        if isBlink {
            targetStillHiddenA = true
            targetStillHiddenB = (engine.slotB.url == nil)
            targetPlayerHiddenA = true
            targetPlayerHiddenB = true
        } else if isScrubbing {
            // NATIVE HARDWARE ACCELERATED SCRUBBING (QuickTime-grade):
            // While dragging the timeline, reveal AVPlayerLayer directly.
            // CoreMedia hardware compositor decodes and presents frames with 0 copy overhead.
            targetPlayerHiddenA = (engine.slotA.url == nil)
            targetStillHiddenA = true
            if mode == .single || engine.slotB.url == nil {
                targetPlayerHiddenB = true
                targetStillHiddenB = true
            } else {
                targetPlayerHiddenB = false
                targetStillHiddenB = true
            }
        } else {
            // PAUSED & STEPPING & LIVE PLAYBACK:
            // stillFrameLayer is the display layer, using uncompressed CGImage with .nearest
            // filtering, 100% immune to CoreMedia motion-downsampling during hand tool panning/zooming.
            targetPlayerHiddenA = true
            targetPlayerHiddenB = true
            targetStillHiddenA = (engine.slotA.url == nil)
            if mode == .single || engine.slotB.url == nil {
                targetStillHiddenB = true
            } else {
                targetStillHiddenB = false
            }
        }
        
        // Fast path: skip expensive CoreAnimation transactions if layer visibility is already identical
        if stillFrameLayerA.isHidden == targetStillHiddenA &&
           stillFrameLayerB.isHidden == targetStillHiddenB &&
           playerLayerA.isHidden == targetPlayerHiddenA &&
           playerLayerB.isHidden == targetPlayerHiddenB {
            return
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateMagnificationFilters()
        
        stillFrameLayerA.isHidden = targetStillHiddenA
        stillFrameLayerB.isHidden = targetStillHiddenB
        playerLayerA.isHidden = targetPlayerHiddenA
        playerLayerB.isHidden = targetPlayerHiddenB
        
        CATransaction.commit()
    }
    
    private func checkStillFrameDisplay() {
        guard let engine = engine, engine.slotA.url != nil else { return }
        
        // If actively playing or scrubbing, displayLink handles frame updates at screen refresh rate
        if engine.isPlaying || engine.isScrubbing {
            updateLayerVisibility()
            return
        }
        
        let timeA = engine.currentTime
        let timeSecsA = CMTimeGetSeconds(timeA)
        let frameDurationA = 1.0 / max(1.0, engine.slotA.fps)
        let toleranceA = min(0.03, frameDurationA * 0.5)
        
        // 1. Check if stillFrameLayerA already displays the current frame
        let isFreshA: Bool
        if let lastA = lastCapturedTimeA, abs(CMTimeGetSeconds(lastA) - timeSecsA) <= toleranceA, stillFrameLayerA.contents != nil {
            isFreshA = true
        } else {
            isFreshA = false
        }
        
        if !isFreshA {
            // 2. Direct VideoOutput pull (<0.15ms execution)
            var fetchedFromOutputA = false
            if let outputA = engine.slotA.videoOutput,
               let pbA = outputA.copyPixelBuffer(forItemTime: timeA, itemTimeForDisplay: nil) {
                var cgImageA: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pbA, options: nil, imageOut: &cgImageA)
                if let img = cgImageA {
                    self.lastCapturedTimeA = timeA
                    self.rawStillFrameA = img
                    let exposedImg = (engine.exposureEV != 0.0) ? ExposureAdjuster.shared.applyExposure(to: img, ev: engine.exposureEV) : img
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.stillFrameLayerA.contents = exposedImg
                    CATransaction.commit()
                    fetchedFromOutputA = true
                }
            }
            
            // 3. Fallback to FrameExtractor (AVAssetImageGenerator ~9.8ms) if videoOutput hasn't buffered this seek frame
            if !fetchedFromOutputA {
                if isCapturingStillA {
                    self.pendingCaptureTimeA = timeA
                } else {
                    self.pendingCaptureTimeA = nil
                    isCapturingStillA = true
                    Task { [weak self] in
                        guard let self = self, let curEngine = self.engine else { return }
                        let img = await curEngine.captureCurrentFrame(for: .slotA, at: timeA)
                        await MainActor.run {
                            self.isCapturingStillA = false
                            guard let curEngine = self.engine else { return }
                            if let img = img {
                                self.lastCapturedTimeA = timeA
                                self.rawStillFrameA = img
                                let exposedImg = (curEngine.exposureEV != 0.0) ? ExposureAdjuster.shared.applyExposure(to: img, ev: curEngine.exposureEV) : img
                                CATransaction.begin()
                                CATransaction.setDisableActions(true)
                                self.stillFrameLayerA.contents = exposedImg
                                CATransaction.commit()
                                self.updateLayerVisibility()
                            }
                            if let pending = self.pendingCaptureTimeA, pending != timeA {
                                self.checkStillFrameDisplay()
                            }
                        }
                    }
                }
            }
        }
        
        // Slot B still frame check if active comparison
        if engine.slotB.url != nil && engine.compareMode != .single {
            let timeB = engine.slotB.player.currentTime()
            let timeSecsB = CMTimeGetSeconds(timeB)
            let frameDurationB = 1.0 / max(1.0, engine.slotB.fps)
            let toleranceB = min(0.03, frameDurationB * 0.5)
            
            let isFreshB: Bool
            if let lastB = lastCapturedTimeB, abs(CMTimeGetSeconds(lastB) - timeSecsB) <= toleranceB, stillFrameLayerB.contents != nil {
                isFreshB = true
            } else {
                isFreshB = false
            }
            
            if !isFreshB {
                var fetchedFromOutputB = false
                if let outputB = engine.slotB.videoOutput,
                   let pbB = outputB.copyPixelBuffer(forItemTime: timeB, itemTimeForDisplay: nil) {
                    var cgImageB: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(pbB, options: nil, imageOut: &cgImageB)
                    if let imgB = cgImageB {
                        self.lastCapturedTimeB = timeB
                        self.rawStillFrameB = imgB
                        let exposedImgB = (engine.exposureEV != 0.0) ? ExposureAdjuster.shared.applyExposure(to: imgB, ev: engine.exposureEV) : imgB
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.stillFrameLayerB.contents = exposedImgB
                        CATransaction.commit()
                        fetchedFromOutputB = true
                    }
                }
                
                if !fetchedFromOutputB {
                    if isCapturingStillB {
                        self.pendingCaptureTimeB = timeB
                    } else {
                        self.pendingCaptureTimeB = nil
                        isCapturingStillB = true
                        Task { [weak self] in
                            guard let self = self, let curEngine = self.engine else { return }
                            let imgB = await curEngine.captureCurrentFrame(for: .slotB, at: timeB)
                            await MainActor.run {
                                self.isCapturingStillB = false
                                guard let curEngine = self.engine else { return }
                                if let imgB = imgB {
                                    self.lastCapturedTimeB = timeB
                                    self.rawStillFrameB = imgB
                                    let exposedImgB = (curEngine.exposureEV != 0.0) ? ExposureAdjuster.shared.applyExposure(to: imgB, ev: curEngine.exposureEV) : imgB
                                    CATransaction.begin()
                                    CATransaction.setDisableActions(true)
                                    self.stillFrameLayerB.contents = exposedImgB
                                    CATransaction.commit()
                                    self.updateLayerVisibility()
                                }
                                if let pendingB = self.pendingCaptureTimeB, pendingB != timeB {
                                    self.checkStillFrameDisplay()
                                }
                            }
                        }
                    }
                }
            }
        }
        
        updateLayerVisibility()
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
