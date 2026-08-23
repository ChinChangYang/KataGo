//
//  HeldAnalysisGuardTests.swift
//  KataGo AnytimeTests
//
//  A search outlives the moment it was asked for. When the engine goes *Held*
//  (the record on screen is bigger than its NN buffer) or a restart begins, the
//  engine is still streaming `kata-analyze` for the PREVIOUS position — and
//  those `info` lines used to be filed against `recordPosition.currentKey`, i.e.
//  against the board on screen, which is exactly the board they do not describe.
//
//  Two halves, both pinned here:
//    • the collector refuses lines from an engine we are no longer talking to;
//    • entering Held sends `stop`, because nothing else can — the ordinary
//      `stop` goes through `appendAndSend` (dropped once the gate shuts) and
//      `loadGame` returns at its `boardFitsEngine` guard without sending at all.
//
//  The transport double is `RecordingEngine` from `MessageListEngineOwnershipTests`
//  — one per target is enough.
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

@MainActor
struct HeldAnalysisGuardTests {
    private let infoLine =
        "info move Q16 visits 10 winrate 0.55 scoreLead 2.5 utilityLcb 0.3 order 0 pv Q16"

    @Test func aLiveEngineSAnalysisIsCollected() async {
        let session = GameSession.accepting()
        await session.maybeCollectAnalysis(message: infoLine)
        #expect(!session.analysis.info.isEmpty,
                "a running engine's analysis must still land")
    }

    @Test func analysisFromAnEngineWeStoppedTalkingToIsRefused() async {
        let session = GameSession.accepting()
        // Exactly what the Held edge and every teardown do.
        session.messageList.isAcceptingCommands = false
        session.gobanState.resetForFreshEngine(stones: session.stones)

        await session.maybeCollectAnalysis(message: infoLine)

        #expect(session.analysis.info.isEmpty,
                "a trailing info line repopulated the overlay for a position the engine is not on")
        #expect(session.analysis.collectedForKey == nil,
                "a trailing info line stamped the displayed position as analysed")
    }

    @Test func theFreshEngineResetDoesNotReOpenTheCollector() async {
        // `resetForFreshEngine` zeroes `showBoardCount`, which is the OTHER
        // guard on this collector — so the gate has to be the one that holds.
        let session = GameSession.accepting()
        session.gobanState.showBoardCount = 3
        session.messageList.isAcceptingCommands = false
        session.gobanState.resetForFreshEngine(stones: session.stones)
        #expect(session.gobanState.showBoardCount == 0)

        await session.maybeCollectAnalysis(message: infoLine)
        #expect(session.analysis.info.isEmpty)
    }

    // MARK: - The Held edge halts the search

    @Test func goingHeldStopsTheSearchAndShutsTheGate() {
        let session = GameSession.accepting()
        let engine = RecordingEngine()
        session.useEngine(engine)
        session.engineStatus.availability = .ready

        let controller = AppEngineController()
        controller.configure(session: session,
                             engineLifecycle: EngineLifecycle(),
                             navigationContext: NavigationContext())

        // The controller's launched buffer is 19 before any spawn; a 37x37
        // record cannot be fed to it.
        controller.applyHeldStatus(boardWidth: 37, boardHeight: 37)

        #expect(session.engineStatus.availability == .held(maxBoardLength: 19))
        #expect(engine.sent.contains("stop"),
                "the engine kept searching the position the board no longer shows")
        #expect(!session.messageList.isAcceptingCommands)
        #expect(!session.stones.isReady)
    }

    @Test func aBoardThatFitsIsNeverHeldAndNothingIsStopped() {
        let session = GameSession.accepting()
        let engine = RecordingEngine()
        session.useEngine(engine)
        session.engineStatus.availability = .ready

        let controller = AppEngineController()
        controller.configure(session: session,
                             engineLifecycle: EngineLifecycle(),
                             navigationContext: NavigationContext())

        controller.applyHeldStatus(boardWidth: 19, boardHeight: 19)

        #expect(session.engineStatus.availability == .ready)
        #expect(engine.sent.isEmpty)
        #expect(session.messageList.isAcceptingCommands)
    }
}
