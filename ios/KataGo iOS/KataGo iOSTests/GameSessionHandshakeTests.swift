//
//  GameSessionHandshakeTests.swift
//  KataGo iOSTests
//
//  The handshake is the only thing that opens the command gate, and it is the
//  only thing that can close it on a failure. Before it, the session is
//  *Launching* and refuses commands; after a `= ` reply it is *Ready* and
//  accepting; after a timeout or an abandonment it is *Failed* and still
//  refusing — with no reader parked on the bridge that would swallow the NEXT
//  engine's `version` reply.
//

import Testing
import Foundation
import SwiftUI
import SwiftData
@testable import KataGoUICore

/// An engine that answers only when the test says so. `getMessageLine(timeoutSeconds:)`
/// returns "" (the "nothing yet" reply every transport gives on a timeout)
/// until a line is queued, which is exactly the shape of a real engine still
/// loading its net. `activeReaders` is how the tests below prove that an
/// abandoned handshake left nobody blocked on the bridge.
final class PendingReplyEngine: KataGoEngineIO, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [String] = []
    private var sent: [String] = []
    private var readers = 0
    private var peakReaders = 0

    init(queued: [String] = []) {
        self.queued = queued
    }

    var sentCommands: [String] { lock.withLock { sent } }
    var pendingLines: [String] { lock.withLock { queued } }
    var activeReaders: Int { lock.withLock { readers } }
    var peakConcurrentReaders: Int { lock.withLock { peakReaders } }

    func queue(_ line: String) { lock.withLock { queued.append(line) } }

    nonisolated func sendCommand(_ command: String) { lock.withLock { sent.append(command) } }

    nonisolated func getMessageLine() -> String {
        getMessageLine(timeoutSeconds: 0.05)
    }

    nonisolated func getMessageLine(timeoutSeconds: Double) -> String {
        lock.withLock {
            readers += 1
            peakReaders = max(peakReaders, readers)
        }
        defer { lock.withLock { readers -= 1 } }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let next: String? = lock.withLock { queued.isEmpty ? nil : queued.removeFirst() }
            if let next { return next }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return ""
    }

    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool { false }
    /// A no-op, like the macOS subprocess transport: this double models a
    /// transport that gets a fresh stream per engine run, so a line queued for
    /// the NEXT engine survives the next handshake's stale-output drain.
    /// (`GameSessionInitializeClearTests` covers the draining transport.)
    nonisolated func clearPendingOutput() {}
}

/// The same exited child, but it cancels the handshake AT THE MOMENT the
/// handshake observes the EOF — `hasReachedEOF` is read from inside the EOF
/// branch, so the cancellation flag is raised after the branch has already
/// recorded its reason and before the post-loop cancellation check reads it.
/// That is the interleaving a `withTimeout` wrapper produces when the helper
/// dies just as the wrapper gives up, and it must not turn "The engine stopped."
/// into a statement about patience.
final class EOFCancellingEngine: KataGoEngineIO, @unchecked Sendable {
    private let lock = NSLock()
    private var _handshake: Task<String?, Never>?

    /// Wire the handshake's own task in. The test does this before awaiting,
    /// and a `@MainActor` `Task { }` cannot start until the test suspends, so
    /// the read below always finds it.
    var handshake: Task<String?, Never>? {
        get { lock.withLock { _handshake } }
        set { lock.withLock { _handshake = newValue } }
    }

    nonisolated func sendCommand(_ command: String) {}
    nonisolated func getMessageLine() -> String { "" }
    nonisolated func getMessageLine(timeoutSeconds: Double) -> String { "" }
    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool {
        handshake?.cancel()
        return true
    }
    nonisolated func clearPendingOutput() {}
}

/// A transport whose child has already exited: every read is "" and
/// `hasReachedEOF` is true. Only the macOS subprocess can be in this state —
/// the in-process bridge never EOFs.
final class ExitedEngine: KataGoEngineIO, @unchecked Sendable {
    nonisolated func sendCommand(_ command: String) {}
    nonisolated func getMessageLine() -> String { "" }
    nonisolated func getMessageLine(timeoutSeconds: Double) -> String { "" }
    nonisolated func sendMessage(_ message: String) {}
    nonisolated var hasReachedEOF: Bool { true }
    nonisolated func clearPendingOutput() {}
}

