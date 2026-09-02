import Foundation
import CoreVideo
import CoreGraphics

public struct EdgeDetector: Sendable {
    
    public init() {}
    
    /// Detects colored lines at frame edges from a CVPixelBuffer (BGRA format)
    public func scanPixelBuffer(_ pixelBuffer: CVPixelBuffer, config: QCConfig) -> [LineDetection] {
        guard let targetRGB = config.targetRGB else { return [] }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return []
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bufferPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        // If searching for black lines, verify if the entire frame is black (e.g. head/tail slates, fades)
        if config.isBlackDetection && config.ignoreFullBlackFrames {
            if isEntireFrameDarkBGRA(ptr: bufferPtr, width: width, height: height, bytesPerRow: bytesPerRow) {
                return []
            }
        }
        
        return scanRawBGRA(
            ptr: bufferPtr,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            targetRGB: targetRGB,
            config: config
        )
    }
    
    /// Detects colored lines from a CGImage (useful for still frames or reference validation)
    public func scanCGImage(_ cgImage: CGImage, config: QCConfig) -> [LineDetection] {
        guard let targetRGB = config.targetRGB else { return [] }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return []
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        return rawData.withUnsafeBufferPointer { buffer in
            guard let ptr = buffer.baseAddress else { return [] }
            
            if config.isBlackDetection && config.ignoreFullBlackFrames {
                if isEntireFrameDarkRGBA(ptr: ptr, width: width, height: height, bytesPerRow: bytesPerRow) {
                    return []
                }
            }
            
            return scanRawRGBA(
                ptr: ptr,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                targetRGB: targetRGB,
                config: config
            )
        }
    }
    
    // MARK: - Frame Darkness Check (Fades & Slates)
    
