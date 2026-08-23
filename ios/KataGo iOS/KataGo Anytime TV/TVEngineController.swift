//
//  TVEngineController.swift
//  KataGo Anytime TV
//
//  Owner of the tvOS engine lifecycle: the initial launch, the in-process
//  "Restart Engine" recovery, the Max Board Size respawn, and the
//  classification of an engine that ended on its own. Apple TV runs a single
//  fixed backend — Core ML (`EngineDeviceAssignments.platformMux` == [100] on
//  tvOS), pinned to CPU+GPU because the Neural Engine never takes this net — so
//  there is no backend to pick.
//
//  The GTP engine is a one-shot blocking thread; "restart" is:
//
//      stop + quit -> wait for the READ LOOP to park -> wait for the ENGINE
//      THREAD to exit (240 s cap) -> spawn -> handshake as the bridge's SOLE
//      reader -> arm/resume the read loop -> decide *Held* -> re-feed the
//      position the board is showing.
//
//  Nothing in that sequence takes the board off screen any more. The library,
//  the review board and the Settings tab stay mounted throughout; what the user
//  sees is one short line in the analysis slot (`EngineStatusView(.tvLine)`)
//  going *Loading engine…* and — if this gives up anywhere — *Engine failed*,
//  with Restart Engine in Settings as the way back.
//
//  The three decisions every in-process controller makes (how long to poll for
//  a teardown, whether a restart may begin, whether a successful start has to
//  ARM the read loop) live in the shared `EngineRestartRules` — the iOS and
//  visionOS controllers use the same ones, and the iOS test bundle pins them.
//

import Foundation
import KataGoUICore

@Observable
@MainActor
final class TVEngineController {
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
    /// with (`maxBoardSizeForNNBuffer`). *Held*, New Game sizing and the
    /// self-play board size read this — never the live `BackendSettings` —
    /// because a `restartEngine()` can take minutes to tear down a searched
    /// engine, during which the old (larger or smaller) buffer is still what
    /// the engine actually serves. Defaults to 37 (the true b18 capability) so
    /// nothing over-blocks before the first spawn sets it from the persisted
    /// setting.
    private(set) var maxBoardLength: Int = 37

    /// Bumped exactly once — when the FIRST handshake lands — so the root's
    /// `.task(id:)` read loop starts then and not before (the handshake must be
    /// the bridge's sole reader while it runs). It deliberately does NOT bump
    /// per restart: a restart parks the loop and unparks it, and re-keying the
    /// task would cancel the parked reader instead, leaving the continuation
    /// dangling.
    private(set) var readLoopGeneration = 0

    @ObservationIgnored private var session: GameSession?
    @ObservationIgnored private var engineLifecycle: EngineLifecycle?
    @ObservationIgnored private var navigationContext: NavigationContext?
    /// The read loop parks HERE between engines, and only here. Deliberately
    /// unbounded: a restart that never comes back must leave the loop parked
    /// (an unparked reader would eat the next handshake's `version` reply).
    @ObservationIgnored private var readLoopPark: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var engineThreadRunning = false
    @ObservationIgnored private var readLoopParked = false

    /// The record whose board is on screen, and its size — set by the review /
    /// play screens as they load, cleared as they leave.
    ///
    /// tvOS cannot use `navigationContext.selectedGameRecord` for this: those
    /// screens deliberately park the selection at nil while a reload or a
    /// variation teardown is in flight (a stray `printsgf` reply must not be
    /// written into a synced record), so the selection is nil for most of a
    /// review. Without a record of its own, a post-handshake resync would send
    /// nothing and the game on screen would never be analysed again.
    @ObservationIgnored private weak var mountedGame: GameRecord?
    @ObservationIgnored private var mountedBoardWidth = 0
    @ObservationIgnored private var mountedBoardHeight = 0

