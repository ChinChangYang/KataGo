//
//  GameSessionInitializeClearTests.swift
//  KataGo iOSTests
//
//  Verifies that GameSession.initialize() drains stale, buffered output from a
//  prior in-process engine run BEFORE reading the `version` reply.
//
//  What the drain protects is NOT a board mount — the board never waits for the
//  engine and draws the record position regardless. It protects the two things
//  a stale line can forge: the IN-SYNC SIGNAL (a leftover `= ` read as this
//  engine's `version` reply opens the command gate against a model that is
//  still loading, and everything sent through it is lost) and the CRASH
//  SENTINEL (`markFirstResponse` clears the OOM sentinel on a `= ` prefix, so a
//  stale one reports a load that never finished as successful).
//

import Testing
@testable import KataGoUICore
import Foundation
import SwiftData

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
        // nudge injected by the quit teardown (an empty line).
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

/// Like `FakeQueueEngine`, but records every command sent through the seam so
/// tests can assert WHICH GTP commands a session phase emitted.
final class RecordingQueueEngine: KataGoEngineIO, @unchecked Sendable {
    private let lock = NSLock()
    private var live: [String]
    private var sent: [String] = []

    init(live: [String]) {
        self.live = live
    }

    var sentCommands: [String] { lock.withLock { sent } }

    nonisolated func sendCommand(_ command: String) { lock.withLock { sent.append(command) } }
    nonisolated func getMessageLine() -> String {
        lock.withLock { live.isEmpty ? "" : live.removeFirst() }
    }
    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool { false }
    nonisolated func clearPendingOutput() {}
}

/// Holds the `version` reply until the test releases it — modelling the
/// engine's multi-second model load, during which the system delivers a
/// cold-launch `open-game` URL on the main actor.
final class GatedVersionEngine: KataGoEngineIO, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)

    nonisolated func releaseVersionReply() { gate.signal() }

    nonisolated func sendCommand(_ command: String) {}
    nonisolated func getMessageLine() -> String {
        gate.wait()
        return "= 1.16.3"
    }
    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool { false }
    nonisolated func clearPendingOutput() {}
}

/// Release cold-launch deep-link race: the widget's `open-game` URL is
/// delivered asynchronously around the first frame, while the Release
/// auto-restore path used to read `DeepLinkRouter.pendingGameID` synchronously
/// on the first frames — losing the race and stranding the late-arriving id
/// (`GameSplitView`'s `.onChange` never sees pre-mount changes). Debug builds
/// always show the model picker (`RecoveryDecision`), so the race was masked
/// everywhere but on-device Release. The fix defers consumption past the
/// engine handshake, whose blocking `version` read spans the model load.
@MainActor
struct GameSessionHandshakeSplitTests {
    /// `handshake` must complete the version/first-response exchange WITHOUT
    /// sending any config commands — those move to `sendInitialCommands`,
    /// called after the host resolves which game seeds the engine.
    @Test func handshakeSendsNoConfigCommandsUntilSendInitialCommands() async {
        let engine = RecordingQueueEngine(live: ["= 1.16.3"])
        let session = GameSession()
        session.useEngine(engine)
        let lifecycle = EngineLifecycle()

        let version = await session.handshake(
            selectedModelTitle: "TestModel",
            engineLifecycle: lifecycle
        )

        #expect(version == "= 1.16.3")
        #expect(lifecycle.lastLoadedModelTitle == "TestModel")
        #expect(!engine.sentCommands.contains { $0.hasPrefix("rectangular_boardsize") || $0.hasPrefix("komi") })

        session.sendInitialCommands(config: Config())

        #expect(engine.sentCommands.contains { $0.hasPrefix("rectangular_boardsize") })
        #expect(engine.sentCommands.contains { $0.hasPrefix("komi") })
    }

    /// The `initialize` convenience (used by the macOS/tvOS hosts and the
    /// tests above) must stay behavior-identical: handshake + config commands.
    @Test func initializeStillSendsConfigCommands() async {
        let engine = RecordingQueueEngine(live: ["= 1.16.3"])
        let session = GameSession()
        session.useEngine(engine)

        let version = await session.initialize(
            selectedModelTitle: "TestModel",
            engineLifecycle: EngineLifecycle(),
            config: Config()
        )

        #expect(version == "= 1.16.3")
        #expect(engine.sentCommands.contains { $0.hasPrefix("rectangular_boardsize") })
        #expect(engine.sentCommands.contains { $0.hasPrefix("komi") })
    }

    /// The regression itself: a pending id set while the handshake's blocking
    /// version read is in flight (URL delivered mid-model-load) must be
    /// visible to the post-handshake resolve. The pre-fix code read the router
    /// BEFORE the handshake and lost exactly this interleaving.
    @Test func pendingIDDeliveredDuringModelLoadSelectsThatGame() async throws {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: ModelConfiguration(schema: SharedModelContainer.schema,
                                               isStoredInMemoryOnly: true)
        )
        let configured = GameRecord(config: Config()); configured.name = "Configured"
        configured.uuid = UUID(); configured.lastModificationDate = Date(timeIntervalSince1970: 1)
        let mostRecent = GameRecord(config: Config()); mostRecent.name = "MostRecent"
        mostRecent.uuid = UUID(); mostRecent.lastModificationDate = Date(timeIntervalSince1970: 2)
        container.mainContext.insert(configured)
        container.mainContext.insert(mostRecent)
        try container.mainContext.save()

        let engine = GatedVersionEngine()
        let session = GameSession()
        session.useEngine(engine)
        let router = DeepLinkRouter()

        let handshake = Task {
            await session.handshake(selectedModelTitle: "TestModel",
                                    engineLifecycle: EngineLifecycle())
        }
        router.pendingGameID = configured.uuid   // the widget URL lands mid-load
        engine.releaseVersionReply()             // model load finishes
        _ = await handshake.value

        let initial = GameRecord.resolveInitialSelection(
            pendingGameID: router.pendingGameID,
            container: container
        )
        #expect(initial?.uuid == configured.uuid)
    }
}
