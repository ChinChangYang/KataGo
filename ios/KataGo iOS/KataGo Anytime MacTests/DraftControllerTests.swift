//
//  DraftControllerTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
import SwiftData
@testable import KataGoGameStore

@MainActor
struct DraftControllerTests {

    private func tempMirrorStore() throws -> DraftMirrorStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "draft-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return DraftMirrorStore(directory: url)
    }

    // The container MUST be a stored property, never returned from a helper and
    // discarded. `try container().mainContext` releases the container at the end
    // of that expression, leaving the ModelContext outliving its own store — that
    // crashes the test runner, which then restarts and re-runs forever. Swift
    // Testing builds a fresh struct per test, so a stored property still gives
    // every test its own isolated in-memory store.
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainer(
            for: GameRecord.self, Config.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func storedGame(in context: ModelContext, name: String = "Saved") throws -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        record.name = name
        context.insert(record)
        try context.save()
        return record
    }

    // MARK: - resolvedRecord: the seam the sidebar depends on

    @Test func resolvedRecordMapsTheDraftBackToItsOrigin() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let controller = DraftController(mirrorStore: try tempMirrorStore())

        let draftRecord = controller.open(origin: origin)

        #expect(draftRecord !== origin)
        #expect(controller.resolvedRecord(draftRecord) === origin)
    }

    @Test func resolvedRecordPassesThroughAnUnrelatedRecord() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let other = try storedGame(in: ctx, name: "Other")
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        _ = controller.open(origin: origin)

        #expect(controller.resolvedRecord(other) === other)
    }

    @Test func resolvedRecordIsNilForAnUntitledDraft() throws {
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let untitled = GameRecord(config: Config())
        let record = controller.openUntitled(untitled)

        #expect(controller.resolvedRecord(record) == nil)
    }

    @Test func resolvedRecordPassesThroughWhenNoDraftIsOpen() throws {
        let ctx = context
        let game = try storedGame(in: ctx)
        let controller = DraftController(mirrorStore: try tempMirrorStore())

        #expect(controller.resolvedRecord(game) === game)
        #expect(controller.resolvedRecord(nil) == nil)
    }

    @Test func isDraftRecordDistinguishesTheDraftFromStoredGames() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let draftRecord = controller.open(origin: origin)

        #expect(controller.isDraftRecord(draftRecord))
        #expect(!controller.isDraftRecord(origin))
        #expect(!controller.isDraftRecord(nil))
    }

    // MARK: - Lifecycle

    @Test func openingAndClosingTracksState() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let controller = DraftController(mirrorStore: try tempMirrorStore())

        #expect(controller.draft == nil)
        _ = controller.open(origin: origin)
        #expect(controller.draft != nil)
        #expect(!controller.isUntitled)
        #expect(controller.displayName == "Saved")

        controller.close()
        #expect(controller.draft == nil)
        #expect(!controller.isDirty)
    }

    @Test func untitledDraftsReportThemselvesAsUntitled() throws {
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let untitled = GameRecord(config: Config())
        untitled.name = "Fresh"
        _ = controller.openUntitled(untitled)

        #expect(controller.isUntitled)
        #expect(controller.displayName == "Fresh")
    }

    @Test func closeRemovesTheMirrorFile() throws {
        let ctx = context
        let store = try tempMirrorStore()
        let controller = DraftController(mirrorStore: store)
        let origin = try storedGame(in: ctx)
        let record = controller.open(origin: origin)
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        store.write(DraftMirror(draft: controller.draft!.snapshot(),
                                baseline: controller.draft!.baseline))
        #expect(store.read() != nil)

        controller.close()

        #expect(store.read() == nil)
    }

    // MARK: - Change tracking
    //
    // `noteChanged()` had exactly one call site — the board's stones-ready
    // handler — so moves and undo scheduled the crash mirror but the comment
    // editor, the config editors and Rename did not: their edits showed no
    // dirty dot and were never mirrored, while File > Save stayed enabled.
    // The controller watches the compared fields itself now, so no writer has
    // to know a draft exists.

    /// A box, because the observation callback is an escaping closure.
    @MainActor private final class Counter { var value = 0 }

    /// The observation callback fires from `willSet` and hops to the next
    /// main-actor turn, so every assertion about it has to let that turn run.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func aCommentEditIsNoticedWithNoExplicitNotify() async throws {
        let ctx = context
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let record = controller.open(origin: try storedGame(in: ctx))
        let changes = Counter()
        controller.onStateChanged = { changes.value += 1 }

        record.comments = [0: "typed into the Comments tab"]
        try await settle()

        #expect(changes.value > 0)
        #expect(controller.isDirty)
    }

    @Test func aRenameIsNoticedWithNoExplicitNotify() async throws {
        let ctx = context
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let record = controller.open(origin: try storedGame(in: ctx))
        let changes = Counter()
        controller.onStateChanged = { changes.value += 1 }

        record.name = "Renamed"
        try await settle()

        #expect(changes.value > 0)
        #expect(controller.isDirty)
    }

    @Test func aConfigEditIsNoticedWithNoExplicitNotify() async throws {
        let ctx = context
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let record = controller.open(origin: try storedGame(in: ctx))
        let changes = Counter()
        controller.onStateChanged = { changes.value += 1 }

        record.concreteConfig.komi = 5.5
        try await settle()

        #expect(changes.value > 0)
        #expect(controller.isDirty)
    }

    /// The other half of the rule: analysis data is rewritten every few hundred
    /// milliseconds while analysis runs, and waking on it would re-arm the
    /// mirror's debounce forever — the mirror would then never be written at
    /// all.
    @Test func analysisDataDoesNotWakeTheTracker() async throws {
        let ctx = context
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let record = controller.open(origin: try storedGame(in: ctx))
        let changes = Counter()
        controller.onStateChanged = { changes.value += 1 }

        record.winRates = [1: 0.7]
        record.ownershipWhiteness = [1: [0.5, 0.5]]
        record.currentIndex = 0
        try await settle()

        #expect(changes.value == 0)
    }

    @Test func aCommentEditReachesTheCrashMirror() async throws {
        let ctx = context
        let store = try tempMirrorStore()
        let controller = DraftController(mirrorStore: store)
        let record = controller.open(origin: try storedGame(in: ctx))

        record.comments = [0: "lost on kill -9 before this was tracked"]
        // Past the one-second mirror debounce.
        try await Task.sleep(for: .milliseconds(1500))

        #expect(store.read()?.draft.game.comments == [0: "lost on kill -9 before this was tracked"])
    }

    /// With no draft open a mirror on disk belongs to a PREVIOUS run and is
    /// waiting to be offered for restore, so a stray notify must not delete it.
    @Test func notifyingWithNoDraftLeavesAPreviousRunsMirrorAlone() throws {
        let ctx = context
        let store = try tempMirrorStore()
        let origin = try storedGame(in: ctx)
        let edited = origin.detachedDraftCopy()
        edited.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        store.write(DraftMirror(draft: DraftSnapshot(record: edited, originUUID: origin.uuid),
                                baseline: DraftSnapshot(record: origin, originUUID: origin.uuid)))

        let controller = DraftController(mirrorStore: store)
        controller.noteChanged()

        #expect(store.read() != nil)
    }

    // MARK: - Save

    @Test func saveWritesThroughAndClearsTheMirror() throws {
        let ctx = context
        let store = try tempMirrorStore()
        let controller = DraftController(mirrorStore: store)
        let origin = try storedGame(in: ctx)
        let record = controller.open(origin: origin)
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        store.write(DraftMirror(draft: controller.draft!.snapshot(),
                                baseline: controller.draft!.baseline))

        let outcome = try controller.save(into: ctx)

        guard case .updatedOrigin(let saved)? = outcome else {
            Issue.record("expected updatedOrigin, got \(String(describing: outcome))")
            return
        }
        #expect(saved === origin)
        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(!controller.isDirty)
        #expect(store.read() == nil)
    }

    @Test func saveWithNoDraftReturnsNil() throws {
        let ctx = context
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        #expect(try controller.save(into: ctx) == nil)
    }

    @Test func saveAsNewGameLeavesTheOriginIntact() throws {
        let ctx = context
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let origin = try storedGame(in: ctx)
        let record = controller.open(origin: origin)
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        let inserted = try controller.saveAsNewGame(into: ctx)

        #expect(inserted?.name == "Saved (conflicted copy)")
        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 2)
    }

    // MARK: - Exit decisions

    @Test func decisionPromptsOnlyWhenDirty() throws {
        let ctx = context
        let controller = DraftController(mirrorStore: try tempMirrorStore())
        #expect(controller.decision(for: .quit) == .proceed)

        let origin = try storedGame(in: ctx)
        let record = controller.open(origin: origin)
        #expect(controller.decision(for: .quit) == .proceed)

        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        #expect(controller.decision(for: .quit) == .prompt)
    }

    // MARK: - Restore

    @Test func restoreRebuildsTheDraftFromAMirror() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)

        let edited = origin.detachedDraftCopy()
        edited.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp];B[cc])"
        let mirror = DraftMirror(
            draft: DraftSnapshot(record: edited, originUUID: origin.uuid),
            baseline: DraftSnapshot(record: origin, originUUID: origin.uuid))

        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let restored = controller.restore(from: mirror, origin: origin)

        #expect(restored.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp];B[cc])")
        #expect(controller.isDirty)
        #expect(controller.resolvedRecord(restored) === origin)
        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
    }

    @Test func restoreWithoutAnOriginComesBackUntitled() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let edited = origin.detachedDraftCopy()
        edited.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        let mirror = DraftMirror(
            draft: DraftSnapshot(record: edited, originUUID: origin.uuid),
            baseline: DraftSnapshot(record: origin, originUUID: origin.uuid))

        let controller = DraftController(mirrorStore: try tempMirrorStore())
        let restored = controller.restore(from: mirror, origin: nil)

        #expect(restored.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(controller.isUntitled)
        #expect(controller.isDirty)
    }
}
