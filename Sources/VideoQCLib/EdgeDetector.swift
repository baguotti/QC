import Foundation
import CoreVideo

/// Line Finder v2. Each pixel near an edge is modelled as a blend of the target colour T and the picture R just
/// inside the line: P ≈ α·T + (1 − α)·R. A line is a contiguous run of positions with α above the sensitivity
/// threshold and a small residual, on depths that step back down to the picture further in.
public struct EdgeDetector: Sendable {
    
    public init() {}
    
    /// Detects target-colour lines at frame edges and internal split-screens from a CVPixelBuffer (BGRA format)
    public func scanPixelBuffer(_ pixelBuffer: CVPixelBuffer, config: QCConfig) -> [LineDetection] {
        let targetRGB = config.targetRGB
        guard config.anyColor || targetRGB != nil else { return [] }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return []
        }
        
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        // Decoded buffers can carry padding (e.g. 1088 rows for 1080p); only the clean aperture is picture.
        // The clean rect's origin is bottom-up.
        var originX = 0, originY = 0, width = bufferWidth, height = bufferHeight
        let clean = CVImageBufferGetCleanRect(pixelBuffer)
        if clean.width >= 1 && clean.height >= 1 {
            originX = min(bufferWidth, max(0, Int(clean.minX.rounded())))
            originY = min(bufferHeight, max(0, bufferHeight - Int(clean.maxY.rounded())))
            width = min(bufferWidth - originX, Int(clean.width.rounded()))
            height = min(bufferHeight - originY, Int(clean.height.rounded()))
        }
        guard width > 0 && height > 0 else { return [] }
        let bufferPtr = UnsafePointer(baseAddress.assumingMemoryBound(to: UInt8.self) + originY * bytesPerRow + originX * 4)
        
        // Verify if the entire frame is dark/black OR dominated by the target color (e.g. green screen, white card, slate)
        if !config.anyColor, let targetRGB {
            let shouldCheckFrameWideSuppression = config.isWhiteDetection ? config.ignoreFullWhiteFrames : config.ignoreFullBlackFrames
            if shouldCheckFrameWideSuppression && isEntireFrameTargetColorOrDarkBGRA(ptr: bufferPtr, width: width, height: height, bytesPerRow: bytesPerRow, targetRGB: targetRGB, config: config) {
                return []
            }
        }
        
        let frame = BGRAFrame(ptr: bufferPtr, width: width, height: height, bytesPerRow: bytesPerRow)
        return BlendLineModel(config: config).scan(frame, config: config)
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
        let isWhite = config.isWhiteDetection
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
                
                if isBlack || isWhite {
                    // Rec.709 perceived luminance
                    let lum = (r * 299 + g * 587 + b * 114) / 1000
                    totalLum += UInt64(lum)
                    if isBlack && lum <= 20 {
                        darkSamples += 1
                        if isPerimeter { perimeterDarkSamples += 1 }
                    }
                }
                
                if !isBlack {
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
        } else if isWhite {
            guard config.ignoreFullWhiteFrames else { return false }
            let avgLum = Double(totalLum) / Double(totalSamples)
            let targetRatio = Double(targetColorSamples) / Double(totalSamples)
            let perimeterTargetRatio = perimeterTotalSamples > 0 ? Double(perimeterTargetSamples) / Double(perimeterTotalSamples) : 0.0
            
            // Full-frame white slate, logo card, or pure white flash transition
            if avgLum >= 250.0 { return true }
            if targetRatio >= 0.94 && perimeterTargetRatio >= 0.94 { return true }
            if targetRatio >= 0.98 { return true }
            return false
        } else {
            let targetRatio = Double(targetColorSamples) / Double(totalSamples)
            let perimeterTargetRatio = perimeterTotalSamples > 0 ? Double(perimeterTargetSamples) / Double(perimeterTotalSamples) : 0.0
            
            // Chroma key green screen backdrop or colored slate
            if targetRatio >= 0.80 && perimeterTargetRatio >= 0.85 { return true }
            if targetRatio >= 0.88 { return true }
            return false
        }
    }
    
}

// MARK: - Blend Model Engine

private struct BGRAFrame {
    let ptr: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

/// One row/column of positions along an edge (or a split-screen seam), addressed in bytes.
private struct LineWalk {
    let origin: Int
    let depthStride: Int
    let positionStride: Int
    let length: Int
}

struct LineRun: Equatable {
    var start = 0
    var end = -1
    var passes = 0
    var fails = 0
    
    var length: Int { end - start + 1 }
}

private struct BlendLineModel {
    static let pass: Int8 = 1
    static let fail: Int8 = -1
    static let skip: Int8 = 0
    
