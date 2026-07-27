//
//  BoardQuadEditor.swift
//  GobanRecogKit
//
//  Pure geometry for the board-grid UI: a draggable quadrilateral over the
//  photo, the homography that warps an N×N lattice onto it, and the rules that
//  keep the shape usable while a corner is being dragged.
//
//  Replaces CropRectEditor. A rectangle is a quadrilateral, so this is a strict
//  superset — but the point is not a tighter crop. The recognizer's `corners`
//  are the four OUTER GRID-LINE INTERSECTIONS of the board, and a quad placed
//  on them can be handed straight to the lattice fit, skipping the quad
//  proposers that fail on hard photos. An axis-aligned crop could never say
//  that: it can only narrow where the app looks.
//
//  UI-independent so the whole interaction model is unit-testable; BoardQuadView
//  is a thin gesture/rendering shell over this. Coordinates are view points
//  inside the fitted image frame, exactly as CropRectEditor used them; the view
//  converts to the normalized [0,1]² top-left-origin space the ingestion and
//  recognition seams speak.
//

import CoreGraphics
import Foundation

/// Which corner of the board grid a handle controls. The order matches the
/// recognizer's `corners` (TL, TR, BR, BL) so the two never need reordering.
public enum BoardCorner: Int, CaseIterable, Sendable {
    case topLeft = 0
    case topRight = 1
    case bottomRight = 2
    case bottomLeft = 3
}

/// Four corners in TL, TR, BR, BL order — the recognizer's convention.
public struct BoardQuad: Equatable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint,
                bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Corners in TL, TR, BR, BL order.
    public var points: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    public init(points: [CGPoint]) {
        precondition(points.count == 4, "a quad has exactly four corners")
        self.init(topLeft: points[0], topRight: points[1],
                  bottomRight: points[2], bottomLeft: points[3])
    }

    public subscript(corner: BoardCorner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: return topLeft
            case .topRight: return topRight
            case .bottomRight: return bottomRight
            case .bottomLeft: return bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }

    /// The axis-aligned rectangle inset into `rect` by `fraction` of each side.
    /// The starting shape when there is no detection to seed from.
    public static func inset(in rect: CGRect, fraction: CGFloat = 0.1) -> BoardQuad {
        let dx = rect.width * fraction
        let dy = rect.height * fraction
        let inner = rect.insetBy(dx: dx, dy: dy)
        return BoardQuad(topLeft: CGPoint(x: inner.minX, y: inner.minY),
                         topRight: CGPoint(x: inner.maxX, y: inner.minY),
                         bottomRight: CGPoint(x: inner.maxX, y: inner.maxY),
                         bottomLeft: CGPoint(x: inner.minX, y: inner.maxY))
    }

    /// Signed area doubled, by the shoelace formula. Positive when the corners
    /// wind clockwise in a top-left-origin space.
    public var signedDoubleArea: CGFloat {
        let p = points
        var total: CGFloat = 0
        for i in 0..<4 {
            let a = p[i]
            let b = p[(i + 1) % 4]
            total += a.x * b.y - b.x * a.y
        }
        return total
    }

    public var area: CGFloat { abs(signedDoubleArea) / 2 }

    /// True when the four corners form a strictly convex, non-self-intersecting
    /// quadrilateral — every consecutive edge pair must turn the same way.
    ///
    /// A concave or bow-tie quad has no usable homography: the warped lattice
    /// folds over itself, and the fit it would produce is meaningless. Rejecting
    /// it during the drag is what lets the rest of the pipeline assume a sane
    /// shape.
    public var isConvex: Bool {
        let p = points
        var sawPositive = false
        var sawNegative = false
        for i in 0..<4 {
            let a = p[i]
            let b = p[(i + 1) % 4]
            let c = p[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross > 0 { sawPositive = true }
            if cross < 0 { sawNegative = true }
            if sawPositive && sawNegative { return false }
        }
        // A zero cross everywhere means three or more collinear corners.
        return sawPositive != sawNegative
    }

    /// Every corner translated by the same offset.
    public func translated(by offset: CGSize) -> BoardQuad {
        BoardQuad(points: points.map {
            CGPoint(x: $0.x + offset.width, y: $0.y + offset.height)
        })
    }

    /// True if `point` is inside, by the same winding test used for convexity.
    /// Only meaningful for a convex quad, which is the only kind this type
    /// allows to be committed.
    public func contains(_ point: CGPoint) -> Bool {
        let p = points
        var sawPositive = false
        var sawNegative = false
        for i in 0..<4 {
            let a = p[i]
            let b = p[(i + 1) % 4]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross > 0 { sawPositive = true }
            if cross < 0 { sawNegative = true }
            if sawPositive && sawNegative { return false }
        }
        return true
    }
}

