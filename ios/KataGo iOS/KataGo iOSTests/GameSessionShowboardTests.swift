//
//  GameSessionShowboardTests.swift
//  KataGo AnytimeTests
//
//  `showboard` is no longer the board — it is the ENGINE-IN-SYNC
//  acknowledgement. `GameSession.maybeCollectSync` may take exactly two things
//  from the block (the side to move and `stones.isReady`) and must leave the
//  record-projected stones, board size, capture counts and move digits alone.
//
//  The ASCII itself is still parsed under DEBUG, but only to log a divergence
//  — never to mutate. `BoardTextParserTests` covers the parser.
//

import Testing
import Foundation
@testable import KataGoUICore

@MainActor
struct GameSessionShowboardTests {
    /// One complete 3×3 showboard reply, in the order KataGo prints it.
    /// The engine's ASCII deliberately DISAGREES with the stones the record
    /// projected in each test, so any write from this block would be visible.
    private static func block(nextPlayer: String) -> [String] {
        [
            "= MoveNum: 2 HASH: 0123456789ABCDEF",
            "   A B C",
            " 3 . O .",
            " 2 X 1 .",
            " 1 . . .",
            "Next player: \(nextPlayer)",
            "Rules: {\"ko\":\"POSITIONAL\"}",
            "B stones captured: 7",
            "W stones captured: 9",
        ]
    }

    /// The board as the record projected it: one black stone on a 19×19.
    private func seedRecordPosition(_ session: GameSession) {
        session.board.width = 19
        session.board.height = 19
        session.stones.blackPoints = [BoardPoint(x: 3, y: 3)]
        session.stones.whitePoints = []
        session.stones.moveOrder = [BoardPoint(x: 3, y: 3): "1"]
        session.stones.blackStonesCaptured = 0
        session.stones.whiteStonesCaptured = 0
        session.stones.isReady = false
    }

    @Test func theAckSetsInSyncAndTheSideToMoveButNeverTheStones() async {
        let session = GameSession.accepting()
        seedRecordPosition(session)
        session.gobanState.showBoardCount = 1

        for line in Self.block(nextPlayer: "White") {
            await session.maybeCollectSync(message: line)
        }

        // What the ack IS allowed to say.
        #expect(session.stones.isReady)
        #expect(session.player.nextColorForPlayCommand == .white)
        #expect(session.player.nextColorFromShowBoard == .white)

        // What it may never touch — all of it record-owned now.
        #expect(session.stones.blackPoints == [BoardPoint(x: 3, y: 3)])
        #expect(session.stones.whitePoints.isEmpty)
        #expect(session.stones.moveOrder == [BoardPoint(x: 3, y: 3): "1"])
        #expect(session.stones.blackStonesCaptured == 0)
        #expect(session.stones.whiteStonesCaptured == 0)
        #expect(session.board.width == 19)
        #expect(session.board.height == 19)
    }

    @Test func aStaleIntermediateAckIsNotParsedAtAll() async {
        // Two showboards outstanding: the first block belongs to a navigation
        // the second one supersedes. Its "Next player" must not flip the turn
        // and its trailing line must not claim the engine is in sync.
        let session = GameSession.accepting()
        seedRecordPosition(session)
        session.player.nextColorForPlayCommand = .black
        session.player.nextColorFromShowBoard = .black
        session.gobanState.showBoardCount = 2

        for line in Self.block(nextPlayer: "White") {
            await session.maybeCollectSync(message: line)
        }

        #expect(session.gobanState.showBoardCount == 1)
        #expect(session.player.nextColorForPlayCommand == .black)
        #expect(!session.stones.isReady)

        // The LAST outstanding ack is the one that counts.
        for line in Self.block(nextPlayer: "White") {
            await session.maybeCollectSync(message: line)
        }

        #expect(session.gobanState.showBoardCount == 0)
        #expect(session.player.nextColorForPlayCommand == .white)
        #expect(session.stones.isReady)
    }

    // MARK: - The shared Held seam

    /// `holdEngineSession` is `abortInFlightBoardCollection` plus the gate,
    /// plus the fresh-engine reset — and the abort is the part four hand-written
    /// host copies used to miss. Without it the collector stays "inside a
    /// block", so the NEXT acknowledgement's `= MoveNum` line is eaten as board
    /// text: `showBoardCount` never returns to 0 and `maybeCollectAnalysis`,
    /// gated on it, is dead until the app relaunches.
    @Test func aHoldMidBlockLetsTheNextAckReturnTheCountToZero() async {
        let session = GameSession.accepting()
        let engine = RecordingEngine()
        session.useEngine(engine)
        session.engineStatus.availability = .ready
        seedRecordPosition(session)

        // A showboard is outstanding, and its block has begun arriving.
        session.gobanState.showBoardCount = 1
        for line in Self.block(nextPlayer: "White").prefix(3) {
            await session.maybeCollectSync(message: line)
        }
        #expect(session.gobanState.showBoardCount == 0)

        session.holdEngineSession(maxBoardLength: 19)
        #expect(session.engineStatus.availability == .held(maxBoardLength: 19))
        #expect(engine.sent.contains("stop"))
        #expect(!session.messageList.isAcceptingCommands)

        session.releaseEngineHold(gameRecord: nil)
        #expect(session.engineStatus.availability == .ready)
        #expect(session.messageList.isAcceptingCommands)

        // The re-feed's own showboard, answered in full.
        session.gobanState.showBoardCount = 1
        for line in Self.block(nextPlayer: "Black") {
            await session.maybeCollectSync(message: line)
        }

        #expect(session.gobanState.showBoardCount == 0,
                "the ack after a hold was eaten as board text — analysis is dead until a relaunch")
        #expect(session.stones.isReady)
        #expect(session.player.nextColorForPlayCommand == .black)
    }

    /// The block a hold interrupted must not be able to finish afterwards: its
    /// trailing lines belong to a position the engine no longer holds.
    @Test func theInterruptedBlockCannotClaimSyncAfterTheHold() async {
        let session = GameSession.accepting()
        let engine = RecordingEngine()
        session.useEngine(engine)
        session.engineStatus.availability = .ready
        seedRecordPosition(session)

        session.gobanState.showBoardCount = 1
        let lines = Self.block(nextPlayer: "White")
        for line in lines.prefix(3) {
            await session.maybeCollectSync(message: line)
        }
        session.holdEngineSession(maxBoardLength: 19)
        session.releaseEngineHold(gameRecord: nil)

        // The dying block's tail arrives after the release.
        for line in lines.dropFirst(3) {
            await session.maybeCollectSync(message: line)
        }

        #expect(!session.stones.isReady)
        #expect(session.player.nextColorForPlayCommand != .white)
    }

    @Test func abortingAnInFlightBlockKeepsItFromClaimingSync() async {
        // A game switch lands mid-block. The rest of the superseded block must
        // not flip `isReady` true for the game that just started loading.
        let session = GameSession.accepting()
        seedRecordPosition(session)
        session.gobanState.showBoardCount = 1

        let lines = Self.block(nextPlayer: "White")
        for line in lines.prefix(4) {
            await session.maybeCollectSync(message: line)
        }
        session.abortInFlightBoardCollection()
        for line in lines.dropFirst(4) {
            await session.maybeCollectSync(message: line)
        }

        #expect(!session.stones.isReady)
        #expect(session.player.nextColorForPlayCommand != .white)
    }
}
