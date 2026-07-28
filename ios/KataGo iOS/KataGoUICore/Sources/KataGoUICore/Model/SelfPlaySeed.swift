//
//  SelfPlaySeed.swift
//  KataGoUICore
//
//  The value carried from TVReviewScreen into TVSelfPlayScreen when Auto-Play
//  reaches the end of an unfinished recorded game and hands off to a live AI
//  continuation.
//
//  A VALUE, not a GameRecord or a PersistentIdentifier: it rides inside a
//  NavigationPath (which requires only Hashable), and a freshly built model
//  carries a temporary identifier that SwiftData remaps on save — which would
//  change the route's hash after it is already on the path.
//

import Foundation

public struct SelfPlaySeed: Hashable, Sendable {
    /// The reviewed game's SGF, verbatim. Board size, komi and rules ride
    /// inside it: `loadGame` overwrites the Config's rule/komi fields from the
    /// SGF on every load, so carrying them on the Config alone would be lost.
    public let sgf: String
    /// The SGF's move count. The seeded record sits at its TIP so
    /// `isOverwriting` stays false and `loadGame`'s rewind loop runs zero times.
    public let moveCount: Int
    /// `Config.rule`, the one field `createGameRecord` does NOT derive from the
    /// SGF.
    public let rule: Int
    /// Shown as the continuation's title, so it does not claim to be the demo.
    public let name: String
    /// Per-move history so the continuation's chart continues the reviewed
    /// game's curve instead of starting empty.
    public let scoreLeads: [Int: Float]
    public let winRates: [Int: Float]

    public init(sgf: String,
                moveCount: Int,
                rule: Int,
                name: String,
                scoreLeads: [Int: Float] = [:],
                winRates: [Int: Float] = [:]) {
        self.sgf = sgf
        self.moveCount = moveCount
        self.rule = rule
        self.name = name
        self.scoreLeads = scoreLeads
        self.winRates = winRates
    }
}
