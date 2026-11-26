//
//  FreshBoard.swift
//  KataGoUICore
//
//  The rule for a *fresh board* (CONTEXT.md): an open game nobody has done
//  anything with. It decides when the iOS start card stands in for the score
//  chart, and it is here rather than in the view so the unit target pins it.
//

import KataGoGameStore

public enum FreshBoard {
    /// Whether the open game is a fresh board: no moves in its record, a
    /// person on both sides, and nothing in flight on top of it.
    ///
    /// `moveCount` is the record's own count, read off a replay by the caller
    /// (a view body must not run one). Nil — not read yet, or a record that
    /// cannot be parsed — is never fresh: an unknown game is not offered a
    /// new one in place of its chart.
    @MainActor
    public static func isFresh(moveCount: Int?, config: Config, gobanState: GobanState) -> Bool {
        moveCount == 0
            && config.blackMaxTime == 0
            && config.whiteMaxTime == 0
            && !gobanState.isBranchActive
            && !gobanState.isAutoPlaying
    }
}
