//
//  BoardSceneGeometry.swift
//  KataGoUICore
//
//  Maps engine board points to 3D world positions and back. Orientation:
//  viewer at the volume front (+Z), GTP row 1 nearest the viewer, column A
//  on the viewer's left (-X), so grid i = BoardPoint.x and grid
//  j = BoardPoint.y (identity on both axes).
//

import Foundation

public struct BoardSceneGeometry: Sendable {
    public let width: Int
    public let height: Int
    public let topY: Float

    /// Convenience for square-only call sites (equals `width`).
    public var size: Int { width }

    /// Row-major: index = point.y * width + point.x.
    private let positions: [SIMD3<Float>]
    private let originX: Float
    private let frontZ: Float
    private let stepX: Float
    private let stepZ: Float

    /// Analytic construction from BoardGeometryRules (any 2...37 rectangle).
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let top = BoardGeometryRules.dimensions(width: width, height: height).topY
        topY = Float(top)
        var built: [SIMD3<Float>] = []
        built.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                built.append(BoardGeometryRules.intersection(
                    x: x, y: y, width: width, height: height, topY: top))
            }
        }
        positions = built
        let first = positions[0]
        originX = first.x
        frontZ = first.z
        stepX = Float(BoardGeometryRules.spacingX)
        stepZ = -Float(BoardGeometryRules.spacingZ)
    }

    public init(entry: BoardAssetManifest.BoardEntry) {
        width = entry.n
        height = entry.n
        topY = Float(entry.topY)
        positions = entry.intersections.flatMap { row in
            row.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) }
        }
        let first = positions[0]
        originX = first.x
        frontZ = first.z
        if entry.n > 1 {
            stepX = (positions[entry.n - 1].x - first.x) / Float(entry.n - 1)
            stepZ = (positions[(entry.n - 1) * entry.n].z - first.z) / Float(entry.n - 1)
        } else {
            stepX = 1
            stepZ = -1
        }
    }

    public func position(of point: BoardPoint) -> SIMD3<Float>? {
        guard point.x >= 0, point.x < width, point.y >= 0, point.y < height else { return nil }
        return positions[point.y * width + point.x]
    }

    /// Nearest intersection to a world-space (x, z), clamped onto the board.
    public func nearestPoint(toX x: Float, z: Float) -> BoardPoint {
        let column = ((x - originX) / stepX).rounded()
        let row = ((z - frontZ) / stepZ).rounded()
        return BoardPoint(
            x: min(max(Int(column), 0), width - 1),
            y: min(max(Int(row), 0), height - 1)
        )
    }

    /// GTP vertex string ("A1", "J9", ...); the letter I is skipped.
    public func vertex(for point: BoardPoint) -> String? {
        guard point.x >= 0, point.x < width, point.y >= 0, point.y < height else { return nil }
        return Coordinate.xLabelMap[point.x].map { "\($0)\(point.y + 1)" }
    }
}
