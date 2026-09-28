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

    /// KataGo reads PL[] off the root node alone, and the board's replay
    /// takes it from the scan too, so a PL[] on a later node (legal SGF, for
    /// the side to move at that node) must not decide the start.
    @Test("PL[] counts on the root only")
    func plIsReadOffTheRootOnly() throws {
        let later = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[9]AB[cc]AW[gg];C[hint]PL[W])"))
        #expect(later.nextPlayerOverride == nil)
        #expect(later.toMove(atMoveIndex: 0) == .black)

        let root = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[9]AB[cc]AW[gg]PL[w];C[hint])"))
        #expect(root.nextPlayerOverride == .white)
    }

    /// KataGo reads PL[] as a single value, and its parser collects every
    /// root PL[] into one list: two values name no side there, so none here.
    @Test("a root PL[] with more than one value names no side")
    func plWithSeveralValuesNamesNoSide() throws {
        for sgf in ["(;FF[4]GM[1]SZ[9]PL[B][x]AB[cc][gg])",
                    "(;FF[4]GM[1]SZ[9]PL[W]AB[cc]PL[B])"] {
            let scan = try #require(SgfHeaderScan(sgf: sgf))
            #expect(scan.nextPlayerOverride == nil, "\(sgf)")
            #expect(scan.toMove(atMoveIndex: 0) == .white, "\(sgf)")
        }
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
