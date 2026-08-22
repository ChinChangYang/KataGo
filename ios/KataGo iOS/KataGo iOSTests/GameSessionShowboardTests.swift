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
        let session = GameSession()
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
        let session = GameSession()
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

    @Test func abortingAnInFlightBlockKeepsItFromClaimingSync() async {
        // A game switch lands mid-block. The rest of the superseded block must
        // not flip `isReady` true for the game that just started loading.
        let session = GameSession()
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