    /// The single fixed tvOS model (the bundled b18). `?? .allCases[0]` is
    /// defensive only — `builtInModel` is always present on tvOS.
    private static var engineModel: NeuralNetworkModel {
        NeuralNetworkModel.builtInModel ?? NeuralNetworkModel.allCases[0]
    }

    // MARK: - Wiring

    func configure(session: GameSession,
                   engineLifecycle: EngineLifecycle,
                   navigationContext: NavigationContext) {
        self.session = session
        self.engineLifecycle = engineLifecycle
        self.navigationContext = navigationContext
        // The way out a failed engine offers. tvOS has no model picker, so
        // Retry is the only action it ever carries — and the affordance that
        // performs it is the Settings tab's "Restart Engine" button, because
        // the one-line status this platform can afford has no room for a
        // button (and a focusable one over the hero board would break the
        // screens' focus contract). Wiring it here keeps the model's contract
        // whole: `endEngineSession` seeds `[.retry]`, and something can act.
        session.engineStatus.onAction = { [weak self] action in
            guard action == .retry else { return }
            Task { await self?.restartEngine() }
        }
    }

    // MARK: - Boot

    /// Cold start. Spawns the engine thread and runs the version handshake in
    /// the background — the caller returns immediately, and the library is
    /// already on screen.
    func startInitial() {
        guard phase == .idle, let session, let engineLifecycle else { return }
        engineLifecycle.reset()
        spawnEngineThread()
        phase = .starting
        session.engineStatus.availability = .launching
        session.engineStatus.actions = []
        Task { await completeInitialHandshake() }
    }

    /// The boot handshake, and everything that depends on it landing.
    ///
    /// It calls `handshake` and then the FEED, never a fixed bundle of config
    /// commands first: such a bundle stated a DEFAULT 19x19 board before
    /// anything had asked whether this engine can hold one (a Max Board Size of
    /// 9 launches a 9 buffer), and the feed states board size, rules, komi and
    /// the human profiles anyway — pinned by
    /// `EngineFeedInitialCommandsTests`.
    private func completeInitialHandshake() async {
        guard let session, let engineLifecycle else { return }
        // The BOOT handshake keeps the full `defaultHandshakeTimeout`: a cold
        // Core ML compile of two networks on an A12 is legitimate work, and
        // cutting it short would report a failure that is really just the box
        // doing its job.
        let reply = await session.handshake(selectedModelTitle: Self.engineModel.title,
                                            engineLifecycle: engineLifecycle)
        guard reply != nil else {
            // `handshake` already ended the session `.failed` with its own
            // reason and seeded `[.retry]`; the phase is ours to add, and it is
            // what lets Retry (and Settings ▸ Restart Engine) through
            // `canRestart`. The read loop is deliberately NOT armed: there is
            // no engine to read, and a reader parked on the bridge would eat
            // the retry handshake's reply.
            phase = .failed(Self.failedReason(session.engineStatus.availability,
                                              fallback: EngineExitDisposition.defaultReason))
            return
        }
        phase = .running
        if EngineRestartRules.shouldArmReadLoop(generation: readLoopGeneration) {
            readLoopGeneration = 1
        }
        // Held BEFORE the feed: a board larger than this engine's NN buffer
        // must never be described to it.
        applyHeldStatus()
        resyncAfterHandshake()
    }

    // MARK: - Read loop

    /// The read loop reports each `session.run` exit here, then parks until a
    /// restart has finished the handshake (during which `handshake` must be
    /// the bridge's only reader).
    func noteRunLoopExited() async {
        readLoopParked = true
        await withCheckedContinuation { continuation in
            readLoopPark = continuation
        }
        readLoopParked = false
    }

    // MARK: - Restart