    /// |T − R| below this says nothing about a line (picture already looks like the target).
    static let minContrast: Float = 40
    static let maxAlpha: Float = 1.35
    static let maxGap = 8
    /// The picture just inside a line must fall back to at most this fraction of the innermost line row's α.
    static let maxInnerAlphaRatio: Float = 0.6
    static let anyColorMinAlpha: Float = 0.6
    
    let lut: [Float]
    let target: SIMD3<Float>?
    let weakAlpha: Float
    let strongAlpha: Float
    let edgeDepth: Int
    let minSpanRatio: Double
    
    init(config: QCConfig) {
        var lut = (0..<256).map { Float($0) }
        if !config.anyColor && config.isBlackDetection && config.enableExposureBoost {
            // Shadow expansion: separates render black from dark picture without clipping bright content.
            lut = lut.map { 255 * ($0 / 255).squareRoot() }
        } else if !config.anyColor && config.isWhiteDetection && config.enableHighlightExpansion {
            lut = lut.map { 255 - 255 * ((255 - $0) / 255).squareRoot() }
        }
        self.lut = lut
        if !config.anyColor, let rgb = config.targetRGB {
            self.target = SIMD3(lut[Int(rgb.r)], lut[Int(rgb.g)], lut[Int(rgb.b)])
            self.weakAlpha = Float(config.weakAlpha)
            self.strongAlpha = Float(config.strongAlpha)
        } else {
            self.target = nil
            self.weakAlpha = Self.anyColorMinAlpha
            self.strongAlpha = Self.anyColorMinAlpha
        }
        self.edgeDepth = config.edgeDepth
        self.minSpanRatio = config.minSpanRatio
    }
    
    func scan(_ frame: BGRAFrame, config: QCConfig) -> [LineDetection] {
        let w = frame.width
        let h = frame.height
        let bpr = frame.bytesPerRow
        var detections: [LineDetection] = []
        
        let edges: [(EdgeLocation, LineWalk, Int)] = [
            (.bottom, LineWalk(origin: (h - 1) * bpr, depthStride: -bpr, positionStride: 4, length: w), h),
            (.top, LineWalk(origin: 0, depthStride: bpr, positionStride: 4, length: w), h),
            (.left, LineWalk(origin: 0, depthStride: 4, positionStride: bpr, length: h), w),
            (.right, LineWalk(origin: (w - 1) * 4, depthStride: -4, positionStride: bpr, length: h), w)
        ]
        for (edge, walk, extent) in edges {
            let depthCount = min(edgeDepth, extent / 2 - 4)
            guard depthCount >= 1 else { continue }
            if let detection = scanEdge(edge, walk: walk, frame: frame, depthCount: depthCount) {
                detections.append(detection)
            }
        }
        
        if config.scanFullScreen {
            detections += scanSplits(.splitHorizontal, frame: frame)
            detections += scanSplits(.splitVertical, frame: frame)
        }
        return detections
    }
    
    // MARK: Edges
    
