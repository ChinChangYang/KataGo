//
//  RecordPosition.swift
//  KataGoUICore
//
//  The board is record-owned: what it draws is the position at the game's
//  current index, replayed from the record's SGF by `GoRulesKit.SgfReplay`.
//  The engine's `showboard` ASCII no longer populates stones — it is only the
//  acknowledgement that the engine caught up (`Stones.isReady`).
//
//  `RecordPosition` is the KataGoUICore-owned value the replay is projected
//  into, so `GoRulesKit` types never appear on this module's public surface
//  (MemberImportVisibility: a consumer that does not import GoRulesKit must
//  still be able to name everything a public API hands it).
//

import SwiftUI
import SwiftData
import GoRulesKit

/// One drawable position: exactly the fields `Stones` + `BoardSize` hold, so
/// projecting is a field-for-field copy rather than a translation.
public struct RecordPosition: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let blackPoints: [BoardPoint]
    public let whitePoints: [BoardPoint]
    /// The 1-2-3 digits `showboard` used to print, keyed by point. Passes and
    /// refused moves mark nothing.
    public let moveOrder: [BoardPoint: Character]
    /// Black stones removed from the board (KataGo's `numBlackCaptures`).
    public let blackStonesCaptured: Int
    /// White stones removed from the board (KataGo's `numWhiteCaptures`).
    public let whiteStonesCaptured: Int
    /// The side the ENGINE would expect to move here — the opposite of the
    /// last accepted move. Not the source of `Turn.nextColorForPlayCommand`,
    /// which stays engine-sourced from the `showboard` "Next player" line so
    /// the turn edge remains asynchronous and real.
    public let toMove: PlayerColor
    /// The last move's vertex, taken from the ENGINE-parity source: the newest
    /// entry of the replay's last-three window (never
    /// `SgfReplay.Position.lastMoveVertex`, which is record-parity and reports
    /// a REFUSED move's point — the engine never played it, so the board must
    /// not mark it). Nil when the window is empty (index 0, a pass, or a
    /// colour repeat that cleared the window onto a pass).
    public let lastMoveVertex: String?
    /// The recorded move vertices at the displayed index and the one before
    /// it, keyed by move index — exactly the pair `GameRecord.moves` caches
    /// for the Commentator. An index the record has no move at (the tip, or
    /// before the first move) is simply absent. Filled here because the
    /// projector already has the record parsed; `RecordStoneCache` would
    /// otherwise re-parse the whole SGF in C++ on every projection.
    public let recordedMoveVertices: [Int: String]

    public init(width: Int,
                height: Int,
                blackPoints: [BoardPoint],
                whitePoints: [BoardPoint],
                moveOrder: [BoardPoint: Character],
                blackStonesCaptured: Int,
                whiteStonesCaptured: Int,
                toMove: PlayerColor,
                lastMoveVertex: String?,
                recordedMoveVertices: [Int: String] = [:]) {
        self.width = width
        self.height = height
        self.blackPoints = blackPoints
        self.whitePoints = whitePoints
        self.moveOrder = moveOrder
        self.blackStonesCaptured = blackStonesCaptured
        self.whiteStonesCaptured = whiteStonesCaptured
        self.toMove = toMove
        self.lastMoveVertex = lastMoveVertex
        self.recordedMoveVertices = recordedMoveVertices
    }

    /// A blank board of the given size — what a nil key publishes (nothing is
    /// selected, so there is no record position to draw).
    public static func empty(width: Int, height: Int) -> RecordPosition {
        RecordPosition(width: width,
                       height: height,
                       blackPoints: [],
                       whitePoints: [],
                       moveOrder: [:],
                       blackStonesCaptured: 0,
                       whiteStonesCaptured: 0,
                       toMove: .black,
                       lastMoveVertex: nil)
    }
}

/// The identity of the position the app is displaying. Everything the replay
/// needs to produce a position, and nothing else — so equal keys mean an
/// identical board and the projector can skip the work.
///
/// `sgf` is carried by value (not just the record id) because a played move
/// rewrites the record's SGF in place: an id + index pair would compare equal
/// across a real change.
public struct RecordPositionKey: Equatable, Sendable {
    public let recordID: PersistentIdentifier?
    public let sgf: String
    public let index: Int
    public let isBranchActive: Bool

    public init(recordID: PersistentIdentifier?,
                sgf: String,
                index: Int,
                isBranchActive: Bool) {
        self.recordID = recordID
        self.sgf = sgf
        self.index = index
        self.isBranchActive = isBranchActive
    }
}