    /// Quit the running engine and bring it straight back on the same Core ML
    /// backend — the Settings "Restart Engine" recovery, the Max Board Size
    /// respawn, the benchmark's downtime window, and the status line's Retry.
    /// Returns true when the new engine answered the version handshake.
    ///
    /// `duringDowntime`, if supplied, runs AFTER the old engine has fully torn
    /// down and BEFORE the replacement is spawned — the window in which the
    /// process holds no resident net. The Core ML benchmark uses it to run with
    /// maximum memory headroom and uncontended timings.
    @discardableResult
    func restartEngine(duringDowntime: (@MainActor () async -> Void)? = nil) async -> Bool {
        guard Self.canRestart(from: phase), let session, let engineLifecycle else { return false }
        phase = .stopping

        // ORDER IS LOAD-BEARING, twice over.
        //
        // 1. `stopRequested` is what the thread-exit classifier reads. An
        //    engine that dies inside the teardown window below must read as the
        //    shutdown WE asked for, not as a crash — so it is raised BEFORE the
        //    `quit` goes out, never after it.
        // 2. The board must stop claiming the engine agrees with it the instant
        //    the restart begins, not minutes later when the handshake finally
        //    runs. `endEngineSession` shuts the command gate, clears
        //    `stones.isReady` and says *Launching*, all synchronously.
        session.stopRequested = true

        // Stop any streaming search, then quit — but ONLY when there is an
        // engine to receive them. `sendCommand` writes into the process-global
        // INPUT buffer, which nothing drains while no engine runs: a `quit`
        // sent to a thread that already died would sit there and be the first
        // thing the REPLACEMENT engine reads, killing it on arrival. That is
        // the Retry-after-a-crash path, and it would look like a second crash.
        //
        // Lifecycle commands go straight to the transport, because the command
        // gate is exactly what a teardown must not be blocked by.
        if engineThreadRunning {
            session.sendLifecycleCommand("stop")
            session.sendLifecycleCommand("quit")
            session.endEngineSession(.launching)
            // Give the loop a second to drain replies before it is nudged.
            try? await Task.sleep(for: .seconds(1))
        } else {
            session.endEngineSession(.launching)
        }

        // Wait for the read loop to stop reading — the handshake below has to
        // be the bridge's only reader.
        //
        // These two waits are POLLED, not parked on a continuation. A
        // `CheckedContinuation` cannot observe cancellation, and a task-group
        // timeout cannot rescue it either (a group awaits its remaining
        // children after `cancelAll()`), so a read loop that never parks or a
        // thread that never exits would hold this restart in `.stopping`
        // forever — no phase, no status, and no way back. A deadline-checked
        // poll gives up on its own and reports it.
        guard await waitForReadLoopPark(timeout: Self.readLoopParkTimeout) else {
            return fail("The engine did not shut down.")
        }

        // CRITICAL: also wait for the ENGINE THREAD itself to finish.
        // MainCmds::gtp keeps tearing down (deleting the engine, NN cleanup)
        // after its reply stream goes quiet; spawning the next runGtp while
        // the old one is still inside that epilogue overlaps two engines on
        // the process-global bridge state and dies with a C++ fatalError
        // (observed as a voluntary exit(1) on the simulator). An idle engine
        // tears down in milliseconds, but one that has just run a search has
        // been observed taking ~2 minutes — allow for it.
        guard await waitForEngineThreadExit(timeout: Self.engineThreadExitTimeout) else {
            return fail("The engine did not shut down.")
        }

        // Engine is fully down and holds no resident net: run the downtime work
        // (the Core ML benchmark) with maximum memory headroom before the
        // replacement is spawned. The read loop stays parked throughout.
        await duringDowntime?()

        // Spawn the replacement and redo the handshake as the sole reader.
        engineLifecycle.reset()
        spawnEngineThread()
        session.stopRequested = false
        phase = .starting
        session.engineStatus.availability = .launching
        session.engineStatus.actions = []

        // A RESTART waits exactly as long as a boot. There is no such thing as
        // a cheap restart here:
        //
        //  * a Max Board Size change ALWAYS recompiles — `CoreMLCacheKey`
        //    carries `boardXLen`/`boardYLen`, so the new buffer misses the
        //    cache by construction and pays a full conversion + compile;
        //  * a Retry is retrying a launch that just failed — often BECAUSE it
        //    was still compiling when something gave up on it;
        //  * the benchmark's restart reloads both nets from cold.
        //
        // The old 120 s came from an assumption that a restart reloads an
        // already-compiled net. It would report "The engine did not come up"
        // for an engine that was simply still working — the trap iOS fixed in
        // C5 and visionOS in C7. The wrapper carries the same deadline as the
        // handshake so neither can outlive the other.
        let handshakeTimeout = Self.restartHandshakeTimeout
        let handshake: Bool? = await withTimeout(seconds: handshakeTimeout) {
            await session.handshake(selectedModelTitle: Self.engineModel.title,
                                    engineLifecycle: engineLifecycle,
                                    timeoutSeconds: handshakeTimeout) != nil
        }

        guard handshake == true else {
            // Leave the read loop parked (engine state unknown): a reader
            // racing the next handshake would eat its `version` reply.
            return fail("The engine did not come up.")
        }

        phase = .running

        // Arm or resume the read loop.
        //
        // A restart usually has one to resume — but not always: when the BOOT
        // handshake failed, the loop was deliberately never armed, and the
        // Retry that brought us here is the first thing that can start it.
        // Without this the replacement engine would come up healthy, the gate
        // would open, the feed would go out, and nothing would read the
        // replies — no in-sync board, no analysis, and a status line claiming
        // all is well. Arming must not RE-key an existing loop: the root's
        // `.task(id:)` would cancel the parked reader instead of resuming it.
        if EngineRestartRules.shouldArmReadLoop(generation: readLoopGeneration) {
            readLoopGeneration = 1
        } else {
            readLoopPark?.resume()
            readLoopPark = nil
        }

        // Held BEFORE anything is sent: a board larger than this engine's NN
        // buffer must never be described to it (`NNEvaluator::evaluate` aborts
        // the process on the first analysis past the buffer), and
        // `applyHeldStatus` shuts the gate so the resync below sends nothing.
        applyHeldStatus()
        resyncAfterHandshake()
        return true
    }