/// The projective map from the unit square onto a quadrilateral.
///
/// Four correspondences determine a homography exactly, so this is closed form
/// (Heckbert's square-to-quad) rather than a least-squares solve — no matrix
/// library, and no dependency on OpenCV from the UI layer. It exists to draw
/// the lattice: grid point (col, row) becomes (col/(n-1), row/(n-1)) in the
/// unit square, and this maps it onto the photo.
public struct QuadHomography: Sendable {
    // [a b c; d e f; g h 1]
    private let a, b, c, d, e, f, g, h: CGFloat

    /// Builds the map taking (0,0)→topLeft, (1,0)→topRight, (1,1)→bottomRight,
    /// (0,1)→bottomLeft. Returns nil for a degenerate quad, whose linear system
    /// has no solution.
    public init?(unitSquareTo quad: BoardQuad) {
        let p0 = quad.topLeft, p1 = quad.topRight
        let p2 = quad.bottomRight, p3 = quad.bottomLeft

        let dx1 = p1.x - p2.x
        let dx2 = p3.x - p2.x
        let dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y
        let dy2 = p3.y - p2.y
        let dy3 = p0.y - p1.y + p2.y - p3.y

        if dx3 == 0 && dy3 == 0 {
            // The quad is a parallelogram: the map is affine, no perspective
            // term. Handled separately because the general branch divides by a
            // determinant that this case leaves at its degenerate form.
            a = p1.x - p0.x
            b = p2.x - p1.x
            c = p0.x
            d = p1.y - p0.y
            e = p2.y - p1.y
            f = p0.y
            g = 0
            h = 0
        } else {
            let denominator = dx1 * dy2 - dx2 * dy1
            guard denominator != 0, denominator.isFinite else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / denominator
            h = (dx1 * dy3 - dx3 * dy1) / denominator
            a = p1.x - p0.x + g * p1.x
            b = p3.x - p0.x + h * p3.x
            c = p0.x
            d = p1.y - p0.y + g * p1.y
            e = p3.y - p0.y + h * p3.y
            f = p0.y
        }

        for value in [a, b, c, d, e, f, g, h] where !value.isFinite {
            return nil
        }
    }

    /// Maps a point of the unit square onto the quad. Returns nil where the
    /// projective denominator vanishes (the map's line at infinity), which a
    /// convex quad never produces inside the unit square but a caller feeding
    /// extrapolated coordinates can.
    public func map(u: CGFloat, v: CGFloat) -> CGPoint? {
        let w = g * u + h * v + 1
        guard w != 0, w.isFinite else { return nil }
        let x = (a * u + b * v + c) / w
        let y = (d * u + e * v + f) / w
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The board's intersections, row-major from the top-left, for a square
    /// board of `size` lines per side. `size` below 2 yields an empty grid —
    /// there is no lattice to draw.
    public func latticePoints(size: Int) -> [[CGPoint]] {
        guard size >= 2 else { return [] }
        let last = CGFloat(size - 1)
        return (0..<size).map { row in
            (0..<size).compactMap { column in
                map(u: CGFloat(column) / last, v: CGFloat(row) / last)
            }
        }
    }
}

/// Hit-testing and drag application for the quad, with the validity rules
/// applied. Mirrors `CropRectEditor`'s shape: classify at drag start, then
/// apply translations to the quad captured AT drag start so they never compound.
public struct BoardQuadEditor: Sendable {

    /// What a drag is manipulating.
    public enum Grab: Equatable, Sendable {
        case corner(BoardCorner)
        case move
    }

    /// The fitted image frame the quad lives in (view points).
    public let bounds: CGRect
    /// Grab radius for the corner handles.
    public let grabRadius: CGFloat
    /// Smallest area the quad may shrink to, as a fraction of `bounds`.
    public let minAreaFraction: CGFloat

    public init(bounds: CGRect, grabRadius: CGFloat = 32, minAreaFraction: CGFloat = 0.02) {
        self.bounds = bounds
        self.grabRadius = grabRadius
        self.minAreaFraction = minAreaFraction
    }

