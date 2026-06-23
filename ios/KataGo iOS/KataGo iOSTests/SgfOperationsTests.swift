//
//  SgfOperationsTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGoUICore

struct SgfOperationsTests {
    private let sgf = "(;FF[4]GM[1]SZ[19]KM[6.5];B[pd];W[dp])"

    @Test func mirrorsSgfHelperForBasics() {
        let ops = SgfOperations(sgf: sgf)
        let ref = SgfHelper(sgf: sgf)
        #expect(ops.moveSize == ref.moveSize)
        #expect(ops.xSize == ref.xSize)
        #expect(ops.ySize == ref.ySize)
        #expect(ops.getMove(at: 0)?.location.x == ref.getMove(at: 0)?.location.x)
        #expect(ops.rules.komi == ref.rules.komi)
    }

    // MARK: - finalStones (F2: feed the Saved Game widget an imported game's position)

    @Test func finalStones_plainGame_returnsStonesOnBoard() {
        let ops = SgfOperations(sgf: "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        let final = ops.finalStones()
        #expect(final.black == ["D16"])
        #expect(final.white == ["Q4"])
    }

    @Test func finalStones_capturedStoneIsRemoved() {
        // Black's corner stone (A9) is captured once White holds B9 and A8.
        let ops = SgfOperations(sgf: "(;FF[4]GM[1]SZ[9];B[aa];W[ba];B[gg];W[ab])")
        let final = ops.finalStones()
        #expect(final.black == ["G3"])               // only the far stone survives
        #expect(!final.black.contains("A9"))         // captured stone is gone
        #expect(final.white.sorted() == ["A8", "B9"])
    }

    @Test func finalStones_includesHandicapSetupStones() {
        // AB setup stones, no played moves: the position IS the handicap stones.
        let ops = SgfOperations(sgf: "(;FF[4]GM[1]SZ[19]AB[pd][dp])")
        let final = ops.finalStones()
        #expect(final.black.sorted() == ["D4", "Q16"])
        #expect(final.white.isEmpty)
    }

    @Test func finalStones_invalidSgf_returnsEmpty() {
        let final = SgfOperations(sgf: "not a real sgf").finalStones()
        #expect(final.black.isEmpty)
        #expect(final.white.isEmpty)
    }

    @Test func finalStones_oversizedBoard_returnsEmptyWithoutCrashing() {
        // A board larger than the compiled MAX_LEN (37) must degrade gracefully,
        // never abort the import by asserting inside the C++ Board.
        let final = SgfOperations(sgf: "(;FF[4]GM[1]SZ[40];B[aa])").finalStones()
        #expect(final.black.isEmpty)
        #expect(final.white.isEmpty)
    }
}
