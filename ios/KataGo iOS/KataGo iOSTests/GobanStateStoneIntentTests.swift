//
//  GobanStateStoneIntentTests.swift
//  KataGo iOSTests
//
//  ADR 0015: stone motion follows PROVENANCE. A command site declares what it
//  is about to do to the board before it acts, and a stone change no intent
//  accounts for mounts instantly. These pin which sites declare and which
//  deliberately do not — the whole safety property of the feature is that the
//  second list is longer than the first, so a jump, a scrub or a game switch
//  can never animate one stone out of a batch.
//
//  Nothing here renders: the queue is the contract, and BoardView's motion
//  layer is the only thing that drains it.
//

import Testing
import Foundation
import SwiftData
@testable import KataGoUICore

@MainActor
struct GobanStateStoneIntentTests {

    /// Black Q16, White D4, Black Q4 on a 19x19 — the same opening the
    /// auto-play suite replays, so the expected vertices are already pinned
    /// there ("play b Q16", "play w D4", "play b Q4").
    private static let threeMoves =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pp])"
    /// One recorded pass, which moves no stone at all.
    private static let onePass =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[])"

    /// `@MainActor` on its own: a nested type does NOT inherit the suite's
    /// isolation, and `GameSession.gobanState` is main-actor state.
    @MainActor
    private struct Fixture {
        let session: GameSession
        let record: GameRecord
        let container: ModelContainer

        var state: GobanState { session.gobanState }
        var pending: [StoneAnimationPlanner.Intent] { session.gobanState.stonePlanner.pending }
    }

    private func makeFixture(sgf: String = threeMoves, currentIndex: Int = 0) throws -> Fixture {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: SharedModelContainer.inMemoryConfig())
        let session = GameSession.accepting()
        session.useEngine(RecordingQueueEngine(live: []))
        let record = GameRecord.createGameRecord(sgf: sgf, currentIndex: currentIndex)
        container.mainContext.insert(record)
        return Fixture(session: session, record: record, container: container)
    }

    private func point(_ vertex: String) -> BoardPoint {
        BoardPoint(move: vertex, width: 19, height: 19)!
    }

    private func forward(_ fixture: Fixture, limit: Int?) {
        fixture.state.forwardMoves(limit: limit,
                                   gameRecord: fixture.record,
                                   board: fixture.session.board,
                                   messageList: fixture.session.messageList,
                                   player: fixture.session.player,
                                   audioModel: nil,
                                   stones: fixture.session.stones)
    }

    private func backward(_ fixture: Fixture, limit: Int?) {
        fixture.state.backwardMoves(limit: limit,
                                    gameRecord: fixture.record,
                                    messageList: fixture.session.messageList,
                                    player: fixture.session.player,
                                    stones: fixture.session.stones)
    }

    // MARK: - The sites that DO declare

    @Test("A one-step forward declares the arriving stone")
    func forwardOneEnqueuesThePlace() throws {
        let fixture = try makeFixture()
        forward(fixture, limit: 1)
        #expect(fixture.pending == [.place(point("Q16"))])
    }

    @Test("A one-step back declares the tip stone leaving")
    func undoIndexEnqueuesTheRemove() throws {
        // Standing at the tip of the three-move record: the stone about to go
        // is the one move 2 played, Q4.
        let fixture = try makeFixture(currentIndex: 3)
        fixture.state.undoIndex(gameRecord: fixture.record)
        #expect(fixture.pending == [.remove(point("Q4"))])
    }

    @Test("An auto-play step declares the stone it replays")
    func autoPlayStepEnqueuesThePlace() throws {
        let fixture = try makeFixture()
        fixture.state.isAutoPlaying = true
        fixture.state.autoPlayStep(gameRecord: fixture.record,
                                   messageList: fixture.session.messageList,
                                   player: fixture.session.player,
                                   stones: fixture.session.stones,
                                   audioModel: nil)
        #expect(fixture.pending == [.place(point("Q16"))])
    }

    // MARK: - The sites that deliberately do NOT

    @Test("A multi-move forward jump leaves nothing queued")
    func forwardJumpClearsTheQueue() throws {
        let fixture = try makeFixture()
        forward(fixture, limit: 3)
        // A jump mounts instantly and clicks once for the whole batch; an
        // intent surviving it would pick one stone out of that batch to
        // animate, which is precisely the accident the queue exists to avoid.
        #expect(fixture.pending.isEmpty)
    }

    @Test("A rewind to the start leaves nothing queued")
    func backwardJumpClearsTheQueue() throws {
        let fixture = try makeFixture(currentIndex: 3)
        // Seed a stale intent the previous command left behind: the clear has
        // to drop that too, not merely refrain from adding more.
        fixture.state.expectStoneMotion(.place(point("D4")))
        backward(fixture, limit: nil)
        #expect(fixture.pending.isEmpty)
    }

    @Test("A one-step scrub leaves nothing queued")
    func goToOneStepAwayClearsTheQueue() throws {
        // `go(to:)` delegates to forwardMoves(limit: 1), which declares — and
        // then drops it. A chart drag and a moves-list tap are navigation, not
        // moves, however short the hop.
        let fixture = try makeFixture()
        fixture.state.go(to: 1,
                         gameRecord: fixture.record,
                         board: fixture.session.board,
                         messageList: fixture.session.messageList,
                         player: fixture.session.player,
                         audioModel: nil,
                         stones: fixture.session.stones)
        #expect(fixture.record.currentIndex == 1)
        #expect(fixture.pending.isEmpty)
    }

    @Test("A recorded pass declares nothing")
    func aPassEnqueuesNothing() throws {
        // A pass moves no stone, so no diff will ever come — and an intent
        // queued for it would sit there until some unrelated diff satisfied
        // it. The click for a pass belongs at the command site instead.
        let fixture = try makeFixture(sgf: Self.onePass)
        forward(fixture, limit: 1)
        #expect(fixture.record.currentIndex == 1)
        #expect(fixture.pending.isEmpty)
    }

    @Test("Motion off declares nothing")
    func disabledMotionEnqueuesNothing() throws {
        // tvOS self-play: an engine-paced attract loop mounts its stones
        // instantly, so the whole feature switches off at one flag.
        let fixture = try makeFixture()
        fixture.state.stoneMotionEnabled = false
        forward(fixture, limit: 1)
        fixture.state.expectStoneMotion(.place(point("D4")))
        #expect(fixture.pending.isEmpty)
    }

    // MARK: - The two resets

    @Test("A game switch arms the silent remount; a jump disarms it")
    func theInitialSyncFlagFollowsTheReset() throws {
        let fixture = try makeFixture()
        fixture.state.expectStoneMotion(.place(point("Q16")))

        fixture.state.prepareStoneMotionForGameSwitch()
        #expect(fixture.pending.isEmpty)
        #expect(fixture.state.stoneMotionInitialSyncArmed)

        // A same-position reload can leave the flag armed with an empty diff.
        // The jump the user then presses must click once for its batch, not
        // consume the silence — so the jump reset disarms it.
        fixture.state.clearStoneMotionForJump()
        #expect(!fixture.state.stoneMotionInitialSyncArmed)
    }
}
