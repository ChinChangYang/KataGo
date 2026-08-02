//
//  DraftComparator.swift
//  KataGo Anytime Mac
//

import Foundation
import KataGoGameStore

/// One comparison serving two questions, both against the baseline snapshot
/// taken when the draft opened (the common ancestor):
///
///   * `differs(draft, baseline)`  — *dirty*: the user changed something.
///   * `differs(origin, baseline)` — *conflict*: another device changed the
///     saved game while the draft was open.
///
/// It compares exactly four things: `sgf`, `name`, `comments`, and every
/// `Config` field. All of `Config` rather than a hand-picked subset, so the
/// list cannot silently drift out of date as settings are added.
///
/// Everything else is ignored on purpose — cursor position and derived
/// analysis data. `maybeUpdateAnalysisData` rewrites `winRates`/`scoreLeads`/
/// `bestMoves`/`ownership*` every few hundred milliseconds while analysis
/// runs; counting those would light up the dirty marker the instant a game is
/// unlocked and make "Save changes?" fire for work the user never did.
enum DraftComparator {
    static func differs(_ a: DraftSnapshot, _ b: DraftSnapshot) -> Bool {
        a.game.sgf != b.game.sgf
            || a.game.name != b.game.name
            || a.game.comments != b.game.comments
            || a.config != b.config
    }

    /// Reads exactly the fields `differs` compares, and nothing else.
    ///
    /// Its only purpose is to be called inside `withObservationTracking`, so a
    /// change to anything that can flip the dirty flag — from ANY writer, not
    /// just the ones anybody remembered to wire up — fires the callback, and a
    /// change to the analysis data ignored above does not (that data is
    /// rewritten every few hundred milliseconds while analysis runs, and
    /// tracking it would re-arm the mirror's debounce forever).
    ///
    /// It sits here rather than next to the observer so the two lists are one
    /// screen apart and cannot drift.
    @MainActor
    static func touchComparedFields(of record: GameRecord) {
        _ = record.sgf
        _ = record.name
        _ = record.comments
        _ = DraftSnapshot.ConfigFields(config: record.concreteConfig)
    }
}