    // MARK: - Held

    /// A review / play screen mounted a board. Records what it is (for the
    /// post-handshake re-feed) and re-decides *Held*.
    ///
    /// Called BEFORE the screen's `loadGame`, so the gate is already shut when
    /// an oversized record starts loading — `loadGame` refuses the feed on its
    /// own (`boardFitsEngine`), but the entry protocol also asks for analysis,
    /// and that request must find a shut gate.
    ///
    /// The size comes from the RECORD's SGF, not from `Config`: an imported
    /// record whose config was never updated would otherwise be called fine
    /// here and then refused by the feed.
    func noteBoardMounted(_ game: GameRecord, width: Int, height: Int) {
        mountedGame = game
        mountedBoardWidth = width
        mountedBoardHeight = height
        // No feed on the way OUT of a hold here: the caller states the whole
        // position itself (`loadGame`) in the next breath, and feeding from
        // both would put the same bundle on the wire twice.
        applyHeldStatus(feedsOnRelease: false)
    }

    /// The screen left. Releases *Held* (no board is showing, and "no game" is
    /// not "too large"), which also reopens the command gate for whatever the
    /// user opens next — the self-play screen included, which never decides
    /// Held of its own accord because its boards are clamped to
    /// `maxBoardLength` at creation.
    ///
    /// Identity-guarded like the navigation selection: on a PUSH (the live
    /// handoff) SwiftUI can run the destination's `onAppear` BEFORE this, and
    /// that screen has already registered its own board.
    func noteBoardDismissed(_ game: GameRecord) {
        guard mountedGame === game else { return }
        mountedGame = nil
        mountedBoardWidth = 0
        mountedBoardHeight = 0
        applyHeldStatus()
    }