/// The ONLY writer of `Stones.blackPoints`/`whitePoints`/`moveOrder`/
/// `blackStonesCaptured`/`whiteStonesCaptured` and of
/// `BoardSize.width`/`height`. It also SETS `GobanState.isShownBoard` — not
/// exclusively: `GobanState.consumeShowBoardResponse` sets it too, when the
/// engine's `= MoveNum` line lands. One instance per `GameSession`
/// (`session.recordPosition`), so the replay cache and the "what is on screen"
/// key are shared by every driver of that session.
@MainActor
public final class RecordPositionProjector {
    /// The key of the position currently on screen, or nil when the board is
    /// blank. `GameSession.maybeCollectAnalysis` stamps incoming analysis with
    /// it, which is how `GobanState.maybeUpdateAnalysisData` can tell whether
    /// the numbers it is about to persist belong to the index it is writing.
    public private(set) var currentKey: RecordPositionKey?

    /// The position last published, returned unchanged for a repeat key.
    public private(set) var currentPosition: RecordPosition?

    /// False until the first `project`, so the very first call publishes even
    /// when the key is nil (the board has to start SOMEWHERE).
    private var hasProjected = false

    /// One parsed record: the C++ parse and the engine-free replay built from
    /// it, kept TOGETHER so a cache hit serves both the position and the move
    /// list without a second `SgfOperations` (a full C++ SGF parse).
    private struct ParsedRecord {
        let operations: SgfOperations
        var replay: SgfReplay
    }

    /// Parsed records keyed by SGF string, newest last. A replay memoizes
    /// checkpoints as it is scrubbed, so keeping the handful the user is moving
    /// between (the open game, plus a branch line) turns navigation into a
    /// lookup. A played move rewrites the SGF, so play itself always misses —
    /// the cache is for navigation, which is where the scrubbing happens.
    private var parsed: [(sgf: String, record: ParsedRecord)] = []
    private static let parseCacheCapacity = 4

    public init() {}

    /// Publishes `key`'s position into the display models. Idempotent: the
    /// same key writes nothing and returns the position already on screen.
    ///
    /// `Analysis` is cleared when the board size changes (as
    /// `adjustBoardDimensionsIfNeeded` did) and whenever the key changes while
    /// the engine is NOT in sync — the numbers were collected for the position
    /// being left, and nothing has analysed the new one yet.
    @discardableResult
    public func project(key: RecordPositionKey?,
                        into stones: Stones,
                        board: BoardSize,
                        analysis: Analysis,
                        gobanState: GobanState) -> RecordPosition {
        if hasProjected, key == currentKey, let currentPosition {
            return currentPosition
        }

        // A nil key (nothing selected) and a record the parser rejects both
        // publish an empty board at the size already on screen — never a 0x0
        // or 1x1 grid derived from a failed parse.
        let position = key.flatMap { resolve($0) }
            ?? RecordPosition.empty(width: Int(board.width), height: Int(board.height))

        let sizeChanged = board.width != CGFloat(position.width)
            || board.height != CGFloat(position.height)
        if sizeChanged || !stones.isReady {
            analysis.clear()
        }

        // Two transactions, both synchronous: stones and geometry swap
        // instantly (a stone does not slide across the board), while the
        // move-number digits animate onto their new points.
        withAnimation(.none) {
            stones.blackPoints = position.blackPoints
            stones.whitePoints = position.whitePoints
            stones.blackStonesCaptured = position.blackStonesCaptured
            stones.whiteStonesCaptured = position.whiteStonesCaptured
            board.width = CGFloat(position.width)
            board.height = CGFloat(position.height)
        }
        withAnimation(.spring) {
            stones.moveOrder = position.moveOrder
        }

        // Wrap-around is harmless: every reader compares generations for
        // inequality (the haptic trigger), never for order.
        stones.positionGeneration &+= 1
        gobanState.isShownBoard = true

        hasProjected = true
        currentKey = key
        currentPosition = position
        return position
    }

    // MARK: - Replay

