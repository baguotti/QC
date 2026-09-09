import Foundation
import CoreVideo

public struct EdgeDetector: Sendable {
    
    public init() {}
    
    /// Detects colored lines at frame edges and internal split-screens from a CVPixelBuffer (BGRA format)
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
        
        // Verify if the entire frame is dark/black OR dominated by the target color (e.g. green screen, white card, slate)
        if config.ignoreFullBlackFrames {
            if isEntireFrameTargetColorOrDarkBGRA(ptr: bufferPtr, width: width, height: height, bytesPerRow: bytesPerRow, targetRGB: targetRGB, config: config) {
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
    
    // MARK: - Frame-Wide Suppression Check (Fades, Slates, Cards & Chroma Backdrops)
    
    private func isEntireFrameTargetColorOrDarkBGRA(
        ptr: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        targetRGB: RGBColor,
        config: QCConfig
    ) -> Bool {
        // Sample a 12x12 grid (144 sample points) across 5% to 95% of the frame
        let gridDim = 12
        let minX = Int(Double(width) * 0.05)
        let maxX = Int(Double(width) * 0.95)
        let minY = Int(Double(height) * 0.05)
        let maxY = Int(Double(height) * 0.95)
        let stepX = max(1, (maxX - minX) / (gridDim - 1))
        let stepY = max(1, (maxY - minY) / (gridDim - 1))
        
        let isBlack = config.isBlackDetection
        let tr = Int(targetRGB.r)
        let tg = Int(targetRGB.g)
        let tb = Int(targetRGB.b)
        let maxDistSqInt = Int(round(config.maxDistance * config.maxDistance * 1.15))
        
        var totalLum: UInt64 = 0
        var darkSamples = 0
        var targetColorSamples = 0
        var perimeterDarkSamples = 0
        var perimeterTargetSamples = 0
        var perimeterTotalSamples = 0
        var totalSamples = 0
        
        for gy in 0..<gridDim {
            let y = minY + (gy * stepY)
            guard y < height else { break }
            let rowStart = ptr + (y * bytesPerRow)
            let isPerimeterY = (gy == 0 || gy == gridDim - 1)
            
            for gx in 0..<gridDim {
                let x = minX + (gx * stepX)
                guard x < width else { break }
                let offset = x * 4
                let b = Int(rowStart[offset + 0])
                let g = Int(rowStart[offset + 1])
                let r = Int(rowStart[offset + 2])
                
                let isPerimeter = isPerimeterY || (gx == 0 || gx == gridDim - 1)
                if isPerimeter {
                    perimeterTotalSamples += 1
                }
                
                if isBlack {
                    // Rec.709 perceived luminance
                    let lum = (r * 299 + g * 587 + b * 114) / 1000
                    totalLum += UInt64(lum)
                    if lum <= 20 {
                        darkSamples += 1
                        if isPerimeter { perimeterDarkSamples += 1 }
                    }
                } else {
                    let dr = r - tr
                    let dg = g - tg
                    let db = b - tb
                    let distSq = dr * dr + dg * dg + db * db
                    if distSq <= maxDistSqInt {
                        targetColorSamples += 1
                        if isPerimeter { perimeterTargetSamples += 1 }
                    }
                }
                totalSamples += 1
            }
        }
        
        guard totalSamples > 0 else { return false }
        
        if isBlack {
            let avgLum = Double(totalLum) / Double(totalSamples)
            let darkRatio = Double(darkSamples) / Double(totalSamples)
            let perimeterDarkRatio = perimeterTotalSamples > 0 ? Double(perimeterDarkSamples) / Double(perimeterTotalSamples) : 0.0
            
            if avgLum <= 6.0 { return true }
            if darkRatio >= 0.75 && perimeterDarkRatio >= 0.90 { return true }
            if darkRatio >= 0.90 { return true }
            return false
        } else {
            let targetRatio = Double(targetColorSamples) / Double(totalSamples)
            let perimeterTargetRatio = perimeterTotalSamples > 0 ? Double(perimeterTargetSamples) / Double(perimeterTotalSamples) : 0.0
            
            // Chroma key green screen backdrop, full white flash frame, or colored slate
            if targetRatio >= 0.80 && perimeterTargetRatio >= 0.85 { return true }
            if targetRatio >= 0.88 { return true }
            return false
        }
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
        guard edgeDepth > 0 else { return [] }
        
        // Helper to check inward continuity beyond edgeDepth.
        func isHorizontallyContinuous(startRow: Int, stepDirection: Int) -> Bool {
            let lookaheadCount = min(max(3, edgeDepth / 2), min(16, (height / 2) - edgeDepth))
            guard lookaheadCount > 0 else { return false }
            var matches = 0
            for i in 0..<lookaheadCount {
                let testY = startRow + (i * stepDirection)
                guard testY >= 0 && testY < height else { break }
                if checkHorizontalRowBGRA(ptr: ptr, y: testY, width: width, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) != nil {
                    matches += 1
                }
            }
            return matches >= min(2, lookaheadCount)
        }
        
        func isVerticallyContinuous(startCol: Int, stepDirection: Int) -> Bool {
            let lookaheadCount = min(max(3, edgeDepth / 2), min(16, (width / 2) - edgeDepth))
            guard lookaheadCount > 0 else { return false }
            var matches = 0
            for i in 0..<lookaheadCount {
                let testX = startCol + (i * stepDirection)
                guard testX >= 0 && testX < width else { break }
                if checkVerticalColumnBGRA(ptr: ptr, x: testX, height: height, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) != nil {
                    matches += 1
                }
            }
            return matches >= min(2, lookaheadCount)
        }
        
        // Helper to verify that an edge line candidate has a clear contrast step against the adjacent picture content.
        func hasBoundaryContrastHorizontal(lineColor: RGBColor, adjacentY: Int) -> Bool {
            guard adjacentY >= 0 && adjacentY < height else { return true }
            let rowStart = ptr + (adjacentY * bytesPerRow)
            let samples = 32
            let stepX = max(1, width / samples)
            var sumR: UInt64 = 0
            var sumG: UInt64 = 0
            var sumB: UInt64 = 0
            var count = 0
            for i in 0..<samples {
                let x = min(width - 1, i * stepX)
                let offset = x * 4
                sumB += UInt64(rowStart[offset + 0])
                sumG += UInt64(rowStart[offset + 1])
                sumR += UInt64(rowStart[offset + 2])
                count += 1
            }
            guard count > 0 else { return true }
            let adjR = Double(sumR) / Double(count)
            let adjG = Double(sumG) / Double(count)
            let adjB = Double(sumB) / Double(count)
            let dr = Double(lineColor.r) - adjR
            let dg = Double(lineColor.g) - adjG
            let db = Double(lineColor.b) - adjB
            let stepDist = sqrt(dr * dr + dg * dg + db * db)
            return stepDist >= 22.0
        }
        
        func hasBoundaryContrastVertical(lineColor: RGBColor, adjacentX: Int) -> Bool {
            guard adjacentX >= 0 && adjacentX < width else { return true }
            let samples = 32
            let stepY = max(1, height / samples)
            var sumR: UInt64 = 0
            var sumG: UInt64 = 0
            var sumB: UInt64 = 0
            var count = 0
            for i in 0..<samples {
                let y = min(height - 1, i * stepY)
                let offset = y * bytesPerRow + (adjacentX * 4)
                sumB += UInt64(ptr[offset + 0])
                sumG += UInt64(ptr[offset + 1])
                sumR += UInt64(ptr[offset + 2])
                count += 1
            }
            guard count > 0 else { return true }
            let adjR = Double(sumR) / Double(count)
            let adjG = Double(sumG) / Double(count)
            let adjB = Double(sumB) / Double(count)
            let dr = Double(lineColor.r) - adjR
            let dg = Double(lineColor.g) - adjG
            let db = Double(lineColor.b) - adjB
            let stepDist = sqrt(dr * dr + dg * dg + db * db)
            return stepDist >= 22.0
        }
        
        // 1. Bottom Edge (rows: height - 1 down to height - edgeDepth)
        var bottomRows: [(row: Int, count: Int, avgColor: RGBColor)] = []
        for d in 0..<edgeDepth {
            let y = height - 1 - d
            if let match = checkHorizontalRowBGRA(ptr: ptr, y: y, width: width, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                bottomRows.append((y, match.count, match.avgColor))
            } else {
                break
            }
        }
        if !bottomRows.isEmpty {
            let isContinuous = (bottomRows.count == edgeDepth && isHorizontallyContinuous(startRow: height - 1 - edgeDepth, stepDirection: -1))
            let avgColor = bottomRows.first?.avgColor ?? targetRGB
            let hasContrast = hasBoundaryContrastHorizontal(lineColor: avgColor, adjacentY: height - 1 - bottomRows.count)
            if !isContinuous && hasContrast {
                let spanRatio = Double(bottomRows.map(\.count).max() ?? 0) / Double(width)
                detections.append(LineDetection(edge: .bottom, thickness: bottomRows.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        // 2. Top Edge (rows: 0 to edgeDepth - 1)
        var topRows: [(row: Int, count: Int, avgColor: RGBColor)] = []
        for y in 0..<edgeDepth {
            if let match = checkHorizontalRowBGRA(ptr: ptr, y: y, width: width, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                topRows.append((y, match.count, match.avgColor))
            } else {
                break
            }
        }
        if !topRows.isEmpty {
            let isContinuous = (topRows.count == edgeDepth && isHorizontallyContinuous(startRow: edgeDepth, stepDirection: 1))
            let avgColor = topRows.first?.avgColor ?? targetRGB
            let hasContrast = hasBoundaryContrastHorizontal(lineColor: avgColor, adjacentY: topRows.count)
            if !isContinuous && hasContrast {
                let spanRatio = Double(topRows.map(\.count).max() ?? 0) / Double(width)
                detections.append(LineDetection(edge: .top, thickness: topRows.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        // 3. Left Edge (columns: 0 to edgeDepth - 1)
        var leftCols: [(col: Int, count: Int, avgColor: RGBColor)] = []
        for x in 0..<edgeDepth {
            if let match = checkVerticalColumnBGRA(ptr: ptr, x: x, height: height, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                leftCols.append((x, match.count, match.avgColor))
            } else {
                break
            }
        }
        if !leftCols.isEmpty {
            let isContinuous = (leftCols.count == edgeDepth && isVerticallyContinuous(startCol: edgeDepth, stepDirection: 1))
            let avgColor = leftCols.first?.avgColor ?? targetRGB
            let hasContrast = hasBoundaryContrastVertical(lineColor: avgColor, adjacentX: leftCols.count)
            if !isContinuous && hasContrast {
                let spanRatio = Double(leftCols.map(\.count).max() ?? 0) / Double(height)
                detections.append(LineDetection(edge: .left, thickness: leftCols.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        // 4. Right Edge (columns: width - 1 down to width - edgeDepth)
        var rightCols: [(col: Int, count: Int, avgColor: RGBColor)] = []
        for d in 0..<edgeDepth {
            let x = width - 1 - d
            if let match = checkVerticalColumnBGRA(ptr: ptr, x: x, height: height, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                rightCols.append((x, match.count, match.avgColor))
            } else {
                break
            }
        }
        if !rightCols.isEmpty {
            let isContinuous = (rightCols.count == edgeDepth && isVerticallyContinuous(startCol: width - 1 - edgeDepth, stepDirection: -1))
            let avgColor = rightCols.first?.avgColor ?? targetRGB
            let hasContrast = hasBoundaryContrastVertical(lineColor: avgColor, adjacentX: width - 1 - rightCols.count)
            if !isContinuous && hasContrast {
                let spanRatio = Double(rightCols.map(\.count).max() ?? 0) / Double(height)
                detections.append(LineDetection(edge: .right, thickness: rightCols.count, detectedColor: avgColor, spanRatio: spanRatio))
            }
        }
        
        // 5. Full Screen Scan for Split Screens (internal rows & columns)
        if config.scanFullScreen {
            let startY = edgeDepth
            let endY = height - edgeDepth
            if startY < endY {
                var currentCluster: [(row: Int, count: Int, avgColor: RGBColor)] = []
                for y in startY..<endY {
                    if let match = checkHorizontalRowBGRA(ptr: ptr, y: y, width: width, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                        currentCluster.append((y, match.count, match.avgColor))
                    } else {
                        if !currentCluster.isEmpty {
                            if currentCluster.count <= edgeDepth {
                                let avgColor = currentCluster.first?.avgColor ?? targetRGB
                                let spanRatio = Double(currentCluster.map(\.count).max() ?? 0) / Double(width)
                                detections.append(LineDetection(edge: .splitHorizontal, thickness: currentCluster.count, detectedColor: avgColor, spanRatio: spanRatio))
                            }
                            currentCluster.removeAll(keepingCapacity: true)
                        }
                    }
                }
                if !currentCluster.isEmpty && currentCluster.count <= edgeDepth {
                    let avgColor = currentCluster.first?.avgColor ?? targetRGB
                    let spanRatio = Double(currentCluster.map(\.count).max() ?? 0) / Double(width)
                    detections.append(LineDetection(edge: .splitHorizontal, thickness: currentCluster.count, detectedColor: avgColor, spanRatio: spanRatio))
                }
            }
            
            let startX = edgeDepth
            let endX = width - edgeDepth
            if startX < endX {
                var currentCluster: [(col: Int, count: Int, avgColor: RGBColor)] = []
                for x in startX..<endX {
                    if let match = checkVerticalColumnBGRA(ptr: ptr, x: x, height: height, bytesPerRow: bytesPerRow, targetRGB: targetRGB, maxDist: maxDist, config: config) {
                        currentCluster.append((x, match.count, match.avgColor))
                    } else {
                        if !currentCluster.isEmpty {
                            if currentCluster.count <= edgeDepth {
                                let avgColor = currentCluster.first?.avgColor ?? targetRGB
                                let spanRatio = Double(currentCluster.map(\.count).max() ?? 0) / Double(height)
                                detections.append(LineDetection(edge: .splitVertical, thickness: currentCluster.count, detectedColor: avgColor, spanRatio: spanRatio))
                            }
                            currentCluster.removeAll(keepingCapacity: true)
                        }
                    }
                }
                if !currentCluster.isEmpty && currentCluster.count <= edgeDepth {
                    let avgColor = currentCluster.first?.avgColor ?? targetRGB
                    let spanRatio = Double(currentCluster.map(\.count).max() ?? 0) / Double(height)
                    detections.append(LineDetection(edge: .splitVertical, thickness: currentCluster.count, detectedColor: avgColor, spanRatio: spanRatio))
                }
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
        
        let minMatchesRequired = Int(ceil(Double(width) * config.minSpanRatio))
        let maxAllowedMisses = width - minMatchesRequired
        var missCount = 0
        
        let isBlack = config.isBlackDetection
        let useBoost = isBlack && config.enableExposureBoost
        let multiplier = useBoost ? config.exposureMultiplier : 1.0
        
        let tr = Int(targetRGB.r)
        let tg = Int(targetRGB.g)
        let tb = Int(targetRGB.b)
        let maxDistSqInt = Int(round(maxDist * maxDist))
        
        // Chromatic saturation of target
        let targetMax = max(tr, max(tg, tb))
        let targetMin = min(tr, min(tg, tb))
        let targetSat = targetMax > 0 ? Double(targetMax - targetMin) / Double(targetMax) : 0.0
        let isSaturatedTarget = targetSat >= 0.50
        
        // Primary & secondary color targets
        let isGreenTarget = tg - tr >= 70 && tg - tb >= 70
        let isMagentaTarget = tr - tg >= 70 && tb - tg >= 70
        let isRedTarget = tr - tg >= 70 && tr - tb >= 70
        let isBlueTarget = tb - tr >= 70 && tb - tg >= 70
        let isCyanTarget = tg - tr >= 70 && tb - tr >= 70
        let isYellowTarget = tr - tb >= 70 && tg - tb >= 70
        
        var blackCount = 0
        var blackMean = 0.0
        var blackM2 = 0.0
        
        var colorCount = 0
        var colorMean = 0.0
        var colorM2 = 0.0
        
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
            var distSq = dr * dr + dg * dg + db * db
            
            // Chroma bleed compensation for video compression (YUV 4:2:0 averaging against light backgrounds)
            if distSq > maxDistSqInt {
                if isGreenTarget && g > r && g > b {
                    let neutral = min(r, b)
                    let bleed = (neutral * 166) >> 8 // ~65% neutral background bleed removal
                    let rc = max(0, r - bleed)
                    let bc = max(0, b - bleed)
                    let drc = rc - tr
                    let dbc = bc - tb
                    let compDistSq = drc * drc + dg * dg + dbc * dbc
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isMagentaTarget && r > g && b > g {
                    let neutral = g
                    let bleed = (neutral * 166) >> 8
                    let gc = max(0, g - bleed)
                    let dgc = gc - tg
                    let compDistSq = dr * dr + dgc * dgc + db * db
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isRedTarget && r > g && r > b {
                    let neutral = min(g, b)
                    let bleed = (neutral * 166) >> 8
                    let gc = max(0, g - bleed)
                    let bc = max(0, b - bleed)
                    let dgc = gc - tg
                    let dbc = bc - tb
                    let compDistSq = dr * dr + dgc * dgc + dbc * dbc
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isBlueTarget && b > r && b > g {
                    let neutral = min(r, g)
                    let bleed = (neutral * 166) >> 8
                    let rc = max(0, r - bleed)
                    let gc = max(0, g - bleed)
                    let drc = rc - tr
                    let dgc = gc - tg
                    let compDistSq = drc * drc + dgc * dgc + db * db
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isCyanTarget && g > r && b > r {
                    let neutral = r
                    let bleed = (neutral * 166) >> 8
                    let rc = max(0, r - bleed)
                    let drc = rc - tr
                    let compDistSq = drc * drc + dg * dg + db * db
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isYellowTarget && r > b && g > b {
                    let neutral = b
                    let bleed = (neutral * 166) >> 8
                    let bc = max(0, b - bleed)
                    let dbc = bc - tb
                    let compDistSq = dr * dr + dg * dg + dbc * dbc
                    if compDistSq < distSq { distSq = compDistSq }
                }
            }
            
            if distSq <= maxDistSqInt {
                if isSaturatedTarget {
                    let pixMax = max(originalR, max(originalG, originalB))
                    let pixMin = min(originalR, min(originalG, originalB))
                    let pixSat = pixMax > 0 ? Double(pixMax - pixMin) / Double(pixMax) : 0.0
                    // Reject washed-out neutral / grayish pixels for saturated targets
                    if pixSat < 0.22 {
                        missCount += 1
                        if missCount > maxAllowedMisses { return nil }
                        continue
                    }
                }
                
                matchCount += 1
                sumR += UInt64(originalR)
                sumG += UInt64(originalG)
                sumB += UInt64(originalB)
                
                if isBlack {
                    let intensity = Double(originalR + originalG + originalB) / 3.0
                    blackCount += 1
                    let delta = intensity - blackMean
                    blackMean += delta / Double(blackCount)
                    let delta2 = intensity - blackMean
                    blackM2 += delta * delta2
                } else if isSaturatedTarget {
                    let intensity = Double(originalR + originalG + originalB) / 3.0
                    colorCount += 1
                    let delta = intensity - colorMean
                    colorMean += delta / Double(colorCount)
                    let delta2 = intensity - colorMean
                    colorM2 += delta * delta2
                }
            } else {
                missCount += 1
                if missCount > maxAllowedMisses {
                    return nil
                }
            }
        }
        
        let ratio = Double(matchCount) / Double(width)
        guard ratio >= config.minSpanRatio, matchCount > 0 else { return nil }
        
        // In black detection mode, enforce strict uniformity (render blanking has ~0 variance)
        if isBlack && blackCount > 10 {
            let variance = blackM2 / Double(blackCount)
            let stdDev = sqrt(max(0.0, variance))
            if stdDev > config.maxBlackVariance {
                return nil
            }
        } else if isSaturatedTarget && colorCount > 10 {
            let variance = colorM2 / Double(colorCount)
            let stdDev = sqrt(max(0.0, variance))
            // Reject natural multi-tone organic scenery (foliage, fabrics, flowers have high variance > 25)
            if stdDev > 22.0 {
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
        
        let minMatchesRequired = Int(ceil(Double(height) * config.minSpanRatio))
        let maxAllowedMisses = height - minMatchesRequired
        var missCount = 0
        
        let isBlack = config.isBlackDetection
        let useBoost = isBlack && config.enableExposureBoost
        let multiplier = useBoost ? config.exposureMultiplier : 1.0
        
        let tr = Int(targetRGB.r)
        let tg = Int(targetRGB.g)
        let tb = Int(targetRGB.b)
        let maxDistSqInt = Int(round(maxDist * maxDist))
        
        // Chromatic saturation of target
        let targetMax = max(tr, max(tg, tb))
        let targetMin = min(tr, min(tg, tb))
        let targetSat = targetMax > 0 ? Double(targetMax - targetMin) / Double(targetMax) : 0.0
        let isSaturatedTarget = targetSat >= 0.50
        
        // Primary & secondary color targets
        let isGreenTarget = tg - tr >= 70 && tg - tb >= 70
        let isMagentaTarget = tr - tg >= 70 && tb - tg >= 70
        let isRedTarget = tr - tg >= 70 && tr - tb >= 70
        let isBlueTarget = tb - tr >= 70 && tb - tg >= 70
        let isCyanTarget = tg - tr >= 70 && tb - tr >= 70
        let isYellowTarget = tr - tb >= 70 && tg - tb >= 70
        
        var blackCount = 0
        var blackMean = 0.0
        var blackM2 = 0.0
        
        var colorCount = 0
        var colorMean = 0.0
        var colorM2 = 0.0
        
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
            var distSq = dr * dr + dg * dg + db * db
            
            // Chroma bleed compensation for video compression (YUV 4:2:0 averaging against light backgrounds)
            if distSq > maxDistSqInt {
                if isGreenTarget && g > r && g > b {
                    let neutral = min(r, b)
                    let bleed = (neutral * 166) >> 8
                    let rc = max(0, r - bleed)
                    let bc = max(0, b - bleed)
                    let drc = rc - tr
                    let dbc = bc - tb
                    let compDistSq = drc * drc + dg * dg + dbc * dbc
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isMagentaTarget && r > g && b > g {
                    let neutral = g
                    let bleed = (neutral * 166) >> 8
                    let gc = max(0, g - bleed)
                    let dgc = gc - tg
                    let compDistSq = dr * dr + dgc * dgc + db * db
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isRedTarget && r > g && r > b {
                    let neutral = min(g, b)
                    let bleed = (neutral * 166) >> 8
                    let gc = max(0, g - bleed)
                    let bc = max(0, b - bleed)
                    let dgc = gc - tg
                    let dbc = bc - tb
                    let compDistSq = dr * dr + dgc * dgc + dbc * dbc
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isBlueTarget && b > r && b > g {
                    let neutral = min(r, g)
                    let bleed = (neutral * 166) >> 8
                    let rc = max(0, r - bleed)
                    let gc = max(0, g - bleed)
                    let drc = rc - tr
                    let dgc = gc - tg
                    let compDistSq = drc * drc + dgc * dgc + db * db
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isCyanTarget && g > r && b > r {
                    let neutral = r
                    let bleed = (neutral * 166) >> 8
                    let rc = max(0, r - bleed)
                    let drc = rc - tr
                    let compDistSq = drc * drc + dg * dg + db * db
                    if compDistSq < distSq { distSq = compDistSq }
                } else if isYellowTarget && r > b && g > b {
                    let neutral = b
                    let bleed = (neutral * 166) >> 8
                    let bc = max(0, b - bleed)
                    let dbc = bc - tb
                    let compDistSq = dr * dr + dg * dg + dbc * dbc
                    if compDistSq < distSq { distSq = compDistSq }
                }
            }
            
            if distSq <= maxDistSqInt {
                if isSaturatedTarget {
                    let pixMax = max(originalR, max(originalG, originalB))
                    let pixMin = min(originalR, min(originalG, originalB))
                    let pixSat = pixMax > 0 ? Double(pixMax - pixMin) / Double(pixMax) : 0.0
                    if pixSat < 0.22 {
                        missCount += 1
                        if missCount > maxAllowedMisses { return nil }
                        continue
                    }
                }
                
                matchCount += 1
                sumR += UInt64(originalR)
                sumG += UInt64(originalG)
                sumB += UInt64(originalB)
                
                if isBlack {
                    let intensity = Double(originalR + originalG + originalB) / 3.0
                    blackCount += 1
                    let delta = intensity - blackMean
                    blackMean += delta / Double(blackCount)
                    let delta2 = intensity - blackMean
                    blackM2 += delta * delta2
                } else if isSaturatedTarget {
                    let intensity = Double(originalR + originalG + originalB) / 3.0
                    colorCount += 1
                    let delta = intensity - colorMean
                    colorMean += delta / Double(colorCount)
                    let delta2 = intensity - colorMean
                    colorM2 += delta * delta2
                }
            } else {
                missCount += 1
                if missCount > maxAllowedMisses {
                    return nil
                }
            }
        }
        
        let ratio = Double(matchCount) / Double(height)
        guard ratio >= config.minSpanRatio, matchCount > 0 else { return nil }
        
        if isBlack && blackCount > 10 {
            let variance = blackM2 / Double(blackCount)
            let stdDev = sqrt(max(0.0, variance))
            if stdDev > config.maxBlackVariance {
                return nil
            }
        } else if isSaturatedTarget && colorCount > 10 {
            let variance = colorM2 / Double(colorCount)
            let stdDev = sqrt(max(0.0, variance))
            if stdDev > 22.0 {
                return nil
            }
        }
        
        let avgR = UInt8(sumR / UInt64(matchCount))
        let avgG = UInt8(sumG / UInt64(matchCount))
        let avgB = UInt8(sumB / UInt64(matchCount))
        return (matchCount, RGBColor(r: avgR, g: avgG, b: avgB))
    }
}