    private func scanEdge(_ edge: EdgeLocation, walk: LineWalk, frame: BGRAFrame, depthCount: Int) -> LineDetection? {
        let n = walk.length
        let ptr = frame.ptr
        let minRun = minimumRun(length: n)
        
        // R(p): median of the 4 depths just past the scanned band.
        var refs = [SIMD3<Float>](repeating: .zero, count: n)
        for p in 0..<n {
            let o = walk.origin + p * walk.positionStride + depthCount * walk.depthStride
            refs[p] = median4(
                color(ptr, o),
                color(ptr, o + walk.depthStride),
                color(ptr, o + 2 * walk.depthStride),
                color(ptr, o + 3 * walk.depthStride)
            )
        }
        
        var states = [Int8](repeating: Self.skip, count: n * depthCount)
        var alphas = [Float](repeating: 0, count: n * depthCount)
        var targets: [SIMD3<Float>] = []
        var runs: [LineRun] = []
        
        // Every depth is judged on its own: a line 1 px in, behind a half-blended outer row, still counts.
        for d in 0..<depthCount {
            let rowOrigin = walk.origin + d * walk.depthStride
            let t = target ?? medianColor(ptr, origin: rowOrigin, stride: walk.positionStride, count: n)
            targets.append(t)
            for p in 0..<n {
                let (state, alpha) = classify(color(ptr, rowOrigin + p * walk.positionStride), ref: refs[p], target: t)
                states[d * n + p] = state
                alphas[d * n + p] = alpha
            }
            runs.append(Self.longestRun(states, from: d * n, count: n))
        }
        
        var best: LineDetection?
        var lo = 0
        while lo < depthCount {
            guard runs[lo].passes >= minRun else {
                lo += 1
                continue
            }
            var hi = lo
            while hi + 1 < depthCount && runs[hi + 1].passes >= minRun { hi += 1 }
            defer { lo = hi + 1 }
            
            // Reaches the end of the band: letterbox / pillarbox or picture content, not a line.
            guard hi < depthCount - 1 else { continue }
            
            let core = (lo...hi).max { runs[$0].passes < runs[$1].passes } ?? lo
            let run = runs[core]
            let t = targets[core]
            
            var lineAlphas: [Float] = []
            var edgeAlphas: [Float] = []
            var innerAlphas: [Float] = []
            var sum = SIMD3<Int>(repeating: 0)
            var passCount = 0
            let innerOrigin = walk.origin + (hi + 1) * walk.depthStride
            let coreOrigin = walk.origin + core * walk.depthStride
            for p in run.start...run.end {
                let i = core * n + p
                if states[i] != Self.skip { lineAlphas.append(alphas[i]) }
                if states[hi * n + p] != Self.skip { edgeAlphas.append(alphas[hi * n + p]) }
                if states[i] == Self.pass {
                    sum &+= rawColor(ptr, coreOrigin + p * walk.positionStride)
                    passCount += 1
                }
                let (innerState, innerAlpha) = classify(color(ptr, innerOrigin + p * walk.positionStride), ref: refs[p], target: t)
                if innerState != Self.skip { innerAlphas.append(innerAlpha) }
            }
            let lineAlpha = Self.median(&lineAlphas)
            let innerAlpha = Self.median(&innerAlphas)
            // Step at the line's inner boundary: a gradient fades out gradually, a line stops.
            let edgeAlpha = Self.median(&edgeAlphas)
            guard passCount > 0, lineAlpha >= weakAlpha, innerAlpha <= edgeAlpha * Self.maxInnerAlphaRatio else { continue }
            
            let avg = sum / passCount
            let detection = LineDetection(
                edge: edge,
                thickness: hi - lo + 1,
                detectedColor: RGBColor(r: UInt8(avg.x), g: UInt8(avg.y), b: UInt8(avg.z)),
                spanRatio: Double(run.length) / Double(n),
                score: Double(lineAlpha),
                isWeak: lineAlpha < strongAlpha
            )
            if best == nil || detection.score > best!.score {
                best = detection
            }
        }
        return best
    }
    
    // MARK: Split Screens
    
    /// Internal seams: each row (column) is compared against the picture `edgeDepth + 1` px away on both sides,
    /// sampling every 2nd pixel along it. Clusters thicker than `edgeDepth` are picture content.
    private func scanSplits(_ kind: EdgeLocation, frame: BGRAFrame) -> [LineDetection] {
        let alongRows = kind == .splitHorizontal
        let lineCount = alongRows ? frame.height : frame.width
        let positions = alongRows ? frame.width : frame.height
        let lineStride = alongRows ? frame.bytesPerRow : 4
        let step = 2
        let positionStride = (alongRows ? 4 : frame.bytesPerRow) * step
        let samples = (positions + step - 1) / step
        let minRun = max(1, minimumRun(length: positions) / step)
        let offset = (edgeDepth + 1) * lineStride
        let ptr = frame.ptr
        guard lineCount > 2 * (edgeDepth + 1) else { return [] }
        
        var detections: [LineDetection] = []
        var states = [Int8](repeating: Self.skip, count: samples)
        var alphas = [Float](repeating: 0, count: samples)
        var clusterStart = -1
        var clusterBest: (alpha: Float, run: LineRun, line: Int, target: SIMD3<Float>)?
        
        func closeCluster(at line: Int) {
            defer {
                clusterStart = -1
                clusterBest = nil
            }
            guard clusterStart >= 0, let best = clusterBest, line - clusterStart <= edgeDepth else { return }
            var sum = SIMD3<Int>(repeating: 0)
            var count = 0
            for s in best.run.start...best.run.end {
                let o = best.line * lineStride + s * positionStride
                if classify(color(ptr, o), ref: color(ptr, o - offset), target: best.target).state == Self.pass {
                    sum &+= rawColor(ptr, o)
                    count += 1
                }
            }
            let avg = sum / max(1, count)
            detections.append(LineDetection(
                edge: kind,
                thickness: line - clusterStart,
                detectedColor: RGBColor(r: UInt8(avg.x), g: UInt8(avg.y), b: UInt8(avg.z)),
                spanRatio: Double(best.run.length) / Double(samples),
                score: Double(best.alpha),
                isWeak: best.alpha < strongAlpha
            ))
        }
        
        let first = edgeDepth + 1
        let last = lineCount - edgeDepth - 1
        for line in first..<last {
            let lineOrigin = line * lineStride
            let t = target ?? medianColor(ptr, origin: lineOrigin, stride: positionStride, count: samples)
            for s in 0..<samples {
                let o = lineOrigin + s * positionStride
                let p = color(ptr, o)
                let a = classify(p, ref: color(ptr, o - offset), target: t)
                let b = classify(p, ref: color(ptr, o + offset), target: t)
                if a.state == Self.skip || b.state == Self.skip {
                    states[s] = Self.skip
                } else {
                    states[s] = (a.state == Self.pass && b.state == Self.pass) ? Self.pass : Self.fail
                }
                alphas[s] = min(a.alpha, b.alpha)
            }
            let run = Self.longestRun(states, from: 0, count: samples)
            var isCandidate = false
            if run.passes >= minRun {
                var runAlphas = (run.start...run.end).compactMap { states[$0] != Self.skip ? alphas[$0] : nil }
                let alpha = Self.median(&runAlphas)
                if alpha >= weakAlpha {
                    isCandidate = true
                    if clusterStart < 0 { clusterStart = line }
                    if clusterBest == nil || alpha > clusterBest!.alpha {
                        clusterBest = (alpha, run, line, t)
                    }
                }
            }
            if !isCandidate && clusterStart >= 0 {
                closeCluster(at: line)
            }
        }
        if clusterStart >= 0 {
            closeCluster(at: last)
        }
        return detections
    }
    
