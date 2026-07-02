//
//  GameSessionCollectSgfGuardTests.swift
//  KataGo iOSTests
//
//  Pins the guarded auto-create in GameSession.maybeCollectSgf. The empty-
//  library auto-create is iOS first-launch behavior (a printsgf reply births
//  the first game); the guards keep it from ever inserting into the WRONG
//  store: with a selection present (the tvOS self-play demo record lives in a
//  separate in-memory container, so the CloudKit query stays empty) the reply
//  belongs to the selected record, and with `autoCreatesGameOnEmptyLibrary`
//  false (set once by the tvOS root) nothing is ever auto-inserted.
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

    @Test("Empty library + nil selection: auto-create fires (iOS first-launch pin)")
    func autoCreateFiresOnFirstLaunch() throws {
        let container = try makeInMemoryContainer()
        let session = GameSession()
        let navigation = NavigationContext()

        session.maybeCollectSgf(message: Self.printsgfReply,
                                gameRecords: [],
                                modelContext: container.mainContext,
                                navigationContext: navigation)

        #expect(try fetchCount(container) == 1)
        #expect(navigation.selectedGameRecord != nil)
        #expect(navigation.selectedGameRecord?.currentIndex == 1)
        #expect(session.gobanState.isEditing == true)
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

    @Test("Opted out + nil selection: nothing is inserted (tvOS kill switch)")
    func optOutInsertsNothing() throws {
        let container = try makeInMemoryContainer()
        let session = GameSession()
        session.autoCreatesGameOnEmptyLibrary = false
        let navigation = NavigationContext()

        session.maybeCollectSgf(message: Self.printsgfReply,
                                gameRecords: [],
                                modelContext: container.mainContext,
                                navigationContext: navigation)

        #expect(try fetchCount(container) == 0)
        #expect(navigation.selectedGameRecord == nil)
    }

    @Test("The opt-in default is true (iOS/macOS unchanged)")
    func defaultsToAutoCreate() {
        #expect(GameSession().autoCreatesGameOnEmptyLibrary == true)
    }
}
