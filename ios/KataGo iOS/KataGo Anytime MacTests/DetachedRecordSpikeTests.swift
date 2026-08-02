//
//  DetachedRecordSpikeTests.swift
//  KataGo Anytime MacTests
//
//  GATE for the draft-editing design: a draft is a GameRecord that is never
//  inserted into a ModelContext, held for a whole editing session. These tests
//  pin the four properties that assumption needs.
//

import Testing
import SwiftData
@testable import KataGoGameStore

@MainActor
struct DetachedRecordSpikeTests {

    private func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: GameRecord.self, Config.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func detachedRecordAcceptsMutationAndReadsItBack() throws {
        let record = GameRecord(config: Config())
        record.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"
        record.currentIndex = 1
        record.comments = [0: "hello"]
        #expect(record.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
        #expect(record.currentIndex == 1)
        #expect(record.comments?[0] == "hello")
    }

    @Test func detachedRecordSurvivesManyMutations() throws {
        // Stands in for a long editing session: a 200-move game.
        let record = GameRecord(config: Config())
        for i in 1...200 {
            record.currentIndex = i
            record.moves?[i] = "move\(i)"
        }
        #expect(record.currentIndex == 200)
        #expect(record.moves?.count == 200)
        #expect(record.moves?[200] == "move200")
    }

    @Test func mutatingADetachedRecordDoesNotReachTheStore() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext

        let stored = GameRecord(config: Config())
        stored.name = "Saved"
        context.insert(stored)
        try context.save()

        let detached = GameRecord(config: Config())
        detached.name = "Draft"
        detached.sgf = "(;FF[4]GM[1]SZ[19];B[dd];W[pp])"
        try context.save()

        let all = try context.fetch(FetchDescriptor<GameRecord>())
        #expect(all.count == 1)
        #expect(all.first?.name == "Saved")
    }

    @Test func aDetachedRecordCanBeInsertedLater() throws {
        let container = try inMemoryContainer()
        let context = container.mainContext

        let detached = GameRecord(config: Config())
        detached.name = "Late"
        detached.sgf = "(;FF[4]GM[1]SZ[19];B[dd])"

        context.insert(detached)
        try context.save()

        let all = try context.fetch(FetchDescriptor<GameRecord>())
        #expect(all.count == 1)
        #expect(all.first?.name == "Late")
        #expect(all.first?.sgf == "(;FF[4]GM[1]SZ[19];B[dd])")
    }

    @Test func detachedRecordCarriesItsOwnConfig() throws {
        let record = GameRecord(config: Config())
        record.concreteConfig.komi = 5.5
        #expect(record.config?.komi == 5.5)
        #expect(record.concreteConfig.komi == 5.5)
    }

    @Test func detachedRecordEmitsObservationOnMutation() async throws {
        // SwiftUI must redraw the board from the draft, which means the
        // generated accessors have to fire observation while detached.
        //
        // Uses `confirmation` rather than a captured `var fired`: this project
        // builds with SWIFT_VERSION 6.0, `withObservationTracking`'s onChange
        // parameter is @Sendable, and mutating a captured local from it is a
        // compile error under complete concurrency checking. `Confirmation` is
        // Sendable and thread-safe, so it carries the signal out instead.
        // onChange fires synchronously during the mutation below, so the
        // confirmation is always satisfied before the body returns.
        let record = GameRecord(config: Config())
        await confirmation("observation fired for a detached record") { fired in
            withObservationTracking {
                _ = record.sgf
            } onChange: {
                fired()
            }
            record.sgf = "(;FF[4]GM[1]SZ[19];B[qq])"
        }
    }
}
