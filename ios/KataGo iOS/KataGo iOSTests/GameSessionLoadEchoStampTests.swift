//
//  GameSessionLoadEchoStampTests.swift
//  KataGo iOSTests
//
//  Pins the load-echo latch. A `printsgf` sent purely to read a just-loaded
//  game back out of the engine — the cold-launch sync on iOS/macOS/visionOS,
//  and the visionOS game switch — syncs the record WITHOUT stamping
//  `lastModificationDate`. Opening a game is not modifying it; stamping there
//  re-sorted the library on every launch, and a widget/Shortcut deep link made
//  the damage visible by floating an arbitrary older game to the top of the
//  library ahead of games the user had actually played.
//

import Foundation
import Testing
import SwiftData
@testable import KataGoUICore

@MainActor
struct GameSessionLoadEchoStampTests {

    /// One move (`;B[pd]`), so delivering it to a fresh record moves
    /// currentIndex 0 → 1: unambiguously a content change, which keeps the
    /// "did it stamp?" assertions from passing for the wrong reason.
    private static let oneMoveReply =
        "= (;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd])"
    private static let oneMoveSgf =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd])"
    private static let twoMoveReply =
        "= (;FF[4]GM[1]SZ[19]KM[7.5]RU[koSIMPLEscoreAREAtaxNONEsui0whbN];B[pd];W[dp])"

    /// Distinct from `Date.now` by decades, so an accidental stamp cannot be
    /// mistaken for the original value.
    private static let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: SharedModelContainer.inMemoryConfig())
    }

    private struct Fixture {
        let session: GameSession
        let record: GameRecord
        let navigation: NavigationContext
        let container: ModelContainer
    }

    /// A session/record/selection wired the way a cold launch leaves them:
    /// one saved game, selected, no branch.
    private func makeFixture() throws -> Fixture {
        let container = try makeInMemoryContainer()
        let record = GameRecord.createGameRecord(name: "Synced game")
        record.lastModificationDate = Self.epoch
        container.mainContext.insert(record)

        let navigation = NavigationContext()
        navigation.selectedGameRecord = record
        return Fixture(session: GameSession(), record: record,
                       navigation: navigation, container: container)
    }

    private func deliver(_ reply: String, to fixture: Fixture) {
        fixture.session.maybeCollectSgf(message: reply,
                                        gameRecords: [fixture.record],
                                        modelContext: fixture.container.mainContext,
                                        navigationContext: fixture.navigation)
    }

    @Test("A load echo syncs the record but never stamps it as modified")
    func loadEchoSyncsWithoutStamping() throws {
        let fixture = try makeFixture()
        fixture.session.gobanState.nextSgfReplyIsLoadEcho = true

        deliver(Self.oneMoveReply, to: fixture)

        // The sync still happens — the record tracks the engine...
        #expect(fixture.record.sgf == Self.oneMoveSgf)
        #expect(fixture.record.currentIndex == 1)
        // ...but opening a game is not modifying it.
        #expect(fixture.record.lastModificationDate == Self.epoch)
    }

    @Test("Without the latch a printsgf reply still stamps (played moves unchanged)")
    func plainReplyStillStamps() throws {
        let fixture = try makeFixture()

        deliver(Self.oneMoveReply, to: fixture)

        #expect(fixture.record.sgf == Self.oneMoveSgf)
        #expect(fixture.record.currentIndex == 1)
        #expect(fixture.record.lastModificationDate != Self.epoch)
    }

    @Test("One reply consumes the latch, so the next move still stamps")
    func latchIsConsumedByOneReply() throws {
        let fixture = try makeFixture()
        fixture.session.gobanState.nextSgfReplyIsLoadEcho = true

        deliver(Self.oneMoveReply, to: fixture)
        #expect(fixture.record.lastModificationDate == Self.epoch)
        #expect(fixture.session.gobanState.nextSgfReplyIsLoadEcho == false)

        // A move played after launch reaches the same collector; the latch is
        // clear by then, so the real edit is stamped.
        deliver(Self.twoMoveReply, to: fixture)
        #expect(fixture.record.currentIndex == 2)
        #expect(fixture.record.lastModificationDate != Self.epoch)
    }

    /// The latch must be consumed by ANY printsgf reply, not just the one that
    /// reaches the record-writing arm — otherwise a launch echo that happened
    /// to land while a branch was active would survive and swallow the stamp of
    /// whatever real edit came next.
    @Test("A branch-routed reply consumes the latch instead of leaking it")
    func branchRoutedReplyConsumesLatch() throws {
        let fixture = try makeFixture()
        fixture.session.gobanState.branchSgf = fixture.record.sgf
        fixture.session.gobanState.branchIndex = 0
        fixture.session.gobanState.nextSgfReplyIsLoadEcho = true

        deliver(Self.oneMoveReply, to: fixture)

        #expect(fixture.session.gobanState.branchSgf == Self.oneMoveSgf)
        #expect(fixture.session.gobanState.nextSgfReplyIsLoadEcho == false)
        #expect(fixture.record.lastModificationDate == Self.epoch)

        // Latch spent: leaving the branch, a real edit stamps normally.
        fixture.session.gobanState.deactivateBranch()
        deliver(Self.twoMoveReply, to: fixture)
        #expect(fixture.record.lastModificationDate != Self.epoch)
    }

    /// The cold-launch echo re-states the record verbatim. SwiftData dirties a
    /// record when a property is set even to its existing value, and a dirtied
    /// record is saved and exported to CloudKit — so an unguarded write pushed
    /// an identical record to iCloud on every single launch.
    @Test("An echo identical to the record leaves the context clean")
    func identicalEchoLeavesContextClean() throws {
        let fixture = try makeFixture()
        fixture.record.sgf = Self.oneMoveSgf
        fixture.record.currentIndex = 1
        // Pre-populated so maybeUpdateMoves — which is not what this test is
        // about — has nothing to write and cannot dirty the context itself.
        fixture.record.moves = [0: "Q16", 1: "Q16"]
        try fixture.container.mainContext.save()
        #expect(fixture.container.mainContext.hasChanges == false)

        fixture.session.gobanState.nextSgfReplyIsLoadEcho = true
        deliver(Self.oneMoveReply, to: fixture)

        #expect(fixture.container.mainContext.hasChanges == false)
        #expect(fixture.record.lastModificationDate == Self.epoch)
    }

    /// First launch on an empty library still auto-creates the game from the
    /// printsgf reply — the latch suppresses the stamp on an EXISTING record,
    /// and must not disturb the creation path (a brand-new record is legitimately
    /// stamped `Date.now` by its initializer).
    @Test("The latch never blocks the empty-library auto-create")
    func latchDoesNotBlockAutoCreate() throws {
        let container = try makeInMemoryContainer()
        let session = GameSession()
        let navigation = NavigationContext()
        session.gobanState.nextSgfReplyIsLoadEcho = true

        session.maybeCollectSgf(message: Self.oneMoveReply,
                                gameRecords: [],
                                modelContext: container.mainContext,
                                navigationContext: navigation)

        let created = try #require(navigation.selectedGameRecord)
        #expect(created.sgf == Self.oneMoveSgf)
        #expect(created.currentIndex == 1)
        #expect(created.lastModificationDate != nil)
    }

    @Test("sendLoadEchoPrintSgf arms the latch and sends the command")
    func helperArmsTheLatchAndSends() throws {
        let session = GameSession()
        #expect(session.gobanState.nextSgfReplyIsLoadEcho == false)

        session.gobanState.sendLoadEchoPrintSgf(messageList: session.messageList)

        #expect(session.gobanState.nextSgfReplyIsLoadEcho == true)
        // MessageList logs commands with a "> " prefix.
        #expect(session.messageList.messages.contains { $0.text == "> printsgf" })
    }
}
