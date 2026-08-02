//
//  DraftEditingSync.swift
//  KataGo Anytime Mac
//

import Foundation

/// The rule that makes "the board is unlocked" and "a draft is open" the same
/// statement.
///
/// The draft used to be opened and closed on the `isEditing` edge, which made
/// its existence a property of a TRANSITION rather than of the state. Any load
/// that left `isEditing` already true produced no edge — switch away from a
/// draft to a game whose SGF is still `GameRecord.defaultSgf`, or Revert onto
/// one, and `GobanState.editingAfterLoad` unlocks the new game while the edge
/// detector sees nothing happen. The board came back unlocked over a STORED
/// record, every pre-existing write path resumed writing straight to SwiftData
/// and iCloud, and no dirty dot hinted at it: the exact bug drafts exist to
/// remove, reachable from the ordinary sidebar.
///
/// Deciding from the state instead, and re-deciding after every load as well
/// as on every change, closes the whole class rather than that one route.
///
/// The equivalence runs both ways on purpose. `loadGame` re-derives `isEditing`
/// from the SGF, so a reload while a draft is open — a crash restore, or a New
/// Game whose load was deferred behind an engine relaunch — would otherwise
/// lock the board and take the unsaved draft down with it. An open draft is the
/// stronger claim, so it wins and the flag is pushed back up. Locking is
/// therefore something only the lock command can do, and it closes the draft
/// itself; anything else that clears `isEditing` without closing the draft is
/// simply overruled, which is the safe direction to fail in.
enum DraftEditingSync: Equatable {
    /// The draft already matches the editing state.
    case none
    /// Drop the draft: it no longer stands for the record on the board. A
    /// clean draft is left open by the exit gate (there is nothing to prompt
    /// about), so a switch can land with it still standing for the game before
    /// — and dropping it loses nothing, because clean means identical to its
    /// origin.
    case closeStale
    /// Unlock the board: a draft is open, so it must be editable.
    case unlock
    /// Open a draft over the selected record: the board is unlocked, so every
    /// write from here has to land in a detached clone.
    case open

    /// `draftStandsForSelection` is object identity — while a draft is open the
    /// selected record IS the draft's detached clone.
    ///
    /// `isDirty` only decides what to do about a STALE draft. One cannot occur:
    /// every path that moves the selection goes through the exit gate first,
    /// which prompts while dirty. Should one ever appear, dropping unsaved work
    /// to tidy up an impossible state would be the worse failure, so it is left
    /// alone for the next exit to prompt about.
    static func decide(isEditing: Bool,
                       hasDraft: Bool,
                       isDirty: Bool,
                       draftStandsForSelection: Bool,
                       hasSelection: Bool) -> DraftEditingSync {
        guard hasDraft else {
            return (isEditing && hasSelection) ? .open : .none
        }
        guard draftStandsForSelection else {
            return isDirty ? .none : .closeStale
        }
        return isEditing ? .none : .unlock
    }
}