@MainActor
struct GameSessionHandshakeTests {

    // MARK: - The happy path

    @Test func aVersionReplyMakesTheSessionReadyAndAccepting() async {
        let engine = PendingReplyEngine()
        let session = GameSession()
        session.useEngine(engine)
        let lifecycle = EngineLifecycle()
        engine.queue("= 1.16.3")

        let version = await session.handshake(selectedModelTitle: "TestModel",
                                              engineLifecycle: lifecycle,
                                              timeoutSeconds: 5)

        #expect(version == "= 1.16.3")
        #expect(session.engineStatus.availability == .ready)
        #expect(session.engineStatus.engineVersion == "= 1.16.3")
        #expect(session.engineStatus.modelTitle == "TestModel")
        #expect(session.messageList.isAcceptingCommands == true)
        #expect(lifecycle.lastLoadedModelTitle == "TestModel")
    }

    /// `version` is a lifecycle command: it has to go out through a gate that
    /// is, by construction, shut at that moment. If it did not, no engine could
    /// ever be handshaken and every platform's launch would hang.
    @Test func versionGoesOutThroughTheShutGate() async {
        let engine = PendingReplyEngine(queued: ["= 1.16.3"])
        let session = GameSession()
        session.useEngine(engine)
        #expect(session.messageList.isAcceptingCommands == false)

        _ = await session.handshake(selectedModelTitle: "TestModel",
                                    engineLifecycle: EngineLifecycle(),
                                    timeoutSeconds: 5)

        #expect(engine.sentCommands.first == "version")
    }

    /// Every engine-agreement signal from the PREVIOUS engine is dropped before
    /// the new one is asked anything: a leftover outstanding-ack count would
    /// keep the board from ever reporting in sync again.
    @Test func theHandshakeResetsThePreviousEnginesBookkeeping() async {
        let engine = PendingReplyEngine(queued: ["= 1.16.3"])
        let session = GameSession()
        session.useEngine(engine)
        session.gobanState.showBoardCount = 4
        session.gobanState.passCount = 2
        session.stones.isReady = true

        _ = await session.handshake(selectedModelTitle: "TestModel",
                                    engineLifecycle: EngineLifecycle(),
                                    timeoutSeconds: 5)

        #expect(session.gobanState.showBoardCount == 0)
        #expect(session.gobanState.passCount == 0)
        // Still false: the new engine has acknowledged no position yet.
        #expect(session.stones.isReady == false)
    }

    // MARK: - Failure

    @Test func aTimeoutFailsTheSessionAndLeavesTheGateShut() async {
        let engine = PendingReplyEngine()
        let session = GameSession()
        session.useEngine(engine)

        let version = await session.handshake(selectedModelTitle: "TestModel",
                                              engineLifecycle: EngineLifecycle(),
                                              timeoutSeconds: 0.3)

        #expect(version == nil)
        #expect(session.messageList.isAcceptingCommands == false)
        if case .failed = session.engineStatus.availability {} else {
            Issue.record("A handshake that never answered must fail, got \(session.engineStatus.availability)")
        }
    }

    /// A failure offers a way out. Retry is the one every platform has; the
    /// hosts add "Choose model" where a picker exists.
    @Test func aFailureOffersRetry() async {
        let session = GameSession()
        session.useEngine(PendingReplyEngine())

        _ = await session.handshake(selectedModelTitle: "TestModel",
                                    engineLifecycle: EngineLifecycle(),
                                    timeoutSeconds: 0.3)

        #expect(session.engineStatus.actions.contains(.retry))
    }

