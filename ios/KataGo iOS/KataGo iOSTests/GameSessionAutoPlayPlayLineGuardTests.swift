//
//  GameSessionAutoPlayPlayLineGuardTests.swift
//  KataGo iOSTests
//
//  Pins the auto-play guard in GameSession.postProcessAIMove: a gen-move
//  that completes just as the replay wand is toggled on still prints its
//  "play <vertex>" line (one the wand's command burst cancels mid-search
//  prints the literal "play cancelled", which the vertex regex drops).
//  That completed stray line must be dropped — played into the record it
//  would truncate and rewrite the game mid-replay (the wand sets
//  isEditing). shouldGenMove already forbids ISSUING gen-moves while
//  auto-playing, so no legitimate play line coexists with isAutoPlaying.
//

import SwiftUI
import Testing
@testable import KataGoUICore

@MainActor
struct GameSessionAutoPlayPlayLineGuardTests {

    private final class AIMoveBox {
        var value: String? = nil
    }

    private func makeBinding(_ box: AIMoveBox) -> Binding<String?> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }

    @Test("While auto-playing, a stray gen-move play line is dropped")
    func autoPlayDropsStrayPlayLine() {
        let session = GameSession()
        session.gobanState.isAutoPlaying = true
        session.player.nextColorForPlayCommand = .black
        let box = AIMoveBox()

        session.postProcessAIMove(message: "play Q16",
                                  navigationContext: NavigationContext(),
                                  audioModel: AudioModel(),
                                  aiMove: makeBinding(box))

        #expect(box.value == nil)
    }

    @Test("Not auto-playing: the play line is processed as before")
    func normalPlayLineStillProcessed() {
        let session = GameSession()
        session.player.nextColorForPlayCommand = .black
        let box = AIMoveBox()

        session.postProcessAIMove(message: "play Q16",
                                  navigationContext: NavigationContext(),
                                  audioModel: AudioModel(),
                                  aiMove: makeBinding(box))

        #expect(box.value == "Q16")
    }
}
