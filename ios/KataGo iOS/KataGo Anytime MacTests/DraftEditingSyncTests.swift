import Testing
import Foundation
import SwiftData
@testable import KataGoGameStore

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

/// The engine-free load, driven through the SAME loop the app runs
/// (`DraftEditingSync.settle`) with a REAL `DraftController` and the REAL rule
/// that decides whether a load leaves the board unlocked
/// (`GameRecord.editingAfterLoad`).
///
/// Separate from `DraftEditingSyncTests` on purpose: this one needs a SwiftData
/// container and the main actor, and the eight pure-decision tests above must
/// not pay for either.
@MainActor
struct DraftEditingSyncLoadTests {

    private func tempMirrorStore() throws -> DraftMirrorStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "draft-editing-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return DraftMirrorStore(directory: url)
    }

    /// The board never waits for the engine, so `load(game:)` now runs on a
    /// cold launch with no engine in the process at all — its feed is dropped
    /// by the command gate and remembered for the handshake. The draft
    /// derivation that rides the same call must NOT be dropped with it: an
    /// unlocked board with no draft means every write goes straight to
    /// SwiftData and iCloud, which is precisely what drafts exist to prevent.
    ///
    /// Nothing about an engine appears anywhere below, which is the claim: the
    /// inputs are the record's SGF and the draft state, and only those.
    @Test func loadWithoutEngineStillDerivesDraft() throws {
        // A local `let` keeps the container alive for the whole function; only
        // a container returned from a helper and immediately discarded leaves
        // the context outliving its store (see `DraftControllerTests`).
        let container = try ModelContainer(
            for: GameRecord.self, Config.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext

        let controller = DraftController(mirrorStore: try tempMirrorStore())

        // A pristine record, as a fresh launch or ⌘N leaves one.
        let record = GameRecord(config: Config())
        record.name = GameRecord.defaultName
        context.insert(record)
        try context.save()

        // What `GobanState.loadGame` derives — the REAL rule, not a literal.
        var selected: GameRecord? = record
        let isEditing = GameRecord.editingAfterLoad(sgf: record.sgf, unlockRequested: false)
        #expect(isEditing)
        #expect(controller.draft == nil)

        // The same loop `MainWindowController.syncDraftToEditingState()` runs.
        DraftEditingSync.settle(
            inputs: {
                DraftEditingSync.Inputs(
                    isEditing: isEditing,
                    hasDraft: controller.draft != nil,
                    isDirty: controller.isDirty,
                    draftStandsForSelection: controller.isDraftRecord(selected),
                    hasSelection: selected != nil)
            },
            apply: { action in
                switch action {
                case .none:
                    break
                case .closeStale:
                    controller.close()
                case .unlock:
                    break   // the controller writes `gobanState.isEditing`
                case .open:
                    guard let origin = selected else { return }
                    selected = controller.open(origin: origin)
                }
            })

        let draft = try #require(controller.draft)
        #expect(draft.origin === record)
        // The window now points at the DETACHED clone, not the stored game.
        #expect(selected === draft.record)
        #expect(controller.isDraftRecord(selected))
        #expect(draft.record !== record)
        #expect(!controller.isDirty)
    }

    /// A game with a move in it stays LOCKED after a load, so no draft is
    /// opened and the stored record is never cloned. The positive control for
    /// the test above: without it, an `editingAfterLoad` stuck at `true` would
    /// pass both.
    @Test func loadingAPlayedGameOpensNoDraft() throws {
        let container = try ModelContainer(
            for: GameRecord.self, Config.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext

        let controller = DraftController(mirrorStore: try tempMirrorStore())

        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        record.name = "Played"
        context.insert(record)
        try context.save()

        var selected: GameRecord? = record
        let isEditing = GameRecord.editingAfterLoad(sgf: record.sgf, unlockRequested: false)
        #expect(!isEditing)

        DraftEditingSync.settle(
            inputs: {
                DraftEditingSync.Inputs(
                    isEditing: isEditing,
                    hasDraft: controller.draft != nil,
                    isDirty: controller.isDirty,
                    draftStandsForSelection: controller.isDraftRecord(selected),
                    hasSelection: selected != nil)
            },
            apply: { action in
                if case .open = action, let origin = selected {
                    selected = controller.open(origin: origin)
                }
            })

        #expect(controller.draft == nil)
        #expect(selected === record)
    }
}
