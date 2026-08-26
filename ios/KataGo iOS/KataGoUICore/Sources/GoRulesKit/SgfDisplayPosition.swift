//
//  SgfDisplayPosition.swift
//  GoRulesKit
//
//  The saved-game position a non-app surface draws, replayed from the record's
//  own SGF.
//
//  The Saved Game widget used to read `GameRecord.blackStones[currentIndex]`,
//  falling back to the highest index the cache happened to hold. Only a host
//  running the position projector fills that cache, so a record whose cursor
//  outran it — a branch saved as a new game parks on the branch tip while its
//  dictionaries stop at the divergence — drew a DIFFERENT move than the phone
//  was showing. The row, the card and the board all derive their picture from
//  the record now (ADR 0014); this is the same rule for the widget, using the
//  bridge-free replay an appex can actually link.
//
//  Same engine the watch app and the Messages extension already replay with, so
//  this adds no new stance about what an SGF means — see the differential tests
//  that hold `SgfReplay` to the C++ board's answers.
//

import Foundation
import KataGoAnalysisKit
import KataGoGameStore

/// Replays a saved game to the position it is parked on.
@MainActor
public enum SgfDisplayPosition {
    /// The record's own SGF at its own cursor, or nil when the SGF cannot be
    /// scanned at all.
    ///
    /// Nil means unreadable, and the caller decides what an unreadable game
    /// looks like — this returns no board rather than an empty one, so "no
    /// stones because the game has none" and "no stones because we could not
    /// read it" stay distinguishable.
    public static func resolve(_ record: GameRecord) -> RecordDisplayPosition? {
        resolve(sgf: record.sgf, index: record.currentIndex)
    }

    /// The same resolution addressed by value, for tests and for any caller that
    /// holds an SGF rather than a record.
    public static func resolve(sgf: String, index: Int) -> RecordDisplayPosition? {
        guard let scan = SgfHeaderScan(sgf: sgf) else { return nil }
        var replay = SgfReplay(scan: scan)

        // Clamp here rather than trusting `position(at:)` to do it silently: the
        // clamped value IS the index the caller captions the board with, so it
        // has to come back out. A cursor past the end draws the last move and
        // says "last move", instead of drawing one move and captioning another.
        let drawn = min(max(index, 0), replay.moveCount)
        let position = replay.position(at: drawn)

        return RecordDisplayPosition(width: replay.width,
                                     height: replay.height,
                                     blackVertices: position.blackVertices,
                                     whiteVertices: position.whiteVertices,
                                     moveIndex: drawn)
    }
}
