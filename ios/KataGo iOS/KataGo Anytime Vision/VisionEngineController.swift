//
//  VisionEngineController.swift
//  KataGo Anytime Vision
//
//  Owner of the visionOS engine lifecycle: the initial launch and the
//  full restarts — Max Board Size changes and model activations both go
//  through the same quit → park read loop → respawn → handshake sequence
//  (with two Vision deviations: the device assignment stays the ANE-only
//  [100, 100], and the post-restart handshake is `session.handshake` —
//  never `initialize`, which would push default 19x19 config commands at
//  the fresh engine; the feed re-states board size, rules and every move
//  itself, so there is nothing left for the initial commands to say).
//  Every spawn arms the ModelRunnerView.pendingLoadModelTitle crash
//  sentinel; the root's lastLoadedModelTitle observer clears it and records
//  the last-good selection once the handshake lands (iOS parity).
//
//  The BOARD does not take part in any of this. It is record-owned and stays
//  on screen through every launch, restart and failure — what changes is the
//  engine status the ornament reports (Launching / Ready / Failed + Retry /
//  Held). So this controller also owns the two things that keep a live board
//  honest while the engine comes and goes: `applyHeldStatus` (a board bigger
//  than the running NN buffer) and `resyncAfterHandshake` (paying the feed
//  debt the shut gate accumulated).
//

import Foundation
import KataGoUICore

@Observable
@MainActor
final class VisionEngineController {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case stopping
        case failed(String)

