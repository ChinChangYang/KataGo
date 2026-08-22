//
//  RecordPositionProjectorTests.swift
//  KataGo AnytimeTests
//
//  The board is record-owned: `RecordPositionProjector` replays the record's
//  SGF and is the ONLY writer of the stones, the board size and the move-number
//  digits. These tests pin what it publishes — never how it caches.
//

import Testing
import Foundation
@testable import KataGoUICore

@MainActor
struct RecordPositionProjectorTests {
    /// Two plain moves on a 9×9: black C7, white D6.
    private static let twoMoves = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[dd])"
    /// The same opening, then a black move onto the occupied C7 — refused by
    /// the tolerant legality both the replay and the engine use.
    private static let refusedThird = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[dd];B[cc])"
    /// White's corner stone at A9 is surrounded by black B9 and A8.
    private static let capture = "(;FF[4]GM[1]SZ[9]KM[7];W[aa];B[ba];W[ii];B[ab])"
    private static let thirteen = "(;FF[4]GM[1]SZ[13]KM[7];B[dd])"
    private static let nineteen = "(;FF[4]GM[1]SZ[19]KM[7];B[dd];W[pp])"

    private func key(_ sgf: String, _ index: Int, branch: Bool = false) -> RecordPositionKey {
        RecordPositionKey(recordID: nil, sgf: sgf, index: index, isBranchActive: branch)
    }

    /// Everything the projector writes into, fresh.
    ///
    /// `@MainActor` on its own: a nested type does NOT inherit the enclosing
    /// suite's isolation, and `RecordPositionProjector()` is a main-actor
    /// initializer being used as a stored-property default.
    @MainActor
    private struct Models {
        let stones = Stones()
        let board = BoardSize()
        let analysis = Analysis()
        let gobanState = GobanState()
        let projector = RecordPositionProjector()

        @discardableResult
        func project(_ key: RecordPositionKey?) -> RecordPosition {
            projector.project(key: key, into: stones, board: board,
                              analysis: analysis, gobanState: gobanState)
        }
    }

    private func point(_ vertex: String, _ size: Int) -> BoardPoint {
        BoardPoint(move: vertex, width: size, height: size)!
    }

    // MARK: - Stones, size, captures

    @Test func stonesComeFromTheRecord() {
        let models = Models()
        let position = models.project(key(Self.twoMoves, 2))

        #expect(position.blackPoints == [point("C7", 9)])
        #expect(position.whitePoints == [point("D6", 9)])
        #expect(models.stones.blackPoints == [point("C7", 9)])
        #expect(models.stones.whitePoints == [point("D6", 9)])
        // The record answers for every index, not just the tip.
        #expect(models.project(key(Self.twoMoves, 1)).whitePoints.isEmpty)
        #expect(models.project(key(Self.twoMoves, 0)).blackPoints.isEmpty)
    }

    @Test func boardSizeComesFromTheRecordsSgf() {
        let models = Models()
        #expect(models.board.width == 19)          // the model's own default

        models.project(key(Self.thirteen, 1))
        #expect(models.board.width == 13)
        #expect(models.board.height == 13)

        models.project(key(Self.twoMoves, 1))
        #expect(models.board.width == 9)
        #expect(models.board.height == 9)
    }

    @Test func capturesComeFromTheReplay() {
        let models = Models()
        let position = models.project(key(Self.capture, 4))

        // White's A9 stone is gone; the counter says one white stone removed.
        #expect(!position.whitePoints.contains(point("A9", 9)))
        #expect(position.whiteStonesCaptured == 1)
        #expect(position.blackStonesCaptured == 0)
        #expect(models.stones.whiteStonesCaptured == 1)
        #expect(models.stones.blackStonesCaptured == 0)
    }

    @Test func moveOrderCarriesTheLastThreeDigits() {
        let models = Models()
        models.project(key(Self.capture, 4))

        // The window holds the last three accepted moves, oldest first.
        #expect(models.stones.moveOrder[point("B9", 9)] == "1")
        #expect(models.stones.moveOrder[point("J1", 9)] == "2")
        #expect(models.stones.moveOrder[point("A8", 9)] == "3")
        #expect(models.stones.moveOrder[point("A9", 9)] == nil)
    }

    @Test func toMoveIsTheOppositeOfTheLastAcceptedMove() {
        // Engine parity: a refused move leaves the turn where the engine left
        // it. `Turn.nextColorForPlayCommand` stays engine-sourced, so nothing
        // displays this yet — it is what the move-by-move feed will send.
        let models = Models()
        #expect(models.project(key(Self.twoMoves, 0)).toMove == .black)
        #expect(models.project(key(Self.twoMoves, 1)).toMove == .white)
        #expect(models.project(key(Self.twoMoves, 2)).toMove == .black)
        // Index 3's move is refused, so the turn does not advance past index 2.
        #expect(models.project(key(Self.refusedThird, 3)).toMove == .black)
    }

    @Test func lastMoveVertexIsTheLastACCEPTEDMoveNotTheRecordedOne() {
        // Index 3's recorded move is B[cc], which the board refuses (occupied).
        // The record-parity answer would be C7 — where the record SAID the move
        // was. The engine never played it, so the marker must stay on D6, the
        // last move the engine actually accepted.
        let models = Models()
        let position = models.project(key(Self.refusedThird, 3))
        #expect(position.lastMoveVertex == "D6")
    }

    // MARK: - Branch line

    @Test func aBranchKeyProjectsTheBranchLine() {
        let models = Models()
        models.project(key(Self.twoMoves, 2))
        #expect(models.stones.whitePoints == [point("D6", 9)])

        // A branch diverging after black's move: white answers at J1 instead.
        let branch = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[ii])"
        models.project(key(branch, 2, branch: true))
        #expect(models.stones.blackPoints == [point("C7", 9)])
        #expect(models.stones.whitePoints == [point("J1", 9)])
    }

    // MARK: - Generation and idempotence

    @Test func everyPublishBumpsTheGeneration() {
        let models = Models()
        let start = models.stones.positionGeneration

        models.project(key(Self.twoMoves, 0))
        let afterFirst = models.stones.positionGeneration
        models.project(key(Self.twoMoves, 1))
        let afterSecond = models.stones.positionGeneration

        #expect(afterFirst != start)
        #expect(afterSecond != afterFirst)
    }

    @Test func repeatingAKeyWritesNothing() {
        let models = Models()
        models.project(key(Self.twoMoves, 2))
        let generation = models.stones.positionGeneration

        // A re-entry, a re-render, a board reload onto the same position.
        let again = models.project(key(Self.twoMoves, 2))
        #expect(models.stones.positionGeneration == generation)
        #expect(again.blackPoints == [point("C7", 9)])
    }

    @Test func repeatingANilKeyWritesNothingAfterTheFirstPublish() {
        let models = Models()
        models.project(nil)
        let generation = models.stones.positionGeneration
        models.project(nil)
        #expect(models.stones.positionGeneration == generation)
    }

    @Test func scrubbingBackAndForthReturnsTheSamePositions() {
        // The replay is cached and memoized between calls; going forward and
        // then back must land on exactly the boards the forward pass drew.
        let models = Models()
        let forward = (0...4).map { models.project(key(Self.capture, $0)) }
        let backward = (0...4).reversed().map { models.project(key(Self.capture, $0)) }

        #expect(Array(backward.reversed()) == forward)
    }

    // MARK: - Records the parser rejects

    @Test func anUnparseableRecordPublishesAnEmptyBoardAtTheCurrentSize() {
        // `SgfCpp` reports a 0x0 board for anything it could not read. A 0-wide
        // board would trap `BoardSize.locationToMove`'s `1...height` range, and
        // `SgfReplay`'s clamped 1x1 substitute would draw a nonsense grid — so
        // the projector refuses the record and leaves the geometry alone.
        let models = Models()
        models.project(key(Self.thirteen, 1))
        #expect(models.board.width == 13)

        let position = models.project(key("this is not an SGF", 0))

        #expect(position.width == 13)
        #expect(position.height == 13)
        #expect(position.blackPoints.isEmpty)
        #expect(position.whitePoints.isEmpty)
        #expect(position.recordedMoveVertices.isEmpty)
        #expect(models.board.width == 13)
        #expect(models.board.height == 13)
        #expect(models.stones.blackPoints.isEmpty)
    }

    @Test func anEmptySgfStringIsRefusedTheSameWay() {
        let models = Models()
        let position = models.project(key("", 0))
        #expect(position.blackPoints.isEmpty)
        #expect(models.board.width == 19)   // the model default, untouched
    }

    // MARK: - The move-vertex pair the record cache consumes

    @Test func recordedMoveVerticesCoverTheDisplayedIndexAndTheOneBefore() {
        let models = Models()

        // Mid-record: the move that led here and the one that leaves.
        #expect(models.project(key(Self.twoMoves, 1)).recordedMoveVertices
                == [0: "C7", 1: "D6"])
        // At index 0 there is no preceding move.
        #expect(models.project(key(Self.twoMoves, 0)).recordedMoveVertices
                == [0: "C7"])
    }

    @Test func atTheTipThereIsNoMoveToName() {
        // The tip is where play sits, so this is the common case: index 2 of a
        // two-move record has no move 2. Nothing is looked up for it.
        let models = Models()
        let position = models.project(key(Self.twoMoves, 2))
        #expect(position.recordedMoveVertices == [1: "D6"])
        #expect(position.recordedMoveVertices[2] == nil)
    }

    // MARK: - Nil key

    @Test func aNilKeyPublishesAnEmptyBoard() {
        let models = Models()
        models.project(key(Self.capture, 4))
        #expect(!models.stones.blackPoints.isEmpty)

        let empty = models.project(nil)
        #expect(models.stones.blackPoints.isEmpty)
        #expect(models.stones.whitePoints.isEmpty)
        #expect(models.stones.moveOrder.isEmpty)
        #expect(models.stones.blackStonesCaptured == 0)
        #expect(models.stones.whiteStonesCaptured == 0)
        #expect(empty.lastMoveVertex == nil)
        // The grid stays the size it was — deselecting is not a board resize.
        #expect(models.board.width == 9)
    }

    // MARK: - Analysis lifetime

    @Test func analysisIsClearedWhenTheKeyChangesWhileNotInSync() {
        let models = Models()
        models.project(key(Self.nineteen, 1))
        models.stones.isReady = true
        models.analysis.ownershipUnits = [OwnershipUnit(point: BoardPoint(x: 0, y: 0),
                                                        whiteness: 1, scale: 1, opacity: 1)]
        models.analysis.collectedForKey = key(Self.nineteen, 1)

        // A played move / a step: `isReady` drops, then the record moves.
        models.stones.isReady = false
        models.project(key(Self.nineteen, 2))

        #expect(models.analysis.ownershipUnits.isEmpty)
        #expect(models.analysis.collectedForKey == nil)
    }

    @Test func analysisSurvivesAKeyChangeWhileInSync() {
        // The auto-play advance moves `currentIndex` AFTER the engine
        // acknowledged the move — the numbers on screen belong to the position
        // the record just arrived at, so they must not be thrown away.
        let models = Models()
        models.project(key(Self.nineteen, 1))
        models.stones.isReady = true
        models.analysis.ownershipUnits = [OwnershipUnit(point: BoardPoint(x: 0, y: 0),
                                                        whiteness: 1, scale: 1, opacity: 1)]

        models.project(key(Self.nineteen, 2))
        #expect(models.analysis.ownershipUnits.count == 1)
    }

    @Test func aBoardSizeChangeAlwaysClearsAnalysis() {
        // Even in sync: ownership and candidate points are indexed by a board
        // of the old size, so they cannot be shown over the new one.
        let models = Models()
        models.project(key(Self.nineteen, 1))
        models.stones.isReady = true
        models.analysis.ownershipUnits = [OwnershipUnit(point: BoardPoint(x: 0, y: 0),
                                                        whiteness: 1, scale: 1, opacity: 1)]

        models.project(key(Self.thirteen, 1))
        #expect(models.analysis.ownershipUnits.isEmpty)
        #expect(models.board.width == 13)
    }

    // MARK: - Bookkeeping the hosts read

    @Test func projectingMarksTheBoardShownAndRemembersTheKey() {
        let models = Models()
        #expect(!models.gobanState.isShownBoard)

        let displayed = key(Self.twoMoves, 2)
        models.project(displayed)

        #expect(models.gobanState.isShownBoard)
        #expect(models.projector.currentKey == displayed)
        #expect(models.projector.currentPosition?.blackPoints == [point("C7", 9)])
    }
}
