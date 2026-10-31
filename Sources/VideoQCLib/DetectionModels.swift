import Foundation

public enum EdgeLocation: String, CaseIterable, Identifiable, Sendable {
    case top = "Top"
    case bottom = "Bottom"
    case left = "Left"
    case right = "Right"
    case splitHorizontal = "Split Screen (H)"
    case splitVertical = "Split Screen (V)"
    
    public var id: String { rawValue }
}

public struct RGBColor: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    
    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
    
    public init?(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }
        guard cleanHex.count == 6, let rgbValue = UInt32(cleanHex, radix: 16) else {
            return nil
        }
        self.r = UInt8((rgbValue >> 16) & 0xFF)
        self.g = UInt8((rgbValue >> 8) & 0xFF)
        self.b = UInt8(rgbValue & 0xFF)
    }
    
    public var hexString: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }
}

public struct LineDetection: Identifiable, Sendable {
    public let id = UUID()
    public let edge: EdgeLocation
    public let thickness: Int
    public let detectedColor: RGBColor
    public let spanRatio: Double
    /// Median blend factor α of the line against the picture inside it (1 = solid target colour).
    public let score: Double
    /// Below the sensitivity threshold: only reported when it persists (`QCConfig.persistenceFrames`).
    public let isWeak: Bool
    /// A line, but not of the target colour (always weak).
    public let isOffColor: Bool
    /// Split seams: first row (H) or column (V) of the seam; edges: depth of the letterbox / pillarbox bar the line sits
    /// inside (nil when the line is at the frame edge itself).
    public let position: Int?

    public init(edge: EdgeLocation, thickness: Int, detectedColor: RGBColor, spanRatio: Double, score: Double = 1, isWeak: Bool = false, isOffColor: Bool = false, position: Int? = nil) {
        self.edge = edge
        self.thickness = thickness
        self.detectedColor = detectedColor
        self.spanRatio = spanRatio
        self.score = score
        self.isWeak = isWeak
        self.isOffColor = isOffColor
        self.position = position
    }

    /// This line as it appears once the track's `preferredTransform` is applied: the edge, and for split seams the first
    /// row / column on screen (bar depths are distances from the edge and don't change).
    public func oriented(by transform: CGAffineTransform) -> LineDetection {
        let oriented = LineDetection(edge: edge.oriented(by: transform), thickness: thickness, detectedColor: detectedColor,
                                     spanRatio: spanRatio, score: score, isWeak: isWeak, isOffColor: isOffColor, position: position)
        guard let position, edge == .splitHorizontal || edge == .splitVertical else { return oriented }
        // The seam covers pixels position ..< position + thickness across it; map both ends of that span.
        let quarterTurn = abs(transform.b) > abs(transform.a)
        func mapped(_ v: CGFloat) -> CGFloat {
            switch (edge, quarterTurn) {
            case (.splitHorizontal, true): return transform.c * v + transform.tx
            case (.splitHorizontal, false): return transform.d * v + transform.ty
            case (_, true): return transform.b * v + transform.ty
            default: return transform.a * v + transform.tx
            }
        }
        let start = min(mapped(CGFloat(position)), mapped(CGFloat(position + thickness)))
        return oriented.withPosition(Int(start.rounded()))
    }

    /// Same line found `matte` px in, at the picture edge inside a letterbox / pillarbox bar.
    public func withPosition(_ position: Int) -> LineDetection {
        LineDetection(edge: edge, thickness: thickness, detectedColor: detectedColor, spanRatio: spanRatio, score: score, isWeak: isWeak, isOffColor: isOffColor, position: position)
    }
}

extension EdgeLocation {
    /// Where this buffer edge appears once the track's `preferredTransform` is applied (rotated clips).
    public func oriented(by transform: CGAffineTransform) -> EdgeLocation {
        let normal: CGPoint
        switch self {
        case .top: normal = CGPoint(x: 0, y: -1)
        case .bottom: normal = CGPoint(x: 0, y: 1)
        case .left: normal = CGPoint(x: -1, y: 0)
        case .right: normal = CGPoint(x: 1, y: 0)
        case .splitHorizontal, .splitVertical:
            let quarterTurn = abs(transform.b) > abs(transform.a)
            guard quarterTurn else { return self }
            return self == .splitHorizontal ? .splitVertical : .splitHorizontal
        }
        let x = transform.a * normal.x + transform.c * normal.y
        let y = transform.b * normal.x + transform.d * normal.y
        if abs(x) > abs(y) {
            return x > 0 ? .right : .left
        }
        return y > 0 ? .bottom : .top
    }
}