        /// The shared vocabulary `EngineRestartRules.canRestart` decides on.
        var kind: EngineRestartRules.PhaseKind {
            switch self {
            case .idle: return .idle
            case .starting: return .starting
            case .running: return .running
            case .stopping: return .stopping
            case .failed: return .failed
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// The NN-buffer board length the CURRENTLY running engine was launched
    /// with (`maxBoardSizeForNNBuffer`). The board gates and New Game sizing
    /// read this — never the live `BackendSettings` — because a restart can
    /// take minutes to tear down a searched engine, during which the old
    /// buffer is still what the engine serves. 19 is only the pre-spawn
    /// placeholder (and the persisted default): `spawnEngineThread` records
    /// the real launched value before its thread starts.
    private(set) var maxBoardLength = 19

    /// The net the CURRENTLY running (or launching) engine serves. Observable
    /// so the Settings card can key its per-model Max Board Size on it and
    /// the Models card can mark the active row. Set only by startInitial and
    /// restartEngine(loading:), always before the spawn reads it.
    private(set) var activeModel: NeuralNetworkModel =
        NeuralNetworkModel.builtInModel ?? NeuralNetworkModel.allCases[0]

    /// Bumped exactly once — when the FIRST handshake lands — so the root's
    /// `.task(id:)` read loop starts then and not before (the handshake must be
    /// the bridge's only reader). It deliberately does NOT bump per restart: a
    /// restart parks the loop and unparks it, and re-keying the task would
    /// cancel the parked reader instead, leaving the continuation dangling.
    private(set) var readLoopGeneration = 0

    @ObservationIgnored private var session: GameSession?
    @ObservationIgnored private var engineLifecycle: EngineLifecycle?
    @ObservationIgnored private var modelSelection: ModelSelectionStore?
    @ObservationIgnored private var navigationContext: NavigationContext?
    /// The read loop parks HERE between engines, and only here. Deliberately
    /// unbounded: a restart that never comes back must leave the loop parked
    /// (an unparked reader would eat the next handshake's `version` reply).
    @ObservationIgnored private var readLoopPark: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var readLoopParked = false
    @ObservationIgnored private var engineThreadRunning = false

    func configure(session: GameSession,
                   engineLifecycle: EngineLifecycle,
                   modelSelection: ModelSelectionStore,
                   navigationContext: NavigationContext) {
        self.session = session
        self.engineLifecycle = engineLifecycle
        self.modelSelection = modelSelection
        self.navigationContext = navigationContext
        // The status line's one way out. visionOS has no model picker on the
        // status card (the Models ornament is that), so Retry is the only
        // action it ever offers.
        session.engineStatus.onAction = { [weak self] action in
            guard action == .retry else { return }
            Task { await self?.restartEngine() }
        }
    }

    /// Boot with the model the root resolved (VisionModelBootResolver — the
    /// persisted selection, crash-recovered to the built-in when needed).
    func startInitial(model: NeuralNetworkModel) {
        guard phase == .idle, let engineLifecycle else { return }
        activeModel = model
        engineLifecycle.reset()
        spawnEngineThread()
        phase = .starting
    }

    /// Called by VisionRootView once the boot version handshake succeeds: the
    /// engine is up, and the read loop may start reading.
    func noteInitialHandshakeComplete() {
        phase = .running
        if EngineRestartRules.shouldArmReadLoop(generation: readLoopGeneration) {
            readLoopGeneration = 1
        }
    }

    /// The boot handshake never answered. `session.handshake` has already ended
    /// the session `.failed` with its own reason and seeded `[.retry]`; the
    /// phase is ours to add, and it is what lets Retry through `canRestart`.
    ///
    /// The read loop is deliberately NOT armed: there is no engine to read, and
    /// a reader parked on the bridge would eat the retry handshake's reply.
    func noteInitialHandshakeFailed() {
        phase = .failed(Self.failedReason(session?.engineStatus.availability,
                                          fallback: EngineExitDisposition.defaultReason))
    }

    /// The read loop reports each `session.run` exit here, then parks until a
    /// restart has finished the handshake (during which the handshake must be
    /// the bridge's only reader).
    func noteRunLoopExited() async {
        readLoopParked = true
        await withCheckedContinuation { continuation in
            readLoopPark = continuation
        }
        readLoopParked = false
    }

    /// Quit the running engine and bring it back — with `newModel` when a
    /// model activation drives the restart, or with the same net and the
    /// freshly persisted Max Board Size when nil.
    ///
    /// The board stays mounted throughout. What the user sees is the status
    /// going *Launching* and — if this gives up anywhere — *Failed* with a
    /// Retry button, never a spinner in place of their game.
    ///
    /// - Returns: true when the new engine answered the version handshake.
    @discardableResult
    func restartEngine(loading newModel: NeuralNetworkModel? = nil) async -> Bool {
        guard Self.canRestart(from: phase), let session, let engineLifecycle else { return false }
        phase = .stopping

        // ORDER IS LOAD-BEARING, twice over.
        //
        // 1. `stopRequested` is what the thread-exit classifier reads. An engine
        //    that dies inside the teardown window below must read as the
        //    shutdown WE asked for, not as a crash — so it is raised BEFORE the
        //    `quit` goes out, never after it.
        // 2. The board must stop claiming the engine agrees with it the instant
        //    the user asks for a different one, not minutes later when the
        //    handshake finally runs. `endEngineSession` shuts the command gate,
        //    clears `stones.isReady` and says *Launching*, all synchronously.
        session.stopRequested = true

        // Stop any streaming search, then quit — but ONLY when there is an
        // engine to receive them. `sendCommand` writes into the process-global
        // INPUT buffer, which nothing drains while no engine runs: a `quit` sent
        // to a thread that already died would sit there and be the first thing
        // the REPLACEMENT engine reads. That is the Retry-after-a-crash path,
        // and it would look exactly like a second crash.
        //
        // Lifecycle commands: they go straight to the transport, because the
        // command gate is exactly what a teardown must not be blocked by.
        if engineThreadRunning {
            session.sendLifecycleCommand("stop")
            session.sendLifecycleCommand("quit")
            session.endEngineSession(.launching)
            // Give the loop a second to drain replies before it is nudged.
            try? await Task.sleep(for: .seconds(1))
        } else {
            session.endEngineSession(.launching)
        }

        // Wait for the read loop to stop reading — the handshake below has to be
        // the bridge's only reader.
        //
        // These two waits are POLLED, not parked on a continuation. A
        // `CheckedContinuation` cannot observe cancellation, and a task-group
        // timeout cannot rescue it either (a group awaits its remaining children
        // after `cancelAll()`), so a read loop that never parks or a thread that
        // never exits would hold this restart in `.stopping` forever — no phase,
        // no status, no Retry, and the board left watching a dead engine. A
        // deadline-checked poll gives up on its own and reports it.
        guard await waitForReadLoopPark(timeout: Self.readLoopParkTimeout) else {
            return fail("The engine did not shut down.")
        }

        // CRITICAL: also wait for the ENGINE THREAD itself to finish.
        // MainCmds::gtp keeps tearing down (deleting the engine, NN cleanup)
        // after its reply stream goes quiet; spawning the next runGtp while
        // the old one is still inside that epilogue overlaps two engines on
        // the process-global bridge state and dies with a C++ fatalError.
        // An idle engine tears down in milliseconds, but one that has just
        // run a search has been observed taking ~2 minutes — allow for it.
        guard await waitForEngineThreadExit(timeout: Self.engineThreadExitTimeout) else {
            return fail("The engine did not shut down.")
        }

        // Spawn the replacement and redo the handshake as the sole reader.
        // The model swaps only after the old engine has fully torn down, so
        // every reader of activeModel sees the running engine's net.
        if let newModel {
            activeModel = newModel
        }
        engineLifecycle.reset()
        spawnEngineThread()
        session.stopRequested = false
        phase = .starting
        session.engineStatus.availability = .launching
        session.engineStatus.actions = []

        // The handshake title is what markFirstResponse persists as the
        // last-good selection — it must be the net this engine loads.
        //
        // A RESTART waits exactly as long as a boot. There is no such thing as a
        // cheap restart on this platform:
        //
        //  * a Max Board Size change always recompiles — `CoreMLCacheKey`
        //    includes `boardXLen`/`boardYLen`, so the new buffer misses the
        //    cache by construction and pays a full conversion + compile;
        //  * an activation can be the first launch of a freshly downloaded net,
        //    i.e. a cold compile of a network nothing has ever converted;
        //  * a Retry is retrying a launch that just failed — often BECAUSE it
        //    was still compiling when something else gave up.
        //
        // The old 120 s came from a time when a Vision restart was assumed to
        // reload an already-compiled net. It would report "The engine did not
        // come up" for an engine that was simply still working — the exact trap
        // iOS fixed in C5. The wrapper carries the same deadline as the
        // handshake so neither can outlive the other.
        let handshakeTimeout = Self.restartHandshakeTimeout
        let handshake: Bool? = await withTimeout(seconds: handshakeTimeout) { [self] in
            await session.handshake(
                selectedModelTitle: activeModel.title,
                engineLifecycle: engineLifecycle,
                timeoutSeconds: handshakeTimeout) != nil
        }

        guard handshake == true else {
            // Leave the read loop parked (engine state unknown): a reader racing
            // the next handshake would eat its `version` reply.
            return fail("The engine did not come up.")
        }

        phase = .running

        // Arm or resume the read loop.
        //
        // A restart usually has one to resume — but not always: when the BOOT
        // handshake failed, the loop was deliberately never armed (a reader
        // would have eaten this handshake's `version` reply), and the Retry that
        // brought us here is the first thing that can start it. Without this,
        // the replacement engine would come up healthy, the gate would open, the
        // feed would go out, and nothing would read the replies — no in-sync
        // board, no plays, no analysis, and a status line claiming all is well.
        //
        // Arming must not RE-key an existing loop: the host's `.task(id:)` would
        // cancel the parked reader instead of resuming it.
        if EngineRestartRules.shouldArmReadLoop(generation: readLoopGeneration) {
            readLoopGeneration = 1
        } else {
            readLoopPark?.resume()
            readLoopPark = nil
        }

        // Held BEFORE anything is sent: a board larger than this engine's NN
        // buffer must never be described to it (`NNEvaluator::evaluate` aborts
        // the process on the first analysis past the buffer), and `applyHeldStatus`
        // shuts the gate so the resync below sends nothing at all.
        applyHeldStatus()
        resyncAfterHandshake()
        return true
    }

    // MARK: - Held

    /// Re-decides *Held* — "this board is larger than the running engine's Max
    /// Board Size" — from the projected board size, the buffer the running
    /// engine LAUNCHED with, and the current availability.
    ///
    /// Held is a status, not a screen: the record position keeps drawing and
    /// navigation keeps working. What changes is that the engine must not be
    /// fed. `GobanState.loadGame` already refuses an oversized record
    /// (`boardFitsEngine`), but `forwardMoves`/`backwardMoves` do not check
    /// board size at all — so stepping through one with L1/R1 would push `play`
    /// after `play` at an engine that was never told this board exists, and its
    /// `?` refusals would then force `stones.isReady = true`, i.e. claim a sync
    /// that does not exist. Shutting the command gate closes that, and reuses
    /// the launching-engine machinery rather than adding a second one.
    ///
    /// Called from exactly three places, all synchronous with the thing that
    /// changed: `switchGame` (a new board size, decided BEFORE that switch's
    /// post-execution commands can go out), the boot handshake, and the restart
    /// handshake (a new buffer). Those are the only inputs.
    func applyHeldStatus() {
        guard let session else { return }
        let engineStatus = session.engineStatus
        let current = engineStatus.availability
        // Zero when nothing is selected: the projector keeps the outgoing
        // game's size, and "no game" is not "too large". The size comes from
        // the PROJECTED position (`session.board`) — the same source the feed
        // sizes itself from — never from `Config`, which an imported record may
        // disagree with.
        let hasGame = navigationContext?.selectedGameRecord != nil
        let next = EngineHeldRule.decide(
            current: current,
            boardWidth: hasGame ? Int(session.board.width) : 0,
            boardHeight: hasGame ? Int(session.board.height) : 0,
            maxBoardLength: maxBoardLength)
        // Assign only on a real change: an `@Observable` write invalidates every
        // reader even when the value is identical, and this runs on every game
        // switch and every engine transition.
        guard next != current else { return }

        // The rule decides THAT it happens; the session owns WHAT happens
        // (`holdEngineSession` / `releaseEngineHold`), shared with iOS, macOS
        // and tvOS. Four hand-written copies of the effect is how three of them
        // ended up skipping `abortInFlightBoardCollection` — which strands a
        // half-read `showboard` block and kills analysis until a relaunch.
        switch next {
        case .held(let maxBoardLength):
            session.holdEngineSession(maxBoardLength: maxBoardLength)
        case .ready:
            session.releaseEngineHold(gameRecord: navigationContext?.selectedGameRecord)
        default:
            // Unreachable — `EngineHeldRule` only ever moves `.ready ↔ .held`,
            // and an unchanged verdict returned above.
            engineStatus.availability = next
        }
    }

    /// Feed the engine the position the board is showing NOW. Everything sent
    /// while it was down was dropped by the gate and recorded as a debt; this is
    /// where the debt is paid, from the LIVE record at the LIVE cursor (the user
    /// may have switched games twice while the model loaded — latest wins).
    ///
    /// The seam parks the turn as part of the feed, and only when a feed goes
    /// out: analysis re-arms off the turn EDGE, and a relaunch does not change
    /// whose move it is.
    func resyncAfterHandshake() {
        guard let session else { return }
        session.gobanState.resyncEngineAfterHandshake(
            gameRecord: navigationContext?.selectedGameRecord,
            player: session.player,
            messageList: session.messageList,
            stones: session.stones,
            projector: session.recordPosition)
    }

    // MARK: - Timeouts

    /// How long a restart waits for the read loop to stop reading. It only has
    /// to notice the blank line the teardown pushes through the bridge.
    static let readLoopParkTimeout: Double = 10

    /// How long a restart waits for `MainCmds::gtp` to return.
    static let engineThreadExitTimeout: Double = 240

    /// How long a RESTART waits for the replacement engine's `version` reply:
    /// the same budget a boot gets, because every restart path here can involve
    /// a cold Core ML compile (see `restartEngine`).
    static var restartHandshakeTimeout: Double { GameSession.defaultHandshakeTimeout }

    // MARK: - Pure decisions

    /// Whether a (re)start may begin right now — what the Models card's
    /// Activate button and the active model's Max Board Size picker gate on.
    /// A FAILED engine says yes: that is how the Models card doubles as the way
    /// out of a launch that never came up.
    var canRestartNow: Bool { Self.canRestart(from: phase) }

    /// Whether a restart may begin from `phase` — `EngineRestartRules.canRestart`
    /// over the phase's shared kind, so the rule (and its `.failed` = Retry
    /// clause) is pinned by tests the app target cannot host.
    static func canRestart(from phase: Phase) -> Bool {
        EngineRestartRules.canRestart(from: phase.kind)
    }

    /// The reason to report, preferring one the session has already recorded.
    /// No defaulted argument on purpose: a default that reads a `static let`
    /// from another module is exactly the thing that goes stale in a separately
    /// compiled target.
    private static func failedReason(
        _ availability: EngineAvailability?,
        fallback: String
    ) -> String {
        if case .failed(let reason) = availability { return reason }
        return fallback
    }

    // MARK: - Waits

    /// Waits for the read loop to stop reading the bridge. Returns at once when
    /// there is no loop yet (a failed BOOT never started one) or when it is
    /// already parked — the Retry-after-a-crash case: the engine died,
    /// `session.run` returned, and the loop parked itself.
    private func waitForReadLoopPark(timeout: Double) async -> Bool {
        guard readLoopGeneration > 0, !readLoopParked else { return true }
        // Unpark a `getline` blocked on an engine that will never speak again.
        // `cout` stays redirected to the bridge for the life of the process, so
        // this reaches the reader even with no engine left to produce output.
        KataGoHelper.sendMessage("\n")
        return await EngineRestartRules.untilSettled(timeout: timeout,
                                                     pollInterval: .milliseconds(50)) { [weak self] in
            self?.readLoopParked ?? true
        }
    }

    /// Waits for `MainCmds::gtp` to return. True when it did, false on timeout.
    private func waitForEngineThreadExit(timeout: Double) async -> Bool {
        await EngineRestartRules.untilSettled(timeout: timeout,
                                              pollInterval: .milliseconds(100)) { [weak self] in
            !(self?.engineThreadRunning ?? false)
        }
    }

    // MARK: - Spawn / teardown

    private func spawnEngineThread() {
        engineThreadRunning = true
        // Read the active model's Max Board Size on the MainActor and record
        // what THIS engine is launched with, BEFORE the off-main thread
        // starts (so the gates read a consistent value). The per-fileName
        // BackendSettings keys make the buffer per-model automatically;
        // `effectiveMaxBoardLength` clamps the choice to the net's nnLen.
        let model = activeModel
        maxBoardLength = BackendSettings(model: model).effectiveMaxBoardLength
        // What *Held* reports, and what makes the feed refuse a record this
        // engine cannot hold. Set here, at the spawn, because this is the first
        // moment the number is true.
        session?.engineStatus.launchedMaxBoardLength = maxBoardLength
        session?.gobanState.engineMaxBoardLength = maxBoardLength
        let launchedMaxBoardLength = maxBoardLength
        // Built-in → nil (runGtp resolves the bundled default_model);
        // downloaded → the Documents file (iOS ModelRunnerView parity).
        let modelPath = model.builtIn ? nil : model.downloadedURL?.path
        // Arm the crash sentinel BEFORE the engine thread starts, for every
        // spawn (boot, model switch, Max-Board-Size restart alike). If the
        // process dies before the handshake's first GTP reply, the surviving
        // value makes the next boot fall back to the built-in net instead of
        // crash-looping (VisionModelBootResolver).
        modelSelection?.pendingLoadModelTitle = model.title
        let thread = Thread { [weak self] in
            // CoreML/ANE only — deliberately NOT EngineDeviceAssignments
            // .platformMux, which resolves to [0, 100] (one MLX/GPU server)
            // on a real visionOS device; the GPU belongs to the 90 Hz
            // compositor, so both NN server threads go to the Neural Engine.
            KataGoHelper.runGtp(modelPath: modelPath,
                                deviceAssignments: [100, 100],
                                numSearchThreads: KataGoHelper.mlxNumSearchThreads,
                                maxBoardSizeForNNBuffer: launchedMaxBoardLength)
            // MainCmds::gtp returned — the engine is fully torn down. Take the
            // fatal error here, on the thread that owns it, and hand it to the
            // MainActor with the exit.
            let exitError = KataGoHelper.takeLastFatalError()
            Task { @MainActor in self?.noteEngineThreadExited(fatalError: exitError) }
        }
        // Needs a >512 KB stack (BoardHistory copies) — match the iOS app's 1 MB.
        thread.stackSize = 4096 * 256
        thread.start()
    }

    /// The engine thread returned. Until the board could outlive the engine this
    /// was bookkeeping; now it is the only thing that can tell the user their
    /// engine died, so it classifies the exit and offers Retry.
    private func noteEngineThreadExited(fatalError: String?) {
        engineThreadRunning = false

        guard let session else { return }
        let disposition = EngineExitDisposition.decide(
            fatalError: fatalError, stopWasRequested: session.stopRequested)
        // The session classifies the exit itself (the same rule, one owner) —
        // called BEFORE anything here touches a stop flag, so an engine that
        // died on its own can never be read as a teardown we asked for.
        session.noteEngineExit(fatalError: fatalError)
        switch disposition {
        case .expected:
            // A restart is driving; it owns the phase and has already said
            // Launching itself.
            break
        case .failed(let reason):
            phase = .failed(reason)
        }
    }

    @discardableResult
    private func fail(_ reason: String) -> Bool {
        // Keep whatever the session already knows. `GameSession.handshake` ends
        // a launch it gave up on with a SPECIFIC reason ("The engine did not
        // answer.", "The engine stopped."), and the engine-thread exit
        // classifier records a real fatal error; our own "The engine did not
        // come up." is the generic fallback and must not paint over any of
        // them. A stale `.failed` from an EARLIER attempt cannot be here:
        // `restartEngine` calls `endEngineSession(.launching)` before anything
        // can fail.
        let reason = Self.failedReason(session?.engineStatus.availability,
                                       fallback: reason)
        phase = .failed(reason)
        // Hand the stop flag back. `restartEngine` raises it before the `quit`
        // so a teardown death is not misreported as a crash; leaving it raised
        // after a restart that gave up would make the NEXT death — a genuine
        // one — classify as `.expected` and pass in silence.
        session?.stopRequested = false
        // Seeds `[.retry]`, which is what the status ornament renders.
        session?.endEngineSession(.failed(reason: reason))
        return false
    }

    /// Runs `operation` with a wall-clock cap; nil on timeout.
    ///
    /// Only ONE caller is left — the handshake — and that is the only kind of
    /// operation this is safe for. `withTaskGroup` awaits its remaining children
    /// after `cancelAll()`, so this can only return once `operation` itself
    /// returns; it is a bound only when the operation honours cancellation.
    /// `GameSession.handshake` does (its read loop checks `Task.isCancelled` and
    /// carries the same deadline). The teardown waits do not, which is why they
    /// poll (`EngineRestartRules.untilSettled`) instead of coming through here.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @MainActor () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
