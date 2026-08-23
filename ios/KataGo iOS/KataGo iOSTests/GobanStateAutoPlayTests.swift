//
//  GobanStateAutoPlayTests.swift
//  KataGo iOSTests
//
//  Auto-play replay ("auto play randomly misses stones"). The advance used to
//  hang off a `stones.isReady` edge, which could be missed or doubled; it now
//  happens at the play site — one call, one settled position, one step — so
//  there is no edge left to lose. What still waits for the engine is the
//  DECISION to step (an analysis has to be in hand before the position it
//  belongs to is left behind), and that gate lives in the hosts.
//

import Testing
import Foundation
import SwiftData
@testable import KataGoUICore

@MainActor
struct GobanStateAutoPlayTests {

    private static let threeMoves =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pp])"

    private struct Fixture {
        let session: GameSession
        let engine: RecordingQueueEngine
        let record: GameRecord
        let container: ModelContainer
    }

    private func makeFixture(sgf: String = threeMoves, currentIndex: Int = 0) throws -> Fixture {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: SharedModelContainer.inMemoryConfig())
        let engine = RecordingQueueEngine(live: [])
        let session = GameSession.accepting()
        session.useEngine(engine)
        session.gobanState.isAutoPlaying = true
        let record = GameRecord.createGameRecord(sgf: sgf, currentIndex: currentIndex)
        container.mainContext.insert(record)
        return Fixture(session: session, engine: engine, record: record, container: container)
    }

    private func step(_ fixture: Fixture) {
        fixture.session.gobanState.autoPlayStep(gameRecord: fixture.record,
                                                messageList: fixture.session.messageList,
                                                player: fixture.session.player,
                                                stones: fixture.session.stones,
                                                audioModel: nil)
    }

    private func plays(_ fixture: Fixture) -> [String] {
        fixture.engine.sentCommands.filter { $0.hasPrefix("play ") }
    }

    @Test("One step plays one move and advances one index")
    func oneStepAdvancesOnce() throws {
        let fixture = try makeFixture()
        step(fixture)

        #expect(fixture.record.currentIndex == 1)
        #expect(plays(fixture) == ["play b Q16"])
        #expect(fixture.engine.sentCommands.last == "showboard")
    }

    @Test("Each settled position advances exactly one move")
    func eachCallAdvancesExactlyOneMove() throws {
        let fixture = try makeFixture()
        step(fixture)
        step(fixture)
        step(fixture)

        #expect(fixture.record.currentIndex == 3)
        #expect(plays(fixture) == ["play b Q16", "play w D4", "play b Q4"])
        #expect(fixture.session.gobanState.isAutoPlaying == true)
    }

    @Test("The advance no longer waits for the engine's acknowledgement")
    func theAdvanceDoesNotWaitForTheAck() throws {
        let fixture = try makeFixture()
        step(fixture)

        // The record has already moved even though nothing has acknowledged the
        // play — which is the whole point: the board draws from the record.
        #expect(fixture.session.stones.isReady == false)
        #expect(fixture.record.currentIndex == 1)
    }

    @Test("Running out of recorded moves ends the loop")
    func runningOutOfMovesStopsAutoPlay() throws {
        let fixture = try makeFixture(currentIndex: 3)
        step(fixture)

        #expect(fixture.session.gobanState.isAutoPlaying == false)
        #expect(fixture.record.currentIndex == 3)
        #expect(plays(fixture).isEmpty)
    }

    /// A refused move produces no `play`, hence no turn change, hence nothing
    /// that would ever wake the loop again — so the step has to walk over it
    /// and land on the next move it CAN play.
    @Test("A refused move is stepped over inside the same step")
    func aRefusedMoveIsSteppedOver() throws {
        let fixture = try makeFixture(
            sgf: "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pd];W[pp])",
            currentIndex: 2)
        step(fixture)

        #expect(fixture.record.currentIndex == 4)
        #expect(plays(fixture) == ["play w Q4"])
    }

    @Test("A record whose only remaining move is refused ends the loop")
    func aTrailingRefusalEndsTheLoop() throws {
        let fixture = try makeFixture(
            sgf: "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pd])",
            currentIndex: 2)
        step(fixture)

        #expect(fixture.record.currentIndex == 3)
        #expect(plays(fixture).isEmpty)
        #expect(fixture.session.gobanState.isAutoPlaying == false)
    }

    @Test("A recorded pass steps and counts as a pass")
    func aPassStepsAndCounts() throws {
        let fixture = try makeFixture(
            sgf: "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[];W[])",
            currentIndex: 0)
        step(fixture)
        step(fixture)

        #expect(plays(fixture) == ["play b pass", "play w pass"])
        #expect(fixture.session.gobanState.passCount == 2)
    }
}

@MainActor
struct GobanStateShowBoardCountClampTests {

    @Test("A stray response cannot wedge future board parses")
    func strayResponseDoesNotWedge() {
        let state = GobanState()
        #expect(state.showBoardCount == 0)
        // A stray "= MoveNum" reply with nothing outstanding parses as a
        // harmless fresh board (it describes the engine's real position)
        // instead of pushing the count negative.
        #expect(state.consumeShowBoardResponse(response: "= MoveNum: 3, B stones: 2") == true)
        #expect(state.showBoardCount == 0)

        // The next legitimate request/response pair must still parse.
        state.showBoardCount += 1  // sendShowBoardCommand's increment
        #expect(state.consumeShowBoardResponse(response: "= MoveNum: 4, B stones: 2") == true)
    }

    @Test("Coalescing of queued responses is unchanged")
    func balancedCoalescingUnchanged() {
        let state = GobanState()
        state.showBoardCount = 2  // two showboards queued
        #expect(state.consumeShowBoardResponse(response: "= MoveNum: 1, B stones: 1") == false)
        #expect(state.consumeShowBoardResponse(response: "= MoveNum: 1, B stones: 1") == true)
        #expect(state.showBoardCount == 0)
    }

    @Test("Non-board lines are ignored")
    func nonBoardLinesIgnored() {
        let state = GobanState()
        state.showBoardCount = 1
        #expect(state.consumeShowBoardResponse(response: "info move Q16 visits 100") == false)
        #expect(state.showBoardCount == 1)
    }
}
