//
//  GameSessionCollectSgfGuardTests.swift
//  KataGo iOSTests
//
//  Pins where a `printsgf` reply may and may not land. It used to be able to
//  CREATE a game (the iOS first-launch path: an empty library plus a reply
//  born the first record), which needed a per-platform kill switch to keep it
//  from inserting into the wrong store. The board is engine-free now — iOS
//  creates its first game at launch, without asking the engine — so no reply
//  ever creates anything, on any platform. What is left to pin: a reply
//  updates the SELECTED record and nothing else.
//

import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
struct GameSessionCollectSgfGuardTests {

    private static let printsgfReply =
        "= (;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd])"

    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: SharedModelContainer.inMemoryConfig())
    }

    private func fetchCount(_ container: ModelContainer) throws -> Int {
        try container.mainContext.fetchCount(FetchDescriptor<GameRecord>())
    }

    @Test("Empty library + nil selection: nothing is created")
    func nothingIsCreatedFromAReply() throws {
        let container = try makeInMemoryContainer()
        let session = GameSession()
        let navigation = NavigationContext()

        session.maybeCollectSgf(message: Self.printsgfReply,
                                gameRecords: [],
                                modelContext: container.mainContext,
                                navigationContext: navigation)

        #expect(try fetchCount(container) == 0)
        #expect(navigation.selectedGameRecord == nil)
    }

    @Test("Empty library + selection present: updates the selected record, inserts nothing")
    func selectionPresentUpdatesSelectedRecord() throws {
        let queryContainer = try makeInMemoryContainer()   // the (stale, empty) CloudKit-side context
        let demoContainer = try makeInMemoryContainer()    // where the demo record actually lives
        let demo = GameRecord.createGameRecord(name: "Demo")
        demoContainer.mainContext.insert(demo)

        let session = GameSession()
        let navigation = NavigationContext()
        navigation.selectedGameRecord = demo

        session.maybeCollectSgf(message: Self.printsgfReply,
                                gameRecords: [],
                                modelContext: queryContainer.mainContext,
                                navigationContext: navigation)

        #expect(try fetchCount(queryContainer) == 0)
        #expect(navigation.selectedGameRecord === demo)
        #expect(demo.sgf.contains(";B[pd]"))
        #expect(demo.currentIndex == 1)
    }

    /// A game that is on screen but not in this context's store — the tvOS
    /// self-play demo record lives in its own in-memory container — still gets
    /// the reply, and the reply still inserts nothing anywhere.
    @Test("A non-empty library with nothing selected is left untouched")
    func aReplyWithNoSelectionWritesNowhere() throws {
        let container = try makeInMemoryContainer()
        let existing = GameRecord.createGameRecord(name: "Existing")
        container.mainContext.insert(existing)
        let session = GameSession()
        let navigation = NavigationContext()

        session.maybeCollectSgf(message: Self.printsgfReply,
                                gameRecords: [existing],
                                modelContext: container.mainContext,
                                navigationContext: navigation)

        #expect(try fetchCount(container) == 1)
        #expect(existing.sgf == GameRecord.defaultSgf)
        #expect(navigation.selectedGameRecord == nil)
    }
}
