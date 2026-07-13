//
//  GameSessionPostProcessAIMoveGuardTests.swift
//  KataGo iOSTests
//
//  Pins the drop guard at the top of GameSession.postProcessAIMove. A
//  cancelled kata-search_analyze_cancellable still prints its best-so-far
//  "play <vertex>" line (the engine never plays it on its own board), so while
//  a screen is a spectator or paused (suppressesGenMove) or a user pick is
//  mid-legality-check (pendingMoveTurn set — the kata-check-move is what
//  cancelled the search), that line must be dropped, not played into the
//  record. With neither condition, the reply plays exactly as before the
//  guard existed (the iOS/macOS regression pin).
//

import Testing
import SwiftUI
import SwiftData
@testable import KataGoUICore

@MainActor
struct GameSessionPostProcessAIMoveGuardTests {

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
            record = GameRecord.createGameRecord(name: "Demo")
            navigation.selectedGameRecord = record
            session.board.width = 19
            session.board.height = 19
            session.player.nextColorForPlayCommand = .black
        }

        func receivePlayReply() {
            let captured = self.captured
            session.postProcessAIMove(message: "play Q16",
                                      navigationContext: navigation,
                                      audioModel: audioModel,
                                      aiMove: Binding(get: { captured.value },
                                                      set: { captured.value = $0 }))
        }

        /// Message texts carry a "> " display prefix — match on the suffix.
        func sent(_ command: String) -> Bool {
            session.messageList.messages.contains { $0.text.hasSuffix(command) }
        }
    }

    @Test("Spectator/paused (suppressesGenMove): the play line is dropped")
    func suppressedDropsPlayLine() {
        let f = Fixture()
        f.session.gobanState.suppressesGenMove = true

        f.receivePlayReply()

        #expect(f.captured.value == nil)
        #expect(f.session.gobanState.isBranchActive == false)
        #expect(f.record.currentIndex == 0)
        #expect(!f.sent("play b Q16"))
    }

    @Test("Pick in flight (pendingMoveTurn set): the play line is dropped")
    func pendingPickDropsPlayLine() {
        let f = Fixture()
        f.session.gobanState.pendingMoveTurn = "b"
        f.session.gobanState.pendingMoveVertex = "D4"

        f.receivePlayReply()

        #expect(f.captured.value == nil)
        #expect(f.record.currentIndex == 0)
        #expect(!f.sent("play b Q16"))
        // The pending pick must survive for its own legality reply.
        #expect(f.session.gobanState.pendingMoveTurn == "b")
        #expect(f.session.gobanState.pendingMoveVertex == "D4")
    }

    @Test("Neither condition: the AI move plays as before (iOS pin)")
    func defaultPlaysAIMove() {
        let f = Fixture()

        f.receivePlayReply()

        #expect(f.captured.value == "Q16")
        #expect(f.sent("play b Q16"))
    }

    @Test("Player .unknown (mid game-switch): the play line is dropped")
    func stalePlayReplyDroppedWhilePlayerUnknown() {
        // The Vision game switch relies on this: loadGame resets the player
        // to .unknown (nil symbol) until the new game's showboard reply
        // resolves the side to move, so a cancelled search's best-so-far
        // "play" line from the OLD game must fall through here.
        let f = Fixture()
        f.session.player.nextColorForPlayCommand = .unknown

        f.receivePlayReply()

        #expect(f.captured.value == nil)
        #expect(f.record.currentIndex == 0)
        #expect(!f.sent("play b Q16"))
    }
}
