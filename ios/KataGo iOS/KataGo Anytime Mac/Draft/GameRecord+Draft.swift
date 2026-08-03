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
    @MainActor
    func detachedDraftCopy() -> GameRecord {
        let copy = GameRecord(config: Config())

        // Copied through DraftSnapshot rather than field-by-field here.
        // DraftSnapshot is the single place the drafted field list lives, so
        // routing the copy through it keeps the copy and the dirty/conflict
        // comparison from ever drifting apart. That matters more than it
        // sounds: `Config(config:)` used to drop six rule fields (ko, scoring,
        // tax, multi-stone suicide, button, white handicap bonus), which would
        // have opened every non-default-rules game's draft already dirty and
        // then written those defaults back over the saved game on Save. That
        // initializer copies them now, but a snapshot-routed copy would have
        // been immune either way.
        DraftSnapshot(record: self, originUUID: nil).apply(to: copy)

        // DraftSnapshot deliberately carries no uuid — applying one must never
        // change a record's identity — so the draft's is set explicitly here.
        copy.uuid = uuid
        copy.config?.gameRecord = copy
        return copy
    }
}
