//
//  GameSessionOpeningSendsNoPrintsgfTests.swift
//  KataGo iOSTests
//
//  Replaces the load-echo latch. Opening a game used to `loadsgf` it into the
//  engine and then `printsgf` it straight back out, which needed a latch to
//  stop the echo from stamping `lastModificationDate` and re-sorting the
//  library on every launch (a widget deep link made the damage visible by
//  floating an arbitrary old game to the top).
//
//  The engine is fed move by move now, so opening a game sends NO `printsgf`
//  at all — there is no echo to suppress, and the latch is gone. What remains
//  to pin is the pair of facts the latch existed to protect: opening a game
//  neither stamps the record nor dirties the context, while a real move's
//  `printsgf` reply still stamps.
//

import Foundation
import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
struct GameSessionOpeningSendsNoPrintsgfTests {

    private static let oneMoveSgf =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd])"
    private static let twoMoveReply =
        "= (;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd];W[dp])"

    /// Distinct from `Date.now` by decades, so an accidental stamp cannot be
    /// mistaken for the original value.
    private static let epoch = Date(timeIntervalSince1970: 1_000_000)

    private struct Fixture {
        let session: GameSession
        let engine: RecordingQueueEngine
        let record: GameRecord
        let navigation: NavigationContext
        let container: ModelContainer
    }

    private func makeFixture() throws -> Fixture {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: SharedModelContainer.inMemoryConfig())
        let record = GameRecord.createGameRecord(sgf: Self.oneMoveSgf,
                                                 currentIndex: 1,
                                                 name: "Synced game")
        record.lastModificationDate = Self.epoch
        record.moves = [0: "Q16"]
        container.mainContext.insert(record)
        try container.mainContext.save()

        let engine = RecordingQueueEngine(live: [])
        let session = GameSession.accepting()
        session.useEngine(engine)
        let navigation = NavigationContext()
        navigation.selectedGameRecord = record
        return Fixture(session: session, engine: engine, record: record,
                       navigation: navigation, container: container)
    }

    private func open(_ fixture: Fixture) {
        fixture.session.gobanState.loadGame(gameRecord: fixture.record,
                                            player: fixture.session.player,
                                            bookLookup: fixture.session.bookLookup,
                                            messageList: fixture.session.messageList,
                                            board: fixture.session.board,
                                            stones: fixture.session.stones,
                                            analysis: fixture.session.analysis,
                                            projector: fixture.session.recordPosition)
    }

    @Test("Opening a game sends no printsgf and no loadsgf")
    func openingSendsNeitherCommand() throws {
        let fixture = try makeFixture()
        open(fixture)

        #expect(!fixture.engine.sentCommands.contains("printsgf"))
        #expect(!fixture.engine.sentCommands.contains { $0.hasPrefix("loadsgf") })
    }

    @Test("Opening a game does not re-sort the library")
    func openingDoesNotStampTheRecord() throws {
        let fixture = try makeFixture()
        open(fixture)

        #expect(fixture.record.lastModificationDate == Self.epoch)
    }

    /// SwiftData dirties a record when a property is set even to its existing
    /// value, and a dirtied record is saved and exported to CloudKit — which is
    /// how the old launch echo pushed an identical record to iCloud on every
    /// cold launch.
    ///
    /// Stated as "re-opening changes nothing" rather than "the first open
    /// changes nothing", because the first open legitimately may change
    /// something: it adopts the SGF's ruleset into `Config`, and a record whose
    /// stored config predates that SGF genuinely differs. What must never
    /// happen is churn — the same open, repeated, writing the same values back
    /// again. That is the property CloudKit cares about, and it is the one the
    /// launch path exercises every single time the app starts.
    @Test("Re-opening a game leaves the context clean")
    func reopeningLeavesTheContextClean() throws {
        let fixture = try makeFixture()
        #expect(fixture.container.mainContext.hasChanges == false)

        // First open: settles the record's config against its own SGF.
        open(fixture)
        try fixture.container.mainContext.save()
        #expect(fixture.container.mainContext.hasChanges == false)

        // Every open after that — i.e. every launch and every game switch —
        // must write nothing at all.
        open(fixture)

        #expect(fixture.container.mainContext.hasChanges == false)
    }

    /// The two properties the launch used to churn on their own, independent of
    /// the ruleset: `GameRecord.updateToLatestVersion` wrote `width`/`height`
    /// unconditionally on every call, and `loadGame` calls it on every open.
    @Test("Re-deriving the record's size writes nothing when it already matches")
    func updateToLatestVersionDoesNotChurnTheSize() throws {
        let fixture = try makeFixture()
        #expect(fixture.container.mainContext.hasChanges == false)

        fixture.record.updateToLatestVersion()
        try fixture.container.mainContext.save()
        #expect(fixture.record.width == 19)
        #expect(fixture.record.height == 19)

        fixture.record.updateToLatestVersion()

        #expect(fixture.container.mainContext.hasChanges == false)
    }

    @Test("A played move's printsgf reply still stamps the record")
    func aRealMoveStillStamps() throws {
        let fixture = try makeFixture()
        open(fixture)

        fixture.session.maybeCollectSgf(message: Self.twoMoveReply,
                                        gameRecords: [fixture.record],
                                        modelContext: fixture.container.mainContext,
                                        navigationContext: fixture.navigation)

        #expect(fixture.record.currentIndex == 2)
        #expect(fixture.record.lastModificationDate != Self.epoch)
    }
}
