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
