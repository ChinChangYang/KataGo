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

    @Test func compressedRangeExpandsToTheFullRectangle() throws {
        // AB[dd:ff] on a 9x9 is the 3x3 rectangle from (3,3) to (5,5) inclusive.
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9]AB[dd:ff])"))
        let expected = Set((3...5).flatMap { y in (3...5).map { x in SgfPoint(x: x, y: y) } })
        #expect(Set(scan.setupBlack) == expected)
        #expect(scan.setupBlack.count == 9)
    }

    @Test func compressedRangeAcceptsEitherCornerOrientation() throws {
        // The opposite corner order ("ff:dd") must expand to the same
        // rectangle. This pins a DELIBERATE divergence from the C++ side:
        // cpp/dataio/sgf.cpp's parseSgfLocRectangle requires x1<=x2, y1<=y2
        // verbatim and fails the whole file (degrading it to an empty
        // position) on "ff:dd" — see the doc comment on
        // SgfHeaderScan.points(_:width:height:) for why this scan is more
        // permissive. Not a parity guarantee with the engine.
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9]AB[ff:dd])"))
        let expected = Set((3...5).flatMap { y in (3...5).map { x in SgfPoint(x: x, y: y) } })
        #expect(Set(scan.setupBlack) == expected)
    }

    @Test func compressedRangeAppliesToAWToo() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9]AW[aa:bb])"))
        #expect(Set(scan.setupWhite) == Set([
            SgfPoint(x: 0, y: 0), SgfPoint(x: 1, y: 0),
            SgfPoint(x: 0, y: 1), SgfPoint(x: 1, y: 1),
        ]))
    }

    @Test func malformedRangeDecodesToNoPointsWithoutCrashing() throws {
        // A bad second corner ("z" is a single letter, not a 2-letter point).
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9]AB[dd:z])"))
        #expect(scan.setupBlack.isEmpty)
    }

    @Test func aeReadsSetupRemovals() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9]AB[dd][ee]AE[dd])"))
        #expect(scan.setupBlack == [SgfPoint(x: 3, y: 3), SgfPoint(x: 4, y: 4)])
        #expect(scan.setupEmpty == [SgfPoint(x: 3, y: 3)])
    }

    @Test func aeAlsoExpandsCompressedRanges() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9]AE[aa:bb])"))
        #expect(Set(scan.setupEmpty) == Set([
            SgfPoint(x: 0, y: 0), SgfPoint(x: 1, y: 0),
            SgfPoint(x: 0, y: 1), SgfPoint(x: 1, y: 1),
        ]))
    }

    @Test func aePropertyIsNeverMistakenForAMove() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[9]AE[dd];B[aa])"))
        #expect(scan.moves == [SgfMove(color: .black, point: SgfPoint(x: 0, y: 0))])
    }

    // MARK: - Root-node SZ (hostile input)

    /// A size written inside a comment is a VALUE, not a property. The
    /// escaped "]" keeps the raw text `SZ[100000:100000]` inside a well-formed
    /// comment (the engine loads this file as 19x19); the old regex took the
    /// first `SZ[...]` anywhere and returned 100000x100000.
    @Test func sizeInsideAValueIsNotTheBoardSize() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: #"(;GM[1]C[x\]SZ[100000:100000]SZ[19];B[dd])"#))
        #expect(scan.boardWidth == 19)
        #expect(scan.boardHeight == 19)
        #expect(scan.boardSizeIsSupported)
        #expect(scan.moves == [SgfMove(color: .black, point: SgfPoint(x: 3, y: 3))])
    }

    /// The Safari decoy: a small size in a comment ahead of the real root SZ.
    /// The old regex read 9 and let the file past the 19x19 gate, but
    /// `loadsgf` loads it as 37x37.
    @Test func decoySizeInACommentDoesNotHideTheRealOne() throws {
        let scan = try #require(SgfHeaderScan(sgf: #"(;GM[1]C[x\]SZ[9]SZ[37];B[aa])"#))
        #expect(scan.boardWidth == 37)
        #expect(scan.boardHeight == 37)
    }

    /// An escaped "]" stays inside the value, so it cannot end the comment
    /// early and expose a forged SZ.
    @Test func escapedBracketKeepsTheForgedSizeInsideTheValue() throws {
        let scan = try #require(SgfHeaderScan(sgf: #"(;GM[1]C[a\]SZ[3]SZ[13])"#))
        #expect(scan.boardWidth == 13)
        #expect(scan.boardHeight == 13)
        #expect(scan.boardSizeIsSupported)
    }

    /// SZ on a later node is not the board size — `getXYSize` reads nodes[0]
    /// only, and defaults to 19.
    @Test func sizeOutsideTheRootNodeIsIgnored() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;GM[1];SZ[9]B[aa])"))
        #expect(scan.boardWidth == 19)
        #expect(scan.boardHeight == 19)
        #expect(scan.boardSizeIsSupported)
    }

    @Test(arguments: [
        "(;GM[1]SZ[100000:100000])",
        "(;GM[1]SZ[100000])",
        "(;GM[1]SZ[99999999999999999999999])",
        "(;GM[1]SZ[38])",
        "(;GM[1]SZ[19:38])",
        "(;GM[1]SZ[1])",
        "(;GM[1]SZ[0:9])",
        "(;GM[1]SZ[-5])",
        "(;GM[1]SZ[nineteen])",
        "(;GM[1]SZ[19:19:19])",
        "(;GM[1]SZ[9]SZ[37])",
        "(;GM[1]SZ[9][37])",
    ])
    func unsupportedRootSizeIsReportedAndClamped(_ sgf: String) throws {
        let scan = try #require(SgfHeaderScan(sgf: sgf))
        #expect(!scan.boardSizeIsSupported)
        #expect(SgfHeaderScan.supportedBoardLengths.contains(scan.boardWidth))
        #expect(SgfHeaderScan.supportedBoardLengths.contains(scan.boardHeight))
    }

    @Test func supportedSizesAreReadExactly() throws {
        let smallest = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[2])"))
        #expect(smallest.boardSizeIsSupported)
        #expect(smallest.boardWidth == 2 && smallest.boardHeight == 2)
        let rectangle = try #require(SgfHeaderScan(sgf: "(;GM[1]SZ[ 37 : 2 ])"))
        #expect(rectangle.boardSizeIsSupported)
        #expect(rectangle.boardWidth == 37 && rectangle.boardHeight == 2)
        let absent = try #require(SgfHeaderScan(sgf: "(;GM[1]KM[6.5])"))
        #expect(absent.boardSizeIsSupported)
        #expect(absent.boardWidth == 19 && absent.boardHeight == 19)
    }

    /// KM/RU/PL are root properties too: text in a comment must not set them.
    @Test func komiRulesAndPlayerComeFromTheRootOnly() throws {
        let komi = try #require(SgfHeaderScan(sgf: #"(;GM[1]C[x\]KM[999]KM[6.5])"#))
        #expect(komi.komi == 6.5)
        let rules = try #require(SgfHeaderScan(sgf: #"(;GM[1]C[x\]RU[Evil]RU[Japanese])"#))
        #expect(rules.rules == "Japanese")
        let player = try #require(SgfHeaderScan(sgf: #"(;GM[1]C[x\]PL[W]SZ[9])"#))
        #expect(player.nextPlayerOverride == nil)
    }
}