    private func isEntireFrameDarkBGRA(ptr: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Bool {
        // Sample 25 points in the center 60% of the frame
        let startX = Int(Double(width) * 0.2)
        let stepX = max(1, Int(Double(width) * 0.6) / 5)
        let startY = Int(Double(height) * 0.2)
        let stepY = max(1, Int(Double(height) * 0.6) / 5)
        
        var totalLum: UInt64 = 0
        var samples = 0
        
        for y in stride(from: startY, to: startY + stepY * 5, by: stepY) {
            let rowStart = ptr + (y * bytesPerRow)
            for x in stride(from: startX, to: startX + stepX * 5, by: stepX) {
                let offset = x * 4
                let b = UInt64(rowStart[offset + 0])
                let g = UInt64(rowStart[offset + 1])
                let r = UInt64(rowStart[offset + 2])
                totalLum += (r + g + b) / 3
                samples += 1
            }
        }
        
        let avgLum = samples > 0 ? Double(totalLum) / Double(samples) : 0
        return avgLum <= 4.0 // Entire scene is black fade / tail
    }
    
    private func isEntireFrameDarkRGBA(ptr: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Bool {
        let startX = Int(Double(width) * 0.2)
        let stepX = max(1, Int(Double(width) * 0.6) / 5)
        let startY = Int(Double(height) * 0.2)
        let stepY = max(1, Int(Double(height) * 0.6) / 5)
        
        var totalLum: UInt64 = 0
        var samples = 0
        
        for y in stride(from: startY, to: startY + stepY * 5, by: stepY) {
            let rowStart = ptr + (y * bytesPerRow)
            for x in stride(from: startX, to: startX + stepX * 5, by: stepX) {
                let offset = x * 4
                let r = UInt64(rowStart[offset + 0])
                let g = UInt64(rowStart[offset + 1])
                let b = UInt64(rowStart[offset + 2])
                totalLum += (r + g + b) / 3
                samples += 1
            }
        }
        
        let avgLum = samples > 0 ? Double(totalLum) / Double(samples) : 0
        return avgLum <= 4.0
    }
    
    // MARK: - Core Scanning Engine (BGRA - AVFoundation native)
    
    private func scanRawBGRA(
        ptr: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        targetRGB: RGBColor,
        config: QCConfig
    ) -> [LineDetection] {
        var detections: [LineDetection] = []
        let maxDist = config.maxDistance
        let edgeDepth = min(config.edgeDepth, min(width / 2, height / 2))
        
        // 1. Scan Bottom Edge (rows: height - 1 down to height - edgeDepth)
        if config.checkBottom {
            var matchingRows: [(row: Int, count: Int, avgColor: RGBColor)] = []
            for d in 0..<edgeDepth {
                let y = height - 1 - d
                if let match = checkHorizontalRowBGRA(ptr: ptr, y: y, width: width, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                    matchingRows.append((y, match.count, match.avgColor))
                }
            }
            if !matchingRows.isEmpty {
                let avgColor = matchingRows.first?.avgColor ?? targetRGB
                let spanRatio = Double(matchingRows.map(\.count).max() ?? 0) / Double(width)
                detections.append(LineDetection(edge: .bottom, thickness: matchingRows.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        // 2. Scan Top Edge (rows: 0 to edgeDepth - 1)
        if config.checkTop {
            var matchingRows: [(row: Int, count: Int, avgColor: RGBColor)] = []
            for y in 0..<edgeDepth {
                if let match = checkHorizontalRowBGRA(ptr: ptr, y: y, width: width, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                    matchingRows.append((y, match.count, match.avgColor))
                }
            }
            if !matchingRows.isEmpty {
                let avgColor = matchingRows.first?.avgColor ?? targetRGB
                let spanRatio = Double(matchingRows.map(\.count).max() ?? 0) / Double(width)
                detections.append(LineDetection(edge: .top, thickness: matchingRows.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        // 3. Scan Left Edge (columns: 0 to edgeDepth - 1)
        if config.checkLeft {
            var matchingCols: [(col: Int, count: Int, avgColor: RGBColor)] = []
            for x in 0..<edgeDepth {
                if let match = checkVerticalColumnBGRA(ptr: ptr, x: x, height: height, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                    matchingCols.append((x, match.count, match.avgColor))
                }
            }
            if !matchingCols.isEmpty {
                let avgColor = matchingCols.first?.avgColor ?? targetRGB
                let spanRatio = Double(matchingCols.map(\.count).max() ?? 0) / Double(height)
                detections.append(LineDetection(edge: .left, thickness: matchingCols.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        // 4. Scan Right Edge (columns: width - 1 down to width - edgeDepth)
        if config.checkRight {
            var matchingCols: [(col: Int, count: Int, avgColor: RGBColor)] = []
            for d in 0..<edgeDepth {
                let x = width - 1 - d
                if let match = checkVerticalColumnBGRA(ptr: ptr, x: x, height: height, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                    matchingCols.append((x, match.count, match.avgColor))
                }
            }
            if !matchingCols.isEmpty {
                let avgColor = matchingCols.first?.avgColor ?? targetRGB
                let spanRatio = Double(matchingCols.map(\.count).max() ?? 0) / Double(height)
                detections.append(LineDetection(edge: .right, thickness: matchingCols.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        return detections
    }
    
    // MARK: - Row & Column Match Helpers (BGRA)
    
    @inline(__always)
    private func checkHorizontalRowBGRA(
        ptr: UnsafePointer<UInt8>,
        y: Int,
        width: Int,
        bytesPerRow: Int,
        targetRGB: RGBColor,
        maxDist: Double,
        config: QCConfig
    ) -> (count: Int, avgColor: RGBColor)? {
        let rowStart = ptr + (y * bytesPerRow)
        var matchCount = 0
        var sumR: UInt64 = 0
        var sumG: UInt64 = 0
        var sumB: UInt64 = 0
        
        let isBlack = config.isBlackDetection
        let useBoost = isBlack && config.enableExposureBoost
        let multiplier = useBoost ? config.exposureMultiplier : 1.0
        
        let tr = Int(targetRGB.r)
        let tg = Int(targetRGB.g)
        let tb = Int(targetRGB.b)
        let maxDistSq = maxDist * maxDist
        
        var intensities: [Double] = []
        if isBlack { intensities.reserveCapacity(width) }
        
        for x in 0..<width {
            let offset = x * 4
            var b = Int(rowStart[offset + 0])
            var g = Int(rowStart[offset + 1])
            var r = Int(rowStart[offset + 2])
            
            let originalR = r
            let originalG = g
            let originalB = b
            
            if useBoost {
                r = min(255, Int(Double(r) * multiplier))
                g = min(255, Int(Double(g) * multiplier))
                b = min(255, Int(Double(b) * multiplier))
            }
            
            let dr = r - tr
            let dg = g - tg
            let db = b - tb
            let distSq = Double(dr * dr + dg * dg + db * db)
            
            if distSq <= maxDistSq {
                matchCount += 1
                sumR += UInt64(originalR)
                sumG += UInt64(originalG)
                sumB += UInt64(originalB)
                if isBlack {
                    intensities.append(Double(originalR + originalG + originalB) / 3.0)
                }
            }
        }
        
        let ratio = Double(matchCount) / Double(width)
        guard ratio >= config.minSpanRatio, matchCount > 0 else { return nil }
        
        // In black detection mode, enforce strict uniformity (render blanking has ~0 variance)
        if isBlack && intensities.count > 10 {
            let mean = intensities.reduce(0.0, +) / Double(intensities.count)
            let variance = intensities.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(intensities.count)
            let stdDev = sqrt(variance)
            if stdDev > config.maxBlackVariance {
                // Natural camera texture/grain present -> not a flat digital matte line
                return nil
            }
        }
        
        let avgR = UInt8(sumR / UInt64(matchCount))
        let avgG = UInt8(sumG / UInt64(matchCount))
        let avgB = UInt8(sumB / UInt64(matchCount))
        return (matchCount, RGBColor(r: avgR, g: avgG, b: avgB))
    }
    
    @inline(__always)
    private func checkVerticalColumnBGRA(
        ptr: UnsafePointer<UInt8>,
        x: Int,
        height: Int,
        bytesPerRow: Int,
        targetRGB: RGBColor,
        maxDist: Double,
        config: QCConfig
    ) -> (count: Int, avgColor: RGBColor)? {
        var matchCount = 0
        var sumR: UInt64 = 0
        var sumG: UInt64 = 0
        var sumB: UInt64 = 0
        
        let isBlack = config.isBlackDetection
        let useBoost = isBlack && config.enableExposureBoost
        let multiplier = useBoost ? config.exposureMultiplier : 1.0
        
        let tr = Int(targetRGB.r)
        let tg = Int(targetRGB.g)
        let tb = Int(targetRGB.b)
        let maxDistSq = maxDist * maxDist
        
        var intensities: [Double] = []
        if isBlack { intensities.reserveCapacity(height) }
        
        for y in 0..<height {
            let rowOffset = y * bytesPerRow + (x * 4)
            var b = Int(ptr[rowOffset + 0])
            var g = Int(ptr[rowOffset + 1])
            var r = Int(ptr[rowOffset + 2])
            
            let originalR = r
            let originalG = g
            let originalB = b
            
            if useBoost {
                r = min(255, Int(Double(r) * multiplier))
                g = min(255, Int(Double(g) * multiplier))
                b = min(255, Int(Double(b) * multiplier))
            }
            
            let dr = r - tr
            let dg = g - tg
            let db = b - tb
            let distSq = Double(dr * dr + dg * dg + db * db)
            
            if distSq <= maxDistSq {
                matchCount += 1
                sumR += UInt64(originalR)
                sumG += UInt64(originalG)
                sumB += UInt64(originalB)
                if isBlack {
                    intensities.append(Double(originalR + originalG + originalB) / 3.0)
                }
            }
        }
        
        let ratio = Double(matchCount) / Double(height)
        guard ratio >= config.minSpanRatio, matchCount > 0 else { return nil }
        
        if isBlack && intensities.count > 10 {
            let mean = intensities.reduce(0.0, +) / Double(intensities.count)
            let variance = intensities.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(intensities.count)
            let stdDev = sqrt(variance)
            if stdDev > config.maxBlackVariance {
                return nil
            }
        }
        
        let avgR = UInt8(sumR / UInt64(matchCount))
        let avgG = UInt8(sumG / UInt64(matchCount))
        let avgB = UInt8(sumB / UInt64(matchCount))
        return (matchCount, RGBColor(r: avgR, g: avgG, b: avgB))
    }
    
    // MARK: - RGBA Scanning (For CGImage contexts)
    
    private func scanRawRGBA(
        ptr: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        targetRGB: RGBColor,
        config: QCConfig
    ) -> [LineDetection] {
        var detections: [LineDetection] = []
        let maxDist = config.maxDistance
        let edgeDepth = min(config.edgeDepth, min(width / 2, height / 2))
        
        // Bottom edge
        if config.checkBottom {
            var matchingRows: [(row: Int, count: Int, avgColor: RGBColor)] = []
            for d in 0..<edgeDepth {
                let y = height - 1 - d
                if let match = checkHorizontalRowRGBA(ptr: ptr, y: y, width: width, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                    matchingRows.append((y, match.count, match.avgColor))
                }
            }
            if !matchingRows.isEmpty {
                let avgColor = matchingRows.first?.avgColor ?? targetRGB
                let spanRatio = Double(matchingRows.map(\.count).max() ?? 0) / Double(width)
                detections.append(LineDetection(edge: .bottom, thickness: matchingRows.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        // Top edge
        if config.checkTop {
            var matchingRows: [(row: Int, count: Int, avgColor: RGBColor)] = []
            for y in 0..<edgeDepth {
                if let match = checkHorizontalRowRGBA(ptr: ptr, y: y, width: width, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                    matchingRows.append((y, match.count, match.avgColor))
                }
            }
            if !matchingRows.isEmpty {
                let avgColor = matchingRows.first?.avgColor ?? targetRGB
                let spanRatio = Double(matchingRows.map(\.count).max() ?? 0) / Double(width)
                detections.append(LineDetection(edge: .top, thickness: matchingRows.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        return detections
    }
    
    @inline(__always)
    private func checkHorizontalRowRGBA(
        ptr: UnsafePointer<UInt8>,
        y: Int,
        width: Int,
        bytesPerRow: Int,
        targetRGB: RGBColor,
        maxDist: Double,
        config: QCConfig
    ) -> (count: Int, avgColor: RGBColor)? {
        let rowStart = ptr + (y * bytesPerRow)
        var matchCount = 0
        var sumR: UInt64 = 0
        var sumG: UInt64 = 0
        var sumB: UInt64 = 0
        
        let isBlack = config.isBlackDetection
        let useBoost = isBlack && config.enableExposureBoost
        let multiplier = useBoost ? config.exposureMultiplier : 1.0
        
        let tr = Int(targetRGB.r)
        let tg = Int(targetRGB.g)
        let tb = Int(targetRGB.b)
        let maxDistSq = maxDist * maxDist
        
        var intensities: [Double] = []
        if isBlack { intensities.reserveCapacity(width) }
        
        for x in 0..<width {
            let offset = x * 4
            var r = Int(rowStart[offset + 0])
            var g = Int(rowStart[offset + 1])
            var b = Int(rowStart[offset + 2])
            
            let originalR = r
            let originalG = g
            let originalB = b
            
            if useBoost {
                r = min(255, Int(Double(r) * multiplier))
                g = min(255, Int(Double(g) * multiplier))
                b = min(255, Int(Double(b) * multiplier))
            }
            
            let dr = r - tr
            let dg = g - tg
            let db = b - tb
            let distSq = Double(dr * dr + dg * dg + db * db)
            
            if distSq <= maxDistSq {
                matchCount += 1
                sumR += UInt64(originalR)
                sumG += UInt64(originalG)
                sumB += UInt64(originalB)
                if isBlack {
                    intensities.append(Double(originalR + originalG + originalB) / 3.0)
                }
            }
        }
        
        let ratio = Double(matchCount) / Double(width)
        guard ratio >= config.minSpanRatio, matchCount > 0 else { return nil }
        
        if isBlack && intensities.count > 10 {
            let mean = intensities.reduce(0.0, +) / Double(intensities.count)
            let variance = intensities.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(intensities.count)
            let stdDev = sqrt(variance)
            if stdDev > config.maxBlackVariance {
                return nil
            }
        }
        
        let avgR = UInt8(sumR / UInt64(matchCount))
        let avgG = UInt8(sumG / UInt64(matchCount))
        let avgB = UInt8(sumB / UInt64(matchCount))
        return (matchCount, RGBColor(r: avgR, g: avgG, b: avgB))
    }
}