    /// Classifies a drag starting at `point`: the nearest corner within the
    /// grab radius wins, then an interior drag moves the whole quad, and a
    /// start outside every zone is ignored.
    ///
    /// Corners beat interior unconditionally. Placing a corner precisely is the
    /// entire job here, and on a small quad every corner handle is also
    /// "inside" — letting interior win would make the corners ungrabbable
    /// exactly when they matter most.
    public func grab(at point: CGPoint, in quad: BoardQuad) -> Grab? {
        var best: (distance: CGFloat, corner: BoardCorner)?
        for corner in BoardCorner.allCases {
            let p = quad[corner]
            let distance = hypot(point.x - p.x, point.y - p.y)
            if distance <= grabRadius, distance < (best?.distance ?? .infinity) {
                best = (distance, corner)
            }
        }
        if let best { return .corner(best.corner) }
        return quad.contains(point) ? .move : nil
    }

    /// Applies a drag translation to `startQuad`, or returns nil if the result
    /// would be unusable — outside the image, self-intersecting, or collapsed.
    ///
    /// `startQuad` must be the quad at DRAG START (the same value for every
    /// update of one gesture), so translations never compound. Returning nil
    /// rather than a clamped shape lets the view simply keep the last accepted
    /// quad, which reads as the handle refusing to cross rather than as the
    /// whole shape snapping somewhere unexpected.
    public func apply(translation: CGSize, grab: Grab, to startQuad: BoardQuad) -> BoardQuad? {
        var candidate = startQuad
        switch grab {
        case .corner(let corner):
            let start = startQuad[corner]
            candidate[corner] = clampToBounds(CGPoint(x: start.x + translation.width,
                                                      y: start.y + translation.height))
        case .move:
            candidate = startQuad.translated(by: translation)
            // A move is all-or-nothing: clamping individual corners would
            // deform the shape the user is only trying to reposition.
            guard candidate.points.allSatisfy(isInBounds) else { return nil }
        }
        return isUsable(candidate) ? candidate : nil
    }

    /// Whether a quad may be committed: convex, and enclosing enough area to be
    /// a board rather than a stray tap.
    public func isUsable(_ quad: BoardQuad) -> Bool {
        guard quad.isConvex else { return false }
        guard bounds.width > 0, bounds.height > 0 else { return false }
        return quad.area >= bounds.width * bounds.height * minAreaFraction
    }

    private func isInBounds(_ point: CGPoint) -> Bool {
        point.x >= bounds.minX && point.x <= bounds.maxX
            && point.y >= bounds.minY && point.y <= bounds.maxY
    }

    private func clampToBounds(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}

/// Normalized ⇄ view-point conversion for the quad, matching `CropGeometry`'s
/// contract so both speak the same [0,1]² top-left-origin space the ingestion
/// and recognition seams use.
public enum QuadGeometry {

    public static func viewQuad(fromNormalized quad: BoardQuad, in frame: CGRect) -> BoardQuad {
        BoardQuad(points: quad.points.map {
            CGPoint(x: frame.minX + $0.x * frame.width,
                    y: frame.minY + $0.y * frame.height)
        })
    }

    /// A degenerate frame yields the full-frame quad (a safe fallback while
    /// layout is settling), mirroring `CropGeometry.normalizedRect`.
    public static func normalizedQuad(fromView quad: BoardQuad, in frame: CGRect) -> BoardQuad {
        guard frame.width > 0, frame.height > 0 else {
            return BoardQuad.inset(in: CGRect(x: 0, y: 0, width: 1, height: 1), fraction: 0)
        }
        return BoardQuad(points: quad.points.map {
            CGPoint(x: ($0.x - frame.minX) / frame.width,
                    y: ($0.y - frame.minY) / frame.height)
        })
    }

    /// The axis-aligned bounding box of a normalized quad, clamped to the unit
    /// square. This is what the auto-detection fallback crops to when the
    /// user's quad cannot be fitted directly.
    public static func boundingRect(of quad: BoardQuad) -> CGRect {
        let xs = quad.points.map(\.x)
        let ys = quad.points.map(\.y)
        let minX = max(0, xs.min() ?? 0)
        let maxX = min(1, xs.max() ?? 1)
        let minY = max(0, ys.min() ?? 0)
        let maxY = min(1, ys.max() ?? 1)
        return CGRect(x: minX, y: minY,
                      width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
