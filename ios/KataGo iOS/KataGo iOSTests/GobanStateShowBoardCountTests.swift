//
//  GobanStateShowBoardCountTests.swift
//  KataGo iOSTests
//
//  `showBoardCount` is the "how many acknowledgements are still outstanding"
//  counter, and reaching zero is what makes the board report in sync. It may
//  therefore only ever count showboards that actually LEFT — an incremented but
//  dropped one pins the count above zero forever, and every later ack is then
//  treated as an intermediate one.
//

import Testing
@testable import KataGoUICore

@MainActor
struct GobanStateShowBoardCountTests {

    private func makeSession() -> (GameSession, RecordingQueueEngine) {
        let engine = RecordingQueueEngine(live: [])
        let session = GameSession()
        session.useEngine(engine)
        return (session, engine)
    }

    /// The pair decision 2 makes: the gate drops the command, so the counter
    /// must not move.
    @Test func droppedShowboardDoesNotIncrementCount() {
        let (session, engine) = makeSession()
        #expect(session.messageList.isAcceptingCommands == false)

        session.gobanState.sendShowBoardCommand(messageList: session.messageList)

        #expect(session.gobanState.showBoardCount == 0)
        #expect(engine.sentCommands.isEmpty)
        // And it is LOGGED like every other drop. A showboard that vanished
        // without a trace is the hardest drop to diagnose later — its symptom
        // is "the board never went in sync", an hour downstream.
        #expect(session.messageList.messages.contains {
            $0.text == "> (dropped — engine unavailable) showboard"
        })
    }

    @Test func aSentShowboardCounts() {
        let (session, engine) = makeSession()
        session.messageList.isAcceptingCommands = true

        session.gobanState.sendShowBoardCommand(messageList: session.messageList)

        #expect(session.gobanState.showBoardCount == 1)
        #expect(engine.sentCommands == ["showboard"])
    }

    /// The trap the guard exists to prevent: send while unavailable, then send
    /// again once the engine is up. If the first had counted, the second ack
    /// would take the count from 2 to 1 and the board would never say in sync.
    @Test func aDropFollowedByARealSendStillReachesZero() {
        let (session, _) = makeSession()

        session.gobanState.sendShowBoardCommand(messageList: session.messageList)
        session.messageList.isAcceptingCommands = true
        session.gobanState.sendShowBoardCommand(messageList: session.messageList)

        #expect(session.gobanState.showBoardCount == 1)
        #expect(session.gobanState.consumeShowBoardResponse(response: "= MoveNum: 0") == true)
        #expect(session.gobanState.showBoardCount == 0)
    }
}
