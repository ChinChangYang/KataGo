//
//  GameDraftTests.swift
//  KataGo Anytime MacTests
//

import Testing
import Foundation
import SwiftData
@testable import KataGoGameStore

@MainActor
struct GameDraftTests {

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

    private func storedGame(in context: ModelContext,
                            sgf: String = "(;FF[4]GM[1]SZ[19];B[dd])",
                            name: String = "Saved") throws -> GameRecord {
        let record = GameRecord(config: Config())
        record.sgf = sgf
        record.name = name
        record.currentIndex = 1
        context.insert(record)
        try context.save()
        return record
    }

    // MARK: - Dirty

    @Test func aFreshDraftIsClean() throws {
        let draft = GameDraft(origin: try storedGame(in: context))
        #expect(!draft.isDirty)
    }

    @Test func playingAMoveMakesTheDraftDirty() throws {
        let draft = GameDraft(origin: try storedGame(in: context))
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        #expect(draft.isDirty)
    }

    @Test func analysisDataDoesNotMakeTheDraftDirty() throws {
        let draft = GameDraft(origin: try storedGame(in: context))
        draft.record.winRates = [1: 0.6]
        draft.record.currentIndex = 0
        #expect(!draft.isDirty)
    }

    @Test func anEmptyUntitledDraftIsClean() throws {
        let untitled = GameRecord(config: Config())
        untitled.sgf = GameRecord.defaultSgf
        let draft = GameDraft(untitled: untitled)
        #expect(!draft.isDirty)
    }

    @Test func anUntitledDraftWithAMoveIsDirty() throws {
        let untitled = GameRecord(config: Config())
        untitled.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        let draft = GameDraft(untitled: untitled)
        #expect(draft.isDirty)
    }

    @Test func anUntitledDraftWithACommentIsDirty() throws {
        let untitled = GameRecord(config: Config())
        untitled.sgf = GameRecord.defaultSgf
        untitled.comments = [0: "opening thoughts"]
        let draft = GameDraft(untitled: untitled)
        #expect(draft.isDirty)
    }

    // MARK: - Isolation

    @Test func editingTheDraftDoesNotTouchTheStore() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)

        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp];B[cc])"
        draft.record.name = "Edited"
        try ctx.save()

        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(origin.name == "Saved")
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 1)
    }

    // MARK: - Save

    @Test func saveAppliesTheDraftOntoTheOrigin() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        let outcome = try draft.save(into: ctx)

        guard case .updatedOrigin(let saved) = outcome else {
            Issue.record("expected updatedOrigin, got \(outcome)")
            return
        }
        #expect(saved === origin)
        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 1)
    }

    @Test func saveClearsDirtyAndStampsTheModificationDate() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        origin.lastModificationDate = Date(timeIntervalSince1970: 0)
        let draft = GameDraft(origin: origin)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        _ = try draft.save(into: ctx)

        #expect(!draft.isDirty)
        #expect((origin.lastModificationDate ?? .distantPast) > Date(timeIntervalSince1970: 1))
    }

    @Test func savingAnUntitledDraftInsertsANewRecord() throws {
        let ctx = context
        let untitled = GameRecord(config: Config())
        untitled.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        untitled.name = "Brand New"
        let draft = GameDraft(untitled: untitled)

        let outcome = try draft.save(into: ctx)

        guard case .insertedNew(let inserted) = outcome else {
            Issue.record("expected insertedNew, got \(outcome)")
            return
        }
        #expect(inserted.name == "Brand New")
        #expect(inserted.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 1)
        #expect(draft.origin === inserted)
        #expect(!draft.isDirty)
    }

    @Test func savingAnOriginThatWasDeletedInsertsInstead() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        ctx.delete(origin)
        try ctx.save()

        let outcome = try draft.save(into: ctx)

        guard case .insertedNew = outcome else {
            Issue.record("expected insertedNew after the origin was deleted")
            return
        }
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 1)
    }

    // MARK: - Conflict

    @Test func aDraftWithAnUntouchedOriginHasNoConflict() throws {
        let ctx = context
        let draft = GameDraft(origin: try storedGame(in: ctx))
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        #expect(!draft.hasConflict)
    }

    @Test func anOriginChangedUnderneathIsAConflict() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)

        // Stands in for a CloudKit import from another device.
        origin.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[qq])"

        #expect(draft.hasConflict)
    }

    @Test func anUntitledDraftNeverConflicts() throws {
        let untitled = GameRecord(config: Config())
        untitled.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        #expect(!GameDraft(untitled: untitled).hasConflict)
    }

    @Test func saveAsNewGameLeavesTheOriginIntact() throws {
        let ctx = context
        let origin = try storedGame(in: ctx)
        let draft = GameDraft(origin: origin)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"

        let inserted = try draft.saveAsNewGame(into: ctx)

        #expect(origin.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(inserted.sgf == "(;FF[4]GM[1]SZ[19];B[dd];W[pp])")
        #expect(inserted.name == "Saved (conflicted copy)")
        #expect(inserted.uuid != origin.uuid)
        #expect(try ctx.fetch(FetchDescriptor<GameRecord>()).count == 2)
    }

    // MARK: - Move count

    @Test func moveCountReadsTheDraftSgf() throws {
        let ctx = context
        let draft = GameDraft(origin: try storedGame(in: ctx))
        #expect(draft.moveCount == 1)
        draft.record.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp];B[cc])"
        #expect(draft.moveCount == 3)
    }
}
