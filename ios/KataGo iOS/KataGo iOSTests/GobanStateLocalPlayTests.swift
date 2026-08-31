//
//  GobanStateLocalPlayTests.swift
//  KataGo iOSTests
//
//  ADR 0018: a human move is decided and written in Swift, against the record
//  position, so a stone can be played with no engine loaded. These pin the
//  contract from `GobanState`'s side — what the record gains, what the engine
//  is (and is not) told, and what waits on "Play Anyway" — with the command
//  gate SHUT unless a test says otherwise. A suite about the gate builds its
//  own `GameSession()` and never uses `EngineGateTestSupport`'s factories.
//

import Testing
import Foundation
import SwiftData
import GoRulesKit
@testable import KataGoUICore

@MainActor
struct GobanStateLocalPlayTests {

    /// Black Q16, White D4, Black Q4 on a 19x19 — the opening the auto-play and
    /// stone-intent suites already pin ("play b Q16", "play w D4", "play b Q4").
    private static let threeMoves =
        "(;FF[4]GM[1]SZ[19]KM[7.5]RU[japanese];B[pd];W[dp];B[pp])"

    /// A ko on a 5x5, White to move after Black's capture at C4 (2,1). The
    /// captured point B4 (1,1) is the simple-ko point.
    ///
    ///     . B W . .        SGF x: a b c d e
    ///     B W . W .        Black: ba ab bc ; White: ca bb db cc ; B[cb] takes.
    ///     . B W . .
    private static let koShape =
        "(;FF[4]GM[1]SZ[5]KM[7.5]RU[japanese]AB[ba][ab][bc]AW[ca][bb][db][cc];B[cb])"

    @MainActor
    private struct Fixture {
        let session: GameSession
        let record: GameRecord
        let container: ModelContainer

        var state: GobanState { session.gobanState }
        var config: Config { record.concreteConfig }

        /// Whether a command actually reached the transport. A dropped command
        /// is logged as "> (dropped — engine unavailable) …", so a suffix match
        /// on the transcript would count it; the recording engine is the truth.
        func sent(_ command: String) -> Bool {
            (session.engine as? RecordingQueueEngine)?.sentCommands.contains(command) ?? false
        }

        var transcript: [String] {
            (session.engine as? RecordingQueueEngine)?.sentCommands ?? []
        }

        /// What every host's driver does after the record changes: project the
        /// live key. The tests call it explicitly because nothing observes the
        /// record here.
        func project() {
            session.recordPosition.project(key: state.recordPositionKey(gameRecord: record),
                                           into: session.stones,
                                           board: session.board,
                                           analysis: session.analysis,
                                           gobanState: state,
                                           engineIsAcceptingCommands: session.messageList.isAcceptingCommands)
        }

        @discardableResult
        func play(_ vertex: String) -> GobanState.HumanMoveOutcome {
            state.playHumanMove(vertex: vertex,
                                gameRecord: record,
                                config: config,
                                analysis: session.analysis,
                                board: session.board,
                                stones: session.stones,
                                messageList: session.messageList,
                                player: session.player,
                                audioModel: nil,
                                bookLookup: nil)
        }

        var canPlay: Bool {
            state.canPlayHumanMove(config: config, stones: session.stones, messageList: session.messageList)
        }

        func move(at index: Int, in sgf: String) -> (color: String, vertex: String)? {
            guard let move = SgfOperations(sgf: sgf).getMove(at: index),
                  let vertex = session.board.locationToMove(location: move.location) else { return nil }
            return (move.player == .black ? "b" : "w", vertex)
        }
    }

