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
    /// The stones the move that produced THIS index took off the board. A
    /// transient annotation of the last move — not part of the position — so
    /// the board can fade captured stones out as the capturing stone lands
    /// (ADR 0015). Empty at index 0, after a pass, after a refused move, and
    /// whenever the move captured nothing.
    public let capturedPoints: [CapturedStone]

    public init(width: Int,
                height: Int,
                blackPoints: [BoardPoint],
                whitePoints: [BoardPoint],
                moveOrder: [BoardPoint: Character],
                blackStonesCaptured: Int,
                whiteStonesCaptured: Int,
                toMove: PlayerColor,
                lastMoveVertex: String?,
                recordedMoveVertices: [Int: String] = [:],
                capturedPoints: [CapturedStone] = []) {
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
        self.capturedPoints = capturedPoints
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
                       lastMoveVertex: nil,
                       capturedPoints: [])
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
    /// `Analysis` is ASYMMETRIC across a position change (ADR 0011). The
    /// candidate moves go on every key change — `clearCandidates()`. The
    /// ownership map STAYS, and is replaced square by square when the engine
    /// answers for the new position: every intersection carries a unit and a
    /// unit's identity is its point, so two non-empty maps interpolate, while a
    /// map replaced by NOTHING is a delete followed by an insert that no
    /// animation on the arrival can make look like anything but a blink.
    ///
    /// The map is dropped outright — the full `clear()` — only where it can no
    /// longer describe anything on screen:
    ///
    ///   • the board changed size (the units are indexed by a grid that is
    ///     gone);
    ///   • nothing is selected, or the record could not be replayed, so the
    ///     board published is empty. Neither trips `sizeChanged`, because
    ///     `RecordPosition.empty` reuses the size already on screen;
    ///   • a different record arrived (`loadGame` clears too, but a host whose
    ///     own driver projects the new key first would make that a no-op);
    ///   • the engine is not being talked to. This is the one that is not about
    ///     the board: while the command gate is shut — a relaunch, *Held*,
    ///     *Failed* — every command is dropped and `maybeCollectAnalysis`
    ///     refuses every line, so a map carried onto a position the user
    ///     scrubbed to has nothing left that could ever correct it. Standing
    ///     still through a relaunch keeps the map; this method is not even
    ///     called, because the key did not change.
    ///
    /// Sync is deliberately NOT one of them: the board leaves sync on every
    /// step by design, which is how clearing on it blanked the overlay on every
    /// move.
    ///
    /// `engineIsAcceptingCommands` has NO DEFAULT on purpose. Either default
    /// would be a wrong answer someone gets by forgetting: `true` silently
    /// holds a map nothing can correct, `false` reinstates the blink. A new
    /// caller has to say which it is, and the compiler asks.
    @discardableResult
    public func project(key: RecordPositionKey?,
                        into stones: Stones,
                        board: BoardSize,
                        analysis: Analysis,
                        gobanState: GobanState,
                        engineIsAcceptingCommands: Bool) -> RecordPosition {
        if hasProjected, key == currentKey, let currentPosition {
            return currentPosition
        }

        // A nil key (nothing selected) and a record the parser rejects both
        // publish an empty board at the size already on screen — never a 0x0
        // or 1x1 grid derived from a failed parse.
        let resolved = key.flatMap { resolve($0) }
        // A record that could not be replayed draws nothing and gets no feed,
        // so the board would otherwise sit at an empty grid with nothing
        // explaining why. Say so. A NIL key is not unreadable — it is "nothing
        // is selected", which is not a defect.
        gobanState.isRecordUnreadable = (key != nil && resolved == nil)
        let position = resolved
            ?? RecordPosition.empty(width: Int(board.width), height: Int(board.height))

        let sizeChanged = board.width != CGFloat(position.width)
            || board.height != CGFloat(position.height)
        let recordChanged = key?.recordID != currentKey?.recordID
        if sizeChanged || resolved == nil || recordChanged || !engineIsAcceptingCommands {
            analysis.clear()
        } else {
            analysis.clearCandidates()
        }

        // Two transactions, both synchronous: stones and geometry swap
        // instantly (a stone does not slide across the board), while the
        // move-number digits animate onto their new points.
        withAnimation(.none) {
            stones.blackPoints = position.blackPoints
            stones.whitePoints = position.whitePoints
            stones.blackStonesCaptured = position.blackStonesCaptured
            stones.whiteStonesCaptured = position.whiteStonesCaptured
            // Written with the stones, inside the same instant transaction:
            // the motion layer reads it off the position-generation bump, and
            // an annotation one publish behind would fade the wrong stones.
            stones.capturedPoints = position.capturedPoints
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

        // The stones the move that landed on this index took, in BoardPoint's
        // space. Routed through the GTP vertex — the very path `points(_:)`
        // above uses for the stone lists — so a captured point and the stone
        // that used to stand on it can never land on different intersections.
        let capturedPoints: [CapturedStone] = position.capturedByLastMove.compactMap {
            guard let point = BoardPoint(move: $0.point.gtpVertex(boardHeight: height),
                                         width: width,
                                         height: height) else { return nil }
            // `GoColor` also has an `.empty` case a cleared stone can never
            // carry; treat anything that is not Black as White, as every other
            // reader of a replayed colour does.
            return CapturedStone(point: point, color: $0.color == .black ? .black : .white)
        }

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
                              recordedMoveVertices: recordedMoveVertices,
                              capturedPoints: capturedPoints)
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
        guard let replay = RecordReplayBuilder.replay(from: operations) else { return nil }
        let built = ParsedRecord(operations: operations, replay: replay)
        store(built, for: sgf)
        return built
    }

    /// Runs `body` on the replay the board was drawn from — the same
    /// `SgfReplay` instance, so the feed inherits its memoized checkpoints and
    /// its already-discovered refusals — and writes back whatever `body`
    /// memoized (`SgfReplay` is a value type). Nil when the record cannot be
    /// parsed.
    ///
    /// This is how `GobanState.syncEngine(to:)` reaches a replay without a
    /// second parse: the projection that just published the position left the
    /// replay warmed to exactly the index the feed has to reach.
    public func withReplay<T>(for sgf: String, _ body: (inout SgfReplay) -> T) -> T? {
        guard var record = parsedRecord(for: sgf) else { return nil }
        let result = body(&record.replay)
        store(record, for: sgf)
        return result
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