/// Temporal hysteresis: strong detections are kept on their own; weak ones only when the same edge
/// has candidates in at least `minRun` consecutive frames (faint but persistent lines).
public enum LineHysteresis {
    public static func filter(_ frames: [FrameError], minRun: Int) -> [FrameError] {
        let sorted = frames.sorted { $0.frameIndex < $1.frameIndex }
        var persistent: [EdgeLocation: Set<Int>] = [:]
        
        for edge in EdgeLocation.allCases {
            var run: [Int] = []
            func close() {
                if run.count >= minRun { persistent[edge, default: []].formUnion(run) }
                run.removeAll(keepingCapacity: true)
            }
            for frame in sorted where frame.detections.contains(where: { $0.edge == edge }) {
                if let last = run.last, frame.frameIndex != last + 1 { close() }
                run.append(frame.frameIndex)
            }
            close()
        }
        
        return sorted.compactMap { frame in
            let kept = frame.detections.filter { !$0.isWeak || persistent[$0.edge]?.contains(frame.frameIndex) == true }
            return kept.isEmpty ? nil : FrameError(frameIndex: frame.frameIndex, timecode: frame.timecode, detections: kept)
        }
    }
}

public struct FrameError: Identifiable, Sendable {
    public let id = UUID()
    public let frameIndex: Int
    public let timecode: String
    public let detections: [LineDetection]
    
    public init(frameIndex: Int, timecode: String, detections: [LineDetection]) {
        self.frameIndex = frameIndex
        self.timecode = timecode
        self.detections = detections
    }
}

public struct GlitchSegment: Identifiable, Sendable {
    public let id = UUID()
    public let startFrame: Int
    public let endFrame: Int
    public let startTimecode: String
    public let endTimecode: String
    public let edge: EdgeLocation
    public let avgThickness: Int
    public let detectedColor: RGBColor
    public let frameCount: Int
    public let durationSeconds: Double
    /// Every frame of the segment is an off-colour line (not the target colour).
    public let isOffColor: Bool
    /// Split seams: row (H) / column (V) of the seam; edges: bar depth when the line is inside a letterbox / pillarbox.
    public let position: Int?
    
    /// "Line glitch" or "Off-colour line", for notes and reports.
    public var lineDescription: String { isOffColor ? "Off-colour line" : "Line glitch" }
    
    /// Where the line is, beyond its edge: "row 540" / "column 960" for split seams, "inside 140 px bar" for letterboxes.
    public var locationDetail: String? {
        guard let position else { return nil }
        switch edge {
        case .splitHorizontal: return "row \(position)"
        case .splitVertical: return "column \(position)"
        default: return "inside \(position) px bar"
        }
    }
    
    public init(
        startFrame: Int,
        endFrame: Int,
        startTimecode: String,
        endTimecode: String,
        edge: EdgeLocation,
        avgThickness: Int,
        detectedColor: RGBColor,
        fps: Double,
        isOffColor: Bool = false,
        position: Int? = nil
    ) {
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTimecode = startTimecode
        self.endTimecode = endTimecode
        self.edge = edge
        self.avgThickness = avgThickness
        self.detectedColor = detectedColor
        self.frameCount = max(1, endFrame - startFrame + 1)
        self.durationSeconds = fps > 0 ? Double(self.frameCount) / fps : 0
        self.isOffColor = isOffColor
        self.position = position
    }
}

