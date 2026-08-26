//
//  RecordBoardPreview.swift
//  KataGoUICore
//
//  The board a game-list row draws, derived from the record and nothing else.
//
//  A library row's picture used to be a CAPTURE: the app rasterized whatever
//  was on screen and stored the bytes on a `GameRecord`. The screen belongs to
//  the session, not to any one game, so the pairing of "these pixels" with
//  "that record" was an assumption — and a game switch, which moves the board
//  and the selection one at a time, broke it: the outgoing game was stamped
//  with the incoming game's stones and the wrong image synced to every device
//  (ADR 0014).
//
//  Here the picture is a PROJECTION instead: the record's own SGF replayed to
//  the record's own index. There is nothing to mispair, so a row cannot draw
//  another game's board — not because a guard refuses, but because the other
//  game's stones are never in reach.
//

import Foundation
import SwiftData

/// Exactly what a library row draws: geometry, stones, and the last-move
/// marker.
///
/// Deliberately smaller than `RecordPosition` — no captures, no `toMove`, no
/// `moveOrder`, no `recordedMoveVertices` — because a row draws no analysis
/// overlay, no move numbers and no coordinates. Carrying them would invite a
/// future row to show session-shaped things again.
///
/// Vertices rather than `BoardPoint`s: `SgfReplay.Position` produces GTP vertex
/// strings and `ReportBoardView` consumes them, so this path skips the
/// `BoardPoint` round-trip `RecordPositionProjector.resolve` has to make for
/// `Stones`.
public struct RecordBoardPreview: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let blackVertices: [String]
    public let whiteVertices: [String]
    /// The last move's vertex, from the ENGINE-parity source: the newest entry
    /// of the replay's last-three window. Never `SgfReplay.Position
    /// .lastMoveVertex`, which is record-parity and reports a REFUSED move's
    /// point — the engine never played it, so the row must not mark it. Nil at
    /// index 0, after a pass, and when the window is empty.
    public let lastMoveVertex: String?

    public init(width: Int,
                height: Int,
                blackVertices: [String],
                whiteVertices: [String],
                lastMoveVertex: String?) {
        self.width = width
        self.height = height
        self.blackVertices = blackVertices
        self.whiteVertices = whiteVertices
        self.lastMoveVertex = lastMoveVertex
    }
}

/// Resolves a record to the board its row should draw.
///
/// Main-actor confined because `SgfOperations` wraps the non-`Sendable` C++
/// bridge parser, and because the cache below is process-global.
@MainActor
public enum RecordBoardPreviewSource {
    /// The position `record` is parked on, replayed from its OWN sgf.
    ///
    /// Nil when the record cannot be drawn — the same rejection
    /// `RecordPositionProjector.resolve` makes, so a row and the board agree
    /// about which records are unreadable.
    public static func preview(for record: GameRecord) -> RecordBoardPreview? {
        // `isBranchActive: false` is not a default being accepted — it is the
        // point. A scratch branch lives on `GobanState.branchSgf` and is never
        // written to the record, so reading the record's own sgf cannot depict
        // one. `RecordStoneCache.write` has to REFUSE branch positions because
        // it is handed the session's; this reads the game's.
        preview(key: RecordPositionKey(recordID: record.persistentModelID,
                                       sgf: record.sgf,
                                       index: record.currentIndex,
                                       isBranchActive: false))
    }

    /// The FINISHED game — the position after every recorded move, wherever the
    /// record's cursor happens to sit.
    ///
    /// This is deliberately NOT what a library row draws. A row depicts the
    /// game at the move it is parked on, because a row is about a game you are
    /// in the middle of. There is one thing in the app that is cover art for a
    /// whole game instead: the tvOS empty state's bundled sample card. Its
    /// record parks at move 0 on purpose — review starts at the opening of the
    /// 1846 game, not its end — so `preview(for:)` would honestly draw an empty
    /// board where the card wants the finished position.
    ///
    /// `.max` is the request, not a sentinel to decode: the replay clamps every
    /// index into `0...moveCount`, so "past the end" resolves to the end. Keyed
    /// on that same `.max`, so the card hits the cache like any other.
    public static func finishedGamePreview(for record: GameRecord) -> RecordBoardPreview? {
        preview(key: RecordPositionKey(recordID: record.persistentModelID,
                                       sgf: record.sgf,
                                       index: .max,
                                       isBranchActive: false))
    }

