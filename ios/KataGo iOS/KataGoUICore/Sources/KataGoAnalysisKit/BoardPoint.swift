//
//  BoardPoint.swift
//  KataGoAnalysisKit
//
//  Core board-point value type, moved verbatim from KataGoUICore's
//  KataGoModel.swift so the bridge-free analysis tier can address board
//  intersections. The UI-facing helpers (position math, Location bridging,
//  GTP-vertex serialization) remain in KataGoUICore as extensions.
//

import Foundation

public struct BoardPoint: Hashable, Comparable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public func isPass(width: Int, height: Int) -> Bool {
        self == BoardPoint.pass(width: width, height: height)
    }

    public static func passY(height: Int) -> Int {
        return height + 1
    }

    public static func pass(width: Int, height: Int) -> BoardPoint {
        return BoardPoint(x: width - 1, y: passY(height: height))
    }

    public static func < (lhs: BoardPoint, rhs: BoardPoint) -> Bool {
        return (lhs.y, lhs.x) < (rhs.y, rhs.x)
    }
}
