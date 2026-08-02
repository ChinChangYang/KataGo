//
//  GameRecord+Draft.swift
//  KataGo Anytime Mac
//

import Foundation
import KataGoGameStore

extension GameRecord {
    /// A detached copy for editing.
    ///
    /// Differs from `clone()` deliberately: `clone()` mints a fresh `uuid`,
    /// appends `" (copy)"` to the name, and stamps `lastModificationDate` to
    /// now — all correct for a user-visible duplicate, all wrong for a draft,
    /// which must be indistinguishable from its origin until the user changes
    /// something.
    ///
    /// The result is NEVER inserted into a `ModelContext`. That is the property
    /// the whole draft design rests on: an unregistered object cannot be
    /// autosaved, cannot be reached by `context.save()`, and cannot be exported
    /// to CloudKit, no matter what code runs.
    func detachedDraftCopy() -> GameRecord {
        let newConfig = Config(config: config)

        let copy = GameRecord(
            sgf: sgf,
            currentIndex: currentIndex,
            config: newConfig,
            name: name,
            lastModificationDate: lastModificationDate,
            comments: comments,
            thumbnail: thumbnail,
            scoreLeads: scoreLeads,
            bestMoves: bestMoves,
            winRates: winRates,
            deadBlackStones: deadBlackStones,
            deadWhiteStones: deadWhiteStones,
            blackSchrodingerStones: blackSchrodingerStones,
            whiteSchrodingerStones: whiteSchrodingerStones,
            moves: moves,
            blackStones: blackStones,
            whiteStones: whiteStones,
            ownershipWhiteness: ownershipWhiteness,
            ownershipScales: ownershipScales,
            width: width,
            height: height
        )

        // `GameRecord.init` has no `uuid` parameter and defaults it to a fresh
        // UUID; the draft must keep the origin's so deep links, the widget's
        // configured game, and `resolvedRecord` all still line up. There is no
        // collision risk because the draft is never inserted.
        copy.uuid = uuid
        newConfig.gameRecord = copy
        return copy
    }
}
