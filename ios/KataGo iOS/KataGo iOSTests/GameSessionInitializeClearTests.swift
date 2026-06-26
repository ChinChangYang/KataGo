//
//  GameSessionInitializeClearTests.swift
//  KataGo iOSTests
//
//  Verifies that GameSession.initialize() drains stale, buffered output from a
//  prior in-process engine run BEFORE reading the `version` reply. Without this,
//  a re-entry after Quit returns a stale line immediately (instead of blocking
//  for the freshly-relaunched engine), mounting the board before the model
//  finishes loading — and a stale `= ` line wrongly fires markFirstResponse,
//  clearing the OOM crash-loop sentinel.
//

import Testing
@testable import KataGoUICore
import Foundation

/// A test double that models the in-process bridge's two temporal regions:
/// `stale` = lines already buffered from a prior run (present before the
/// handshake), `live` = lines the relaunched engine emits AFTER the buffer is
/// cleared (in reality these arrive seconds later via a blocking read; here we
/// serve them only once the stale region is gone). Honors `clearPendingOutput()`
/// — i.e. it behaves like `InProcessKataGoEngine`.
final class FakeQueueEngine: KataGoEngineIO, @unchecked Sendable {
    private let lock = NSLock()
    private var stale: [String]
    private var live: [String]

    init(stale: [String], live: [String]) {
        self.stale = stale
        self.live = live
    }

    nonisolated func sendCommand(_ command: String) {}
    nonisolated func getMessageLine() -> String {
        lock.withLock {
            if !stale.isEmpty { return stale.removeFirst() }
            if !live.isEmpty { return live.removeFirst() }
            return ""
        }
    }
    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool { false }
    nonisolated func clearPendingOutput() { lock.withLock { stale.removeAll() } }
}

/// Same shape as `FakeQueueEngine` but DOES NOT override `clearPendingOutput()`,
/// so it inherits the protocol-extension no-op — modelling the subprocess
/// transport / any conformer that gets a fresh stream per run. Used to document
/// the pre-fix bug: stale lines are never dropped.
final class NoClearQueueEngine: KataGoEngineIO, @unchecked Sendable {
    private let lock = NSLock()
    private var stale: [String]
    private var live: [String]

    init(stale: [String], live: [String]) {
        self.stale = stale
        self.live = live
    }

    nonisolated func sendCommand(_ command: String) {}
    nonisolated func getMessageLine() -> String {
        lock.withLock {
            if !stale.isEmpty { return stale.removeFirst() }
            if !live.isEmpty { return live.removeFirst() }
            return ""
        }
    }
    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool { false }
    // No clearPendingOutput() override: inherits the default no-op.
}

@MainActor
struct GameSessionInitializeClearTests {
    /// With the fix, `initialize()` clears the stale region first, so the
    /// blocking read returns the GENUINE version reply and markFirstResponse
    /// fires on it.
    @Test func initializeClearsStaleOutputBeforeVersionRead() async {
        // Stale lines a prior run left behind: a kata-analyze `info` line, the
        // bare `= ` reply to `quit` (the sentinel-poisoning line), and the `\n`
        // nudge injected by QuitButton (an empty line).
        let engine = FakeQueueEngine(
            stale: ["info move Q16 visits 10 winrate 0.5", "= ", ""],
            live: ["= 1.16.3"]
        )
        let session = GameSession()
        session.useEngine(engine)
        let lifecycle = EngineLifecycle()

        let version = await session.initialize(
            selectedModelTitle: "TestModel",
            engineLifecycle: lifecycle,
            config: nil
        )

        #expect(version == "= 1.16.3")
        #expect(lifecycle.lastLoadedModelTitle == "TestModel")
    }

    /// Documents the bug a transport that does NOT honor clearPendingOutput
    /// would exhibit: the stale `= ` line is read as the version reply and
    /// wrongly clears the crash sentinel. This is the behavior the fix prevents
    /// on the in-process bridge; the subprocess transport is immune anyway
    /// (fresh stream per process), so its inherited no-op is correct.
    @Test func withoutClearStaleLinePoisonsHandshake() async {
        let engine = NoClearQueueEngine(
            stale: ["= stale-poison"],
            live: ["= 1.16.3"]
        )
        let session = GameSession()
        session.useEngine(engine)
        let lifecycle = EngineLifecycle()

        let version = await session.initialize(
            selectedModelTitle: "TestModel",
            engineLifecycle: lifecycle,
            config: nil
        )

        #expect(version == "= stale-poison")
        #expect(lifecycle.lastLoadedModelTitle == "TestModel")
    }
}
