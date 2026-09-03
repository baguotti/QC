import SwiftUI
import AppKit
import AVFoundation

public struct VideoViewportView: NSViewRepresentable {
    @ObservedObject var engine: PlayerEngine
    var isLightMode: Bool
    
    public init(engine: PlayerEngine, isLightMode: Bool) {
        self.engine = engine
        self.isLightMode = isLightMode
    }
    
    public func makeNSView(context: Context) -> PlayerContainerNSView {
        let view = PlayerContainerNSView()
        view.setup(engine: engine)
        return view
    }
    
    public func updateNSView(_ nsView: PlayerContainerNSView, context: Context) {
        nsView.update(engine: engine, isLightMode: isLightMode)
    }
}

public final class PlayerContainerNSView: NSView {
    private let canvasLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let stillFrameLayer = CALayer()
    private let crosshairLayer = CAShapeLayer()
    private weak var engine: PlayerEngine?
    private var dragStartLocation: NSPoint? = nil
    private var initialPanOffset: CGSize = .zero
    
    private var lastCapturedTime: CMTime? = nil
    private var isCapturingStill: Bool = false
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        
        // Canvas Container Layer (anchored at center for clean scaling & translation)
        canvasLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        canvasLayer.backgroundColor = NSColor.clear.cgColor
        canvasLayer.borderWidth = 0
        canvasLayer.shadowOpacity = 0
        layer?.addSublayer(canvasLayer)
        
        // Player Video Layer (active during playback)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.magnificationFilter = .linear
        playerLayer.minificationFilter = .linear
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.borderWidth = 0
        playerLayer.shadowOpacity = 0
        playerLayer.actions = ["hidden": NSNull(), "opacity": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        canvasLayer.addSublayer(playerLayer)
        
        // Still Frame Layer (active when paused for 100% pixel-perfect inspection)
        stillFrameLayer.contentsGravity = .resizeAspect
        stillFrameLayer.magnificationFilter = .linear
        stillFrameLayer.minificationFilter = .linear
        stillFrameLayer.backgroundColor = NSColor.clear.cgColor
        stillFrameLayer.borderWidth = 0
        stillFrameLayer.shadowOpacity = 0
        stillFrameLayer.isHidden = true
        stillFrameLayer.actions = ["hidden": NSNull(), "opacity": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        canvasLayer.addSublayer(stillFrameLayer)
        
        // Center crosshair overlay (top-to-bottom centering guide)
        crosshairLayer.fillColor = nil
        crosshairLayer.strokeColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
        crosshairLayer.lineWidth = 1.0
        crosshairLayer.shadowOpacity = 0
        crosshairLayer.zPosition = 100
        canvasLayer.addSublayer(crosshairLayer)
        
        // Native trackpad pinch gesture for zoom in / zoom out
        let pinchGesture = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinchGesture)
        
        // Track mouse movement for custom cursor
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
        playerLayer.player = engine.player
    }
    
    public func update(engine: PlayerEngine, isLightMode: Bool) {
        self.engine = engine
        if playerLayer.player != engine.player {
            playerLayer.player = engine.player
            // Clear stale still frame from previous video to prevent wrong-AR ghost
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.lastCapturedTime = nil
            self.stillFrameLayer.contents = nil
            self.stillFrameLayer.isHidden = true
            self.playerLayer.isHidden = false
            CATransaction.commit()
        }
        
        // Deep canvas background (Premiere style neutral dark gray)
        let canvasColor = isLightMode ? NSColor(white: 0.88, alpha: 1.0).cgColor : NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        layer?.backgroundColor = canvasColor
        
        layoutPlayerLayer()
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
        playerLayer.contentsScale = scale
        stillFrameLayer.contentsScale = scale
        crosshairLayer.contentsScale = scale
    }
    
    public override func layout() {
        super.layout()
        layoutPlayerLayer()
    }
    
    // MARK: - Video Aspect Ratio & Layout
    
    private func getVideoAspectRatio() -> CGFloat {
        guard let engine = engine else { return 16.0 / 9.0 }
        let w = engine.videoSize.width
        let h = engine.videoSize.height
        if w > 0 && h > 0 {
            return w / h
        }
        return 16.0 / 9.0
    }
    
    private func getBaseFittedSize(in bounds: CGRect) -> CGSize {
        let aspect = getVideoAspectRatio()
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds.size
        }
        