    // MARK: Pixel Model
    
    private func minimumRun(length: Int) -> Int {
        max(Int((Double(length) * minSpanRatio).rounded(.up)), min(64, length))
    }
    
    @inline(__always)
    private func color(_ ptr: UnsafePointer<UInt8>, _ offset: Int) -> SIMD3<Float> {
        SIMD3(lut[Int(ptr[offset + 2])], lut[Int(ptr[offset + 1])], lut[Int(ptr[offset])])
    }
    
    @inline(__always)
    private func rawColor(_ ptr: UnsafePointer<UInt8>, _ offset: Int) -> SIMD3<Int> {
        SIMD3(Int(ptr[offset + 2]), Int(ptr[offset + 1]), Int(ptr[offset]))
    }
    
    /// α = ((P − R)·(T − R)) / |T − R|², residual = |P − R − α(T − R)|.
    @inline(__always)
    private func classify(_ p: SIMD3<Float>, ref r: SIMD3<Float>, target t: SIMD3<Float>) -> (state: Int8, alpha: Float) {
        let tr = t - r
        let contrastSq = (tr * tr).sum()
        guard contrastSq >= Self.minContrast * Self.minContrast else { return (Self.skip, 0) }
        let pr = p - r
        let alpha = (pr * tr).sum() / contrastSq
        let residual = pr - alpha * tr
        let tolerance = max(24, 0.3 * contrastSq.squareRoot())
        let isLine = alpha >= weakAlpha && alpha <= Self.maxAlpha && (residual * residual).sum() <= tolerance * tolerance
        return (isLine ? Self.pass : Self.fail, alpha)
    }
    
    private func median4(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) -> SIMD3<Float> {
        let lo = pointwiseMin(pointwiseMin(a, b), pointwiseMin(c, d))
        let hi = pointwiseMax(pointwiseMax(a, b), pointwiseMax(c, d))
        return (a + b + c + d - lo - hi) * 0.5
    }
    
    /// "Any colour" target: per-channel median of the candidate line.
    private func medianColor(_ ptr: UnsafePointer<UInt8>, origin: Int, stride: Int, count: Int) -> SIMD3<Float> {
        var r: [Float] = [], g: [Float] = [], b: [Float] = []
        r.reserveCapacity(count); g.reserveCapacity(count); b.reserveCapacity(count)
        for i in 0..<count {
            let c = color(ptr, origin + i * stride)
            r.append(c.x); g.append(c.y); b.append(c.z)
        }
        return SIMD3(Self.median(&r), Self.median(&g), Self.median(&b))
    }
    
    private static func median(_ values: inout [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        values.sort()
        return values[values.count / 2]
    }
    
    /// Longest run of passing positions, bridging gaps of up to `maxGap` failing positions. Uninformative
    /// positions neither break nor extend a run. Runs with fewer than 75% passes are ignored.
    static func longestRun(_ states: [Int8], from start: Int, count: Int) -> LineRun {
        var best = LineRun()
        var current = LineRun()
        var inRun = false
        var pendingFails = 0
        
        func finish() {
            if current.passes > best.passes && current.passes * 4 >= (current.passes + current.fails) * 3 {
                best = current
            }
            inRun = false
            pendingFails = 0
        }
        
        for i in 0..<count {
            switch states[start + i] {
            case pass:
                if inRun {
                    current.passes += 1
                    current.fails += pendingFails
                    current.end = i
                } else {
                    current = LineRun(start: i, end: i, passes: 1, fails: 0)
                    inRun = true
                }
                pendingFails = 0
            case fail:
                guard inRun else { break }
                pendingFails += 1
                if pendingFails > maxGap { finish() }
            default:
                break
            }
        }
        if inRun { finish() }
        return best
    }
}
