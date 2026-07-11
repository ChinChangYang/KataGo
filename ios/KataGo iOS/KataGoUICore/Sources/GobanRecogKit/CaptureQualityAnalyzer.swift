//
//  CaptureQualityAnalyzer.swift
//  GobanRecogKit
//
//  Pure capture-guidance math for a live camera-capture screen. Given a detected
//  board quad and a grayscale preview frame it produces a `CaptureGuidance`
//  ("board cut off", "too dark", "shadow on the board", ...).
//
//  Everything here is deterministic, side-effect free, and platform-neutral
//  (Foundation + CoreGraphics value types only — NO AVFoundation / Vision /
//  UIKit), so it compiles for iOS and macOS and is fully unit-testable from
//  synthetic grids. A future AVFoundation screen calls `analyze` per preview
//  frame; callers throttle, so nothing here uses concurrency.
//
//  These thresholds are UX-guidance thresholds, NOT recognition-pipeline
//  thresholds — they deliberately live only in GobanRecogKit and never touch the
//  CGobanRecog recognition core.
//

import CoreGraphics
import Foundation

public enum CaptureQualityAnalyzer {

    /// Tunable thresholds for the guidance checks, gathered in one place with the
    /// rationale for each. All are UX-guidance values, not recognition thresholds.
    enum Thresholds {
        /// `tooFar` when the quad's normalized area fraction is below this.
        static let tooFarAreaFraction = 0.20
        /// `boardCutOff` when any vertex is within this normalized distance of
        /// any frame edge (`x < margin || x > 1 - margin`, likewise `y`).
        static let cutOffMargin = 0.02
        /// `tooTilted` when the longer of an opposite side pair exceeds the
        /// shorter by more than this ratio (in pixel space). A top-down goban
        /// shot has near-equal opposite sides; perspective stretches one pair.
        static let tiltRatio = 1.35
        /// `tooDark` when the rectified board's mean luma is below this (of 255).
        static let tooDarkMean = 60.0
        /// A rectified pixel at or above this luma counts as blown-out (glare).
        static let glareLuma: UInt8 = 250
        /// `glare` when the blown-out fraction of the rectified board exceeds this.
        static let glareFraction = 0.025
        /// `shadow` when `shadowFraction` exceeds this. On the IMG_0819
        /// camera-shadow photo `shadowFraction` measures ~0.17; clean boards sit
        /// well below 0.08.
        static let shadowFraction = 0.08
        /// A pixel is part of a shadow depression when it sits more than this
        /// relative fraction below the median illumination: `(med - v) / med`.
        static let shadowDepressionRatio = 0.10
        /// The rectified board is normalized to this side length (px) before the
        /// exposure and shadow checks run.
        static let rectifiedSide = 128
        /// Gaussian blur sigma for the illumination field is `width / this`
        /// (128 px -> sigma 12.8).
        static let shadowSigmaDivisor = 10.0
    }

    // MARK: - Orchestrator

    /// Analyzes one preview frame. When `quad` is absent or malformed the result
    /// is `[.noBoard]`; otherwise framing issues are computed on the quad and the
    /// board is rectified to a normalized square for the exposure + shadow checks.
    /// The returned `issues` are sorted by priority (most urgent first).
    public static func analyze(frame: LumaGrid, quad: [CGPoint]?, imageSize: CGSize) -> CaptureGuidance {
        guard let quad, quad.count == 4 else {
            return CaptureGuidance(quad: nil, issues: [.noBoard])
        }

        var issues = framingIssues(quad: quad, imageSize: imageSize)

        let rectified = rectify(frame: frame, quad: quad, side: Thresholds.rectifiedSide)
        issues.append(contentsOf: exposureIssues(rectified: rectified))
        if shadowFraction(rectified: rectified) > Thresholds.shadowFraction {
            issues.append(.shadow)
        }

        issues.sort { $0.priority < $1.priority }
        return CaptureGuidance(quad: quad, issues: issues)
    }

    // MARK: - Framing (on the normalized quad)

