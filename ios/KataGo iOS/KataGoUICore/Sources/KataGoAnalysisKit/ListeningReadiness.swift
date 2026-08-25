//
//  ListeningReadiness.swift
//  KataGoAnalysisKit
//
//  The two pure judgments behind Listen's persistence-free bookkeeping:
//  whether a game is "ready to listen", and where a stored Listening Cursor
//  may resume. Both are derived, never stored — the SwiftData schema is
//  CloudKit-frozen, so readiness is read off the record's analysis coverage
//  each time, and the cursor (device-local UserDefaults) is clamped against
//  the game as it is NOW, not as it was when the cursor was written
//  (ADR 0013: a Listening Session is a read-only projection of the record).
//

import Foundation

public enum ListeningReadiness {
    /// A game is ready to listen when EVERY position carries analysis:
    /// indices 0 (the opening position, needed for move 1's deltas) through
    /// `moveCount` (the final position). Sparse coverage — only the indices
    /// the user happened to visit — is exactly what this marker exists to
    /// distinguish from a Prepared game, so one hole means not ready.
    /// An empty game has nothing to narrate and is never "ready".
    public static func isReady(moveCount: Int, analyzedIndices: Set<Int>) -> Bool {
        guard moveCount > 0 else { return false }
        return (0...moveCount).allSatisfy { analyzedIndices.contains($0) }
    }

    /// Where a session may resume: the stored cursor (the next move number to
    /// narrate, 1-based), clamped into the game's current 1...moveCount. A
    /// cursor past the end of a game that has since shrunk snaps back to the
    /// last move the game still has; no cursor — or a cursor for an
    /// empty game — starts at move 1.
    public static func clampedCursor(stored: Int?, moveCount: Int) -> Int {
        guard let stored, moveCount > 0 else { return 1 }
        return max(1, min(stored, moveCount))
    }
}
