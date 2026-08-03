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

    // 5x5 board, five moves. Used for the branch-relative (`startIndex`) walk:
    // a branch that diverges after move 2 numbers moves 3..5 as 1..3.
    static let fiveMoveSgf = "(;FF[4]GM[1]SZ[5];B[aa];W[bb];B[cc];W[dd];B[ba])"

    // As fiveMoveSgf but move 4 (index 3) is a pass — inside the branch region.
    static let branchPassMiddleSgf = "(;FF[4]GM[1]SZ[5];B[aa];W[bb];B[cc];W[];B[ba])"

    // As fiveMoveSgf but the final branch move (index 4) is a pass.
    static let branchPassEndSgf = "(;FF[4]GM[1]SZ[5];B[aa];W[bb];B[cc];W[dd];B[])"

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

    @Test func branchRelativeNumbersFromStartIndex() {
        // Divergence after move 2 (startIndex 2): only moves 3..5 are numbered,
        // renumbered 1..3, and the pre-branch stones are absent.
        let result = MoveNumbers.derive(sgf: Self.fiveMoveSgf, currentIndex: 5, startIndex: 2)
        #expect(result.numbers == [point(2, 2): 1, point(3, 3): 2, point(1, 0): 3])
        #expect(result.lastPoint == point(1, 0))
        #expect(result.lastNumber == 3)
    }

    @Test func startIndexZeroMatchesDefault() {
        // startIndex 0 must equal the no-argument call — this pins the Vision
        // stone-fly paths, which derive without the parameter.
        #expect(MoveNumbers.derive(sgf: Self.fiveMoveSgf, currentIndex: 5, startIndex: 0)
                == MoveNumbers.derive(sgf: Self.fiveMoveSgf, currentIndex: 5))
        #expect(MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 2, startIndex: 0)
                == MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 2))
    }

    @Test func startIndexAtOrPastCurrentIndexIsEmpty() {
        #expect(MoveNumbers.derive(sgf: Self.fiveMoveSgf, currentIndex: 3, startIndex: 3) == .empty)
        #expect(MoveNumbers.derive(sgf: Self.fiveMoveSgf, currentIndex: 3, startIndex: 4) == .empty)
    }

    @Test func passInsideBranchConsumesARelativeNumber() {
        // Move 4 (index 3) is a pass: skipped from `numbers` but it still
        // advances the relative count, so the next stone is number 3.
        let result = MoveNumbers.derive(sgf: Self.branchPassMiddleSgf, currentIndex: 5, startIndex: 2)
        #expect(result.numbers == [point(2, 2): 1, point(1, 0): 3])
        #expect(result.lastPoint == point(1, 0))
        #expect(result.lastNumber == 3)
    }

    @Test func branchEndingInPassClearsLastPoint() {
        let result = MoveNumbers.derive(sgf: Self.branchPassEndSgf, currentIndex: 5, startIndex: 2)
        #expect(result.numbers == [point(2, 2): 1, point(3, 3): 2])
        #expect(result.lastPoint == nil)
        #expect(result.lastNumber == nil)
    }

    @Test func negativeStartIndexTreatedAsZero() {
        #expect(MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 3, startIndex: -5)
                == MoveNumbers.derive(sgf: Self.threeMoveSgf, currentIndex: 3))
    }

    /// The O(1) accessor must agree with the full walk at EVERY index of
    /// several games, including the pass and recapture SGFs — it is the whole
    /// justification for reading one move instead of the mainline.
    @Test(arguments: [threeMoveSgf, recaptureSgf, passSgf, fiveMoveSgf])
    func lastPlayedVertexMatchesTheFullDerivation(sgf: String) {
        let helper = SgfHelper(sgf: sgf)
        for index in 0...6 {
            let derived = MoveNumbers.derive(sgf: sgf, currentIndex: index).lastPoint
            let expected = derived.flatMap {
                BoardPoint.toString([$0], width: helper.xSize, height: helper.ySize)
            }
            #expect(MoveNumbers.lastPlayedVertex(sgf: sgf, currentIndex: index) == expected,
                    "index \(index)")
        }
    }

    /// `startIndex` rebases the NUMBERING only. Which move is last is a
    /// property of the position, so branch mode must not change it.
    @Test func lastPlayedVertexIgnoresBranchRebasing() {
        let helper = SgfHelper(sgf: Self.fiveMoveSgf)
        for start in [0, 2, 4] {
            let derived = MoveNumbers.derive(sgf: Self.fiveMoveSgf,
                                             currentIndex: 5, startIndex: start).lastPoint
            let expected = derived.flatMap {
                BoardPoint.toString([$0], width: helper.xSize, height: helper.ySize)
            }
            #expect(MoveNumbers.lastPlayedVertex(sgf: Self.fiveMoveSgf, currentIndex: 5) == expected)
        }
    }

    /// A pass has no point to mark, matching the board's own marker.
    @Test func lastPlayedVertexIsNilForAPassAndForTheStart() {
        #expect(MoveNumbers.lastPlayedVertex(sgf: Self.passSgf, currentIndex: 2) == nil)
        #expect(MoveNumbers.lastPlayedVertex(sgf: Self.threeMoveSgf, currentIndex: 0) == nil)
        // An index past the end of the mainline clamps to the final move,
        // matching `derive`, rather than reporting "no last move".
        #expect(MoveNumbers.lastPlayedVertex(sgf: Self.threeMoveSgf, currentIndex: 99) == "C3")
    }

    @Test func styleStringsMatchEnumOrder() {
        #expect(Config.moveNumberStyles.count == 4)
        #expect(Config.moveNumberStyles[MoveNumberStyle.lastThreeMoves.rawValue] == Config.lastThreeMovesNumberStyle)
        #expect(Config.moveNumberStyles[MoveNumberStyle.lastMove.rawValue] == Config.lastMoveNumberStyle)
        #expect(Config.moveNumberStyles[MoveNumberStyle.allMoves.rawValue] == Config.allMovesNumberStyle)
        #expect(Config.moveNumberStyles[MoveNumberStyle.lastMoveMarker.rawValue] == Config.lastMoveMarkerNumberStyle)
    }
}
