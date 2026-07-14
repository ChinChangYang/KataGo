//
//  BoardStarPoints.swift
//  KataGoGameStore
//
//  The one star-point (hoshi) rule shared by every board renderer: the 2D
//  boards (BoardLineView, WidgetBoardView) and the visionOS generated
//  board-top texture. Lives in KataGoGameStore because it is the lowest
//  package in the dependency graph that all of them can import.
//
//  Per axis (0-indexed lines, length m): odd m >= 15 gets corner lines at
//  edge distance 3 plus the center ("full" axis, side stars allowed); odd
//  7...13 gets corners (distance 3 for 13, else 2) plus the center; 5 gets
//  the center only; even or < 5 gets nothing. Points are the corner cross
//  product, plus the center when both axes have one, plus mixed
//  corner-center side stars only when BOTH axes are full - which reproduces
//  the classic layouts exactly: five points on 9x9 and 13x13 (the 2D
//  convention, chosen over the asset pipeline's nine for 13x13) and the
//  full 3x3 grid on 19x19.
//

public enum BoardStarPoints {
    private struct AxisLines {
        let corners: [Int]
        let center: Int?
        let isFull: Bool
    }

    private static func axisLines(_ m: Int) -> AxisLines {
        guard m >= 5, m % 2 == 1 else { return AxisLines(corners: [], center: nil, isFull: false) }
        let center = (m - 1) / 2
        guard m > 5 else { return AxisLines(corners: [], center: center, isFull: false) }
        let edge = m >= 13 ? 3 : 2
        return AxisLines(corners: [edge, m - 1 - edge], center: center, isFull: m >= 15)
    }

    /// 0-based grid coordinates of the star points for a `width` x `height`
    /// board, sorted by (x, y). Pure, so it is callable from any actor.
    public static func points(width: Int, height: Int) -> [(x: Int, y: Int)] {
        let xAxis = axisLines(width)
        let yAxis = axisLines(height)
        var points: [(x: Int, y: Int)] = []
        for x in xAxis.corners {
            for y in yAxis.corners {
                points.append((x, y))
            }
        }
        if let centerX = xAxis.center, let centerY = yAxis.center {
            points.append((centerX, centerY))
        }
        if xAxis.isFull && yAxis.isFull {
            if let centerX = xAxis.center {
                for y in yAxis.corners {
                    points.append((centerX, y))
                }
            }
            if let centerY = yAxis.center {
                for x in xAxis.corners {
                    points.append((x, centerY))
                }
            }
        }
        return points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    }
}
