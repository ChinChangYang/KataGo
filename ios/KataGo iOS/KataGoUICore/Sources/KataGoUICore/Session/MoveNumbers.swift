//
//  MoveNumbers.swift
//  KataGo iOS
//

import Foundation
import KataGoInterface

/// How the board annotates move numbers. Raw values index
/// `Config.moveNumberStyles` (the picker's display strings) — keep the two in
/// the same order.
public enum MoveNumberStyle: Int {
    case lastThreeMoves = 0
    case lastMove = 1
    case allMoves = 2
    case lastMoveMarker = 3
}

/// Absolute move numbers derived from the active game's SGF, independent of
/// the engine's showboard markers. When the same point is played more than
/// once (ko, recapture), the latest move number wins. `lastPoint`/`lastNumber`
/// are nil when no move was played or the last move was a pass.
public struct MoveNumbers: Equatable, Sendable {
    public let numbers: [BoardPoint: Int]
    public let lastPoint: BoardPoint?
    public let lastNumber: Int?

    public static let empty = MoveNumbers(numbers: [:], lastPoint: nil, lastNumber: nil)

    public static func derive(sgf: String, currentIndex: Int) -> MoveNumbers {
        let sgfHelper = SgfHelper(sgf: sgf)
        let width = sgfHelper.xSize
        let height = sgfHelper.ySize
        var numbers: [BoardPoint: Int] = [:]
        var lastPoint: BoardPoint?
        var lastNumber: Int?
        var index = 0

        while index < currentIndex, let move = sgfHelper.getMove(at: index) {
            let number = index + 1
            if move.location.pass {
                lastPoint = nil
                lastNumber = nil
            } else {
                let point = BoardPoint(location: move.location, width: width, height: height)
                numbers[point] = number
                lastPoint = point
                lastNumber = number
            }
            index += 1
        }

        return MoveNumbers(numbers: numbers, lastPoint: lastPoint, lastNumber: lastNumber)
    }
}