    /// Re-decides *Held* — "this board is larger than the running engine's Max
    /// Board Size" — from the mounted board, the buffer the running engine
    /// LAUNCHED with, and the current availability.
    ///
    /// Held is a status, not a screen: the record position keeps DRAWING, at the
    /// index the record was saved at. It does not keep moving — tvOS gates its
    /// stepping on `stones.isReady` (`TVReviewScreen.stepBy`), which a held
    /// engine never grants — and that is deliberate here, because
    /// `forwardMoves`/`backwardMoves` do not check board size at all: a step
    /// would push `play` after `play` at an engine that was never told this
    /// board exists, and its `?` refusals would then claim a sync that does not
    /// exist. Shutting the command gate closes that second door (the analysis
    /// request the entry protocol sends), and reuses the launching-engine
    /// machinery rather than adding a second one.
    ///
    /// - Parameter feedsOnRelease: whether leaving *Held* should re-state the
    ///   position. False only where the caller is about to state it anyway.
    private func applyHeldStatus(feedsOnRelease: Bool = true) {
        guard let session else { return }
        let engineStatus = session.engineStatus
        let current = engineStatus.availability
        // The rule itself lives in the package (`EngineHeldRule`), shared with
        // iOS/macOS/visionOS: one board-size answer, one place to change it.
        let next = EngineHeldRule.decide(current: current,
                                         boardWidth: mountedBoardWidth,
                                         boardHeight: mountedBoardHeight,
                                         maxBoardLength: maxBoardLength)
        // Assign only on a real change: an `@Observable` write invalidates
        // every reader even when the value is identical, and this runs on every
        // screen entry and every engine transition.
        guard next != current else { return }

        // The rule decides THAT it happens; the session owns WHAT happens
        // (`holdEngineSession` / `releaseEngineHold`), shared with iOS, macOS
        // and visionOS. Four hand-written copies of the effect is how three of
        // them ended up skipping `abortInFlightBoardCollection` — which strands
        // a half-read `showboard` block and kills analysis until a relaunch.
        switch next {
        case .held(let maxBoardLength):
            session.holdEngineSession(maxBoardLength: maxBoardLength)
        case .ready:
            // The mounted board first, the navigation selection second — the
            // same order `resyncAfterHandshake` uses, and for the same reason
            // (the review and play screens park the selection at nil).
            session.releaseEngineHold(
                gameRecord: mountedGame ?? navigationContext?.selectedGameRecord,
                feeds: feedsOnRelease)
        default:
            // Unreachable — `EngineHeldRule` only ever moves `.ready ↔ .held`,
            // and an unchanged verdict returned above.
            engineStatus.availability = next
        }
    }

