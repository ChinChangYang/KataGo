//
//  WidgetBoardGeometry.swift
//  KataGoGameStore
//
//  THE grid layout for `WidgetBoardView` — one source of truth for where the
//  intersections land.
//
//  This exists because the layout has two consumers that MUST agree: the
//  renderer, and any interactive host that hit-tests taps against the drawn
//  grid (the Messages extension). They used to compute it separately, and the
//  copy silently assumed margin 0 — correct only while coordinates were off.
//  Turning labels on shifts both `cell` and the origin, so the copy would have
//  put every tap on the wrong intersection. Deriving both from this type makes
//  that class of bug unrepresentable.
//

import CoreGraphics

public struct WidgetBoardGeometry: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let size: CGSize
    /// Whether coordinate labels are actually drawn: requested AND legible at
    /// this pitch. When false the margin is 0 and the geometry is
    /// byte-identical to the original no-labels layout.
    public let showsLabels: Bool
    public let cell: CGFloat
    public let originX: CGFloat
    public let originY: CGFloat

    /// The band reserved outside the outermost lines for coordinate labels.
    public static let coordinateMarginRatio: CGFloat = 0.06

    public init(width: Int, height: Int, size: CGSize, showCoordinates: Bool = false) {
        let w = max(width, 1)
        let h = max(height, 1)
        self.width = w
        self.height = h
        self.size = size

        let fits = WidgetBoardGeometry.coordinateLabelsFit(size: size, width: w, height: h)
        let showsLabels = showCoordinates && fits
        self.showsLabels = showsLabels

        let margin = showsLabels
            ? min(size.width, size.height) * WidgetBoardGeometry.coordinateMarginRatio
            : 0
        let availableWidth = size.width - 2 * margin
        let availableHeight = size.height - 2 * margin
        let cell = min(availableWidth / CGFloat(w), availableHeight / CGFloat(h))
        self.cell = cell
        self.originX = (size.width - cell * CGFloat(w - 1)) / 2
        self.originY = (size.height - cell * CGFloat(h - 1)) / 2
    }

    /// Center of the intersection at 0-based grid coordinates.
    public func position(x: Int, y: Int) -> CGPoint {
        CGPoint(x: originX + CGFloat(x) * cell, y: originY + CGFloat(y) * cell)
    }

    /// The intersection nearest `location`, or nil when the point resolves off
    /// the board. Rounds to the nearest line in both axes, so the whole cell
    /// around an intersection is a target.
    public func gridPoint(at location: CGPoint) -> (x: Int, y: Int)? {
        guard cell > 0 else { return nil }
        let x = Int(((location.x - originX) / cell).rounded())
        let y = Int(((location.y - originY) / cell).rounded())
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return (x: x, y: y)
    }

    /// Whether coordinate labels render INTACT for a `width` x `height` board
    /// drawn into `size`. The appGoban label is clipped to a cell-sized frame,
    /// so once the cell pitch falls under the widest label's width at the font
    /// floor the text truncates — and at these sizes it does not even keep a
    /// leading digit: a 19x19 in the small widget families drew a bare "…" in
    /// place of every row number 10-19, i.e. two columns of dots down the sides
    /// of the board. The unclipped styles smear into their neighbours over the
    /// same range. Below the threshold the board renders as if coordinates were
    /// off, margin included, so the stones get the space back.
    ///
    /// Deliberately style-blind: it applies the strictest style's metrics
    /// (bold, clipped) everywhere, which costs ~8% against the unbolded styles
    /// and keeps iOS, macOS, and visionOS hiding coordinates in the same cases.
    public static func coordinateLabelsFit(size: CGSize, width: Int, height: Int) -> Bool {
        let margin = min(size.width, size.height) * coordinateMarginRatio
        let cell = min((size.width - 2 * margin) / CGFloat(width),
                       (size.height - 2 * margin) / CGFloat(height))
        return cell >= WidgetCoordinateMetrics.requiredCell(width: width, height: height)
    }
}
