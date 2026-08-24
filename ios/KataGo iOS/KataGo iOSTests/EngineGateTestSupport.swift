//
//  EngineGateTestSupport.swift
//  KataGo iOSTests
//
//  `MessageList.isAcceptingCommands` defaults to FALSE — a session that has
//  handshaken with nothing has no engine to send to. Only `GameSession.handshake`
//  opens the gate.
//
//  Most suites are not about the gate: they assert what a live engine is told,
//  and they predate the gate entirely. These two factories put such a fixture in
//  the state a completed handshake would have left it in, so those tests keep
//  saying what they always said. A suite that IS about the gate
//  (`MessageListEngineGateTests`, `GameSessionHandshakeTests`,
//  `GobanStateFreshEngineTests`, `GameSessionInitializeClearTests`) constructs
//  its subject directly and never uses these.
//

import Foundation
@testable import KataGoUICore

extension MessageList {
    /// A message list wired to an engine that is listening.
    static func accepting() -> MessageList {
        let list = MessageList()
        list.isAcceptingCommands = true
        return list
    }
}

extension GameSession {
    /// A session already past its handshake.
    static func accepting() -> GameSession {
        let session = GameSession()
        session.messageList.isAcceptingCommands = true
        return session
    }
}

/// One `kata-analyze` line shaped the way the APP asks for it: candidates plus a
/// full root ownership grid.
///
/// Every app target requests ownership (`AnalysisCommand.analyze` defaults it
/// true; only the iOS Safari appex opts out, and it never reaches
/// `GameSession`). Since ADR 0011 the collector drops any line whose grid does
/// not fit the board on screen, so a fixture WITHOUT a grid is not a line the
/// collector can ever see — and a test built on one would be pinning a path
/// that does not exist.
enum AnalyzeLineFixture {
    static func line(move: String = "Q16",
                     visits: Int = 10,
                     boardWidth: Int = 19,
                     boardHeight: Int = 19) -> String {
        let count = boardWidth * boardHeight
        let ownership = Array(repeating: "0.5", count: count).joined(separator: " ")
        let stdev = Array(repeating: "0.1", count: count).joined(separator: " ")
        return "info move \(move) visits \(visits) winrate 0.55 scoreLead 2.5"
            + " utilityLcb 0.3 order 0 pv \(move)"
            + " ownership \(ownership) ownershipStdev \(stdev)"
    }

    /// A line whose grid belongs to a DIFFERENT board — what a search for the
    /// position the user just left keeps streaming after a size change.
    static func lineForAnotherBoard(boardWidth: Int, boardHeight: Int) -> String {
        line(boardWidth: boardWidth, boardHeight: boardHeight)
    }
}