    /// Feed the engine the position the board is showing NOW. Everything sent
    /// while it was down was dropped by the gate and recorded as a debt; this
    /// is where the debt is paid, from the LIVE record at the LIVE cursor.
    ///
    /// The seam parks the turn as part of the feed, and only when a feed goes
    /// out: analysis re-arms off the turn EDGE, and a relaunch does not change
    /// whose move it is.
    private func resyncAfterHandshake() {
        guard let session else { return }
        // The mounted board first, the navigation selection second: the review
        // and play screens park the selection at nil (see `mountedGame`), while
        // the self-play screen — which registers no board of its own — keeps it
        // pointed at the record it is playing.
        session.gobanState.resyncEngineAfterHandshake(
            gameRecord: mountedGame ?? navigationContext?.selectedGameRecord,
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
    /// the same budget a boot gets, because every restart path here can be a
    /// cold Core ML compile (see `restartEngine`).
    static var restartHandshakeTimeout: Double { GameSession.defaultHandshakeTimeout }

    // MARK: - Pure decisions

    /// Whether a (re)start may begin right now — what Settings' Restart Engine
    /// button and its Max Board Size picker gate on. A FAILED engine says yes:
    /// that is what makes those two controls the way out of a launch that never
    /// came up. A *Held* engine says yes too — its phase is `.running`, and
    /// raising Max Board Size is exactly the remedy the held line names.
    var canRestartNow: Bool { Self.canRestart(from: phase) }

    /// Whether a restart may begin from `phase` — `EngineRestartRules.canRestart`
    /// over the phase's shared kind, so the rule (and its `.failed` = Retry
    /// clause) is pinned by tests this app target cannot host.
    static func canRestart(from phase: Phase) -> Bool {
        EngineRestartRules.canRestart(from: phase.kind)
    }

    /// The reason to report, preferring one the session has already recorded.
    /// No defaulted argument on purpose: a default that reads a `static let`
    /// from another module is exactly the thing that goes stale in a separately
    /// compiled target.
    private static func failedReason(_ availability: EngineAvailability?,
                                     fallback: String) -> String {
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
        // Read the user's Max Board Size on the MainActor and record what THIS
        // engine is launched with, BEFORE the off-main thread starts (so the
        // gates read a consistent value). `effectiveMaxBoardLength` clamps the
        // choice to the net's nnLen (37).
        maxBoardLength = BackendSettings(model: Self.engineModel).effectiveMaxBoardLength
        // What *Held* reports, and what makes the feed refuse a record this
        // engine cannot hold. Set here, at the spawn, because this is the first
        // moment the number is true.
        session?.engineStatus.launchedMaxBoardLength = maxBoardLength
        session?.gobanState.engineMaxBoardLength = maxBoardLength
        let launchedMaxBoardLength = maxBoardLength   // captured for the off-main thread
        // Built-in b18 net and human-SL net, Core ML pinned to CPU+GPU. Needs a
        // >512 KB stack (BoardHistory copies) — match the iOS app's 1 MB.
        let thread = Thread { [weak self] in
            KataGoHelper.runGtp(deviceAssignments: EngineDeviceAssignments.platformMux,
                                numSearchThreads: KataGoHelper.mlxNumSearchThreads,
                                maxBoardSizeForNNBuffer: launchedMaxBoardLength)
            // MainCmds::gtp returned — the engine is fully torn down. Take the
            // fatal error here, on the thread that owns it, and hand it to the
            // MainActor with the exit.
            let exitError = KataGoHelper.takeLastFatalError()
            Task { @MainActor in self?.noteEngineThreadExited(fatalError: exitError) }
        }
        thread.stackSize = 4096 * 256
        thread.start()
    }

    /// The engine thread returned. Until the board could outlive the engine
    /// this was bookkeeping; now it is the only thing that can tell the viewer
    /// their engine died, so it classifies the exit and reports it.
    private func noteEngineThreadExited(fatalError: String?) {
        engineThreadRunning = false

        guard let session else { return }
        let disposition = EngineExitDisposition.decide(fatalError: fatalError,
                                                       stopWasRequested: session.stopRequested)
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
        // classifier records a real fatal error; our own generic line must not
        // paint over any of them. A stale `.failed` from an EARLIER attempt
        // cannot be here: `restartEngine` calls `endEngineSession(.launching)`
        // before anything can fail.
        let reason = Self.failedReason(session?.engineStatus.availability,
                                       fallback: reason)
        phase = .failed(reason)
        // Hand the stop flag back. `restartEngine` raises it before the `quit`
        // so a teardown death is not misreported as a crash; leaving it raised
        // after a restart that gave up would make the NEXT death — a genuine
        // one — classify as `.expected` and pass in silence.
        session?.stopRequested = false
        // Seeds `[.retry]`, which is what the status line's action carries.
        session?.endEngineSession(.failed(reason: reason))
        return false
    }

    /// Runs `operation` with a wall-clock cap; nil on timeout.
    ///
    /// Only ONE caller is left — the handshake — and that is the only kind of
    /// operation this is safe for. `withTaskGroup` awaits its remaining
    /// children after `cancelAll()`, so this can only return once `operation`
    /// itself returns; it is a bound only when the operation honours
    /// cancellation. `GameSession.handshake` does (its read loop checks
    /// `Task.isCancelled` and carries the same deadline). The teardown waits do
    /// not, which is why they poll (`EngineRestartRules.untilSettled`).
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
