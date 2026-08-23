//
//  TurnChangeRearmTests.swift
//  KataGo iOSTests
//
//  Analysis re-arms itself off the turn change. That is load-bearing now that
//  opening a game no longer requests analysis by hand: `loadGame` parks the
//  side to move at `.unknown`, the feed's `showboard` reply resolves it to a
//  colour, and THAT edge is what asks the engine to start analysing the new
//  position. The hosts route their `onChange` through
//  `GobanState.handleTurnChange`, so this pins the shared body once instead of
//  once per platform.
//

import Testing
import Foundation
import SwiftData
@testable import KataGoUICore

@MainActor
struct TurnChangeRearmTests {

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
        let record = GameRecord.createGameRecord(
            sgf: "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd])",
            currentIndex: 1)
        container.mainContext.insert(record)
        let engine = RecordingQueueEngine(live: [])
        let session = GameSession()
        session.useEngine(engine)
        let navigation = NavigationContext()
        navigation.selectedGameRecord = record
        return Fixture(session: session, engine: engine, record: record,
                       navigation: navigation, container: container)
    }

    /// The cold-launch sequence in miniature: the load parks the turn at
    /// `.unknown`, and the engine's `showboard` answer resolves it. Analysis is
    /// requested off that resolution and nowhere else.
    @Test("Resolving .unknown to a colour re-requests analysis")
    func unknownToColourRearmsAnalysis() throws {
        let fixture = try makeFixture()
        let gobanState = fixture.session.gobanState
        gobanState.analysisStatus = .run
        fixture.session.player.nextColorForPlayCommand = .unknown
        // Both sides human, so the continuous-analysis branch is taken rather
        // than a gen-move bundle — this test is about the re-arm, not about
        // which bundle a configured AI side would earn.
        let config = fixture.record.concreteConfig
        config.blackMaxTime = 0
        config.whiteMaxTime = 0

        gobanState.handleTurnChange(to: .white,
                                    config: config,
                                    messageList: fixture.session.messageList)

        #expect(fixture.engine.sentCommands.contains { $0.hasPrefix("kata-analyze") })
    }

    /// `.pause` re-arms — deliberately. `maybePauseAnalysis()` sets `.pause`
    /// AND `waitingForAnalysis = true` so the next streamed line drives a
    /// true->false edge that stops the engine; the analysis is switched off at
    /// the engine, not at this gate (`shouldRequestAnalysis` only refuses
    /// `.clear`). The iPhone push-pop restore depends on exactly this: leaving
    /// and returning to the board pauses then re-arms without the user
    /// touching the Analyze button.
    @Test("A paused session still re-arms on the turn change")
    func pausedSessionStillRearms() throws {
        let fixture = try makeFixture()
        let gobanState = fixture.session.gobanState
        gobanState.analysisStatus = .pause

        gobanState.handleTurnChange(to: .white,
                                    config: fixture.record.concreteConfig,
                                    messageList: fixture.session.messageList)

        #expect(fixture.engine.sentCommands.contains { $0.hasPrefix("kata-analyze") })
    }

    /// Analysis genuinely switched off is the one status that asks for nothing.
    @Test("Analysis turned off asks for nothing on the turn change")
    func clearedAnalysisAsksForNothing() throws {
        let fixture = try makeFixture()
        let gobanState = fixture.session.gobanState
        gobanState.analysisStatus = .clear

        gobanState.handleTurnChange(to: .white,
                                    config: fixture.record.concreteConfig,
                                    messageList: fixture.session.messageList)

        #expect(!fixture.engine.sentCommands.contains { $0.hasPrefix("kata-analyze") })
    }

    /// The power-saving gate: a human-vs-AI game with the overlay hidden and the
    /// HUMAN to move has nothing to show and nothing to decide, so the turn
    /// change asks for nothing even at `.run`.
    @Test("A hidden overlay on the human's turn asks for nothing")
    func powerSavingAsksForNothing() throws {
        let fixture = try makeFixture()
        let gobanState = fixture.session.gobanState
        gobanState.analysisStatus = .run
        gobanState.eyeStatus = .closed
        let config = fixture.record.concreteConfig
        config.blackMaxTime = 1      // the AI plays Black
        config.whiteMaxTime = 0      // the human plays White

        gobanState.handleTurnChange(to: .white,
                                    config: config,
                                    messageList: fixture.session.messageList)

        #expect(!fixture.engine.sentCommands.contains { $0.hasPrefix("kata-analyze") })
    }

    /// The turn is ENGINE-sourced: only the `showboard` "Next player" line may
    /// move it. A `printsgf` reply — which is what a played move produces
    /// first, now that the record has to update before the sync ack — must
    /// leave it exactly where it was, or the board would re-arm analysis for a
    /// position the engine has not reached.
    @Test("A printsgf reply leaves the side to move alone")
    func printsgfReplyLeavesTheTurnAlone() throws {
        let fixture = try makeFixture()
        fixture.session.player.nextColorForPlayCommand = .white
        fixture.session.player.nextColorFromShowBoard = .white

        fixture.session.maybeCollectSgf(
            message: "= (;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp])",
            gameRecords: [fixture.record],
            modelContext: fixture.container.mainContext,
            navigationContext: fixture.navigation)

        #expect(fixture.session.player.nextColorForPlayCommand == .white)
        #expect(fixture.session.player.nextColorFromShowBoard == .white)
        #expect(fixture.record.currentIndex == 2)
    }

}
