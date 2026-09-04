import SwiftUI
import AppKit
import AVFoundation

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
    
    // Slot B (Underneath in comparison modes)
    private let playerLayerB = AVPlayerLayer()
    
    // Slot A (Master / Top layer)
    private let playerLayerA = AVPlayerLayer()
    private let maskLayerA = CAShapeLayer()
    
    // Split Divider & Handle
    private let splitDividerLayer = CALayer()
    private let splitHandleLayer = CALayer()
    private let splitHandleGripLayer = CAShapeLayer()
    
    // Center Crosshair Guide
    private let crosshairLayer = CAShapeLayer()
    
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
    private var lastSlotAURL: URL? = nil
    private var lastSlotBURL: URL? = nil
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
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
        playerLayerB.videoGravity = .resizeAspect
        playerLayerB.magnificationFilter = .linear
        playerLayerB.minificationFilter = .linear
        playerLayerB.backgroundColor = NSColor.clear.cgColor
        playerLayerB.borderWidth = 0
        playerLayerB.shadowOpacity = 0
        playerLayerB.isHidden = true
        playerLayerB.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        canvasLayer.addSublayer(playerLayerB)
        
        // Slot A: Player Video Layer (Master playback)
        playerLayerA.videoGravity = .resizeAspect
        playerLayerA.magnificationFilter = .linear
        playerLayerA.minificationFilter = .linear
        playerLayerA.backgroundColor = NSColor.clear.cgColor
        playerLayerA.borderWidth = 0
        playerLayerA.shadowOpacity = 0
        playerLayerA.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        canvasLayer.addSublayer(playerLayerA)
        
        // Mask Layer for Layer A (disables implicit animation for instantaneous 120fps wipe tracking)
        maskLayerA.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "frame": NSNull()]
        
        // Split Divider Line Layer
        splitDividerLayer.backgroundColor = NSColor(red: 0.1, green: 0.95, blue: 0.85, alpha: 0.9).cgColor
        splitDividerLayer.isHidden = true
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
        splitHandleLayer.isHidden = true
        splitHandleLayer.actions = ["hidden": NSNull(), "opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        canvasLayer.addSublayer(splitHandleLayer)
        
        // Tactile micro-groove grip lines inside handle
        splitHandleGripLayer.strokeColor = NSColor(white: 0.25, alpha: 0.85).cgColor
        splitHandleGripLayer.fillColor = nil
        splitHandleGripLayer.lineWidth = 1.0
        splitHandleGripLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "path": NSNull()]
        splitHandleLayer.addSublayer(splitHandleGripLayer)
        
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
        
        let canvasColor = isLightMode ? NSColor(white: 0.88, alpha: 1.0).cgColor : NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        layer?.backgroundColor = canvasColor
        
        layoutPlayerLayer()
        updateCompareLayers()
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
        crosshairLayer.contentsScale = scale
        splitHandleGripLayer.contentsScale = scale
    }
    
    public override func layout() {
        super.layout()
        layoutPlayerLayer()
        updateCompareLayers()
    }
    
    // MARK: - Video Aspect Ratio & Layout
    
    private func getVideoAspectRatio() -> CGFloat {
        if let item = playerLayerA.player?.currentItem, item.presentationSize.width > 0, item.presentationSize.height > 0 {
            return item.presentationSize.width / item.presentationSize.height
        }
        guard let engine = engine else { return 16.0 / 9.0 }
        let w = engine.videoSize.width
        let h = engine.videoSize.height
        if w > 0 && h > 0 {
            return w / h
        }
        return 16.0 / 9.0
    }
    
    private func getBaseFittedSize(in bounds: CGRect) -> CGSize {
        guard let engine = engine else { return bounds.size }
        let isSideBySideH = (engine.compareMode == .sideBySide && engine.slotB.url != nil)
        let isSideBySideV = (engine.compareMode == .sideBySideVertical && engine.slotB.url != nil)
        let aspectMultiplier: CGFloat = isSideBySideH ? 2.0 : (isSideBySideV ? 0.5 : 1.0)
        let aspect = getVideoAspectRatio() * aspectMultiplier
        guard aspect > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds.size
        }
        
        let boundsAspect = bounds.width / bounds.height
        if boundsAspect > aspect {
            let h = round(bounds.height)
            let w = round(h * aspect)
            return CGSize(width: w, height: h)
        } else {
            let w = round(bounds.width)
            let h = round(w / aspect)
            return CGSize(width: w, height: h)
        }
    }
    
    private func layoutPlayerLayer() {
        guard let engine = engine else { return }
        let viewBounds = bounds
        guard viewBounds.width > 0 && viewBounds.height > 0 else { return }
        
        let zoomScale: CGFloat = engine.isFitZoom ? 1.0 : engine.zoomScale
        let panOffset = engine.isFitZoom ? .zero : engine.panOffset
        let isFitZoom = engine.isFitZoom
        let showCrosshair = engine.showCenterCrosshair
        let baseSize = getBaseFittedSize(in: viewBounds)
        
        // Fast path: skip expensive layer transforms & path reallocations if unchanged
        if viewBounds.size == lastBoundsSize &&
           zoomScale == lastZoomScale &&
           panOffset == lastPanOffset &&
           isFitZoom == lastIsFitZoom &&
           showCrosshair == lastShowCrosshair &&
           canvasLayer.bounds.size == baseSize {
            return
        }
        
        lastBoundsSize = viewBounds.size
        lastZoomScale = zoomScale
        lastPanOffset = panOffset
        lastIsFitZoom = isFitZoom
        lastShowCrosshair = showCrosshair
        
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        updateScale(for: scale)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        if canvasLayer.bounds.size != baseSize {
            canvasLayer.bounds = CGRect(origin: .zero, size: baseSize)
            updateCrosshairPath(size: baseSize)
        }
        
        let centerX = viewBounds.midX + panOffset.width
        let centerY = viewBounds.midY + panOffset.height
        
        canvasLayer.position = CGPoint(x: centerX, y: centerY)
        canvasLayer.setAffineTransform(CGAffineTransform(scaleX: zoomScale, y: zoomScale))
        
        crosshairLayer.lineWidth = 1.0 / max(0.01, zoomScale)
        crosshairLayer.isHidden = !showCrosshair
        
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
        let slotAURL = engine.slotA.url
        let slotBURL = engine.slotB.url
        
        // Fast path: skip re-rendering layers if compare state and canvas size are unchanged
        if mode == lastCompareMode &&
           splitPos == lastSplitPosition &&
           isBlink == lastIsBlink &&
           slotAURL == lastSlotAURL &&
           slotBURL == lastSlotBURL &&
           playerLayerA.frame.size == canvasLayer.bounds.size {
            return
        }
        
        lastCompareMode = mode
        lastSplitPosition = splitPos
        lastIsBlink = isBlink
        lastSlotAURL = slotAURL
        lastSlotBURL = slotBURL
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        // Blink compare: Rapidly show 100% Slot B when toggled
        if isBlink {
            playerLayerA.isHidden = true
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            playerLayerA.compositingFilter = nil
            
            playerLayerB.isHidden = false
            playerLayerB.frame = canvasLayer.bounds
            
            splitDividerLayer.isHidden = true
            splitHandleLayer.isHidden = true
            CATransaction.commit()
            return
        }
        
        switch mode {
        case .single:
            playerLayerB.isHidden = true
            playerLayerA.isHidden = false
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            playerLayerA.compositingFilter = nil
            playerLayerA.frame = canvasLayer.bounds
            
            splitDividerLayer.isHidden = true
            splitHandleLayer.isHidden = true
            
        case .splitVertical:
            playerLayerB.isHidden = false
            playerLayerA.isHidden = false
            playerLayerA.compositingFilter = nil
            playerLayerA.frame = canvasLayer.bounds
            playerLayerB.frame = canvasLayer.bounds
            
            let splitX = round(w * splitPos)
            let maskRect = CGRect(x: 0, y: 0, width: splitX, height: h)
            let maskPath = CGPath(rect: maskRect, transform: nil)
            
            maskLayerA.path = maskPath
            if playerLayerA.mask !== maskLayerA {
                playerLayerA.mask = maskLayerA
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
            playerLayerB.isHidden = false
            playerLayerA.isHidden = false
            playerLayerA.compositingFilter = nil
            playerLayerA.frame = canvasLayer.bounds
            playerLayerB.frame = canvasLayer.bounds
            
            // In AppKit, y=0 is at bottom. splitY from bottom.
            let splitY = round(h * splitPos)
            let maskRect = CGRect(x: 0, y: splitY, width: w, height: h - splitY)
            let maskPath = CGPath(rect: maskRect, transform: nil)
            
            maskLayerA.path = maskPath
            if playerLayerA.mask !== maskLayerA {
                playerLayerA.mask = maskLayerA
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
            playerLayerB.isHidden = false
            playerLayerA.isHidden = false
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            playerLayerA.compositingFilter = nil
            
            let halfW = (w - 4) / 2
            let singleAspect = getVideoAspectRatio()
            let fittedHeight = min(h, halfW / max(0.1, singleAspect))
            let fittedWidth = round(fittedHeight * singleAspect)
            let yPos = (h - fittedHeight) / 2
            
            let frameA = CGRect(x: (halfW - fittedWidth) / 2, y: yPos, width: fittedWidth, height: fittedHeight)
            let frameB = CGRect(x: w / 2 + 2 + (halfW - fittedWidth) / 2, y: yPos, width: fittedWidth, height: fittedHeight)
            
            playerLayerA.frame = frameA
            playerLayerB.frame = frameB
            
            splitDividerLayer.isHidden = false
            splitDividerLayer.backgroundColor = NSColor(white: 0.35, alpha: 0.7).cgColor
            splitDividerLayer.frame = CGRect(x: round(w / 2 - 0.75), y: yPos, width: 1.5, height: fittedHeight)
            splitHandleLayer.isHidden = true
            
        case .sideBySideVertical:
            playerLayerB.isHidden = false
            playerLayerA.isHidden = false
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            playerLayerA.compositingFilter = nil
            
            let halfH = (h - 4) / 2
            let singleAspect = getVideoAspectRatio()
            let fittedWidth = min(w, halfH * singleAspect)
            let fittedHeight = round(fittedWidth / max(0.1, singleAspect))
            let xPos = (w - fittedWidth) / 2
            
            // In AppKit, y=0 is bottom (Slot B), y=h is top (Slot A)
            let frameB = CGRect(x: xPos, y: (halfH - fittedHeight) / 2, width: fittedWidth, height: fittedHeight)
            let frameA = CGRect(x: xPos, y: h / 2 + 2 + (halfH - fittedHeight) / 2, width: fittedWidth, height: fittedHeight)
            
            playerLayerA.frame = frameA
            playerLayerB.frame = frameB
            
            splitDividerLayer.isHidden = false
            splitDividerLayer.backgroundColor = NSColor(white: 0.35, alpha: 0.7).cgColor
            splitDividerLayer.frame = CGRect(x: xPos, y: round(h / 2 - 0.75), width: fittedWidth, height: 1.5)
            splitHandleLayer.isHidden = true
            
        case .difference:
            // Pure GPU difference blend (|RGB_A - RGB_B|) directly between playerLayerA and playerLayerB
            playerLayerB.isHidden = false
            playerLayerA.isHidden = false
            if playerLayerA.mask != nil {
                playerLayerA.mask = nil
            }
            playerLayerA.frame = canvasLayer.bounds
            playerLayerB.frame = canvasLayer.bounds
            
            playerLayerA.compositingFilter = "differenceBlendMode"
            
            splitDividerLayer.isHidden = true
            splitHandleLayer.isHidden = true
        }
        
        CATransaction.commit()
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
    
    // MARK: - Interactive Split Wipe Drag & Canvas Pan
    
    private func pointInCanvas(from windowPoint: NSPoint) -> CGPoint {
        let viewPoint = convert(windowPoint, from: nil)
        return layer?.convert(viewPoint, to: canvasLayer) ?? viewPoint
    }
    
    private func isNearSplitDivider(windowPoint: NSPoint) -> Bool {
        guard let engine = engine, engine.slotB.url != nil, engine.compareMode != .single else { return false }
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
