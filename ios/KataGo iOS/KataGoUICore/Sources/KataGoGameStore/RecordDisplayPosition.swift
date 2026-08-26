//
//  RecordDisplayPosition.swift
//  KataGoGameStore
//
//  The board a saved game shows outside the app — resolved once, then carried.
//
//  This type exists to break a dependency cycle rather than to model anything
//  new. Replaying a game needs the rules (`GoRulesKit`), and `GoRulesKit`
//  already sits ABOVE this module, so nothing here can call it. The widget's
//  snapshot ladder therefore takes the resolution as an argument — see
//  `SavedGameSnapshot.resolveSnapshot(configuredID:container:position:)` — and
//  this is the shape that crosses the seam.
//

import Foundation

/// A saved game's position as a non-app surface draws it: geometry, stones, and
/// the index those stones actually belong to.
///
/// `moveIndex` is load-bearing, not incidental. It is the record's cursor
/// CLAMPED into the game, and everything the widget shows about the position —
/// the stones, the "Move N" line, the comment — is keyed on it, so the three can
/// never describe different moves. A record whose cursor points past its own
/// SGF (a game that shrank, a hand-edited record) draws its last move and says
/// so, instead of drawing one move and captioning another.
public struct RecordDisplayPosition: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let blackVertices: [String]
    public let whiteVertices: [String]
    /// The index actually drawn: `currentIndex` clamped to `0...moveCount`.
    public let moveIndex: Int

    public init(width: Int,
                height: Int,
                blackVertices: [String],
                whiteVertices: [String],
                moveIndex: Int) {
        self.width = width
        self.height = height
        self.blackVertices = blackVertices
        self.whiteVertices = whiteVertices
        self.moveIndex = moveIndex
    }

    /// The board to draw for a record whose SGF cannot be read at all.
    ///
    /// An empty grid at the record's cached size, parked at move 0. The cached
    /// `width`/`height` are exactly what ADR 0014 refuses to trust when a replay
    /// is available — but here there is no replay to trust instead, and a
    /// plausible grid beats a 19×19 guess for a 9×9 game. Nothing is drawn on
    /// it, so it cannot be confidently wrong about stones.
    public static func unreadable(width: Int?, height: Int?) -> RecordDisplayPosition {
        RecordDisplayPosition(width: width ?? 19,
                              height: height ?? 19,
                              blackVertices: [],
                              whiteVertices: [],
                              moveIndex: 0)
    }
}
