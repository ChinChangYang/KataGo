//
//  BroadcastGenMoveTests.swift
//  KataGo AnytimeTests
//
//  The tvOS broadcast's licensed gen-move: suppressesGenMove stays true for
//  the whole broadcast, so a single gen-move reply is let through
//  postProcessAIMove by the one-shot broadcastGenMovePending license —
//  armed by requestBroadcastGenMove, consumed on the first play line.
//

import Testing
import SwiftUI
import SwiftData
@testable import KataGoUICore

@MainActor
struct BroadcastGenMoveTests {

    private final class CapturedMove {
        var value: String?
    }

    @MainActor
    private struct Fixture {
        let session = GameSession()
        let navigation = NavigationContext()
        let audioModel = AudioModel()
        let record: GameRecord
        let captured = CapturedMove()

        init() {
            // The real broadcast record: createGameRecord + both maxTimes 1.0
            // (requestBroadcastGenMove is a no-op for a side with maxTime 0).
            record = SelfPlayGame.makeRecord()
            navigation.selectedGameRecord = record
            session.board.width = 19
            session.board.height = 19
            session.player.nextColorForPlayCommand = .black
            session.gobanState.suppressesGenMove = true   // broadcast invariant
        }

        func receivePlayReply() {
            let captured = self.captured
            session.postProcessAIMove(message: "play Q16",
                                      navigationContext: navigation,
                                      audioModel: audioModel,
                                      aiMove: Binding(get: { captured.value },
                                                      set: { captured.value = $0 }))
        }

        func sent(_ fragment: String) -> Bool {
            session.messageList.messages.contains { $0.text.contains(fragment) }
        }
    }

    @Test("requestBroadcastGenMove arms the license and sends the bundle")
    func requestArmsAndSends() {
        let f = Fixture()
        let config = f.record.concreteConfig

        f.session.gobanState.requestBroadcastGenMove(config: config,
                                                     messageList: f.session.messageList,
                                                     nextColorForPlayCommand: .black)

        #expect(f.session.gobanState.broadcastGenMovePending)
        #expect(f.sent("kata-search_analyze_cancellable"))
        #expect(f.session.gobanState.waitingForAnalysis)
    }

    @Test("Game over (two passes): no command, no license")
    func gameOverIsANoOp() {
        let f = Fixture()
        f.session.gobanState.passCount = 2

        f.session.gobanState.requestBroadcastGenMove(config: f.record.concreteConfig,
                                                     messageList: f.session.messageList,
                                                     nextColorForPlayCommand: .black)

        #expect(!f.session.gobanState.broadcastGenMovePending)
        #expect(!f.sent("kata-search_analyze_cancellable"))
    }

    @Test("Licensed reply plays through suppression, exactly once")
    func licensePlaysOneReply() {
        let f = Fixture()
        f.session.gobanState.broadcastGenMovePending = true

        f.receivePlayReply()

        #expect(f.captured.value == "Q16")
        #expect(f.sent("play b Q16"))
        #expect(!f.session.gobanState.broadcastGenMovePending)   // consumed

        // A second stray play line is back to the plain suppression drop.
        f.captured.value = nil
        f.session.player.nextColorForPlayCommand = .white
        f.receivePlayReply()
        #expect(f.captured.value == nil)
    }

    @Test("License is consumed even when another guard drops the reply")
    func licenseConsumedOnDroppedReply() {
        let f = Fixture()
        f.session.gobanState.broadcastGenMovePending = true
        f.session.gobanState.pendingMoveTurn = "b"     // pick mid-legality-check

        f.receivePlayReply()

        #expect(f.captured.value == nil)
        #expect(!f.session.gobanState.broadcastGenMovePending)
    }

    @Test("Unlicensed suppression still drops (the existing pin)")
    func unlicensedStillDrops() {
        let f = Fixture()

        f.receivePlayReply()

        #expect(f.captured.value == nil)
        #expect(!f.sent("play b Q16"))
    }
}