    /// Framing issues for a board quad: `boardCutOff`, `tooFar`, `tooTilted`,
    /// returned in priority order. Assumes exactly 4 normalized points in
    /// TL, TR, BR, BL order (`analyze` guards the count upstream).
    public static func framingIssues(quad: [CGPoint], imageSize: CGSize) -> [GuidanceIssue] {
        var issues: [GuidanceIssue] = []

        // boardCutOff: any vertex hugging a frame edge.
        let margin = Thresholds.cutOffMargin
        let cutOff = quad.contains { p in
            Double(p.x) < margin || Double(p.x) > 1 - margin
                || Double(p.y) < margin || Double(p.y) > 1 - margin
        }
        if cutOff { issues.append(.boardCutOff) }

        // tooFar: shoelace area on normalized coords IS the frame-area fraction.
        if shoelaceArea(quad) < Thresholds.tooFarAreaFraction {
            issues.append(.tooFar)
        }

        // tooTilted: compare opposite side pairs in pixel space.
        let w = Double(imageSize.width)
        let h = Double(imageSize.height)
        func side(_ a: CGPoint, _ b: CGPoint) -> Double {
            let dx = (Double(a.x) - Double(b.x)) * w
            let dy = (Double(a.y) - Double(b.y)) * h
            return (dx * dx + dy * dy).squareRoot()
        }
        let top = side(quad[0], quad[1])
        let right = side(quad[1], quad[2])
        let bottom = side(quad[2], quad[3])
        let left = side(quad[3], quad[0])
        let topBottomMin = min(top, bottom)
        let leftRightMin = min(left, right)
        if topBottomMin > 0, leftRightMin > 0 {
            let topBottom = max(top, bottom) / topBottomMin
            let leftRight = max(left, right) / leftRightMin
            if topBottom > Thresholds.tiltRatio || leftRight > Thresholds.tiltRatio {
                issues.append(.tooTilted)
            }
        }

        return issues
    }

    // MARK: - Exposure (on the rectified board)

    /// Exposure issues for the rectified board: `tooDark` (mean too low) and
    /// `glare` (too many blown-out pixels), returned in priority order.
    public static func exposureIssues(rectified: LumaGrid) -> [GuidanceIssue] {
        let pixels = rectified.pixels
        guard !pixels.isEmpty else { return [] }

        var sum = 0
        var glareCount = 0
        for p in pixels {
            sum += Int(p)
            if p >= Thresholds.glareLuma { glareCount += 1 }
        }
        let mean = Double(sum) / Double(pixels.count)
        let glareFrac = Double(glareCount) / Double(pixels.count)

        var issues: [GuidanceIssue] = []
        if mean < Thresholds.tooDarkMean { issues.append(.tooDark) }
        if glareFrac > Thresholds.glareFraction { issues.append(.glare) }
        return issues
    }

    // MARK: - Shadow (on the rectified board)

    /// Fraction of the rectified board covered by the largest soft-shadow blob.
    ///
    /// Heuristic (the load-bearing one, validated on real camera-shadow photos):
    ///   1. Illumination field = Gaussian blur of the luma with `sigma = width/10`
    ///      (separable 1-D convolution, kernel radius `ceil(3*sigma)`, renormalized
    ///      at the borders so no wrap/zero-pad darkening). Computed in `Double`.
    ///   2. `med` = median of the field.
    ///   3. Depression mask = pixels where `(med - field) / med > 0.10`.
    ///   4. Result = area fraction of the LARGEST 4-connected component of the
    ///      mask (iterative flood fill).
    ///
    /// On the IMG_0819 camera-shadow photo this measures ~0.17; clean boards sit
    /// well below the 0.08 `shadow` threshold. Guidance thresholds, not
    /// recognition thresholds.
    public static func shadowFraction(rectified: LumaGrid) -> Double {
        let width = rectified.width
        let height = rectified.height
        let count = width * height
        guard count > 0 else { return 0 }

        let field = gaussianBlur(rectified.pixels, width: width, height: height,
                                 sigma: Double(width) / Thresholds.shadowSigmaDivisor)
        let med = median(field)
        guard med > 0 else { return 0 }

        // Depression mask.
        let threshold = Thresholds.shadowDepressionRatio
        var mask = [Bool](repeating: false, count: count)
        for i in 0..<count {
            mask[i] = (med - field[i]) / med > threshold
        }

        let largest = largestConnectedComponent(mask, width: width, height: height)
        return Double(largest) / Double(count)
    }

