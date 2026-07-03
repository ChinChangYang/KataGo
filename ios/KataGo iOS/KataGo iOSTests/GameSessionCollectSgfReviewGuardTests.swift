//
//  GameSessionCollectSgfReviewGuardTests.swift
//  KataGo iOSTests
//
//  Pins the maybeCollectSgf review guard: while forcesBranchOnPlay is set
//  (the tvOS review screen), a printsgf reply arriving with a selection and
//  NO active branch is a stray — it must never write the synced record. With
//  the flag clear, the selected-record write is unchanged (iOS pin).
//

import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
struct GameSessionCollectSgfReviewGuardTests {

    private static let printsgfReply =
        "= (;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd])"

    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: SharedModelContainer.inMemoryConfig())
    }

    @Test("Review flag set: a stray printsgf never writes the selected record")
    func reviewFlagBlocksRecordWrite() throws {
        let container = try makeInMemoryContainer()
        let record = GameRecord.createGameRecord(name: "Synced game")
        container.mainContext.insert(record)
        let sgfBefore = record.sgf
        let dateBefore = record.lastModificationDate

        let session = GameSession()
        session.gobanState.forcesBranchOnPlay = true
        let navigation = NavigationContext()
        navigation.selectedGameRecord = record

        session.maybeCollectSgf(message: Self.printsgfReply,
                                gameRecords: [record],
                                modelContext: container.mainContext,
                                navigationContext: navigation)

        #expect(record.sgf == sgfBefore)
        #expect(record.currentIndex == 0)
        #expect(record.lastModificationDate == dateBefore)
    }

    @Test("Review flag set + branch active: the branch still receives the reply")
    func reviewFlagKeepsBranchRouting() throws {
        let container = try makeInMemoryContainer()
        let record = GameRecord.createGameRecord(name: "Synced game")
        container.mainContext.insert(record)

        let session = GameSession()
        session.gobanState.forcesBranchOnPlay = true
        session.gobanState.branchSgf = record.sgf
        session.gobanState.branchIndex = 0
        let navigation = NavigationContext()
        navigation.selectedGameRecord = record

        session.maybeCollectSgf(message: Self.printsgfReply,
                                gameRecords: [record],
                                modelContext: container.mainContext,
                                navigationContext: navigation)

        #expect(session.gobanState.branchSgf.contains(";B[pd]"))
        #expect(session.gobanState.branchIndex == 1)
        #expect(!record.sgf.contains(";B[pd]"))
    }

    @Test("Flag clear: the selected record is written as before (iOS pin)")
    func defaultWritesSelectedRecord() throws {
        let container = try makeInMemoryContainer()
        let record = GameRecord.createGameRecord(name: "Editing game")
        container.mainContext.insert(record)

        let session = GameSession()
        let navigation = NavigationContext()
        navigation.selectedGameRecord = record

        session.maybeCollectSgf(message: Self.printsgfReply,
                                gameRecords: [record],
                                modelContext: container.mainContext,
                                navigationContext: navigation)

        #expect(record.sgf.contains(";B[pd]"))
        #expect(record.currentIndex == 1)
    }
}
