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

    @Test func readsMoveCoordinates() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]FF[4]SZ[19];B[pd];W[dp];B[qp])"))
        #expect(scan.moves == [
            SgfMove(color: .black, point: SgfPoint(x: 15, y: 3)),
            SgfMove(color: .white, point: SgfPoint(x: 3, y: 15)),
            SgfMove(color: .black, point: SgfPoint(x: 16, y: 15)),
        ])
    }

    @Test func emptyValueIsAPass() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9];B[aa];W[])"))
        #expect(scan.moves[1].point == nil)
        #expect(scan.moves[1].color == .white)
    }

    @Test func offBoardValueIsAPass() throws {
        // "tt" is the legacy pass on boards up to 19x19; it decodes to (19,19),
        // which is off a 9x9 board, so the generic off-board rule covers it.
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9];B[aa];W[tt])"))
        #expect(scan.moves[1].point == nil)
        #expect(scan.moveCount == 2)
    }

    @Test func readsSetupStones() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;GM[1]SZ[19]HA[2]AB[pd][dp]AW[dd];W[qq])"))
        #expect(scan.setupBlack == [SgfPoint(x: 15, y: 3), SgfPoint(x: 3, y: 15)])
        #expect(scan.setupWhite == [SgfPoint(x: 3, y: 3)])
        // Setup stones are NOT moves.
        #expect(scan.moves == [SgfMove(color: .white, point: SgfPoint(x: 16, y: 16))])
    }

    @Test func setupPropertyIsNeverMistakenForABlackMove() throws {
        // The whole reason for a token scanner: "AB" is one property
        // identifier, not "A" followed by a "B" move.
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[19]AB[dd][pp])"))
        #expect(scan.moves.isEmpty)
        #expect(scan.setupBlack.count == 2)
    }

    @Test func uppercaseCoordinateLettersDecodePastZ() throws {
        // SGF coordinates continue "A"..."Z" = 26...51 for boards over 26.
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[37];B[aA];W[Ab])"))
        #expect(scan.moves[0].point == SgfPoint(x: 0, y: 26))
        #expect(scan.moves[1].point == SgfPoint(x: 26, y: 1))
    }

    @Test func moveColorsStillMirrorsTheMoveList() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9];B[aa];W[bb];B[cc])"))
        #expect(scan.moveColors == scan.moves.map(\.color))
        #expect(scan.moveColors == [.black, .white, .black])
    }
}