    // MARK: - Rectify (quad -> normalized square)

    /// Rectifies the board region bounded by `quad` (4 normalized frame corners,
    /// TL, TR, BR, BL) into a `side x side` grayscale square via a projective
    /// (homography) warp with bilinear sampling and edge clamping.
    ///
    /// Builds the 3x3 transform H mapping the unit-square corners
    /// (0,0),(1,0),(1,1),(0,1) to the quad, then for each output pixel maps its
    /// center back through H to normalized frame coordinates and samples.
    public static func rectify(frame: LumaGrid, quad: [CGPoint], side: Int) -> LumaGrid {
        let clampedSide = max(1, side)
        let h = homography(unitSquareTo: quad)

        var out = [UInt8](repeating: 0, count: clampedSide * clampedSide)
        let fw = Double(frame.width)
        let fh = Double(frame.height)
        let sideD = Double(clampedSide)

        for i in 0..<clampedSide {
            let v = (Double(i) + 0.5) / sideD
            for j in 0..<clampedSide {
                let u = (Double(j) + 0.5) / sideD
                let denom = h[6] * u + h[7] * v + h[8]
                let nx = (h[0] * u + h[1] * v + h[2]) / denom
                let ny = (h[3] * u + h[4] * v + h[5]) / denom
                let sample = bilinear(frame, px: nx * fw, py: ny * fh)
                out[i * clampedSide + j] = UInt8(max(0.0, min(255.0, sample.rounded())))
            }
        }

        // The invariant (count == side*side, side > 0) always holds here.
        return LumaGrid(pixels: out, width: clampedSide, height: clampedSide)
            ?? LumaGrid(pixels: [0], width: 1, height: 1)!
    }

    // MARK: - Private helpers

    /// Twice-signed-area shoelace magnitude, halved. On normalized coordinates
    /// the frame area is 1, so this IS the quad's area fraction.
    private static func shoelaceArea(_ q: [CGPoint]) -> Double {
        var sum = 0.0
        for i in 0..<q.count {
            let a = q[i]
            let b = q[(i + 1) % q.count]
            sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return abs(sum) / 2.0
    }

    /// Separable Gaussian blur with border renormalization (no wrap, no
    /// zero-padding darkening). Returns the blurred field in `Double`.
    private static func gaussianBlur(_ pixels: [UInt8], width: Int, height: Int, sigma: Double) -> [Double] {
        let source = pixels.map(Double.init)
        guard sigma > 0 else { return source }

        let radius = max(1, Int(ceil(3 * sigma)))
        var kernel = [Double](repeating: 0, count: 2 * radius + 1)
        let twoSigmaSq = 2 * sigma * sigma
        for k in -radius...radius {
            kernel[k + radius] = exp(-Double(k * k) / twoSigmaSq)
        }

        // Horizontal pass.
        var horizontal = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var acc = 0.0
                var wsum = 0.0
                for k in -radius...radius {
                    let xx = x + k
                    if xx >= 0, xx < width {
                        let w = kernel[k + radius]
                        acc += w * source[row + xx]
                        wsum += w
                    }
                }
                horizontal[row + x] = acc / wsum
            }
        }

        // Vertical pass.
        var vertical = [Double](repeating: 0, count: width * height)
        for x in 0..<width {
            for y in 0..<height {
                var acc = 0.0
                var wsum = 0.0
                for k in -radius...radius {
                    let yy = y + k
                    if yy >= 0, yy < height {
                        let w = kernel[k + radius]
                        acc += w * horizontal[yy * width + x]
                        wsum += w
                    }
                }
                vertical[y * width + x] = acc / wsum
            }
        }

