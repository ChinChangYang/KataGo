//
//  SgfReplayPositionTests.swift
//  GoRulesKitTests
//
//  SgfReplay is the whole source of the record position the board draws, so
//  a Position has to carry everything `showboard` used to supply: capture
//  counts, the move-number digits, and the side to move. These pin those,
//  plus the refusal accounting the engine feed subtracts from its undo
//  counts, and the value-based initialiser the C++ parser feeds.
//

import Foundation
import Testing
@testable import GoRulesKit
import KataGoAnalysisKit

struct SgfReplayPositionTests {
    private func replay(_ sgf: String) throws -> SgfReplay {
        SgfReplay(scan: try #require(SgfHeaderScan(sgf: sgf)))
    }

    /// A ko: Black takes E5, White takes back at D5, Black retakes E5. The
    /// replay ignores ko (as KataGo's tolerant `play` does), so all three are
    /// accepted — which puts D5 in the move window twice and captures three
    /// stones between the two colours.
    private static let koSgf =
        "(;GM[1]SZ[9]AB[ed][ef][fe]AW[dd][df][ce][ee];B[de];W[ee];B[de])"

    // MARK: - Captures

    @Test func capturedStonesAreCounted() throws {
        // Black surrounds a lone White stone in the corner and takes it.
        var r = try replay("(;GM[1]SZ[9];B[bi];W[ai];B[ah])")
        let p = r.position(at: 3)
        #expect(p.whiteCaptures == 1)
        #expect(p.blackCaptures == 0)
    }

    @Test func capturesAccumulateForBothColours() throws {
        var r = try replay(Self.koSgf)
        #expect(r.position(at: 1).whiteCaptures == 1)
        #expect(r.position(at: 1).blackCaptures == 0)
        #expect(r.position(at: 2).blackCaptures == 1)
        let p = r.position(at: 3)
        #expect(p.whiteCaptures == 2)
        #expect(p.blackCaptures == 1)
    }

    @Test func noCapturesAtTheStartingPosition() throws {
        var r = try replay("(;GM[1]SZ[19]AB[pd][dp];W[dd])")
        let start = r.position(at: 0)
        #expect(start.blackCaptures == 0)
        #expect(start.whiteCaptures == 0)
    }

    // MARK: - Captured stones: which points, and which colour

    @Test func aCaptureNamesThePointAndTheColourItTook() throws {
        // Black surrounds a lone White stone in the corner and takes it: A1.
        var r = try replay("(;GM[1]SZ[9];B[bi];W[ai];B[ah])")
        let p = r.position(at: 3)
        #expect(p.capturedByLastMove
                == [SgfReplay.CapturedStone(point: GoPoint(x: 0, y: 8), color: .white)])
    }

