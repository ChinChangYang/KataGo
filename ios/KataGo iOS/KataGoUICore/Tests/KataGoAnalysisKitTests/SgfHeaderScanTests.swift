//
//  SgfHeaderScanTests.swift
//  KataGoAnalysisKitTests
//
//  Locks in the engine-free SGF root/mainline scan the Safari extension uses
//  to answer `start` before the engine boots.
//

import Foundation
import Testing
@testable import KataGoAnalysisKit

struct SgfHeaderScanTests {
    @Test func readsSquareSizeKomiRulesAndMoves() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]FF[4]SZ[19]KM[7.5]RU[Chinese];B[pd];W[dp];B[qp])"))
        #expect(scan.boardWidth == 19)
        #expect(scan.boardHeight == 19)
        #expect(scan.komi == 7.5)
        #expect(scan.rules == "Chinese")
        #expect(scan.moveColors == [.black, .white, .black])
        #expect(scan.moveCount == 3)
    }

    @Test func readsRectangularSize() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[19:9];B[aa])"))
        #expect(scan.boardWidth == 19)
        #expect(scan.boardHeight == 9)
    }

    @Test func defaultsToNineteenWithoutSZ() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1];B[aa];W[bb])"))
        #expect(scan.boardWidth == 19)
        #expect(scan.boardHeight == 19)
        #expect(scan.komi == nil)
        #expect(scan.rules == nil)
    }

    @Test func handicapSetupStonesAreNotMoves() throws {
        // AB[] setup stones must not count; White makes the first move.
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]SZ[19]HA[2]AB[pd][dp];W[qq];B[dd])"))
        #expect(scan.moveColors == [.white, .black])
        #expect(scan.toMove(atMoveIndex: 0) == .white)
        #expect(scan.toMove(atMoveIndex: 1) == .black)
        #expect(scan.toMove(atMoveIndex: 2) == .white)
    }

    @Test func mainlineFollowsFirstBranchAtEachFork() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]SZ[9];B[aa];W[bb](;B[cc];W[dd])(;B[ee]))"))
        // The first branch IS the mainline (children[0], as WGo plays it);
        // the second variation (;B[ee]) is excluded.
        #expect(scan.moveColors == [.black, .white, .black, .white])
    }

    @Test func commentsWithParensAndMoveLikeTextDoNotBreakTheScan() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]SZ[9]C[a trap ) with ;B[zz] inside];B[aa];W[bb])"))
        #expect(scan.moveColors == [.black, .white])
    }

    @Test func passMovesCount() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9];B[aa];W[];B[tt])"))
        #expect(scan.moveCount == 3)
    }

    @Test func toMoveAfterFinalMoveIsOpponentOfLastMover() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9];B[aa];W[bb])"))
        #expect(scan.toMove(atMoveIndex: 2) == .black)
    }

    @Test func emptyGameDefaultsToBlackToMove() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9]KM[6.5])"))
        #expect(scan.moveCount == 0)
        #expect(scan.toMove(atMoveIndex: 0) == .black)
    }

    @Test func nonSgfTextIsRejected() {
        #expect(SgfHeaderScan(sgf: "<html>Not a game</html>") == nil)
        #expect(SgfHeaderScan(sgf: "") == nil)
    }
}