public struct VideoQCResult: Identifiable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let fileName: String
    public let resolution: String
    public let fps: Double
    public let totalFrames: Int
    public let durationSeconds: Double
    public let errorFrames: [FrameError]
    public let glitchSegments: [GlitchSegment]
    /// Set when the file couldn't be opened or decoding stopped early: lines found up to that point are still listed.
    public let readError: String?
    /// The scan was stopped before this file's last frame: a clean result here proves nothing.
    var stoppedEarly = false
    
    public var isFlagged: Bool {
        !errorFrames.isEmpty || readError != nil
    }

    /// A copy without the detections `dismiss` matches (frames left with none are dropped): Line Check findings the
    /// user marked as not a line.
    public func removingDetections(where dismiss: (Int, LineDetection) -> Bool) -> VideoQCResult {
        var changed = false
        let frames = errorFrames.compactMap { frame -> FrameError? in
            let kept = frame.detections.filter { !dismiss(frame.frameIndex, $0) }
            guard kept.count != frame.detections.count else { return frame }
            changed = true
            return kept.isEmpty ? nil : FrameError(frameIndex: frame.frameIndex, timecode: frame.timecode, detections: kept)
        }
        guard changed else { return self }
        var copy = VideoQCResult(id: id, fileURL: fileURL, fileName: fileName, resolution: resolution, fps: fps,
                                 totalFrames: totalFrames, durationSeconds: durationSeconds, errorFrames: frames, readError: readError)
        copy.stoppedEarly = stoppedEarly
        return copy
    }
    
    public init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String,
        resolution: String,
        fps: Double,
        totalFrames: Int,
        durationSeconds: Double,
        errorFrames: [FrameError],
        readError: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.resolution = resolution
        self.fps = fps
        self.totalFrames = totalFrames
        self.durationSeconds = durationSeconds
        self.errorFrames = errorFrames
        self.readError = readError
        self.glitchSegments = Self.calculateGlitchSegments(from: errorFrames, fps: fps)
    }
    
    /// Groups individual error frames into continuous glitch segments (start TC -> end TC, duration). A segment follows one
    /// line through consecutive frames: same edge and, for split seams, the same row / column (±2 px), so two seams in
    /// the same frames stay two segments.
    private static func calculateGlitchSegments(from errorFrames: [FrameError], fps: Double) -> [GlitchSegment] {
        struct Track {
            let edge: EdgeLocation
            let start: (index: Int, tc: String, detection: LineDetection)
            var end: (index: Int, tc: String)
            var position: Int?
            var thicknessSum: Int
            var count = 1
            var allOffColor: Bool
            
            init(index: Int, tc: String, detection: LineDetection) {
                edge = detection.edge
                start = (index, tc, detection)
                end = (index, tc)
                position = detection.position
                thicknessSum = detection.thickness
                allOffColor = detection.isOffColor
            }
            
            func continues(_ detection: LineDetection, at index: Int) -> Bool {
                guard detection.edge == edge, index == end.index + 1 else { return false }
                guard edge == .splitHorizontal || edge == .splitVertical, let position, let other = detection.position else { return true }
                return abs(other - position) <= 2
            }
            
            mutating func extend(_ detection: LineDetection, index: Int, tc: String) {
                end = (index, tc)
                position = detection.position ?? position
                thicknessSum += detection.thickness
                count += 1
                allOffColor = allOffColor && detection.isOffColor
            }
            
            func segment(fps: Double) -> GlitchSegment {
                GlitchSegment(
                    startFrame: start.index,
                    endFrame: end.index,
                    startTimecode: start.tc,
                    endTimecode: end.tc,
                    edge: edge,
                    avgThickness: max(1, thicknessSum / count),
                    detectedColor: start.detection.detectedColor,
                    fps: fps,
                    isOffColor: allOffColor,
                    position: start.detection.position
                )
            }
        }
        
        var segments: [GlitchSegment] = []
        var open: [Track] = []
        for frame in errorFrames.sorted(by: { $0.frameIndex < $1.frameIndex }) {
            var continued: [Track] = []
            for detection in frame.detections {
                if let k = open.firstIndex(where: { $0.continues(detection, at: frame.frameIndex) }) {
                    var track = open.remove(at: k)
                    track.extend(detection, index: frame.frameIndex, tc: frame.timecode)
                    continued.append(track)
                } else {
                    continued.append(Track(index: frame.frameIndex, tc: frame.timecode, detection: detection))
                }
            }
            segments += open.map { $0.segment(fps: fps) }
            open = continued
        }
        segments += open.map { $0.segment(fps: fps) }
        
        return segments.sorted { $0.startFrame < $1.startFrame }
    }
}

