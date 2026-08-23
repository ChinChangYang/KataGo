//
//  MessageListEngineGateTests.swift
//  KataGo iOSTests
//
//  The board never waits for the engine, so a board can be on screen — and
//  navigating — before any engine exists. The command gate is what keeps that
//  safe: everything except the three lifecycle commands is DROPPED (and logged)
//  until the handshake says the engine is listening.
//
//  Buffering was rejected deliberately: the in-process bridge's command buffer
//  is process-global and would replay a stale burst into the NEXT engine, and
//  the macOS pipe throws the write away anyway. A dropped command is re-sent by
//  the resync after the handshake, which knows the LIVE position.
//

import Testing
@testable import KataGoUICore

@MainActor
struct MessageListEngineGateTests {

    /// A fresh session has not handshaken with anything, so it refuses.
    /// This default is the whole point: `BoardView.onAppear` would otherwise
    /// `showboard` into a pre-loop buffer, and the tap gate would open against
    /// an engine that is still loading its net.
    @Test func aFreshSessionRefusesCommands() {
        let session = GameSession()
        let engine = RecordingQueueEngine(live: [])
        session.useEngine(engine)

        #expect(session.messageList.isAcceptingCommands == false)
        #expect(session.messageList.appendAndSend(command: "showboard") == false)
        #expect(engine.sentCommands.isEmpty)
    }

    /// Logged, never silent: a dropped command shows up much later as "the
    /// engine is on the wrong position", and the transcript is where that gets
    /// diagnosed.
    @Test func aDroppedCommandIsLoggedInTheTranscript() {
        let session = GameSession()
        session.useEngine(RecordingQueueEngine(live: []))

        session.messageList.appendAndSend(command: "play b Q16")

        #expect(session.messageList.messages.contains {
            $0.text == "> (dropped — engine unavailable) play b Q16"
        })
        // Never the ordinary echo — that would read as a command that went out.
        #expect(!session.messageList.messages.contains { $0.text == "> play b Q16" })
    }

    /// Once accepting, the command goes out and is echoed the ordinary way.
    @Test func anAcceptingSessionSendsAndEchoes() {
        let session = GameSession()
        let engine = RecordingQueueEngine(live: [])
        session.useEngine(engine)
        session.messageList.isAcceptingCommands = true

        #expect(session.messageList.appendAndSend(command: "showboard") == true)
        #expect(engine.sentCommands == ["showboard"])
        #expect(session.messageList.messages.contains { $0.text == "> showboard" })
    }

    /// The batch overload reports the same thing the single one does, so a
    /// caller can tell whether the whole bundle reached the engine.
    @Test func aBatchReportsWhetherEverythingWentOut() {
        let session = GameSession()
        let engine = RecordingQueueEngine(live: [])
        session.useEngine(engine)

        #expect(session.messageList.appendAndSend(commands: ["komi 7.5", "showboard"]) == false)
        #expect(engine.sentCommands.isEmpty)

        session.messageList.isAcceptingCommands = true
        #expect(session.messageList.appendAndSend(commands: ["komi 7.5", "showboard"]) == true)
        #expect(engine.sentCommands == ["komi 7.5", "showboard"])
    }

    /// `version`, `stop` and `quit` are how a host TALKS to an engine it is
    /// tearing down or starting up — exactly the moments the gate is shut. They
    /// bypass it, and they are still echoed so the transcript stays complete.
    @Test func lifecycleCommandsBypassTheGate() {
        let session = GameSession()
        let engine = RecordingQueueEngine(live: [])
        session.useEngine(engine)

        #expect(session.messageList.isAcceptingCommands == false)
        session.sendLifecycleCommand("stop")
        session.sendLifecycleCommand("quit")

        #expect(engine.sentCommands == ["stop", "quit"])
        #expect(session.messageList.messages.contains { $0.text == "> stop" })
        #expect(session.messageList.messages.contains { $0.text == "> quit" })
    }

    /// The gate must not leave the engine holding a command it never saw: a
    /// dropped send changes NOTHING on the transport.
    @Test func aDroppedCommandIsNeverBufferedForTheNextEngine() {
        let session = GameSession()
        let engine = RecordingQueueEngine(live: [])
        session.useEngine(engine)

        session.messageList.appendAndSend(commands: ["clear_board", "play b Q16"])
        // The next engine arrives; nothing from before may leak into it.
        session.messageList.isAcceptingCommands = true
        session.messageList.appendAndSend(command: "showboard")

        #expect(engine.sentCommands == ["showboard"])
    }
}