    /// The same resolution addressed by value — the seam tests use, so the
    /// rules below can be pinned without a `ModelContainer`.
    public static func preview(sgf: String, index: Int) -> RecordBoardPreview? {
        preview(key: RecordPositionKey(recordID: nil,
                                       sgf: sgf,
                                       index: index,
                                       isBranchActive: false))
    }

    // MARK: - Cache

    /// Resolved previews, newest last, keyed by `RecordPositionKey`.
    ///
    /// The key is reused rather than invented for the reason its own doc gives:
    /// it carries `sgf` BY VALUE, because a played move rewrites the record's
    /// SGF in place and an id + index pair would compare equal across a real
    /// change. That is exactly what makes a row self-invalidating when its game
    /// gets a move, with no invalidation logic anywhere.
    ///
    /// Caching matters because the DRAW is not the cost — the PARSE is. A miss
    /// is a full C++ `CompactSgf` parse, which is why the projector keeps a
    /// parse cache of its own (`RecordPositionProjector.parsed`) and why
    /// `RecordStoneCache.writeMoves` goes out of its way not to trigger one.
    /// A library row is re-evaluated on every body pass, and the game list's
    /// query is unbounded, so an uncached row would re-parse its whole game
    /// every time SwiftData saved.
    ///
    /// The resolved preview is cached, never a rasterized image: rows stay live
    /// views, so stone style, vertical flip and appearance changes reflow for
    /// free.
    private static var cache: [(key: RecordPositionKey, value: RecordBoardPreview)] = []

    /// A screenful of rows on the largest layout, plus room to scroll. Values
    /// are two string arrays — tens of KB for the whole cache, against the
    /// per-record HEIC blobs this replaces.
    private static let capacity = 32

    private static func preview(key: RecordPositionKey) -> RecordBoardPreview? {
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            return entry.value
        }

        resolveCountForTesting += 1
        guard let resolved = resolve(key) else {
            // A rejected record is never cached, so a later fix to the same
            // string is picked up — matching `parsedRecord(for:)`.
            return nil
        }
        cache.append((key: key, value: resolved))
        if cache.count > capacity {
            cache.removeFirst(cache.count - capacity)
        }
        return resolved
    }

    /// How many times a preview has actually been RESOLVED — i.e. how many
    /// cache misses have been paid, each one a full C++ SGF parse.
    ///
    /// Exposed so the cache's effectiveness is testable by counting rather than
    /// by timing: a wall-clock assertion about a main-actor loop is both flaky
    /// and, in a parallel suite, disruptive to every neighbour waiting on a
    /// deadline. Same spirit as `RecordStoneCache.write`'s `@discardableResult`
    /// Bool — make the discipline visible instead of hoping it holds.
    public private(set) static var resolveCountForTesting = 0

    /// Test hook: the cache is process-global, so a test that pins invalidation
    /// has to start from a known state.
    public static func resetCacheForTesting() {
        cache.removeAll()
        resolveCountForTesting = 0
    }

    // MARK: - Resolution

    /// Nil when the parser rejected the record.
    ///
    /// Goes through `SgfOperations` — the C++ `CompactSgf` — and NOT the
    /// bridge-free `SgfHeaderScan`, even though the scan is cheaper and
    /// `Sendable`. The scan collapses every mainline AB/AW/AE into index 0
    /// (see its own note), so a mid-game setup node would place stones the
    /// board does not show. Two parsers for one game is the "two sources
    /// disagree" shape this file exists to remove, not a performance knob.
    private static func resolve(_ key: RecordPositionKey) -> RecordBoardPreview? {
        let operations = SgfOperations(sgf: key.sgf)
        guard var replay = RecordReplayBuilder.replay(from: operations) else { return nil }

        // Out-of-range indices clamp inside `position(at:)`, so a record parked
        // past the end of a game that has since shrunk still draws.
        let position = replay.position(at: key.index)

        // Geometry from the REPLAY, never from `GameRecord.width`/`height`.
        // Those are optional cached fields that can disagree with the SGF (an
        // import writes the sgf first), and a grid that disagrees with its own
        // stones is worse than no picture.
        return RecordBoardPreview(width: replay.width,
                                  height: replay.height,
                                  blackVertices: position.blackVertices,
                                  whiteVertices: position.whiteVertices,
                                  // Oldest-first window, so the last entry is
                                  // the newest move the board ACCEPTED.
                                  lastMoveVertex: position.lastThreeMoves.last?.vertex)
    }
}