public struct QCConfig: Sendable {
    public var targetHex: String = "#00FF00"
    public var tolerance: Double = 0.25 // Colour distance for full-frame suppression (slates, chroma backdrops)
    public var edgeDepth: Int = 12 // Scan outer 12 pixels
    public var minSpanRatio: Double = 0.25 // Longest contiguous run must cover 25% of the edge (and at least 64 px)
    public var scanFullScreen: Bool = false // When true, scans entire frame for internal split screen lines
    public var sensitivity: Double = 0.5 // 0...1, maps to the blend factor α a line needs
    public var anyColor: Bool = false // Target = median colour of each candidate line instead of `targetHex`
    public var persistenceFrames: Int = 6 // Weak lines are flagged once they hold this many consecutive frames
    public var reportOffColorLines: Bool = true // Also report persistent lines of another colour (separately)
    
    // Enhanced Black Line Detection options
    public var enableExposureBoost: Bool = true
    public var ignoreFullBlackFrames: Bool = true
    
    // Enhanced White Line Detection options (High-Key / White Cove)
    public var enableHighlightExpansion: Bool = true
    public var ignoreFullWhiteFrames: Bool = true
    
    public init(
        targetHex: String = "#00FF00",
        tolerance: Double = 0.25,
        edgeDepth: Int = 12,
        minSpanRatio: Double = 0.25,
        scanFullScreen: Bool = false,
        sensitivity: Double = 0.5,
        anyColor: Bool = false,
        persistenceFrames: Int = 6,
        reportOffColorLines: Bool = true,
        enableExposureBoost: Bool = true,
        ignoreFullBlackFrames: Bool = true,
        enableHighlightExpansion: Bool = true,
        ignoreFullWhiteFrames: Bool = true
    ) {
        self.targetHex = targetHex
        self.tolerance = tolerance
        self.edgeDepth = edgeDepth
        self.minSpanRatio = minSpanRatio
        self.scanFullScreen = scanFullScreen
        self.sensitivity = sensitivity
        self.anyColor = anyColor
        self.persistenceFrames = persistenceFrames
        self.reportOffColorLines = reportOffColorLines
        self.enableExposureBoost = enableExposureBoost
        self.ignoreFullBlackFrames = ignoreFullBlackFrames
        self.enableHighlightExpansion = enableHighlightExpansion
        self.ignoreFullWhiteFrames = ignoreFullWhiteFrames
    }
    
    public var targetRGB: RGBColor? {
        RGBColor(hex: targetHex)
    }

    /// Blend factor α at which a single frame is flagged (sensitivity 0.5 → 0.275).
    public var strongAlpha: Double {
        0.45 - 0.35 * min(1, max(0, sensitivity))
    }

    /// Lower α that is flagged only when it persists for `persistenceFrames`.
    public var weakAlpha: Double {
        strongAlpha * 0.7
    }
    
    /// True if searching for pure black or near-black
    public var isBlackDetection: Bool {
        guard let rgb = targetRGB else { return false }
        return rgb.r <= 15 && rgb.g <= 15 && rgb.b <= 15
    }
    
    /// True if searching for pure white or near-white (high-key / cove blanking)
    public var isWhiteDetection: Bool {
        guard let rgb = targetRGB else { return false }
        return rgb.r >= 240 && rgb.g >= 240 && rgb.b >= 240
    }
    
    public var maxDistance: Double {
        // Max theoretical distance in RGB space is sqrt(255^2 * 3) ~ 441.67
        // For black detection with exposure boost, use tighter distance threshold
        if isBlackDetection && enableExposureBoost {
            // Very tight tolerance for boosted black (e.g. max dist 8.0-15.0)
            return min(441.67 * tolerance, 441.67 * 0.05)
        }
        // For white detection with highlight expansion, use tighter distance threshold
        if isWhiteDetection && enableHighlightExpansion {
            return min(441.67 * tolerance, 441.67 * 0.05)
        }
        return 441.67 * tolerance
    }
}
