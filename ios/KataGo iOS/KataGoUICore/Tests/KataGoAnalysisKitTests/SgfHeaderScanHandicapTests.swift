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

    @Test("moves still govern when present")
    func movesStillGovern() throws {
        // The mainline records White playing first (consistent with PL[W]
        // here), so moveColors[0] — not the PL/setup fallback — answers.
        let scan = try #require(SgfHeaderScan(
            sgf: "(;FF[4]GM[1]SZ[19]HA[2]AB[pd][dp]PL[W];W[dd])"))
        #expect(scan.toMove(atMoveIndex: 0) == .white)
    }
}
