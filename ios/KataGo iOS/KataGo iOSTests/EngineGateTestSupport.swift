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