    /// A session with the gate SHUT (no handshake ever happened) unless
    /// `accepting`, a record loaded through `loadGame` — which projects it,
    /// parks the turn `.unknown` and decides `isEditing` exactly as a host's
    /// load does — and the transport recording.
    private func makeFixture(sgf: String = GameRecord.defaultSgf,
                             currentIndex: Int = 0,
                             accepting: Bool = false) throws -> Fixture {
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: SharedModelContainer.inMemoryConfig())
        let session = GameSession()
        session.messageList.isAcceptingCommands = accepting
        session.useEngine(RecordingQueueEngine(live: []))
        let record = GameRecord.createGameRecord(sgf: sgf, currentIndex: currentIndex)
        container.mainContext.insert(record)
        session.gobanState.loadGame(gameRecord: record,
                                    player: session.player,
                                    bookLookup: session.bookLookup,
                                    messageList: session.messageList,
                                    board: session.board,
                                    stones: session.stones,
                                    analysis: session.analysis,
                                    projector: session.recordPosition)
        return Fixture(session: session, record: record, container: container)
    }

    // MARK: - No engine at all

    @Test("With no engine a tap lands in the record, and the engine is owed the position")
    func playsWithNoEngine() throws {
        let f = try makeFixture()
        #expect(f.state.isEditing == true)          // a pristine new game unlocks
        #expect(f.session.player.nextColorForPlayCommand == .unknown)
        #expect(f.state.recordSideToMove == .black)
        #expect(f.canPlay == true)

        #expect(f.play("Q16") == .played)

        #expect(f.record.currentIndex == 1)
        #expect(f.move(at: 0, in: f.record.sgf)?.color == "b")
        #expect(f.move(at: 0, in: f.record.sgf)?.vertex == "Q16")
        // Nothing reached a transport that does not exist, and nothing was
        // asked of the engine either: legality was Swift's.
        #expect(f.transcript.isEmpty)
        #expect(!f.session.messageList.messages.contains { $0.text.contains("kata-check-move") })
        // The debt: the handshake's resync feeds the live record.
        #expect(f.state.engineSyncGate.pending?.index == 1)
        // The engine's turn stays parked; the RECORD carries the side to move.
        #expect(f.session.player.nextColorForPlayCommand == .unknown)
        f.project()
        #expect(f.state.recordSideToMove == .white)
        #expect(f.session.stones.blackPoints.contains(BoardPoint(move: "Q16", width: 19, height: 19)!))
    }

    @Test("The second move is White's, from the record")
    func alternatesFromTheRecord() throws {
        let f = try makeFixture()
        f.play("Q16")
        f.project()
        #expect(f.play("D4") == .played)
        #expect(f.move(at: 1, in: f.record.sgf)?.color == "w")
        #expect(f.move(at: 1, in: f.record.sgf)?.vertex == "D4")
        #expect(f.record.currentIndex == 2)
    }

    @Test("An occupied point is refused and changes nothing")
    func occupiedIsRefused() throws {
        let f = try makeFixture()
        f.play("Q16")
        f.project()
        let sgfBefore = f.record.sgf
        #expect(f.play("Q16") == .refused(.occupied))
        #expect(f.record.sgf == sgfBefore)
        #expect(f.record.currentIndex == 1)
        #expect(f.state.confirmingIllegalMove == false)
    }

    @Test("A pass is written as an empty move and counted")
    func passIsWritten() throws {
        let f = try makeFixture()
        #expect(f.play("pass") == .played)
        #expect(SgfOperations(sgf: f.record.sgf).getMove(at: 0)?.location.pass == true)
        #expect(f.record.currentIndex == 1)
        #expect(f.state.passCount == 1)
    }

    // MARK: - Ko and Play Anyway

    @Test("A ko retake waits on Play Anyway, then plays")
    func koWaitsOnPlayAnyway() throws {
        let f = try makeFixture(sgf: Self.koShape, currentIndex: 1)
        f.state.isEditing = true                     // exercise the record path
        #expect(f.state.recordSideToMove == .white)
        let sgfBefore = f.record.sgf

        let outcome = f.play("B4")
        #expect(outcome == .confirming(.ko))
        #expect(f.state.confirmingIllegalMove == true)
        #expect(f.state.illegalMoveReason == "ko")
        #expect(f.state.pendingMoveTurn == "w")
        #expect(f.state.pendingMoveVertex == "B4")
        #expect(f.record.sgf == sgfBefore)
        // One decision at a time.
        #expect(f.canPlay == false)

        f.state.playPendingHumanMove(gameRecord: f.record, analysis: f.session.analysis,
                                     board: f.session.board, stones: f.session.stones,
                                     messageList: f.session.messageList, player: f.session.player,
                                     audioModel: AudioModel())
        #expect(f.state.pendingMoveTurn == nil)
        #expect(f.state.confirmingIllegalMove == false)
        #expect(f.record.currentIndex == 2)
        #expect(f.move(at: 1, in: f.record.sgf)?.vertex == "B4")
        #expect(f.move(at: 1, in: f.record.sgf)?.color == "w")
    }

    @Test("Cancelling Play Anyway drops the move and reopens the gate")
    func cancelDropsThePendingMove() throws {
        let f = try makeFixture(sgf: Self.koShape, currentIndex: 1)
        f.play("B4")
        f.state.clearPendingMove()
        #expect(f.state.pendingMoveTurn == nil)
        #expect(f.canPlay == true)
        #expect(f.record.currentIndex == 1)
    }

    // MARK: - Locked games

    @Test("A locked game off the recorded line branches; the record is untouched")
    func lockedGameBranches() throws {
        let f = try makeFixture(sgf: Self.threeMoves, currentIndex: 0)
        #expect(f.state.isEditing == false)
        let sgfBefore = f.record.sgf

        #expect(f.play("D4") == .played)

        #expect(f.state.isBranchActive == true)
        #expect(f.state.branchIndex == 1)
        #expect(f.move(at: 0, in: f.state.branchSgf)?.vertex == "D4")
        #expect(SgfOperations(sgf: f.state.branchSgf).moveSize == 1)
        #expect(f.record.sgf == sgfBefore)
        #expect(f.record.currentIndex == 0)
    }

    @Test("A locked game's next recorded move steps the mainline, writing nothing")
    func mainlineShortcutStepsTheCursor() throws {
        let f = try makeFixture(sgf: Self.threeMoves, currentIndex: 0)
        let sgfBefore = f.record.sgf

        #expect(f.play("Q16") == .played)

        #expect(f.state.isBranchActive == false)
        #expect(f.record.currentIndex == 1)
        #expect(f.record.sgf == sgfBefore)
        #expect(f.state.engineSyncGate.pending?.index == 1)
    }

    // MARK: - Whose turn

    @Test("The record's side to move blocks a human move on the AI's turn")
    func aiSideBlocksTheGate() throws {
        let f = try makeFixture()
        f.config.whiteMaxTime = 0.5                  // White is the engine's
        #expect(f.canPlay == true)                   // Black, a human, may play
        f.play("Q16")
        f.project()
        #expect(f.state.recordSideToMove == .white)
        // No engine to answer, but the turn is the engine's all the same: the
        // human does not play the AI's colour by accident.
        #expect(f.canPlay == false)
        f.config.whiteMaxTime = 0
        #expect(f.canPlay == true)
    }

    // MARK: - A live engine

    @Test("With a live engine the record is written first and the engine follows: play, printsgf, showboard")
    func liveEngineFollowsTheRecord() throws {
        let f = try makeFixture(accepting: true)
        f.session.stones.isReady = true              // the feed's ack has landed
        #expect(f.canPlay == true)

        #expect(f.play("Q16") == .played)

        #expect(f.record.currentIndex == 1)
        #expect(f.move(at: 0, in: f.record.sgf)?.vertex == "Q16")
        // The tail of the transcript, in order; nothing asked the engine
        // whether the move was legal.
        #expect(f.transcript.suffix(3) == ["play b Q16", "printsgf", "showboard"])
        #expect(!f.transcript.contains { $0.hasPrefix("kata-check-move") })
        // One move in flight at a time while the engine is live.
        #expect(f.session.stones.isReady == false)
        #expect(f.canPlay == false)
        #expect(f.state.engineSyncGate.pending == nil)
    }

    @Test("Moves played with no engine are fed when the engine arrives")
    func catchUpAfterHandshake() throws {
        let f = try makeFixture()
        f.play("Q16")
        f.project()
        f.play("D4")
        f.project()
        #expect(f.transcript.isEmpty)

        f.session.messageList.isAcceptingCommands = true
        let drained = f.state.resyncEngineAfterHandshake(gameRecord: f.record,
                                                         player: f.session.player,
                                                         messageList: f.session.messageList,
                                                         stones: f.session.stones,
                                                         projector: f.session.recordPosition)
        #expect(drained?.index == 2)
        #expect(f.transcript.contains("clear_board"))
        #expect(f.transcript.contains("play b Q16"))
        #expect(f.transcript.contains("play w D4"))
        #expect(f.transcript.last == "showboard")
        // The feed parked the turn for the ack to resolve.
        #expect(f.session.player.nextColorForPlayCommand == .unknown)
    }

    // MARK: - Hygiene

    @Test("A GobanState no session owns plays nothing")
    func orphanStateRefuses() throws {
        let f = try makeFixture()
        let orphan = GobanState()
        let outcome = orphan.playHumanMove(vertex: "Q16", gameRecord: f.record, config: f.config,
                                           analysis: f.session.analysis, board: f.session.board,
                                           stones: f.session.stones, messageList: f.session.messageList,
                                           player: f.session.player, audioModel: nil)
        #expect(outcome == .refused(nil))
        #expect(f.record.currentIndex == 0)
    }
}
