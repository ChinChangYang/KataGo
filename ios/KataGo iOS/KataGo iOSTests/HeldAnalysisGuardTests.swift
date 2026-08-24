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
    private let infoLine = AnalyzeLineFixture.line()

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
        session.analysis.ownershipUnits = [OwnershipUnit(point: BoardPoint(x: 0, y: 0),
                                                         whiteness: 1, scale: 1, opacity: 1)]

        controller.applyHeldStatus(boardWidth: 37, boardHeight: 37)

        #expect(session.engineStatus.availability == .held(maxBoardLength: 19))
        #expect(engine.sent.contains("stop"),
                "the engine kept searching the position the board no longer shows")
        #expect(!session.messageList.isAcceptingCommands)
        #expect(!session.stones.isReady)
        #expect(session.analysis.ownershipUnits.isEmpty,
                "shading survived the engine that produced it, under a badged sparkle")
    }

    // MARK: - The ownership hold expires with the engine (ADR 0011)

    @Test func ownershipIsClearedWhenTheEngineLeavesAWorkingState() {
        func session(seeded: Bool = true) -> GameSession {
            let session = GameSession.accepting()
            session.useEngine(RecordingEngine())
            session.engineStatus.availability = .ready
            if seeded {
                session.analysis.ownershipUnits =
                    [OwnershipUnit(point: BoardPoint(x: 0, y: 0),
                                   whiteness: 1, scale: 1, opacity: 1)]
            }
            return session
        }

        let held = session()
        held.holdEngineSession(maxBoardLength: 19)
        #expect(held.analysis.ownershipUnits.isEmpty)

        let failed = session()
        failed.endEngineSession(.failed(reason: "x"))
        #expect(failed.analysis.ownershipUnits.isEmpty)

        let absent = session()
        absent.endEngineSession(.absent)
        #expect(absent.analysis.ownershipUnits.isEmpty)

        // Launching is deliberately a WORKING state: every restart passes
        // through it, and most change neither the position nor the engine's
        // opinion of it. Clearing here would blink the board on every backend
        // change, thread-count change and Retry.
        let launching = session()
        launching.endEngineSession(.launching)
        #expect(launching.analysis.ownershipUnits.count == 1)
    }

    @Test func aMalformedInfoLineDoesNotBlankTheOwnershipOverlay() async {
        // A search for the board we just LEFT keeps streaming. Its grid is
        // count-validated against the board on screen, so it parses to no
        // units — and writing that emptiness would blink the held map exactly
        // as the projector's old clear did.
        let session = GameSession.accepting()
        session.board.width = 2
        session.board.height = 2
        session.analysis.ownershipUnits = (0..<2).flatMap { y in
            (0..<2).map { x in
                OwnershipUnit(point: BoardPoint(x: x, y: y),
                              whiteness: 1, scale: 1, opacity: 1)
            }
        }

        await session.maybeCollectAnalysis(
            message: AnalyzeLineFixture.lineForAnotherBoard(boardWidth: 3, boardHeight: 3))

        #expect(session.analysis.ownershipUnits.count == 4,
                "a report for a board we already left blanked the overlay")
        #expect(session.analysis.collectedForKey == nil,
                "a report for another board stamped the displayed position as analysed")
    }

    /// One complete showboard reply, in the order KataGo prints it.
    private static let showboardBlock = [
        "= MoveNum: 2 HASH: 0123456789ABCDEF",
        "   A B C",
        " 3 . O .",
        " 2 X 1 .",
        " 1 . . .",
        "Next player: White",
        "Rules: {\"ko\":\"POSITIONAL\"}",
        "B stones captured: 0",
        "W stones captured: 0",
    ]

    /// The Held edge shuts the gate mid-block, and the block it interrupts must
    /// not survive it.
    ///
    /// `maybeCollectSync` is a two-state machine: the `= MoveNum` line is the
    /// LAST outstanding showboard's acknowledgement, and once consumed the
    /// collector is "inside a block" until the trailing capture line. A hold
    /// that leaves that flag set means the NEXT engine's first `= MoveNum` is
    /// eaten as board text — `consumeShowBoardResponse` never runs,
    /// `showBoardCount` never returns to 0, and `maybeCollectAnalysis`
    /// (gated on it) is dead until the app is relaunched.
    @Test func aHoldMidBlockDoesNotStrandTheSyncCounter() async {
        let session = GameSession.accepting()
        let engine = RecordingEngine()
        session.useEngine(engine)
        session.engineStatus.availability = .ready

        let controller = AppEngineController()
        controller.configure(session: session,
                             engineLifecycle: EngineLifecycle(),
                             navigationContext: NavigationContext())

        // A showboard is outstanding and its block has begun arriving.
        session.gobanState.showBoardCount = 1
        for line in Self.showboardBlock.prefix(3) {
            await session.maybeCollectSync(message: line)
        }
        #expect(session.gobanState.showBoardCount == 0)

        // The record on screen goes oversized, then fits again.
        controller.applyHeldStatus(boardWidth: 37, boardHeight: 37)
        #expect(session.engineStatus.availability == .held(maxBoardLength: 19))
        controller.applyHeldStatus(boardWidth: 19, boardHeight: 19)
        #expect(session.engineStatus.availability == .ready)

        // The re-feed's own showboard, answered in full by the live engine.
        session.gobanState.showBoardCount = 1
        for line in Self.showboardBlock {
            await session.maybeCollectSync(message: line)
        }

        #expect(session.gobanState.showBoardCount == 0,
                "the ack after a hold was eaten as board text — analysis is dead until a relaunch")
        #expect(session.stones.isReady,
                "the board never reported in sync with the engine that took it back")
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
