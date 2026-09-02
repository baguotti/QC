import Foundation

public enum EdgeLocation: String, CaseIterable, Identifiable, Sendable {
    case top = "Top"
    case bottom = "Bottom"
    case left = "Left"
    case right = "Right"
    
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
    
    public func distance(to other: RGBColor) -> Double {
        let dr = Double(Int(r) - Int(other.r))
        let dg = Double(Int(g) - Int(other.g))
        let db = Double(Int(b) - Int(other.b))
        return sqrt(dr * dr + dg * dg + db * db)
    }
}

public struct LineDetection: Identifiable, Sendable {
    public let id = UUID()
    public let edge: EdgeLocation
    public let thickness: Int
    public let detectedColor: RGBColor
    public let spanRatio: Double
    
    public init(edge: EdgeLocation, thickness: Int, detectedColor: RGBColor, spanRatio: Double) {
        self.edge = edge
        self.thickness = thickness
        self.detectedColor = detectedColor
        self.spanRatio = spanRatio
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
    
    public init(
        startFrame: Int,
        endFrame: Int,
        startTimecode: String,
        endTimecode: String,
        edge: EdgeLocation,
        avgThickness: Int,
        detectedColor: RGBColor,
        fps: Double
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
    }
}

public struct VideoQCResult: Identifiable, Sendable {
    public let id = UUID()
    public let fileURL: URL
    public let fileName: String
    public let resolution: String
    public let fps: Double
    public let totalFrames: Int
    public let durationSeconds: Double
    public let errorFrames: [FrameError]
    
    public var isFlagged: Bool {
        !errorFrames.isEmpty
    }
    
    /// Groups individual error frames into continuous glitch segments (start TC -> end TC, duration)
    public var glitchSegments: [GlitchSegment] {
        guard !errorFrames.isEmpty else { return [] }
        
        var segments: [GlitchSegment] = []
        
        // Group by edge location
        for edge in EdgeLocation.allCases {
            // Find all frames with detections on this edge
            let edgeFrames = errorFrames.compactMap { frame -> (index: Int, tc: String, detection: LineDetection)? in
                guard let det = frame.detections.first(where: { $0.edge == edge }) else { return nil }
                return (frame.frameIndex, frame.timecode, det)
            }.sorted { $0.index < $1.index }
            
            guard !edgeFrames.isEmpty else { continue }
            
            var currentStart = edgeFrames[0]
            var currentEnd = edgeFrames[0]
            var thicknessSum = edgeFrames[0].detection.thickness
            var count = 1
            
            for i in 1..<edgeFrames.count {
                let item = edgeFrames[i]
                if item.index == currentEnd.index + 1 {
                    // Consecutive frame -> extend current segment
                    currentEnd = item
                    thicknessSum += item.detection.thickness
                    count += 1
                } else {
                    // Gap encountered -> finalize segment
                    let avgThick = max(1, thicknessSum / count)
                    segments.append(GlitchSegment(
                        startFrame: currentStart.index,
                        endFrame: currentEnd.index,
                        startTimecode: currentStart.tc,
                        endTimecode: currentEnd.tc,
                        edge: edge,
                        avgThickness: avgThick,
                        detectedColor: currentStart.detection.detectedColor,
                        fps: fps
                    ))
                    
                    currentStart = item
                    currentEnd = item
                    thicknessSum = item.detection.thickness
                    count = 1
                }
            }
            
            // Finalize trailing segment
            let avgThick = max(1, thicknessSum / count)
            segments.append(GlitchSegment(
                startFrame: currentStart.index,
                endFrame: currentEnd.index,
                startTimecode: currentStart.tc,
                endTimecode: currentEnd.tc,
                edge: edge,
                avgThickness: avgThick,
                detectedColor: currentStart.detection.detectedColor,
                fps: fps
            ))
        }
        
        return segments.sorted { $0.startFrame < $1.startFrame }
    }
}

public struct QCConfig: Sendable {
    public var targetHex: String = "#FF00B4"
    public var tolerance: Double = 0.15 // 15% tolerance default
    public var edgeDepth: Int = 12 // Scan outer 12 pixels
    public var minSpanRatio: Double = 0.70 // Must span at least 70% of row/column
    public var checkTop: Bool = true
    public var checkBottom: Bool = true
    public var checkLeft: Bool = true
    public var checkRight: Bool = true
    
    // Enhanced Black Line Detection options
    public var enableExposureBoost: Bool = true
    public var exposureMultiplier: Double = 10.0
    public var ignoreFullBlackFrames: Bool = true
    public var maxBlackVariance: Double = 2.0 // Strict row uniformity check for digital black
    
    public init(
        targetHex: String = "#FF00B4",
        tolerance: Double = 0.15,
        edgeDepth: Int = 12,
        minSpanRatio: Double = 0.70,
        checkTop: Bool = true,
        checkBottom: Bool = true,
        checkLeft: Bool = true,
        checkRight: Bool = true,
        enableExposureBoost: Bool = true,
        exposureMultiplier: Double = 10.0,
        ignoreFullBlackFrames: Bool = true,
        maxBlackVariance: Double = 2.0
    ) {
        self.targetHex = targetHex
        self.tolerance = tolerance
        self.edgeDepth = edgeDepth
        self.minSpanRatio = minSpanRatio
        self.checkTop = checkTop
        self.checkBottom = checkBottom
        self.checkLeft = checkLeft
        self.checkRight = checkRight
        self.enableExposureBoost = enableExposureBoost
        self.exposureMultiplier = exposureMultiplier
        self.ignoreFullBlackFrames = ignoreFullBlackFrames
        self.maxBlackVariance = maxBlackVariance
    }
    
    public var targetRGB: RGBColor? {
        RGBColor(hex: targetHex)
    }
    
    /// True if searching for pure black or near-black
    public var isBlackDetection: Bool {
        guard let rgb = targetRGB else { return false }
        return rgb.r <= 15 && rgb.g <= 15 && rgb.b <= 15
    }
    
    public var maxDistance: Double {
        // Max theoretical distance in RGB space is sqrt(255^2 * 3) ~ 441.67
        // For black detection with exposure boost, use tighter distance threshold
        if isBlackDetection && enableExposureBoost {
            // Very tight tolerance for boosted black (e.g. max dist 8.0-15.0)
            return min(441.67 * tolerance, 441.67 * 0.05)
        }
        return 441.67 * tolerance
    }
}