    /// Nil when the record cannot be drawn — see `parsedRecord(for:)`.
    private func resolve(_ key: RecordPositionKey) -> RecordPosition? {
        guard var record = parsedRecord(for: key.sgf) else { return nil }
        let position = record.replay.position(at: key.index)
        store(record, for: key.sgf)

        let width = record.replay.width
        let height = record.replay.height

        func points(_ vertices: [String]) -> [BoardPoint] {
            vertices.compactMap { BoardPoint(move: $0, width: width, height: height) }
        }

        var moveOrder: [BoardPoint: Character] = [:]
        for mark in position.lastThreeMoves {
            guard let point = BoardPoint(move: mark.vertex, width: width, height: height) else { continue }
            moveOrder[point] = Character(String(mark.order))
        }

        // The window is appended oldest-first, so the last entry is the newest
        // move the ENGINE accepted. See `RecordPosition.lastMoveVertex` for why
        // the replay's own `lastMoveVertex` is deliberately not used.
        let lastMoveVertex = position.lastThreeMoves.last?.vertex

        // The `moves` cache pair, read off the parse already in hand. Absent
        // indices (before the first move, and at the tip, where there is no
        // move N yet) simply produce no entry.
        var recordedMoveVertices: [Int: String] = [:]
        for index in [key.index - 1, key.index] where index >= 0 {
            guard let location = record.operations.getMove(at: index)?.location,
                  let vertex = BoardSize.locationToMove(location: location,
                                                        width: width,
                                                        height: height)
            else { continue }
            recordedMoveVertices[index] = vertex
        }

        return RecordPosition(width: width,
                              height: height,
                              blackPoints: points(position.blackVertices),
                              whitePoints: points(position.whiteVertices),
                              moveOrder: moveOrder,
                              blackStonesCaptured: position.blackCaptures,
                              whiteStonesCaptured: position.whiteCaptures,
                              toMove: position.toMove,
                              lastMoveVertex: lastMoveVertex,
                              recordedMoveVertices: recordedMoveVertices)
    }

    /// Parses `sgf` the way the app parses SGF everywhere else — the C++
    /// `CompactSgf` behind `SgfOperations` — so display, navigation and the
    /// engine feed all share one index space. The bridge-free `SgfHeaderScan`
    /// construction stays for targets that cannot link the engine (the watch).
    ///
    /// Nil when the parser rejected the record: `SgfCpp` reports a 0x0 board
    /// for anything it could not read, and neither a 0-wide board (which traps
    /// `BoardSize.locationToMove`'s `1...height` range) nor `SgfReplay`'s
    /// clamped 1x1 substitute is a board worth drawing. A rejected record is
    /// never cached, so a later fix to the same string is picked up.
    private func parsedRecord(for sgf: String) -> ParsedRecord? {
        if let index = parsed.firstIndex(where: { $0.sgf == sgf }) {
            let entry = parsed.remove(at: index)
            parsed.append(entry)
            return entry.record
        }

        let operations = SgfOperations(sgf: sgf)
        guard operations.xSize > 0, operations.ySize > 0 else { return nil }
        let placements = operations.placements()
        func setup(_ kind: Placement.Kind) -> [GoPoint] {
            placements.filter { $0.kind == kind }.map { GoPoint(x: $0.x, y: $0.y) }
        }

        var moves: [SgfReplay.RecordedMove] = []
        let moveCount = operations.moveSize ?? 0
        moves.reserveCapacity(moveCount)
        for index in 0..<moveCount {
            // A nil here would shift every later index, so stop rather than
            // skip: the record is malformed past this point and the shorter
            // replay is the honest one.
            guard let move = operations.getMove(at: index) else { break }
            moves.append(SgfReplay.RecordedMove(
                color: move.player == .black ? .black : .white,
                point: move.location.pass ? nil : GoPoint(x: move.location.x,
                                                          y: move.location.y)))
        }

        let built = ParsedRecord(
            operations: operations,
            replay: SgfReplay(width: operations.xSize,
                              height: operations.ySize,
                              setupBlack: setup(.black),
                              setupWhite: setup(.white),
                              setupEmpty: setup(.removal),
                              moves: moves))
        store(built, for: sgf)
        return built
    }

    /// Writes a parsed record back after `position(at:)` memoized new
    /// checkpoints into its replay (SgfReplay is a value type), keeping the
    /// cache bounded.
    private func store(_ record: ParsedRecord, for sgf: String) {
        if let index = parsed.firstIndex(where: { $0.sgf == sgf }) {
            parsed.remove(at: index)
        }
        parsed.append((sgf: sgf, record: record))
        if parsed.count > Self.parseCacheCapacity {
            parsed.removeFirst(parsed.count - Self.parseCacheCapacity)
        }
    }
}
