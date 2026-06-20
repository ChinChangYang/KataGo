//
//  MessageListEngineOwnershipTests.swift
//  KataGo iOSTests
//
//  Verifies that MessageList.appendAndSend routes through GameSession.engine
//  (not a duplicate engine owned by MessageList).
//

import Testing
@testable import KataGoUICore
import Foundation

/// A test double that records every command sent to it.
/// Uses an internal lock so nonisolated protocol methods can safely mutate state.
final class RecordingEngine: KataGoEngineIO, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []

    var sent: [String] {
        lock.withLock { _sent }
    }

    nonisolated func sendCommand(_ command: String) {
        lock.withLock { _sent.append(command) }
    }
    nonisolated func getMessageLine() -> String { "" }
    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool { false }
}

@MainActor
struct MessageListEngineOwnershipTests {
    @Test func appendAndSendRoutesThroughSessionEngine() {
        let session = GameSession()
        let engine = RecordingEngine()
        session.useEngine(engine)
        session.messageList.appendAndSend(command: "version")
        #expect(engine.sent == ["version"])
    }
}