    /// The read must not outlive the handshake that started it. A parked reader
    /// would consume the NEXT engine's `version` reply — the relaunch would then
    /// block forever on a line that was already eaten.
    @Test func aTimedOutHandshakeLeavesNoParkedReader() async throws {
        let engine = PendingReplyEngine()
        let session = GameSession()
        session.useEngine(engine)

        _ = await session.handshake(selectedModelTitle: "TestModel",
                                    engineLifecycle: EngineLifecycle(),
                                    timeoutSeconds: 0.3)

        // Give any stray detached read a moment to show itself.
        try await Task.sleep(for: .milliseconds(120))
        #expect(engine.activeReaders == 0)
        #expect(engine.peakConcurrentReaders <= 1)

        // The next engine's reply is still there for the next handshake.
        engine.queue("= 1.16.3")
        let version = await session.handshake(selectedModelTitle: "TestModel",
                                              engineLifecycle: EngineLifecycle(),
                                              timeoutSeconds: 5)
        #expect(version == "= 1.16.3")
        #expect(session.messageList.isAcceptingCommands == true)
    }

    /// A thread/process exit during the handshake ends it at once instead of
    /// waiting out the (multi-minute) launch timeout on an engine that is
    /// already gone.
    @Test func anExitDuringTheHandshakeAbandonsItImmediately() async {
        let engine = PendingReplyEngine()
        let session = GameSession()
        session.useEngine(engine)

        let handshake = Task {
            await session.handshake(selectedModelTitle: "TestModel",
                                    engineLifecycle: EngineLifecycle(),
                                    timeoutSeconds: 600)
        }
        try? await Task.sleep(for: .milliseconds(80))
        session.endEngineSession(.failed(reason: "The engine stopped."))
        let version = await handshake.value

        #expect(version == nil)
        #expect(session.messageList.isAcceptingCommands == false)
        #expect(session.engineStatus.availability == .failed(reason: "The engine stopped."))
    }

    /// `endEngineSession` is a teardown, so it must also drop everything that
    /// claims the old engine agreed with the board.
    @Test func endEngineSessionRunsTheFreshEngineReset() {
        let session = GameSession()
        session.useEngine(PendingReplyEngine())
        session.messageList.isAcceptingCommands = true
        session.gobanState.showBoardCount = 2
        session.stones.isReady = true

        session.endEngineSession(.failed(reason: "boom"))

        #expect(session.messageList.isAcceptingCommands == false)
        #expect(session.gobanState.showBoardCount == 0)
        #expect(session.stones.isReady == false)
    }


    // MARK: - Cancellation

    /// visionOS and tvOS wrap their restart handshake in
    /// `withTimeout(seconds: 120)`. That wrapper is not a bound on its own — a
    /// task group AWAITS its cancelled child — so the handshake must give up on
    /// cancellation itself, promptly, and without leaving a reader parked on the
    /// process-global bridge for the next engine's `version` reply to fall into.
    @Test func aCancelledHandshakeGivesUpPromptlyAndParksNoReader() async throws {
        let engine = PendingReplyEngine()
        let session = GameSession()
        session.useEngine(engine)

        let started = Date()
        let handshake = Task {
            await session.handshake(selectedModelTitle: "TestModel",
                                    engineLifecycle: EngineLifecycle(),
                                    timeoutSeconds: 600)
        }
        try await Task.sleep(for: .milliseconds(80))
        handshake.cancel()
        let version = await handshake.value

        #expect(version == nil)
        // Nothing like the 600 s deadline it was given.
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(session.messageList.isAcceptingCommands == false)
        #expect(session.engineStatus.availability
                == .failed(reason: "The engine did not answer in time."))

