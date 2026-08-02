//
//  DraftEditingSyncTests.swift
//  KataGo Anytime MacTests
//

import Testing

struct DraftEditingSyncTests {

    /// The hole the rule exists to close: a load that leaves `isEditing`
    /// already true produces no edge, so the edge-driven version left the board
    /// unlocked over a STORED record with every write path pointed at SwiftData.
    @Test func unlockedWithNoDraftAlwaysOpensOne() {
        #expect(DraftEditingSync.decide(isEditing: true,
                                        hasDraft: false,
                                        isDirty: false,
                                        draftStandsForSelection: false,
                                        hasSelection: true) == .open)
    }

    @Test func unlockedWithNothingSelectedHasNothingToDraft() {
        #expect(DraftEditingSync.decide(isEditing: true,
                                        hasDraft: false,
                                        isDirty: false,
                                        draftStandsForSelection: false,
                                        hasSelection: false) == .none)
    }

    @Test func lockedWithNoDraftIsSettled() {
        #expect(DraftEditingSync.decide(isEditing: false,
                                        hasDraft: false,
                                        isDirty: false,
                                        draftStandsForSelection: false,
                                        hasSelection: true) == .none)
    }

    /// `loadGame` re-derives `isEditing` from the SGF, so a reload under an
    /// open draft (crash restore, or a New Game whose load was deferred behind
    /// an engine relaunch) must not be able to lock the board and take the
    /// unsaved draft with it.
    @Test func anOpenDraftOverrulesALockedBoard() {
        #expect(DraftEditingSync.decide(isEditing: false,
                                        hasDraft: true,
                                        isDirty: true,
                                        draftStandsForSelection: true,
                                        hasSelection: true) == .unlock)
    }

    @Test func anUnlockedBoardWithItsOwnDraftIsSettled() {
        #expect(DraftEditingSync.decide(isEditing: true,
                                        hasDraft: true,
                                        isDirty: true,
                                        draftStandsForSelection: true,
                                        hasSelection: true) == .none)
    }

    /// A clean draft survives the exit gate, so a switch can land with it still
    /// standing for the game before. Dropping it loses nothing.
    @Test func aCleanDraftLeftBehindByASwitchIsDropped() {
        #expect(DraftEditingSync.decide(isEditing: true,
                                        hasDraft: true,
                                        isDirty: false,
                                        draftStandsForSelection: false,
                                        hasSelection: true) == .closeStale)
    }

    /// Unreachable by construction — every selection change goes through the
    /// exit gate, which prompts while dirty — but if it ever happened, dropping
    /// unsaved work to tidy up would be the worse failure.
    @Test func aDirtyDraftIsNeverDroppedToTidyUp() {
        #expect(DraftEditingSync.decide(isEditing: true,
                                        hasDraft: true,
                                        isDirty: true,
                                        draftStandsForSelection: false,
                                        hasSelection: true) == .none)
    }

    /// Applying the rule twice always settles: `.closeStale` is the only action
    /// that leaves anything to decide, and it clears the draft.
    @Test func aSecondPassAfterCloseStaleSettles() {
        let first = DraftEditingSync.decide(isEditing: true,
                                            hasDraft: true,
                                            isDirty: false,
                                            draftStandsForSelection: false,
                                            hasSelection: true)
        #expect(first == .closeStale)

        let second = DraftEditingSync.decide(isEditing: true,
                                             hasDraft: false,
                                             isDirty: false,
                                             draftStandsForSelection: false,
                                             hasSelection: true)
        #expect(second == .open)

        let third = DraftEditingSync.decide(isEditing: true,
                                            hasDraft: true,
                                            isDirty: false,
                                            draftStandsForSelection: true,
                                            hasSelection: true)
        #expect(third == .none)
    }
}
