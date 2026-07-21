import Testing
import Foundation
@testable import KataGoUICore
import KataGoGameStore

@MainActor
struct WatchHostGateTests {
    // 4 mainline moves; currentIndex 4 = at the head.
    private static let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[bb];B[cc];W[dd])"

    private func makeHost(currentIndex: Int = 4, editing: Bool = true)
        -> (session: GameSession, gameRecord: GameRecord) {
        let session = GameSession()
        let gameRecord = GameRecord.createGameRecord(sgf: Self.sgf, currentIndex: currentIndex)
        // Human-vs-human, black to move, analysis running: the all-green case.
        gameRecord.concreteConfig.blackMaxTime = 0
        gameRecord.concreteConfig.whiteMaxTime = 0
        session.player.nextColorForPlayCommand = .black
        session.gobanState.analysisStatus = .run
        session.gobanState.isEditing = editing
        return (session, gameRecord)
    }

    @Test func allGreenAllowsScrubAndPlay() {
        let (session, gameRecord) = makeHost()
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.isHumanTurn == true && gate.canScrub && gate.canPlay)
    }

    @Test func noGameBlocksEverything() {
        let gate = WatchHostGate.evaluate(session: GameSession(), gameRecord: nil)
        #expect(gate.isHumanTurn == nil && !gate.canScrub && !gate.canPlay)
    }

    @Test func lockedGameBlocksPlayOnly() {
        // Play on a locked game would start a branch — not mainline append.
        let (session, gameRecord) = makeHost(editing: false)
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.canScrub && !gate.canPlay)
    }

    @Test func behindHeadBlocksPlayOnly() {
        // Playing behind the head truncates the record (overwrite) — the phone
        // confirms that destructive path with a dialog; the watch must never
        // reach it.
        let (session, gameRecord) = makeHost(currentIndex: 2)
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.canScrub && !gate.canPlay)
    }

    @Test func activeBranchBlocksBoth() {
        let (session, gameRecord) = makeHost()
        session.gobanState.branchSgf = Self.sgf
        session.gobanState.branchIndex = 2
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(!gate.canScrub && !gate.canPlay)
    }

    @Test func aiTurnBlocksBoth() {
        // shouldGenMove true (gen-move may be streaming; if it completes
        // just as a goTo's undo lands, its "play" reply could land on the
        // wrong board — the tvOS lesson; an undo-cancelled search prints
        // "play cancelled", which the vertex regex drops).
        let (session, gameRecord) = makeHost()
        gameRecord.concreteConfig.blackMaxTime = 10
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.isHumanTurn == false && !gate.canScrub && !gate.canPlay)
    }

    @Test func pendingMoveBlocksBoth() {
        let (session, gameRecord) = makeHost()
        session.gobanState.pendingMoveTurn = "b"
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(!gate.canScrub && !gate.canPlay)
    }

    @Test func pausedAnalysisStillAllowsPlay() {
        // Paused candidates are position-fresh (one analysis burst per
        // position change) and playable on the phone; the watch matches.
        let (session, gameRecord) = makeHost()
        session.gobanState.analysisStatus = .pause
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.canScrub && gate.canPlay)
    }

    @Test func clearedAnalysisBlocksPlayOnly() {
        let (session, gameRecord) = makeHost()
        session.gobanState.analysisStatus = .clear
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.canScrub && !gate.canPlay)
    }

    @Test func unknownTurnBlocksPlay() {
        let (session, gameRecord) = makeHost()
        session.player.nextColorForPlayCommand = .unknown
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(gate.isHumanTurn == nil && !gate.canPlay)
    }

    @Test func autoPlayBlocksBoth() {
        let (session, gameRecord) = makeHost()
        session.gobanState.isAutoPlaying = true
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(!gate.canScrub && !gate.canPlay)
    }

    @Test func showBoardInFlightBlocksBoth() {
        let (session, gameRecord) = makeHost()
        session.gobanState.showBoardCount = 1
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(!gate.canScrub && !gate.canPlay)
    }

    @Test func reportGenerationBlocksBoth() {
        let (session, gameRecord) = makeHost()
        session.gobanState.reportGenerationActive = true
        let gate = WatchHostGate.evaluate(session: session, gameRecord: gameRecord)
        #expect(!gate.canScrub && !gate.canPlay)
    }
}