        // Give any read that was in flight at cancellation time its half-second
        // slice to finish, then prove nobody is still sitting on the bridge.
        try await Task.sleep(for: .milliseconds(700))
        #expect(engine.activeReaders == 0)
    }

    /// A helper that dies DURING the launch says what happened, not that it was
    /// slow — this is the string a macOS user reads.
    @Test func aTransportThatEOFsDuringTheHandshakeReportsTheEngineStopped() async {
        let session = GameSession()
        session.useEngine(ExitedEngine())

        let version = await session.handshake(selectedModelTitle: "TestModel",
                                              engineLifecycle: EngineLifecycle(),
                                              timeoutSeconds: 5)

        #expect(version == nil)
        #expect(session.engineStatus.availability
                == .failed(reason: EngineExitDisposition.defaultReason))
    }

    /// An EOF and a cancellation in the same slice: the EOF is what the
    /// handshake actually LEARNED (the engine is gone), and it must survive the
    /// cancellation wording, which only knows that time ran out.
    @Test func anEOFThatRacesCancellationStillReportsTheEngineStopped() async {
        let engine = EOFCancellingEngine()
        let session = GameSession()
        session.useEngine(engine)

        let handshake = Task {
            await session.handshake(selectedModelTitle: "TestModel",
                                    engineLifecycle: EngineLifecycle(),
                                    timeoutSeconds: 5)
        }
        engine.handshake = handshake
        let version = await handshake.value

        #expect(version == nil)
        #expect(session.engineStatus.availability
                == .failed(reason: EngineExitDisposition.defaultReason),
                "the EOF reason was overwritten by the cancellation's timeout wording")
    }

    // MARK: - How an exit is classified

    /// The macOS relaunch path (`stopEngineAndSession`) sets `stopRequested`
    /// BEFORE it sends `quit`, so the EOF that follows is a teardown we asked
    /// for. Reporting it as a failure would put "Engine failed — Retry" on
    /// screen during every ordinary model switch.
    @Test func anExitWeAskedForIsNotAFailure() {
        let session = GameSession()
        session.useEngine(ExitedEngine())
        session.messageList.isAcceptingCommands = true
        session.stopRequested = true

        session.noteEngineExit(fatalError: nil)

        #expect(session.engineStatus.availability == .launching)
        #expect(session.engineStatus.actions.isEmpty)
        // Still a teardown: the gate shuts and nothing claims the engine agrees.
        #expect(session.messageList.isAcceptingCommands == false)
    }

    @Test func anExitNobodyAskedForIsAFailureWithAWayOut() {
        let session = GameSession()
        session.useEngine(ExitedEngine())
        session.messageList.isAcceptingCommands = true

        session.noteEngineExit(fatalError: nil)

        #expect(session.engineStatus.availability
                == .failed(reason: EngineExitDisposition.defaultReason))
        #expect(session.engineStatus.actions.contains(.retry))
        #expect(session.messageList.isAcceptingCommands == false)
    }

    @Test func aFatalErrorFromAnUnrequestedExitBecomesTheReason() {
        let session = GameSession()
        session.useEngine(ExitedEngine())

        session.noteEngineExit(fatalError: "std::bad_alloc")

        #expect(session.engineStatus.availability == .failed(reason: "std::bad_alloc"))
    }

    // MARK: - The message loop's EOF branch

    private func drainOneLine(_ session: GameSession) async throws {
        let container = try ModelContainer(
            for: SharedModelContainer.schema,
            configurations: SharedModelContainer.inMemoryConfig())
        let box = MoveBox()
        await session.messaging(gameRecords: [],
                                modelContext: container.mainContext,
                                navigationContext: NavigationContext(),
                                audioModel: AudioModel(),
                                aiMove: Binding(get: { box.value },
                                                set: { box.value = $0 }))
    }

    private final class MoveBox { var value: String? }

    /// The helper crashed on its own. Until now the board kept its "in sync"
    /// claim against a process that no longer existed.
    @Test func anUnrequestedEOFFailsTheSession() async throws {
        let session = GameSession()
        session.useEngine(ExitedEngine())
        session.messageList.isAcceptingCommands = true
        session.stones.isReady = true

        try await drainOneLine(session)

        #expect(session.stopRequested == true)
        #expect(session.messageList.isAcceptingCommands == false)
        #expect(session.stones.isReady == false)
        #expect(session.engineStatus.availability
                == .failed(reason: EngineExitDisposition.defaultReason))
    }

    /// The same EOF, reached through the macOS relaunch. `stopRequested` is read
    /// BEFORE the loop sets its own copy — otherwise every crash would look like
    /// a teardown we asked for.
    @Test func anEOFWeAskedForIsNotReportedAsAFailure() async throws {
        let session = GameSession()
        session.useEngine(ExitedEngine())
        session.messageList.isAcceptingCommands = true
        session.stopRequested = true

        try await drainOneLine(session)

        #expect(session.messageList.isAcceptingCommands == false)
        #expect(session.engineStatus.availability != .ready)
        if case .failed = session.engineStatus.availability {
            Issue.record("A teardown we asked for must not be reported as a failure")
        }
        #expect(session.engineStatus.actions.isEmpty)
    }

    // MARK: - Late replies from a dying engine

    /// A `showboard` block still draining out of an engine that is on its way
    /// down must not claim the board is in sync with it.
    @Test func aLateAckWhileNotAcceptingCannotClaimSync() async {
        let session = GameSession()
        session.useEngine(PendingReplyEngine())
        session.gobanState.showBoardCount = 1
        session.stones.isReady = false
        #expect(session.messageList.isAcceptingCommands == false)

        for line in ["= MoveNum: 2 HASH: 0", "Next player: White", "W stones captured: 0"] {
            await session.maybeCollectSync(message: line)
        }

        #expect(session.stones.isReady == false)
        #expect(session.player.nextColorForPlayCommand != .white)
    }

    /// A `? ` reply proves the GTP command loop is running and reading, which
    /// is exactly what the gate is about — so it opens the gate, and the engine
    /// gets its board fed as usual.
    ///
    /// Behaviour-preserving: before the gate existed, a `? ` version reply fell
    /// through the `hasPrefix("= ")` check and the host went straight on to
    /// its config commands and `loadGame`, which sent normally. The one thing the
    /// `= ` path does that this one must NOT is clear the OOM crash-loop
    /// sentinel: a `?` is not a successful model load.
    @Test func aQuestionMarkReplyOpensTheGateButLeavesTheSentinelArmed() async {
        let engine = PendingReplyEngine(queued: ["? unknown command"])
        let session = GameSession()
        session.useEngine(engine)
        let lifecycle = EngineLifecycle()

        let version = await session.handshake(selectedModelTitle: "TestModel",
                                              engineLifecycle: lifecycle,
                                              timeoutSeconds: 5)

        #expect(version == "? unknown command")
        #expect(session.engineStatus.availability == .ready)
        #expect(session.messageList.isAcceptingCommands == true)
        // The sentinel stays armed: nothing proved the net finished loading.
        #expect(lifecycle.lastLoadedModelTitle == nil)
    }

    /// The same block against a live engine still works — the gate is the only
    /// difference between the two.
    @Test func theSameAckAgainstALiveEngineStillSyncs() async {
        let session = GameSession()
        session.useEngine(PendingReplyEngine())
        session.messageList.isAcceptingCommands = true
        session.gobanState.showBoardCount = 1

        for line in ["= MoveNum: 2 HASH: 0", "Next player: White", "W stones captured: 0"] {
            await session.maybeCollectSync(message: line)
        }

        #expect(session.stones.isReady == true)
    }

    /// A `? ` reply during a relaunch used to force `stones.isReady = true`,
    /// which says "the engine holds this position" about an engine that holds
    /// nothing.
    @Test func anErrorReplyWhileNotAcceptingCannotClaimSync() {
        let session = GameSession()
        session.useEngine(PendingReplyEngine())
        session.stones.isReady = false

        session.maybeResetPendingStatesOnError(message: "? unknown command")

        #expect(session.stones.isReady == false)
    }

    @Test func anErrorReplyAgainstALiveEngineStillResetsPendingState() {
        let session = GameSession()
        session.useEngine(PendingReplyEngine())
        session.messageList.isAcceptingCommands = true
        session.gobanState.pendingMoveTurn = "b"
        session.gobanState.pendingMoveVertex = "Q16"
        session.stones.isReady = false

        session.maybeResetPendingStatesOnError(message: "? illegal move")

        #expect(session.gobanState.pendingMoveTurn == nil)
        #expect(session.stones.isReady == true)
    }
}
