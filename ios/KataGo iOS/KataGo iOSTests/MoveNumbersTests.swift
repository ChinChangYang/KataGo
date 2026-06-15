//
//  MoveNumbersTests.swift
//  KataGo AnytimeTests
//

import Testing
import KataGoUICore
@testable import KataGo_Anytime
@testable import KataGoUICore

struct MoveNumbersTests {
    // 5x5 board, three moves: B top-left, W b-b, B c-c.
    static let threeMoveSgf = "(;FF[4]GM[1]SZ[5];B[aa];W[bb];B[cc])"

    // Move 2 (W at the top-left corner) is captured by B move 3 and the corner
    // is refilled by B as move 5 — one board point hosts two move numbers.
    static let recaptureSgf = "(;FF[4]GM[1]SZ[5];B[ab];W[aa];B[ba];W[cc];B[aa])"

    // Move 2 (W) is a pass.
    static let passSgf = "(;FF[4]GM[1]SZ[5];B[aa];W[];B[cc])"

    // Build expected points through the same Location->BoardPoint converter
    // the implementation uses, so tests don't re-encode the y-flip convention.
    private func point(_ x: Int, _ y: Int) -> BoardPoint {
        BoardPoint(location: Location(x: x, y: y), width: 5, height: 5)
    }

    @Test func allMovesAreNumbered() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 3)
        #expect(result.numbers == [point(0, 0): 1, point(1, 1): 2, point(2, 2): 3])
        #expect(result.lastPoint == point(2, 2))
        #expect(result.lastNumber == 3)
    }

    @Test func indexLimitsNumbering() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 2)
        #expect(result.numbers == [point(0, 0): 1, point(1, 1): 2])
        #expect(result.lastPoint == point(1, 1))
        #expect(result.lastNumber == 2)
    }

    @Test func indexPastMoveListStopsAtLastMove() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 99)
        #expect(result.numbers.count == 3)
        #expect(result.lastNumber == 3)
    }

    @Test func zeroIndexYieldsEmptyResult() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 0)
        #expect(result == .empty)
    }

    @Test func invalidSgfYieldsEmptyResult() {
        let result = MoveNumbers.derive(sgf: "not an sgf", currentIndex: 5)
        #expect(result == .empty)
    }

    @Test func replayedPointShowsLatestNumber() {
        let result = MoveNumbers.derive(sgf: Self.recaptureSgf, currentIndex: 5)
        #expect(result.numbers[point(0, 0)] == 5)
        #expect(result.numbers.count == 4)
        #expect(result.lastPoint == point(0, 0))
        #expect(result.lastNumber == 5)
    }

    @Test func passMovesAreSkipped() {
        let result = MoveNumbers.derive(sgf: Self.passSgf, currentIndex: 3)
        #expect(result.numbers == [point(0, 0): 1, point(2, 2): 3])
        #expect(result.lastNumber == 3)
    }

    @Test func passAsLastMoveClearsLastPoint() {
        let result = MoveNumbers.derive(sgf: Self.passSgf, currentIndex: 2)
        #expect(result.numbers == [point(0, 0): 1])
        #expect(result.lastPoint == nil)
        #expect(result.lastNumber == nil)
    }

    @Test func coordinateConventionAnchor() {
        // SGF "aa" is the TOP-left corner; BoardPoint y is 0-indexed from the
        // bottom, so on a 5x5 board it maps to y = 4.
        #expect(point(0, 0) == BoardPoint(x: 0, y: 4))
    }

    @Test func negativeIndexYieldsEmptyResult() {
        let result = MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: -1)
        #expect(result == .empty)
    }

    @Test func styleStringsMatchEnumOrder() {
        #expect(Config.moveNumberStyles.count == 4)
        #expect(Config.moveNumberStyles[MoveNumberStyle.lastThreeMoves.rawValue] == Config.lastThreeMovesNumberStyle)
        #expect(Config.moveNumberStyles[MoveNumberStyle.lastMove.rawValue] == Config.lastMoveNumberStyle)
        #expect(Config.moveNumberStyles[MoveNumberStyle.allMoves.rawValue] == Config.allMovesNumberStyle)
        #expect(Config.moveNumberStyles[MoveNumberStyle.lastMoveMarker.rawValue] == Config.lastMoveMarkerNumberStyle)
    }
}