    @Test func aMultiStoneCaptureNamesEveryStone() throws {
        // A two-stone White chain on the bottom edge, taken by Black's C1.
        var r = try replay("(;GM[1]SZ[9]AW[ai][bi]AB[ah][bh];B[ci])")
        let p = r.position(at: 1)
        #expect(Set(p.capturedByLastMove)
                == [SgfReplay.CapturedStone(point: GoPoint(x: 0, y: 8), color: .white),
                    SgfReplay.CapturedStone(point: GoPoint(x: 1, y: 8), color: .white)])
        #expect(p.whiteCaptures == 2)
    }

    @Test func aMultiStoneSuicideNamesTheMoversOwnStones() throws {
        // The one case where the stones removed are NOT the opponent's: the
        // mover's own chain is what leaves, so that is the colour reported.
        var r = try replay("(;GM[1]SZ[9]AW[ah][bh][ci]AB[bi];B[ai])")
        let p = r.position(at: 1)
        #expect(Set(p.capturedByLastMove)
                == [SgfReplay.CapturedStone(point: GoPoint(x: 0, y: 8), color: .black),
                    SgfReplay.CapturedStone(point: GoPoint(x: 1, y: 8), color: .black)])
        #expect(p.blackCaptures == 2)
    }

    @Test func nothingIsCapturedAtTheStartOrByAPass() throws {
        var r = try replay("(;GM[1]SZ[9];B[bi];W[ai];B[ah];W[])")
        #expect(r.position(at: 0).capturedByLastMove.isEmpty)
        // Index 3 DID capture; the pass that follows takes nothing, and the
        // capturing index's annotation must not carry onto index 4.
        #expect(r.position(at: 3).capturedByLastMove.count == 1)
        #expect(r.position(at: 4).capturedByLastMove.isEmpty)
    }

    @Test func aRefusedMoveCapturesNothing() throws {
        // The refusal is at index 3 (an occupied point), directly after a
        // capturing move — exactly where an inherited annotation would show.
        var r = try replay("(;GM[1]SZ[9];B[bi];W[ai];B[ah];W[ah])")
        #expect(r.position(at: 3).capturedByLastMove.count == 1)
        #expect(r.position(at: 4).capturedByLastMove.isEmpty)
        #expect(r.isRefused(3))
    }

    @Test func aCheckpointedReplayStillReportsItsCapture() throws {
        // 26 moves, so the replay memoizes a checkpoint at index 25 and index
        // 26 is only ever reached by replaying forward FROM that checkpoint.
        // The annotation rides `State`, so it has to survive that round trip —
        // and the checkpointed index itself, whose move took nothing, has to
        // report empty rather than the capture that follows it.
        var moves: [SgfReplay.RecordedMove] = []
        for i in 0..<24 {
            // Two chains hugging opposite edges: 12 moves each, no contact,
            // no captures.
            moves.append(SgfReplay.RecordedMove(
                color: i.isMultiple(of: 2) ? .black : .white,
                point: GoPoint(x: i / 2, y: i.isMultiple(of: 2) ? 0 : 18)))
        }
        // Move 24: Black in the corner beside the White setup stone, leaving
        // itself exactly one liberty. Move 25: White takes it.
        moves.append(SgfReplay.RecordedMove(color: .black, point: GoPoint(x: 18, y: 0)))
        moves.append(SgfReplay.RecordedMove(color: .white, point: GoPoint(x: 18, y: 1)))

        var r = SgfReplay(width: 19, height: 19,
                          setupWhite: [GoPoint(x: 17, y: 0)],
                          moves: moves)
        #expect(r.moveCount == SgfReplay.checkpointStride + 1)
        // Force the replay past the checkpoint, then ask again: the second ask
        // is the one that restarts from checkpoint 25.
        _ = r.position(at: 26)
        #expect(r.position(at: 25).capturedByLastMove.isEmpty)
        #expect(r.position(at: 26).capturedByLastMove
                == [SgfReplay.CapturedStone(point: GoPoint(x: 18, y: 0), color: .black)])
    }

    // MARK: - lastThreeMoves (showboard's move-number digits)

    @Test func theLastThreeMovesAreNumberedOldestFirst() throws {
        var r = try replay("(;GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])")
        let two = r.position(at: 2)
        #expect(two.lastThreeMoves.map(\.vertex) == ["A9", "B8"])
        #expect(two.lastThreeMoves.map(\.order) == [1, 2])

        let four = r.position(at: 4)
        #expect(four.lastThreeMoves.map(\.vertex) == ["B8", "C7", "D6"])
        #expect(four.lastThreeMoves.map(\.order) == [1, 2, 3])
    }

    @Test func aPassOccupiesASlotWithoutMarkingAPoint() throws {
        var r = try replay("(;GM[1]SZ[9];B[aa];W[];B[cc])")
        let p = r.position(at: 3)
        #expect(p.lastThreeMoves.map(\.vertex) == ["A9", "C7"])
        // The pass sits between them and still consumes digit 2.
        #expect(p.lastThreeMoves.map(\.order) == [1, 3])
    }

    @Test func aRepeatedPointKeepsItsOldestDigit() throws {
        // Window: D5, E5, D5. printBoard breaks at the first match, so D5
        // keeps digit 1 and nothing is printed for the retake.
        var r = try replay(Self.koSgf)
        let p = r.position(at: 3)
        #expect(p.lastThreeMoves.map(\.vertex) == ["D5", "E5"])
        #expect(p.lastThreeMoves.map(\.order) == [1, 2])
    }

    @Test func aPointKeepsItsDigitAfterItsStoneIsCaptured() throws {
        // At index 2 White has just retaken, so D5 is EMPTY — but it is still
        // the oldest move in the window and still carries digit 1.
        var r = try replay(Self.koSgf)
        let p = r.position(at: 2)
        #expect(!p.blackVertices.contains("D5"))
        #expect(p.lastThreeMoves.map(\.vertex) == ["D5", "E5"])
        #expect(p.lastThreeMoves.map(\.order) == [1, 2])
    }

    @Test func aColourRepeatRestartsTheWindow() throws {
        // Two White moves in a row: Search::makeMove clears BoardHistory, so
        // the repeating move starts a fresh window containing only itself.
        var r = try replay("(;GM[1]SZ[9];B[aa];W[bb];W[cc];B[dd])")
        let three = r.position(at: 3)
        #expect(three.lastThreeMoves.map(\.vertex) == ["C7"])
        #expect(three.lastThreeMoves.map(\.order) == [1])

        let four = r.position(at: 4)
        #expect(four.lastThreeMoves.map(\.vertex) == ["C7", "D6"])
        #expect(four.lastThreeMoves.map(\.order) == [1, 2])
    }

    @Test func aRefusedMoveIsNotInTheWindow() throws {
        // The refused move repeats White's colour, so the moves the engine
        // actually receives still alternate and nothing is cleared.
        var r = try replay("(;GM[1]SZ[9];B[aa];W[bb];W[bb];B[cc])")
        let p = r.position(at: 4)
        #expect(p.lastThreeMoves.map(\.vertex) == ["A9", "B8", "C7"])
        #expect(p.lastThreeMoves.map(\.order) == [1, 2, 3])
    }

    @Test func aRefusalCanMakeTheNextMoveAColourRepeat() throws {
        // Black's refused move is never sent, so White's next move arrives
        // when the engine still expects Black — a repeat that clears the
        // window, exactly as it would if the record had no Black move there.
        var r = try replay("(;GM[1]SZ[9];B[aa];W[bb];B[bb];W[cc])")
        let p = r.position(at: 4)
        #expect(p.lastThreeMoves.map(\.vertex) == ["C7"])
        #expect(p.lastThreeMoves.map(\.order) == [1])
    }

    // MARK: - Refusals

    @Test func refusedIndicesCollectsEveryRefusal() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg];B[cc];W[gg];B[dd])")
        _ = r.position(at: r.moveCount)
        #expect(r.refusedIndices == [2, 3])
        #expect(r.isRefused(2))
        #expect(!r.isRefused(4))
    }

    @Test func anomalyIndexIsTheEarliestRefusal() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg];B[cc];W[gg];B[dd])")
        _ = r.position(at: r.moveCount)
        #expect(r.anomalyIndex == 2)
    }

    @Test func singleStoneSuicideIsRefusedAndMultiStoneSuicideIsNot() throws {
        // A lone Black stone into a White box is refused; the same point with
        // a Black neighbour to connect to is a legal multi-stone suicide.
        var lone = try replay("(;GM[1]SZ[9]AW[ah][bi];B[ai])")
        _ = lone.position(at: 1)
        #expect(lone.refusedIndices == [0])

        var group = try replay("(;GM[1]SZ[9]AW[ah][bh][ci]AB[bi];B[ai])")
        let p = group.position(at: 1)
        #expect(group.refusedIndices.isEmpty)
        #expect(!p.blackVertices.contains("A1"))
        #expect(!p.blackVertices.contains("B1"))
        #expect(p.blackCaptures == 2)
    }

    @Test func acceptedMoveCountSkipsRefusals() throws {
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg];B[cc];W[gg];B[dd])")
        #expect(r.acceptedMoveCount(upTo: 0) == 0)
        #expect(r.acceptedMoveCount(upTo: 2) == 2)
        #expect(r.acceptedMoveCount(upTo: 3) == 2)
        #expect(r.acceptedMoveCount(upTo: 4) == 2)
        #expect(r.acceptedMoveCount(upTo: 5) == 3)
    }

    @Test func toMoveFollowsTheLastAcceptedMove() throws {
        // Index 2's Black move is refused, so at indices 3 AND 4 the last
        // accepted move is still White's — Black is to move at both.
        var r = try replay("(;GM[1]SZ[9];B[cc];W[gg];B[cc];W[gg];B[dd])")
        #expect(r.position(at: 1).toMove == .white)
        #expect(r.position(at: 2).toMove == .black)
        #expect(r.position(at: 3).toMove == .black)
        #expect(r.position(at: 4).toMove == .black)
        #expect(r.position(at: 5).toMove == .white)
    }

    @Test func toMoveIsWhiteWhenEverySetupStoneIsBlack() throws {
        var handicap = try replay("(;GM[1]SZ[19]HA[2]AB[pd][dp];W[dd])")
        #expect(handicap.position(at: 0).toMove == .white)

        var mixed = try replay("(;GM[1]SZ[9]AB[cc]AW[gg];B[dd])")
        #expect(mixed.position(at: 0).toMove == .black)

        var bare = try replay("(;GM[1]SZ[9];B[cc])")
        #expect(bare.position(at: 0).toMove == .black)
    }

    // MARK: - Trailing passes

    @Test func trailingPassCountCountsConsecutiveAcceptedPasses() throws {
        var r = try replay("(;GM[1]SZ[9];B[aa];W[];B[];W[bb])")
        #expect(r.trailingPassCount(at: 0) == 0)
        #expect(r.trailingPassCount(at: 1) == 0)
        #expect(r.trailingPassCount(at: 2) == 1)
        #expect(r.trailingPassCount(at: 3) == 2)
        #expect(r.trailingPassCount(at: 4) == 0)
    }

    @Test func trailingPassCountLooksThroughARefusedMove() throws {
        // Index 2 repeats an occupied point and is refused, so the two passes
        // around it are consecutive as far as the engine is concerned.
        var r = try replay("(;GM[1]SZ[9];B[aa];W[];B[aa];W[])")
        #expect(r.trailingPassCount(at: 4) == 2)
    }

    // MARK: - Recorded moves

    @Test func moveAtReturnsTheRecordedMove() throws {
        let r = try replay("(;GM[1]SZ[9];B[cc];W[])")
        #expect(r.move(at: 0)?.color == .black)
        #expect(r.move(at: 0)?.point == GoPoint(x: 2, y: 2))
        #expect(r.move(at: 1)?.color == .white)
        #expect(r.move(at: 1)?.point == nil)
        #expect(r.move(at: 2) == nil)
        #expect(r.move(at: -1) == nil)
    }

    // MARK: - The two constructions

    @Test func theMoveListInitAgreesWithTheScanInit() throws {
        // Setup stones, a capture, a pass and a refusal in one game. The
        // values are written out rather than derived from the scan, so this
        // pins what the scan-based initialiser turns an SGF INTO — not just
        // that it calls the other one.
        let sgf = "(;GM[1]SZ[9]AB[bi]AW[ai];B[ah];W[];B[ah];W[gg];B[cc])"
        var fromScan = SgfReplay(scan: try #require(SgfHeaderScan(sgf: sgf)))
        var fromValues = SgfReplay(
            width: 9, height: 9,
            setupBlack: [GoPoint(x: 1, y: 8)],
            setupWhite: [GoPoint(x: 0, y: 8)],
            moves: [
                SgfReplay.RecordedMove(color: .black, point: GoPoint(x: 0, y: 7)),
                SgfReplay.RecordedMove(color: .white, point: nil),
                SgfReplay.RecordedMove(color: .black, point: GoPoint(x: 0, y: 7)),
                SgfReplay.RecordedMove(color: .white, point: GoPoint(x: 6, y: 6)),
                SgfReplay.RecordedMove(color: .black, point: GoPoint(x: 2, y: 2)),
            ])

        #expect(fromValues.width == fromScan.width)
        #expect(fromValues.height == fromScan.height)
        #expect(fromValues.moveCount == fromScan.moveCount)
        for index in 0...fromScan.moveCount {
            #expect(fromValues.position(at: index) == fromScan.position(at: index),
                    "positions diverge at index \(index)")
        }
        #expect(fromValues.refusedIndices == fromScan.refusedIndices)
        #expect(fromValues.acceptedMoveCount(upTo: fromValues.moveCount)
                == fromScan.acceptedMoveCount(upTo: fromScan.moveCount))
    }
}