        let boundsAspect = bounds.width / bounds.height
        if boundsAspect > aspect {
            // Limited by height
            let h = round(bounds.height)
            let w = round(h * aspect)
            return CGSize(width: w, height: h)
        } else {
            // Limited by width
            let w = round(bounds.width)
            let h = round(w / aspect)
            return CGSize(width: w, height: h)
        }
    }
    
    private func layoutPlayerLayer() {
        guard let engine = engine else { return }
        let viewBounds = bounds
        guard viewBounds.width > 0 && viewBounds.height > 0 else { return }
        
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        updateScale(for: scale)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        let baseSize = getBaseFittedSize(in: viewBounds)
        
        // Only re-size canvasLayer and playerLayer when baseSize actually changes
        // (e.g. window resize or different aspect ratio file loaded)
        // Moving the canvas with the hand tool NEVER resizes or touches playerLayer!
        if canvasLayer.bounds.size != baseSize {
            canvasLayer.bounds = CGRect(origin: .zero, size: baseSize)
            playerLayer.frame = canvasLayer.bounds
            stillFrameLayer.frame = canvasLayer.bounds
            updateCrosshairPath(size: baseSize)
        }
        
        let zoomScale: CGFloat = engine.isFitZoom ? 1.0 : engine.zoomScale
        let centerX = viewBounds.midX + (engine.isFitZoom ? 0 : engine.panOffset.width)
        let centerY = viewBounds.midY + (engine.isFitZoom ? 0 : engine.panOffset.height)
        
        canvasLayer.position = CGPoint(x: centerX, y: centerY)
        canvasLayer.setAffineTransform(CGAffineTransform(scaleX: zoomScale, y: zoomScale))
        
        // Keep crosshair 1.0px on screen regardless of zoom level
        crosshairLayer.lineWidth = 1.0 / max(0.01, zoomScale)
        crosshairLayer.isHidden = !engine.showCenterCrosshair
        
        CATransaction.commit()
    }
    
    private func checkStillFrameDisplay() {
        guard let engine = engine else { return }
        
        // If playing or actively scrubbing, show the live AVPlayerLayer
        if engine.isPlaying || engine.isScrubbing {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillFrameLayer.isHidden = true
            playerLayer.isHidden = false
            CATransaction.commit()
            return
        }
        
        let time = engine.currentTime
        if let last = lastCapturedTime, abs(CMTimeGetSeconds(last) - CMTimeGetSeconds(time)) < 0.005 {
            // Already showing this exact frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stillFrameLayer.isHidden = false
            playerLayer.isHidden = true
            CATransaction.commit()
            return
        }
        
        guard !isCapturingStill else { return }
        isCapturingStill = true
        
        Task { [weak self] in
            guard let self = self, let curEngine = self.engine else { return }
            let img = await curEngine.captureCurrentFrame(at: time)
            await MainActor.run {
                self.isCapturingStill = false
                guard let img = img, let curEngine = self.engine else { return }
                if !curEngine.isPlaying && abs(CMTimeGetSeconds(curEngine.currentTime) - CMTimeGetSeconds(time)) < 0.04 {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.lastCapturedTime = time
                    self.stillFrameLayer.contents = img
                    self.stillFrameLayer.isHidden = false
                    self.playerLayer.isHidden = true
                    CATransaction.commit()
                }
            }
        }
    }
    
    private func updateCrosshairPath(size: CGSize) {
        crosshairLayer.frame = CGRect(origin: .zero, size: size)
        let midX = size.width / 2.0
        let midY = size.height / 2.0
        
        let path = CGMutablePath()
        path.move(to: CGPoint(x: midX, y: 0))
        path.addLine(to: CGPoint(x: midX, y: size.height))
        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: size.width, y: midY))
        crosshairLayer.path = path
    }
    
    // MARK: - Interactive Pan & Drag
    
    public override func mouseDown(with event: NSEvent) {
        guard let engine = engine else {
            super.mouseDown(with: event)
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
        guard let engine = engine, let start = dragStartLocation, !engine.isFitZoom else {
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
            // Double click: toggle between Fit and 100%
            if let engine = engine {
                if engine.isFitZoom {
                    engine.setZoomLevel(1.0)
                } else {
                    engine.setZoomFit()
                }
            }
            return
        }
        
        if dragStartLocation != nil {
            dragStartLocation = nil
            updateCursor()
        } else {
            super.mouseUp(with: event)
        }
    }
    
    // MARK: - Pinch Gesture & Scroll Wheel
    
    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        guard let engine = engine else { return }
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
        guard let engine = engine else {
            super.scrollWheel(with: event)
            return
        }
        
        // Gentle, controlled mouse scroll wheel zoom
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
        
        // Horizontal scroll pans canvas horizontally when not in fit mode
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
    
    private func updateCursor() {
        guard let engine = engine else { return }
        if !engine.isFitZoom {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
