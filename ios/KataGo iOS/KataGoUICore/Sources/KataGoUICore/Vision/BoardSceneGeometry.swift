//
//  BoardSceneGeometry.swift
//  KataGoUICore
//
//  Maps engine board points to 3D world positions and back. Orientation:
//  viewer at the volume front (+Z), GTP row 1 nearest the viewer, column A
//  on the viewer's left (-X), so manifest i = BoardPoint.x and
//  manifest j = BoardPoint.y (identity on both axes).
//

import Foundation

public struct BoardSceneGeometry: Sendable {
    public let size: Int
    public let topY: Float

    /// Row-major: index = point.y * size + point.x.
    private let positions: [SIMD3<Float>]
    private let originX: Float
    private let frontZ: Float
    private let stepX: Float
    private let stepZ: Float

    public init(entry: BoardAssetManifest.BoardEntry) {
        size = entry.n
        topY = Float(entry.topY)
        positions = entry.intersections.flatMap { row in
            row.map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) }
        }
        let first = positions[0]
        originX = first.x
        frontZ = first.z
        if size > 1 {
            stepX = (positions[size - 1].x - first.x) / Float(size - 1)
            stepZ = (positions[(size - 1) * size].z - first.z) / Float(size - 1)
        } else {
            stepX = 1
            stepZ = -1
        }
    }

    public func position(of point: BoardPoint) -> SIMD3<Float>? {
        guard point.x >= 0, point.x < size, point.y >= 0, point.y < size else { return nil }
        return positions[point.y * size + point.x]
    }

    /// Nearest intersection to a world-space (x, z), clamped onto the board.
    public func nearestPoint(toX x: Float, z: Float) -> BoardPoint {
        let column = ((x - originX) / stepX).rounded()
        let row = ((z - frontZ) / stepZ).rounded()
        return BoardPoint(
            x: min(max(Int(column), 0), size - 1),
            y: min(max(Int(row), 0), size - 1)
        )
    }

    /// GTP vertex string ("A1", "J9", ...); the letter I is skipped.
    public func vertex(for point: BoardPoint) -> String? {
        guard point.x >= 0, point.x < size, point.y >= 0, point.y < size else { return nil }
        return Coordinate.xLabelMap[point.x].map { "\($0)\(point.y + 1)" }
    }
}
