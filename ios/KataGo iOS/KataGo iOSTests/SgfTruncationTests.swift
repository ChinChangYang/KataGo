//
//  SgfTruncationTests.swift
//  KataGo AnytimeTests
//

import Testing
import KataGoInterface
@testable import KataGo_Anytime
@testable import KataGoUICore

struct SgfTruncationTests {
    static let fourMoves = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"

    @Test func truncatesToTwoMoves() {
        let r = SgfTruncation.truncate(Self.fourMoves, toMoveCount: 2)
        #expect(r == "(;FF[4]GM[1]SZ[9];B[aa];W[bb])")
        #expect(SgfHelper(sgf: r).moveSize == 2)
    }

    @Test func truncatesToZeroKeepsOnlyRoot() {
        let r = SgfTruncation.truncate(Self.fourMoves, toMoveCount: 0)
        #expect(r == "(;FF[4]GM[1]SZ[9])")
        #expect(SgfHelper(sgf: r).moveSize == 0)
    }

    @Test func fullCountReturnsUnchanged() {
        #expect(SgfTruncation.truncate(Self.fourMoves, toMoveCount: 4) == Self.fourMoves)
    }

    @Test func countBeyondMovesReturnsUnchanged() {
        #expect(SgfTruncation.truncate(Self.fourMoves, toMoveCount: 10) == Self.fourMoves)
    }

    @Test func semicolonInsideCommentDoesNotShiftCut() {
        // The ';' inside C[...] must not be counted as a node delimiter.
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa]C[hi; there];W[bb];B[cc])"
        let r = SgfTruncation.truncate(sgf, toMoveCount: 1)
        #expect(r == "(;FF[4]GM[1]SZ[9];B[aa]C[hi; there])")
        #expect(SgfHelper(sgf: r).moveSize == 1)
    }

    @Test func passMoveIsCounted() {
        // W[] is a pass; truncate-to-2 keeps B[aa] and the pass.
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[];B[cc])"
        let r = SgfTruncation.truncate(sgf, toMoveCount: 2)
        #expect(r == "(;FF[4]GM[1]SZ[9];B[aa];W[])")
        #expect(SgfHelper(sgf: r).moveSize == 2)
    }
}
