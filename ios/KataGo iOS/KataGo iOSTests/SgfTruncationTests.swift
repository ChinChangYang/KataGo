//
//  SgfTruncationTests.swift
//  KataGo AnytimeTests
//

import Testing
import KataGoUICore
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

    @Test func rootPlayerIsAddedAfterTheRootsSemicolon() {
        let r = SgfTruncation.withRootPlayer(.white, in: "(;FF[4]GM[1]SZ[9]AB[cc]AW[gg])")
        #expect(r == "(;PL[W]FF[4]GM[1]SZ[9]AB[cc]AW[gg])")
        #expect(SgfHelper(sgf: r).initialPlayer == .white)
    }

    /// Only the root's PL[] is replaced, every value of it, and brackets are
    /// honoured: text in a comment, or a later node's PL[], stays.
    @Test func rootPlayerReplacesOnlyTheRootsPL() {
        let sgf = "(;FF[4]C[set PL\\] here]PL[B][x]SZ[9]AB[cc];PL[B])"
        let r = SgfTruncation.withRootPlayer(.white, in: sgf)
        #expect(r == "(;FF[4]C[set PL\\] here]PL[W]SZ[9]AB[cc];PL[B])")
        #expect(SgfHelper(sgf: r).initialPlayer == .white)
    }

    /// Property names read as KataGo's parser reads them: whitespace may sit
    /// before a value, and a repeated root PL[] adds values to one list. The
    /// result must hold exactly one root PL[] value, or KataGo reads none.
    @Test func rootPlayerReplacesEveryRootPLTheParserReads() {
        let spaced = SgfTruncation.withRootPlayer(.white, in: "(;FF[4]SZ[9]AB[cc]AW[gg]PL\n[B])")
        #expect(spaced == "(;FF[4]SZ[9]AB[cc]AW[gg]PL[W])")
        #expect(SgfHelper(sgf: spaced).initialPlayer == .white)

        let repeated = SgfTruncation.withRootPlayer(.black, in: "(;PL[W]SZ[9]AB[cc]PL[W]AW[gg])")
        #expect(repeated == "(;PL[B]SZ[9]AB[cc]AW[gg])")
        #expect(SgfHelper(sgf: repeated).initialPlayer == .black)
    }

    @Test func rootPlayerLeavesTextWithNoRootAlone() {
        #expect(SgfTruncation.withRootPlayer(.white, in: "not an sgf") == "not an sgf")
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
