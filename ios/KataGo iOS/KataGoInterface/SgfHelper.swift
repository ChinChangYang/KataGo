//
//  SgfHelper.swift
//  KataGoInterface
//
//  Created by Chin-Chang Yang on 2024/7/8.
//

import Foundation

public struct Location {
    public let x: Int
    public let y: Int
    public let pass: Bool

    public init() {
        self.x = -1
        self.y = -1
        self.pass = true
    }

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
        self.pass = false
    }
}

public enum Player {
    case black
    case white
}

public struct Move {
    public let location: Location
    public let player: Player

    public init(location: Location, player: Player) {
        self.location = location
        self.player = player
    }
}

public class SgfHelper {
    let sgfCpp: SgfCpp

    public init(sgf: String) {
        sgfCpp = SgfCpp(std.string(sgf))
    }

    public func getMove(at index: Int) -> Move? {
        guard sgfCpp.isValidMoveIndex(Int32(index)) else { return nil }
        let moveCpp = sgfCpp.getMoveAt(Int32(index))
        let location = moveCpp.pass ? Location() : Location(x: Int(moveCpp.x), y: Int(moveCpp.y))
        let player: Player = (moveCpp.player == PlayerCpp.black) ? .black : .white
        return Move(location: location, player: player)
    }

    public func getComment(at index: Int) -> String? {
        guard sgfCpp.isValidCommentIndex(Int32(index)) else { return nil }
        let commentCpp = sgfCpp.getCommentAt(Int32(index))
        return String(commentCpp)
    }

    public func getLastMoveIndex() -> Int? {
        return ((sgfCpp.valid) && (sgfCpp.movesSize > 0)) ? Int(sgfCpp.movesSize - 1) : nil
    }
}
