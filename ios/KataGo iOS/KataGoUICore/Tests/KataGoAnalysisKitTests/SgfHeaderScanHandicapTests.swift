//
//  SgfHeaderScanHandicapTests.swift
//  KataGoAnalysisKitTests
//
//  Locks in the PL[] override and the all-black-setup fallback that let
//  toMove(atMoveIndex:) name White to move for a fresh, moveless handicap
//  root — mirroring the C++ engine's CompactSgf::setupInitialBoardAndHist.
//

import Testing
@testable import KataGoAnalysisKit

struct SgfHeaderScanHandicapTests {
    @Test("PL[W] on a zero-move handicap root reads White to move")
    func plOverrideWhite() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;FF[4]GM[1]SZ[19]HA[2]AB[pd][dp]PL[W]KM[0.5]RU[japanese])"))
        #expect(scan.nextPlayerOverride == .white)
        #expect(scan.toMove(atMoveIndex: 0) == .white)
    }

    @Test("all-black setup implies White even without PL (engine parity)")
    func allBlackSetupImpliesWhite() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19]AB[pd][dp])"))
        #expect(scan.nextPlayerOverride == nil)
        #expect(scan.toMove(atMoveIndex: 0) == .white)
    }

    @Test("PL[B] wins over the setup rule")
    func plBlackWins() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19]AB[pd]PL[B])"))
        #expect(scan.toMove(atMoveIndex: 0) == .black)
    }

    @Test("plain empty and mixed-setup boards still open with Black")
    func plainStillBlack() throws {
        let empty = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19])"))
        #expect(empty.toMove(atMoveIndex: 0) == .black)
        let mixed = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19]AB[pd]AW[dp])"))
        #expect(mixed.toMove(atMoveIndex: 0) == .black)
    }

    /// The exact shape `gobanToSgf` emits for an OGS handicap game (ADR
    /// 0017): setup stones and PL[] on the root, then the main line. The two
    /// sides of the extension have to agree about how many moves that is and
    /// who is to move where, and nothing but a fixture says so.
    @Test("an OGS-shaped handicap root scans as White to move")
    func ogsShapedHandicapRoot() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]FF[4]CA[UTF-8]SZ[19]PB[Kuro]PW[Shiro]KM[0.5]RU[japanese]"
               + "HA[2]PL[W]AB[pd][dp];W[dd];B[pp];W[])"))
        #expect(scan.boardWidth == 19)
        #expect(scan.boardHeight == 19)
        #expect(scan.komi == 0.5)
        #expect(scan.rules == "japanese")
        #expect(scan.setupBlack.count == 2)
        #expect(scan.setupWhite.isEmpty)
        // A pass is a move: three of them, and the side to move alternates
        // across it exactly as the colors on the nodes say.
        #expect(scan.moveCount == 3)
        #expect(scan.toMove(atMoveIndex: 0) == .white)
        #expect(scan.toMove(atMoveIndex: 1) == .black)
        #expect(scan.toMove(atMoveIndex: 2) == .white)
        #expect(scan.toMove(atMoveIndex: 3) == .black)
    }

    @Test("moves still govern when present")
    func movesStillGovern() throws {
        // The mainline records White playing first (consistent with PL[W]
        // here), so moveColors[0] — not the PL/setup fallback — answers.
        let scan = try #require(SgfHeaderScan(
            sgf: "(;FF[4]GM[1]SZ[19]HA[2]AB[pd][dp]PL[W];W[dd])"))
        #expect(scan.toMove(atMoveIndex: 0) == .white)
    }
}
