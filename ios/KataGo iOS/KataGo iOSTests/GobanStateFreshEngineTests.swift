//
//  GobanStateFreshEngineTests.swift
//  KataGo iOSTests
//
//  A fresh engine knows nothing. Everything that says "the engine and the board
//  agree" — the outstanding-acknowledgement counter, the in-sync flag, a move
//  waiting on a legality check, the running pass count — has to go back to its
//  zero state before the new engine is told anything, or the first reply lands
//  against the previous engine's bookkeeping.
//
//  The other half is the resync: while the engine was down, navigation kept
//  moving the board and every send was dropped. Once the handshake lands, the
//  engine is fed the position the board is showing NOW — not the one that was
//  showing when the first send was dropped.
//

import Testing
import Foundation
import SwiftData
@testable import KataGoUICore

@MainActor
struct GobanStateFreshEngineTests {

    private static let fourMoves =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pp];W[dd])"
    private static let twoMoves =
        "(;FF[4]GM[1]SZ[9]KM[7.5]RU[japanese];B[ee];W[cc])"

    private struct Fixture {
        let session: GameSession
        let engine: RecordingQueueEngine
        let container: ModelContainer
    }

    private func makeFixture() throws -> Fixture {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: SharedModelContainer.inMemoryConfig())
        let engine = RecordingQueueEngine(live: [])
        let session = GameSession()
        session.useEngine(engine)
        return Fixture(session: session, engine: engine, container: container)
    }

    private func insert(_ record: GameRecord, in fixture: Fixture) -> GameRecord {
        fixture.container.mainContext.insert(record)
        return record
    }

    private func load(_ record: GameRecord, in fixture: Fixture) {
        fixture.session.gobanState.loadGame(gameRecord: record,
                                            player: fixture.session.player,
                                            bookLookup: fixture.session.bookLookup,
                                            messageList: fixture.session.messageList,
                                            board: fixture.session.board,
                                            stones: fixture.session.stones,
                                            analysis: fixture.session.analysis,
                                            projector: fixture.session.recordPosition)
    }

    // MARK: - The reset

    @Test func resetForFreshEngineClearsEveryEngineAgreementSignal() throws {
        let fixture = try makeFixture()
        let state = fixture.session.gobanState
        let stones = fixture.session.stones

        state.showBoardCount = 3
        state.waitingForAnalysis = true
        state.passCount = 2
        state.broadcastGenMovePending = true
        state.pendingMoveTurn = "b"
        state.pendingMoveVertex = "Q16"
        stones.isReady = true

        state.resetForFreshEngine(stones: stones)

        #expect(state.showBoardCount == 0)
        #expect(state.waitingForAnalysis == false)
        #expect(state.passCount == 0)
        #expect(state.broadcastGenMovePending == false)
        #expect(state.pendingMoveTurn == nil)
        #expect(state.pendingMoveVertex == nil)
        #expect(stones.isReady == false)
    }

    /// The board is record-owned, so the reset must not touch what is drawn —
    /// only what claims the engine agrees with it.
    @Test func resetForFreshEngineLeavesTheDrawnPositionAlone() throws {
        let fixture = try makeFixture()
        fixture.session.messageList.isAcceptingCommands = true
        load(insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 4),
                    in: fixture), in: fixture)
        let drawn = fixture.session.stones.blackPoints.count + fixture.session.stones.whitePoints.count
        #expect(drawn == 4)

        fixture.session.gobanState.resetForFreshEngine(stones: fixture.session.stones)

        #expect(fixture.session.stones.blackPoints.count
                + fixture.session.stones.whitePoints.count == 4)
    }

    // MARK: - The deferred-sync gate

    /// Navigation while the engine is down must leave a note that the engine
    /// owes this position a feed.
    @Test func requestStashesWhenTheEngineIsNotAccepting() throws {
        let fixture = try makeFixture()
        let record = insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2),
                            in: fixture)

        load(record, in: fixture)

        #expect(fixture.engine.sentCommands.isEmpty)
        let pending = try #require(fixture.session.gobanState.engineSyncGate.pending)
        #expect(pending.index == 2)
        #expect(pending.recordID == record.persistentModelID)
    }

    /// A load that DID reach the engine leaves nothing owing.
    @Test func nothingIsStashedWhenTheSendWentThrough() throws {
        let fixture = try makeFixture()
        fixture.session.messageList.isAcceptingCommands = true

        load(insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2),
                    in: fixture), in: fixture)

        #expect(fixture.session.gobanState.engineSyncGate.pending == nil)
    }

    /// Latest selection wins. The stashed payload records WHAT was dropped, but
    /// the feed is built from the live record and the live cursor — the user
    /// may have switched games four times while the model compiled.
    @Test func resyncFeedsTheLiveSelectionNotTheStashedOne() throws {
        let fixture = try makeFixture()
        let stale = insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 4),
                           in: fixture)
        let live = insert(GameRecord.createGameRecord(sgf: Self.twoMoves, currentIndex: 1),
                          in: fixture)

        load(stale, in: fixture)          // dropped: the engine is not up yet
        load(live, in: fixture)           // dropped too; this is what is on screen
        #expect(fixture.engine.sentCommands.isEmpty)

        fixture.session.messageList.isAcceptingCommands = true
        let drained = fixture.session.gobanState.resyncEngineAfterHandshake(
            gameRecord: live,
            player: fixture.session.player,
            messageList: fixture.session.messageList,
            stones: fixture.session.stones,
            projector: fixture.session.recordPosition)

        // The payload names the last dropped request (diagnostics)…
        #expect(drained?.recordID == live.persistentModelID)
        // …and the feed describes the LIVE 9x9 record at its own cursor.
        #expect(fixture.engine.sentCommands.first == "rectangular_boardsize 9 9")
        #expect(fixture.engine.sentCommands.filter { $0.hasPrefix("play ") } == ["play b E5"])
        #expect(fixture.engine.sentCommands.last == "showboard")
    }

    /// Draining is one-shot: a later readiness cycle must not replay it.
    @Test func theGateIsEmptyAfterAResync() throws {
        let fixture = try makeFixture()
        let record = insert(GameRecord.createGameRecord(sgf: Self.twoMoves, currentIndex: 1),
                            in: fixture)
        load(record, in: fixture)
        #expect(fixture.session.gobanState.engineSyncGate.pending != nil)

        fixture.session.messageList.isAcceptingCommands = true
        _ = fixture.session.gobanState.resyncEngineAfterHandshake(
            gameRecord: record,
            player: fixture.session.player,
            messageList: fixture.session.messageList,
            stones: fixture.session.stones,
            projector: fixture.session.recordPosition)

        #expect(fixture.session.gobanState.engineSyncGate.pending == nil)
    }

    /// A resync into an engine that is STILL not accepting sends nothing — and
    /// must not throw the debt away either.
    @Test func aResyncWhileStillUnavailableSendsNothing() throws {
        let fixture = try makeFixture()
        let record = insert(GameRecord.createGameRecord(sgf: Self.twoMoves, currentIndex: 1),
                            in: fixture)
        load(record, in: fixture)

        _ = fixture.session.gobanState.resyncEngineAfterHandshake(
            gameRecord: record,
            player: fixture.session.player,
            messageList: fixture.session.messageList,
            stones: fixture.session.stones,
            projector: fixture.session.recordPosition)

        #expect(fixture.engine.sentCommands.isEmpty)
        #expect(fixture.session.gobanState.engineSyncGate.pending != nil)
    }

    /// Navigation is the other dropper: forward steps move the cursor whether
    /// or not the engine can hear about them, so the debt has to be recorded
    /// at the index the board ended on.
    @Test func navigationWhileUnavailableStashesTheIndexItLandedOn() throws {
        let fixture = try makeFixture()
        let record = insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 0),
                            in: fixture)
        load(record, in: fixture)

        fixture.session.gobanState.forwardMoves(limit: 2,
                                                gameRecord: record,
                                                board: fixture.session.board,
                                                messageList: fixture.session.messageList,
                                                player: fixture.session.player,
                                                audioModel: nil,
                                                stones: fixture.session.stones)

        #expect(record.currentIndex == 2)
        #expect(fixture.engine.sentCommands.isEmpty)
        #expect(fixture.session.gobanState.engineSyncGate.pending?.index == 2)
    }

    // MARK: - The turn park

    /// A relaunch does not change whose move it is — and analysis re-arms ONLY
    /// off the turn EDGE (the hosts' `onChange(of: player.nextColorForPlayCommand)`).
    /// Without a park, the feed's `showboard` reply would restate the colour the
    /// board already held, no edge would fire, and a perfectly healthy fresh
    /// engine would sit there analysing nothing.
    ///
    /// So: park at `.unknown` as part of the feed, and let the ack resolve it.
    @Test func aResyncParksTheTurnSoTheAckReArmsAnalysis() async throws {
        let fixture = try makeFixture()
        let record = insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2),
                            in: fixture)
        load(record, in: fixture)                       // dropped: no engine yet
        // The side to move BEFORE the relaunch — and, after two moves, the same
        // side the fresh engine will report. Without the park this value never
        // changes and no edge ever fires.
        fixture.session.player.nextColorForPlayCommand = .black

        fixture.session.messageList.isAcceptingCommands = true
        fixture.session.gobanState.resyncEngineAfterHandshake(
            gameRecord: record,
            player: fixture.session.player,
            messageList: fixture.session.messageList,
            stones: fixture.session.stones,
            projector: fixture.session.recordPosition)

        #expect(fixture.session.player.nextColorForPlayCommand == .unknown)
        #expect(fixture.engine.sentCommands.last == "showboard")

        // The ack lands: the SAME side to move as before the relaunch, and it is
        // an edge because the park made it one.
        for line in ["= MoveNum: 2 HASH: 0123456789ABCDEF",
                     "Next player: Black",
                     "B stones captured: 0",
                     "W stones captured: 0"] {
            await fixture.session.maybeCollectSync(message: line)
        }
        #expect(fixture.session.player.nextColorForPlayCommand == .black)
        #expect(fixture.session.stones.isReady)
    }

    /// A park nothing can resolve is worse than no park at all: the edge that
    /// re-arms analysis would never fire again. So when the resync sends
    /// nothing — a shut gate — the turn is left exactly where it was.
    @Test func aResyncThatSendsNothingLeavesTheTurnAlone() throws {
        let fixture = try makeFixture()
        let record = insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2),
                            in: fixture)
        load(record, in: fixture)
        fixture.session.player.nextColorForPlayCommand = .black

        // Still launching: the gate is shut, so nothing goes out.
        fixture.session.gobanState.resyncEngineAfterHandshake(
            gameRecord: record,
            player: fixture.session.player,
            messageList: fixture.session.messageList,
            stones: fixture.session.stones,
            projector: fixture.session.recordPosition)

        #expect(fixture.engine.sentCommands.isEmpty)
        #expect(fixture.session.player.nextColorForPlayCommand == .black)
    }

    /// The Held case, which is the one that bit macOS: the engine is up and
    /// accepting, but this board is larger than its NN buffer, so the feed is
    /// refused. The turn must survive that too.
    @Test func aResyncRefusedForBoardSizeLeavesTheTurnAlone() throws {
        let fixture = try makeFixture()
        fixture.session.messageList.isAcceptingCommands = true
        fixture.session.gobanState.engineMaxBoardLength = 9
        let record = insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2),
                            in: fixture)
        load(record, in: fixture)
        fixture.session.player.nextColorForPlayCommand = .white

        fixture.session.gobanState.resyncEngineAfterHandshake(
            gameRecord: record,
            player: fixture.session.player,
            messageList: fixture.session.messageList,
            stones: fixture.session.stones,
            projector: fixture.session.recordPosition)

        #expect(fixture.engine.sentCommands.isEmpty)
        #expect(fixture.session.player.nextColorForPlayCommand == .white)
    }

    // MARK: - onAppear

    /// `BoardView.onAppear` re-arms the turn edge (the iPhone push-pop restore
    /// after `maybePauseAnalysis` depends on it) — but only against an engine
    /// that can answer. Against an unavailable one it is a no-op, so the
    /// `.unknown` park is not left hanging with nothing to resolve it.
    @Test func resyncOnAppearOnlyAsksAReadyEngine() throws {
        let fixture = try makeFixture()
        fixture.session.player.nextColorForPlayCommand = .black

        fixture.session.gobanState.resyncOnAppear(engineReady: false,
                                                  player: fixture.session.player,
                                                  messageList: fixture.session.messageList)

        #expect(fixture.engine.sentCommands.isEmpty)
        #expect(fixture.session.player.nextColorForPlayCommand == .black)
        #expect(fixture.session.gobanState.showBoardCount == 0)
    }

    @Test func resyncOnAppearParksTheTurnAndAsksAReadyEngine() throws {
        let fixture = try makeFixture()
        fixture.session.messageList.isAcceptingCommands = true
        fixture.session.player.nextColorForPlayCommand = .black

        fixture.session.gobanState.resyncOnAppear(engineReady: true,
                                                  player: fixture.session.player,
                                                  messageList: fixture.session.messageList)

        #expect(fixture.session.player.nextColorForPlayCommand == .unknown)
        #expect(fixture.engine.sentCommands == ["showboard"])
        #expect(fixture.session.gobanState.showBoardCount == 1)
    }

    // MARK: - The unreadable record

    /// An SGF the C++ parser rejects draws no position and gets no feed, so the
    /// board would sit at an empty grid with nothing ever explaining why. It is
    /// a RECORD state, not an engine state — hence its own flag rather than a
    /// sixth `EngineAvailability` case.
    @Test func anUnreadableRecordIsFlagged() throws {
        let fixture = try makeFixture()
        fixture.session.messageList.isAcceptingCommands = true

        load(insert(GameRecord.createGameRecord(sgf: "not an sgf at all", currentIndex: 0),
                    in: fixture), in: fixture)

        #expect(fixture.session.gobanState.isRecordUnreadable == true)
        #expect(fixture.engine.sentCommands.isEmpty)
    }

    @Test func aReadableRecordClearsTheFlag() throws {
        let fixture = try makeFixture()
        fixture.session.messageList.isAcceptingCommands = true

        load(insert(GameRecord.createGameRecord(sgf: "not an sgf at all", currentIndex: 0),
                    in: fixture), in: fixture)
        #expect(fixture.session.gobanState.isRecordUnreadable == true)

        load(insert(GameRecord.createGameRecord(sgf: Self.fourMoves, currentIndex: 2),
                    in: fixture), in: fixture)

        #expect(fixture.session.gobanState.isRecordUnreadable == false)
    }
}
