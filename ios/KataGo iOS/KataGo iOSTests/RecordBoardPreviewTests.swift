//
//  RecordBoardPreviewTests.swift
//  KataGo AnytimeTests
//
//  A library row's board is DERIVED from the record — its own SGF replayed to
//  its own index — never captured from the screen (ADR 0014). These pin the
//  rules that make that derivation trustworthy: the geometry comes from the
//  replay rather than from the record's cached size fields, the marker follows
//  the move the board ACCEPTED, a branch cannot be depicted, and the resolution
//  agrees with the one the live board draws.
//

import Testing
import Foundation
import SwiftData
@testable import KataGoUICore

@MainActor
struct RecordBoardPreviewTests {
    private static let sgf = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[dd])"

    // MARK: - The position

    @Test func indexZeroIsAnEmptyBoardNotAFailure() throws {
        let preview = try #require(RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 0))
        #expect(preview.width == 9)
        #expect(preview.height == 9)
        #expect(preview.blackVertices.isEmpty)
        #expect(preview.whiteVertices.isEmpty)
        #expect(preview.lastMoveVertex == nil)
    }

    @Test func eachIndexDrawsItsOwnPosition() throws {
        let first = try #require(RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 1))
        #expect(first.blackVertices == ["C7"])
        #expect(first.whiteVertices.isEmpty)
        #expect(first.lastMoveVertex == "C7")

        let second = try #require(RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 2))
        #expect(second.blackVertices == ["C7"])
        #expect(second.whiteVertices == ["D6"])
        #expect(second.lastMoveVertex == "D6")
    }

    /// A record can be parked past the end of a game that has since shrunk, and
    /// a row still has to draw something.
    @Test func anOutOfRangeIndexClamps() {
        #expect(RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 999)
                == RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 2))
        #expect(RecordBoardPreviewSource.preview(sgf: Self.sgf, index: -5)
                == RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 0))
    }

    @Test func capturedStonesAreResolvedAwayNotStacked() throws {
        // Black's stone at A9 is surrounded by White at B9 and A8 and lifted:
        // the row shows a position the rules could produce, never a stone dump.
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[ba];B[ii];W[ab])"
        let preview = try #require(RecordBoardPreviewSource.preview(sgf: sgf, index: 4))
        #expect(!preview.blackVertices.contains("A9"))
        #expect(preview.blackVertices == ["J1"])
        #expect(preview.whiteVertices.sorted() == ["A8", "B9"])
    }

    @Test func setupStonesAreShownAtIndexZero() throws {
        let sgf = try #require(GameRecord.makeSgf(width: 19, height: 19, komi: 0.5,
                                                  ruleString: "chinese", handicap: 4))
        let preview = try #require(RecordBoardPreviewSource.preview(sgf: sgf, index: 0))
        #expect(preview.blackVertices.count == 4)
        #expect(preview.whiteVertices.isEmpty)
        #expect(preview.lastMoveVertex == nil)
    }

    // MARK: - Geometry

    @Test func rectangularGeometryComesFromTheSgf() throws {
        let preview = try #require(
            RecordBoardPreviewSource.preview(sgf: "(;FF[4]GM[1]SZ[19:13])", index: 0))
        #expect(preview.width == 19)
        #expect(preview.height == 13)
    }

    /// `GameRecord.width`/`height` are optional cached fields that an import can
    /// leave disagreeing with the SGF. A grid that disagrees with its own stones
    /// is worse than no picture, so the replay wins.
    @Test func geometryBeatsALyingCachedField() throws {
        let record = GameRecord.createGameRecord(sgf: Self.sgf, width: 19, height: 19)
        let preview = try #require(RecordBoardPreviewSource.preview(for: record))
        #expect(preview.width == 9)
        #expect(preview.height == 9)
    }

    /// The same rule one level over: a record also carries a per-move stone
    /// cache, and the preview must ignore that too.
    ///
    /// Only a host running the position projector fills `blackStones` /
    /// `whiteStones`, so a cursor no host ever visited has no entry there —
    /// which is precisely the record `GobanState.cloneCurrentPosition` mints
    /// when a branch is saved as a new game: the cursor lands on the branch tip
    /// while the dictionaries are trimmed back to the divergence point. tvOS
    /// cards used to resolve from that cache and fall back to the highest
    /// cached move, so Apple TV drew a different move of the game than the
    /// phone did. Reading the SGF and nothing else is what makes them agree,
    /// and an "optimisation" back to the cache fails here.
    @Test func theCachedStoneDictionariesAreNotConsulted() throws {
        let record = GameRecord.createGameRecord(sgf: Self.sgf, currentIndex: 2)
        // A cache that lies in both available ways at once: it stops short of
        // the cursor, and what it does hold belongs to no position of this game.
        record.blackStones = [1: "G1"]
        record.whiteStones = [1: "H2"]

        let preview = try #require(RecordBoardPreviewSource.preview(for: record))
        #expect(preview.blackVertices == ["C7"])
        #expect(preview.whiteVertices == ["D6"])
        #expect(preview.lastMoveVertex == "D6")
    }

    // MARK: - Cover art

    /// The one deliberate departure from "draw the parked move": the tvOS
    /// sample card advertises a whole game, and its record parks at move 0 so
    /// review opens at the game's start. Cover art must not be an empty board.
    @Test func theFinishedGameIgnoresTheCursor() throws {
        let record = GameRecord.createGameRecord(sgf: Self.sgf, currentIndex: 0)
        // The positive control: parked at 0, the row draws nothing at all.
        let parked = try #require(RecordBoardPreviewSource.preview(for: record))
        #expect(parked.blackVertices.isEmpty)
        #expect(parked.whiteVertices.isEmpty)

        let finished = try #require(RecordBoardPreviewSource.finishedGamePreview(for: record))
        #expect(finished.blackVertices == ["C7"])
        #expect(finished.whiteVertices == ["D6"])
        #expect(finished.lastMoveVertex == "D6")
    }

    /// "Past the end" is a request the clamp answers, not a sentinel anyone
    /// decodes — so the finished game is exactly the last move's position.
    @Test func theFinishedGameIsTheLastMove() {
        let record = GameRecord.createGameRecord(sgf: Self.sgf, currentIndex: 0)
        #expect(RecordBoardPreviewSource.finishedGamePreview(for: record)
                == RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 2))
    }

    @Test func anUnreadableRecordHasNoCoverArtEither() {
        let record = GameRecord.createGameRecord(sgf: "not an sgf at all")
        #expect(RecordBoardPreviewSource.finishedGamePreview(for: record) == nil)
    }

    // MARK: - The marker

    /// A pass places no stone, so it moves no marker: the dot stays on the last
    /// stone actually PLAYED. The replay's window keeps an empty slot for the
    /// pass and the marks skip it — the same thing `showboard` prints, and the
    /// same thing the live board draws.
    @Test func aPassDoesNotMoveTheMarker() throws {
        let sgf = "(;FF[4]GM[1]SZ[9];B[cc];W[])"
        let preview = try #require(RecordBoardPreviewSource.preview(sgf: sgf, index: 2))
        #expect(preview.blackVertices == ["C7"])
        #expect(preview.whiteVertices.isEmpty)
        #expect(preview.lastMoveVertex == "C7")

        // And it is the board's answer, not a second opinion.
        let projector = RecordPositionProjector()
        let published = projector.project(
            key: RecordPositionKey(recordID: nil, sgf: sgf, index: 2, isBranchActive: false),
            into: Stones(), board: BoardSize(), analysis: Analysis(),
            gobanState: GobanState(), engineIsAcceptingCommands: true)
        #expect(preview.lastMoveVertex == published.lastMoveVertex)
    }

    /// The marker follows the move the BOARD accepted, not the one the record
    /// wrote: a refused move was never played, so marking its point would put a
    /// dot where no stone of that move exists.
    @Test func aRefusedMoveIsNotMarked() throws {
        // White's C7 lands on Black's stone — refused by tolerant legality.
        let preview = try #require(
            RecordBoardPreviewSource.preview(sgf: "(;FF[4]GM[1]SZ[9];B[cc];W[cc])", index: 2))
        #expect(preview.blackVertices == ["C7"])
        #expect(preview.whiteVertices.isEmpty)
        // Still Black's accepted move, never White's refused one.
        #expect(preview.lastMoveVertex == "C7")
    }

    // MARK: - What it can never draw

    /// A scratch branch lives on `GobanState.branchSgf` and is never written to
    /// the record, so reading the record's own SGF cannot depict one. This pins
    /// the property rather than a guard: a future refactor that starts reading
    /// `gobanState.branchSgf` here would fail this test.
    @Test func aBranchIsNeverDepicted() throws {
        let record = GameRecord.createGameRecord(sgf: Self.sgf, currentIndex: 1)

        let gobanState = GobanState()
        gobanState.branchSgf = "(;FF[4]GM[1]SZ[9];B[cc];W[gg];B[gc])"
        gobanState.branchIndex = 3
        #expect(gobanState.isBranchActive)

        let preview = try #require(RecordBoardPreviewSource.preview(for: record))
        // The mainline at index 1 — not the branch's three stones.
        #expect(preview.blackVertices == ["C7"])
        #expect(preview.whiteVertices.isEmpty)
    }

    @Test func anUnreadableRecordDrawsNothing() {
        #expect(RecordBoardPreviewSource.preview(sgf: "not an sgf at all", index: 0) == nil)
        #expect(RecordBoardPreviewSource.preview(sgf: "", index: 0) == nil)
    }

    // MARK: - Agreement with the board

    /// The row and the board must never disagree about one game. Both resolve
    /// the same key; this asserts they land on the same stones rather than
    /// merely claiming to share a parser.
    @Test func theRowAgreesWithTheBoard() throws {
        let key = RecordPositionKey(recordID: nil, sgf: Self.sgf, index: 2, isBranchActive: false)
        let projector = RecordPositionProjector()
        let published = projector.project(key: key,
                                          into: Stones(),
                                          board: BoardSize(),
                                          analysis: Analysis(),
                                          gobanState: GobanState(),
                                          engineIsAcceptingCommands: true)

        let preview = try #require(RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 2))

        #expect(preview.width == published.width)
        #expect(preview.height == published.height)
        #expect(preview.lastMoveVertex == published.lastMoveVertex)

        let previewBlack = preview.blackVertices
            .compactMap { BoardPoint(move: $0, width: preview.width, height: preview.height) }
        let previewWhite = preview.whiteVertices
            .compactMap { BoardPoint(move: $0, width: preview.width, height: preview.height) }
        #expect(Set(previewBlack) == Set(published.blackPoints))
        #expect(Set(previewWhite) == Set(published.whitePoints))
    }

    // MARK: - Cache

    /// The cache key carries the SGF BY VALUE, because a played move rewrites
    /// the record's SGF in place. That is what makes a row self-invalidating
    /// when its game gets a move, with no invalidation logic anywhere.
    @Test func oneMoreMoveInvalidatesTheCachedBoard() throws {
        RecordBoardPreviewSource.resetCacheForTesting()

        let first = try #require(RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 2))
        let repeated = try #require(RecordBoardPreviewSource.preview(sgf: Self.sgf, index: 2))
        #expect(first == repeated)

        let extended = "(;FF[4]GM[1]SZ[9]KM[7];B[cc];W[dd];B[gg])"
        let afterMove = try #require(RecordBoardPreviewSource.preview(sgf: extended, index: 3))
        #expect(afterMove != first)
        #expect(afterMove.blackVertices.sorted() == ["C7", "G3"])
    }
}