        return vertical
    }

    /// Median of `values` (average of the two central samples for an even count).
    /// The blurred field is finite (no NaN), so a plain sort is safe here.
    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    /// Size (in pixels) of the largest 4-connected `true` component of `mask`.
    /// Iterative flood fill — a 128x128 mask would blow the stack recursively.
    private static func largestConnectedComponent(_ mask: [Bool], width: Int, height: Int) -> Int {
        var visited = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        var largest = 0

        for start in 0..<mask.count where mask[start] && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            var size = 0

            while let idx = stack.popLast() {
                size += 1
                let x = idx % width
                let y = idx / width
                if x > 0 {
                    let n = idx - 1
                    if mask[n], !visited[n] { visited[n] = true; stack.append(n) }
                }
                if x < width - 1 {
                    let n = idx + 1
                    if mask[n], !visited[n] { visited[n] = true; stack.append(n) }
                }
                if y > 0 {
                    let n = idx - width
                    if mask[n], !visited[n] { visited[n] = true; stack.append(n) }
                }
                if y < height - 1 {
                    let n = idx + width
                    if mask[n], !visited[n] { visited[n] = true; stack.append(n) }
                }
            }

            largest = max(largest, size)
        }

        return largest
    }

    /// The 9 row-major entries of the 3x3 homography mapping the unit-square
    /// corners (0,0),(1,0),(1,1),(0,1) to `quad` (TL, TR, BR, BL). Solves the
    /// standard 4-point DLT 8x8 system by Gaussian elimination; `h[8] == 1`.
    private static func homography(unitSquareTo quad: [CGPoint]) -> [Double] {
        // Source (unit square) -> destination (quad) correspondences.
        let src: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        let dst: [(Double, Double)] = quad.map { (Double($0.x), Double($0.y)) }

        // 8x8 system A * hVec = b for [h0..h7], with h8 fixed at 1.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
        var b = [Double](repeating: 0, count: 8)
        for i in 0..<4 {
            let (x, y) = src[i]
            let (X, Y) = dst[i]
            let r0 = 2 * i
            let r1 = 2 * i + 1
            a[r0] = [x, y, 1, 0, 0, 0, -x * X, -y * X]
            b[r0] = X
            a[r1] = [0, 0, 0, x, y, 1, -x * Y, -y * Y]
            b[r1] = Y
        }

        let solution = solveLinearSystem(a, b) ?? [1, 0, 0, 0, 1, 0, 0, 0]
        return solution + [1.0]
    }

    /// Solves the square linear system `a * x = b` by Gaussian elimination with
    /// partial pivoting. Returns `nil` on a singular (degenerate) system.
    private static func solveLinearSystem(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        var m = a
        var rhs = b

        for col in 0..<n {
            // Partial pivot: largest-magnitude entry in this column.
            var pivot = col
            var best = abs(m[col][col])
            for r in (col + 1)..<n where abs(m[r][col]) > best {
                best = abs(m[r][col])
                pivot = r
            }
            if best < 1e-12 { return nil }
            if pivot != col {
                m.swapAt(col, pivot)
                rhs.swapAt(col, pivot)
            }

            let pivotVal = m[col][col]
            for r in 0..<n where r != col {
                let factor = m[r][col] / pivotVal
                if factor == 0 { continue }
                for c in col..<n {
                    m[r][c] -= factor * m[col][c]
                }
                rhs[r] -= factor * rhs[col]
            }
        }

        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            x[i] = rhs[i] / m[i][i]
        }
        return x
    }

    /// Bilinear sample of `frame` at pixel-space coordinate `(px, py)` (pixel
    /// centers at integer + 0.5), with edge clamping.
    private static func bilinear(_ frame: LumaGrid, px: Double, py: Double) -> Double {
        let w = frame.width
        let h = frame.height
        let fx = px - 0.5
        let fy = py - 0.5
        let x0 = Int(floor(fx))
        let y0 = Int(floor(fy))
        let tx = fx - Double(x0)
        let ty = fy - Double(y0)

        func clampX(_ v: Int) -> Int { min(max(v, 0), w - 1) }
        func clampY(_ v: Int) -> Int { min(max(v, 0), h - 1) }
        let x0c = clampX(x0)
        let x1c = clampX(x0 + 1)
        let y0c = clampY(y0)
        let y1c = clampY(y0 + 1)

        let p00 = Double(frame.pixels[y0c * w + x0c])
        let p10 = Double(frame.pixels[y0c * w + x1c])
        let p01 = Double(frame.pixels[y1c * w + x0c])
        let p11 = Double(frame.pixels[y1c * w + x1c])

        let topRow = p00 * (1 - tx) + p10 * tx
        let botRow = p01 * (1 - tx) + p11 * tx
        return topRow * (1 - ty) + botRow * ty
    }
}
