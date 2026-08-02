//
//  GameDraft.swift
//  KataGo Anytime Mac
//

import Foundation
import SwiftData
import KataGoGameStore
import KataGoAnalysisKit

/// An unsaved editing session over one game.
///
/// `record` is a DETACHED `GameRecord` — never inserted into any
/// `ModelContext`. That is the structural safety property the whole design
/// rests on: an unregistered object cannot be autosaved, cannot be reached by
/// `context.save()`, and cannot be exported to CloudKit, no matter what code
/// runs while it is being edited.
///
/// `origin` is the saved record it came from, or nil while untitled (a game
/// created with the New Game sheet that has never been saved, so it has no
/// library row).
@MainActor
final class GameDraft {
    /// The detached record the board, engine and inspector all read and write.
    let record: GameRecord
    /// The saved record to write back to, or nil while untitled.
    private(set) var origin: GameRecord?
    /// The common ancestor: the state at the moment the draft opened.
    private(set) var baseline: DraftSnapshot

    enum SaveOutcome {
        case updatedOrigin(GameRecord)
        case insertedNew(GameRecord)
    }

    /// How a staged save is actually written. A seam only because SwiftData
    /// offers no supported way to make `ModelContext.save()` fail on demand,
    /// and the rollback that failure has to trigger is the whole point of
    /// `commitOrRollback`. Production never replaces it.
    var writeToStore: (ModelContext) throws -> Void = { try $0.save() }

    /// Opens a draft over an existing saved game.
    init(origin: GameRecord) {
        self.record = origin.detachedDraftCopy()
        self.origin = origin
        self.baseline = DraftSnapshot(record: origin, originUUID: origin.uuid)
    }

    /// Opens a draft over a brand-new game that is not in the library. The
    /// record must already be detached; the caller builds it from the New Game
    /// sheet's board size, komi and rules.
    init(untitled record: GameRecord) {
        self.record = record
        self.origin = nil
        self.baseline = DraftSnapshot(record: record, originUUID: nil)
    }

    /// Restores a draft recovered from the crash mirror, whose baseline may
    /// predate changes another device has since made to `origin`.
    init(record: GameRecord, origin: GameRecord?, baseline: DraftSnapshot) {
        self.record = record
        self.origin = origin
        self.baseline = baseline
    }

    func snapshot() -> DraftSnapshot {
        DraftSnapshot(record: record, originUUID: origin?.uuid)
    }

    /// Moves on the draft's mainline. Read via the bridge-free `SgfHeaderScan`
    /// rather than `SgfOperations`, which lives in `KataGoUICore` and would
    /// drag the C++ bridge into the non-hosted test bundle.
    var moveCount: Int {
        SgfHeaderScan(sgf: record.sgf)?.moveCount ?? 0
    }

    /// Whether the origin is still a live row in the store.
    ///
    /// NOT `!origin.isDeleted`. SwiftData sets `isDeleted` only between
    /// `context.delete(_:)` and the following `save()`, and clears it again
    /// afterwards — so by the time a draft comes to save, a deleted origin
    /// reports `isDeleted == false` and would be written onto a tombstone.
    /// `modelContext` is nil'd by that save and STAYS nil, which is the signal
    /// that survives. (A never-inserted record also has a nil context, but
    /// `origin` is only ever nil or a stored record, never a detached one.)
    private var originIsLive: Bool {
        guard let origin else { return false }
        return origin.modelContext != nil
    }

    /// True when the user has changed something worth saving.
    ///
    /// For an untitled draft there is no meaningful baseline to compare
    /// against — it was captured from an empty board — so it is dirty once it
    /// has real content instead. Otherwise abandoning a ⌘N you immediately
    /// changed your mind about would prompt for nothing.
    var isDirty: Bool {
        if origin == nil {
            return moveCount > 0 || !(record.comments?.isEmpty ?? true)
        }
        return DraftComparator.differs(snapshot(), baseline)
    }

    /// True when the saved game changed under the draft — another device's
    /// CloudKit import landed after the draft opened.
    var hasConflict: Bool {
        guard let origin, originIsLive else { return false }
        return DraftComparator.differs(
            DraftSnapshot(record: origin, originUUID: origin.uuid), baseline)
    }

    /// Writes the draft through: onto the origin when there is one, otherwise
    /// as a new record. An origin that has been deleted (locally or by a
    /// remote delete) falls back to inserting, so the user's work survives
    /// rather than being written onto a tombstone.
    @discardableResult
    func save(into context: ModelContext) throws -> SaveOutcome {
        record.lastModificationDate = .now

        if let origin, originIsLive {
            // Captured BEFORE the write, so a failure can put the origin back
            // field for field. `rollback()` alone is not enough: it is
            // documented to discard the context's pending changes, not to
            // refresh an already-materialized model's in-memory properties —
            // and those in-memory properties are exactly what the conflict
            // check, the window subtitle and Revert all read.
            let priorOrigin = DraftSnapshot(record: origin, originUUID: origin.uuid)
            snapshot().apply(to: origin)
            try commitOrRollback(context) { priorOrigin.apply(to: origin) }
            rebaseline()
            return .updatedOrigin(origin)
        }

        let inserted = record.detachedDraftCopy()
        inserted.uuid = UUID()
        context.insert(inserted)
        try commitOrRollback(context)
        origin = inserted
        rebaseline()
        return .insertedNew(inserted)
    }

    /// The conflict sheet's non-destructive escape hatch: insert the draft as
    /// a separate game and leave the incoming version untouched, so nothing is
    /// lost on either side.
    @discardableResult
    func saveAsNewGame(into context: ModelContext) throws -> GameRecord {
        let copy = record.detachedDraftCopy()
        copy.uuid = UUID()
        copy.name = "\(record.name) (conflicted copy)"
        copy.lastModificationDate = .now
        context.insert(copy)
        try commitOrRollback(context)
        return copy
    }

    /// Commits the mutations the callers above have already staged, and undoes
    /// them when the write fails.
    ///
    /// The undo is the point. `apply(to:)` and `insert(_:)` mutate the context
    /// BEFORE the save, and `container.mainContext` autosaves — so without it a
    /// transient failure leaves the draft sitting in the context, SwiftData
    /// retries on its own cycle, and the changes reach the store and CloudKit
    /// with the user never having saved, underneath an alert that says they are
    /// "still here and unsaved". Two quieter consequences ride along:
    /// `hasConflict` would then compare a mutated origin against the baseline
    /// and read "Changed on another device" for the rest of the session, and
    /// Revert would revert onto an origin already carrying the draft.
    ///
    /// `rollback()` discards every pending change in the context, not only
    /// ours. That is the right trade here: a failed save means the context is
    /// no longer in a state anybody reasoned about, and a discarded analysis
    /// cache re-derives on the next move.
    private func commitOrRollback(_ context: ModelContext,
                                  undo: () -> Void = {}) throws {
        do {
            try writeToStore(context)
        } catch {
            undo()
            context.rollback()
            throw error
        }
    }

    /// Re-reads the baseline from the origin after a successful save, so the
    /// draft object can stay live and selected without churning identity.
    func rebaseline() {
        if let origin, originIsLive {
            baseline = DraftSnapshot(record: origin, originUUID: origin.uuid)
        } else {
            baseline = snapshot()
        }
    }
}
