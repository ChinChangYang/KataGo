//
//  AppEngineController.swift
//  KataGo Anytime
//
//  Owner of the iOS engine lifecycle: the initial launch, every relaunch
//  (model activation, backend/Max-Board-Size change, Retry after a failure)
//  and the classification of an engine that ended on its own.
//
//  It exists because the board no longer waits for the engine. `ContentView`
//  used to BE the launch: it mounted a loading screen, ran the handshake in a
//  `.task`, and only then built the board — so "restart the engine" meant
//  "unmount the whole tree and start over", which is exactly why the old flow
//  set `selectedModel = nil` when `runGtp` returned. With the board mounted
//  from the first frame, none of that is available: the engine has to come and
//  go underneath a live view tree, and something has to own the order in which
//  that happens.
//
//  This is a PORT of `VisionEngineController`, not an extraction of it (global
//  constraints, decision 12 — unifying the three in-process controllers is a
//  follow-up). The teardown discipline is the part worth copying verbatim:
//
//      quit -> wait for the READ LOOP to park -> wait for the ENGINE THREAD to
//      exit (240 s cap) -> spawn -> handshake as the bridge's sole reader ->
//      beginEngineSession -> re-feed the position the board is showing.
//
//  Two iOS-only additions:
//    • `restart` is allowed from `.failed` — that is what the remedy surface's
//      Retry button is. visionOS has no such button.
//    • a thread that returns without being asked to becomes `.failed` with
//      BOTH ways out (`.retry` and `.chooseModel`); iOS is the only platform
//      with a model picker to offer.
//

import Foundation
import UIKit
import OSLog
import KataGoUICore

private let engineLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "KataGo Anytime",
    category: "engine.lifecycle"
)

@Observable
@MainActor
final class AppEngineController {
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

    /// Set by "Relaunch Without Custom Parameters"; consumed by the next spawn.
    private var setAsideCustomParametersOnNextLaunch = false

    /// The NN-buffer board length the CURRENTLY running engine was launched
    /// with (`maxBoardSizeForNNBuffer`). Board gates and New Game sizing read
    /// this — never the live `BackendSettings` — because a restart can take
    /// minutes to tear down a searched engine, during which the OLD buffer is
    /// still what the engine serves. 19 is only the pre-spawn placeholder (and
    /// the persisted default); `spawnEngineThread` records the real launched
    /// value before its thread starts.
    private(set) var maxBoardLength = 19

    /// The net the running (or launching) engine serves. Nil until the first
    /// spawn, which is the *Absent* state.
    private(set) var activeModel: NeuralNetworkModel?

    /// Bumped exactly once — when the FIRST handshake lands — so the host's
    /// `.task(id:)` read loop starts then and not before. It deliberately does
    /// NOT bump per restart: a restart parks the loop and unparks it, and
    /// re-keying the task would cancel the parked reader instead, leaving the
    /// continuation dangling.
    private(set) var readLoopGeneration = 0

    @ObservationIgnored private var session: GameSession?
    @ObservationIgnored private var engineLifecycle: EngineLifecycle?
    @ObservationIgnored private var navigationContext: NavigationContext?
    /// The read loop parks HERE between engines, and only here. This is the one
    /// remaining continuation, and it is deliberately unbounded: a restart that
    /// never comes back must leave the loop parked (an unparked reader would eat
    /// the next handshake's `version` reply), so there is nothing to time out.
    @ObservationIgnored private var readLoopPark: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var engineThreadRunning = false
    @ObservationIgnored private var readLoopParked = false

    /// A model the user chose while a launch or a teardown was already in
    /// flight. `.starting` and `.stopping` cannot be interrupted safely — a
    /// `quit` sent under an in-flight handshake races the bridge's sole-reader
    /// rule — so the choice is remembered and applied when the current
    /// transition lands. Latest selection wins; a silent no-op would simply
    /// lose the tap.
    @ObservationIgnored private var queuedModel: NeuralNetworkModel?

    /// The same two `ModelRunnerView.*` UserDefaults keys the iOS host has
    /// always used: the last-good selection and the crash sentinel. Reached
    /// through the shared store rather than `@AppStorage` because arming the
    /// sentinel has to happen inside `spawnEngineThread`, next to the thread it
    /// protects — not in a view body several hops away.
    @ObservationIgnored private let modelSelection = ModelSelectionStore()

    // MARK: - Wiring

    func configure(session: GameSession,
                   engineLifecycle: EngineLifecycle,
                   navigationContext: NavigationContext) {
        self.session = session
        self.engineLifecycle = engineLifecycle
        self.navigationContext = navigationContext
    }

    /// The last net that finished loading, as the previous run left it.
    var persistedSelectionTitle: String { modelSelection.selectedModelTitle }

    /// The crash sentinel, as the previous run left it.
    var pendingLoadTitle: String { modelSelection.pendingLoadModelTitle }

    /// A load reached the engine's first GTP reply: record the selection and
    /// disarm the sentinel. Driven by `EngineLifecycle.lastLoadedModelTitle`.
    func noteLoadSucceeded(title: String) {
        modelSelection.selectedModelTitle = title
        modelSelection.pendingLoadModelTitle = ""
    }

    // MARK: - Launch states

    /// No model chosen. The board still mounts; the status line says so and
    /// offers the picker.
    func presentAbsent() {
        phase = .idle
        session?.endEngineSession(.absent)
        session?.engineStatus.actions = [.chooseModel]
    }

    /// The previous launch died mid-load. Nothing is relaunched.
    func presentFailedLastLaunch(title: String) {
        engineLogger.error(
            "Previous launch did not finish loading model: \(title, privacy: .public). Not relaunching it."
        )
        phase = .failed("The last launch did not finish loading \(title)")
        session?.endEngineSession(
            .failed(reason: "The last launch did not finish loading \(title)"))
        // No `.retry`: retrying the net that just took the process down is the
        // crash loop this sentinel exists to break. Choosing another one is the
        // only honest way forward.
        session?.engineStatus.actions = [.chooseModel]
    }

    /// First launch of this app run. Spawns and then completes the handshake in
    /// the background — the caller returns immediately and the board is already
    /// on screen.
    func start(model: NeuralNetworkModel) {
        // Only a genuinely idle controller may spawn straight away. A model
        // chosen with an engine up (or dead) is a RESTART; one chosen mid
        // transition waits for that transition to land.
        guard phase == .idle else {
            if Self.canRestart(from: phase) {
                Task { await restart(loading: model) }
            } else {
                queuedModel = model
            }
            return
        }
        guard let session, let engineLifecycle else { return }

        let resolved = Self.resolveLaunchModel(model, fileExists: Self.fileExists)
        activeModel = resolved.model
        session.engineStatus.note = resolved.note
        session.engineStatus.availability = .launching
        session.engineStatus.actions = []
        engineLifecycle.reset()
        spawnEngineThread(model: resolved.model)
        phase = .starting

        // PROTOTYPE (wayfinder #41): with `-prototype.coreAI.bench 1` the app drives the engine
        // itself (no handshake, no session), measures visits/s and exits.
        if UserDefaults.standard.string(forKey: "prototype.coreAI.bench") == "1",
           let arm = UserDefaults.standard.string(forKey: "prototype.coreAI.arm") {
            UIApplication.shared.isIdleTimerDisabled = true
            let rep = UserDefaults.standard.integer(forKey: "prototype.coreAI.rep")
            let only = UserDefaults.standard.string(forKey: "prototype.coreAI.position")
            let rest = UserDefaults.standard.object(forKey: "prototype.coreAI.rest") == nil
                ? 0.0 : UserDefaults.standard.double(forKey: "prototype.coreAI.rest")
            Thread.detachNewThread { GateBench.run(arm: arm, rep: rep, only: only, rest: rest) }
            return
        }

        Task { await completeHandshake(model: resolved.model) }
    }

    /// Retry from the status line. Same path as a model activation, with the
    /// net that is already selected.
    func retry() {
        Task { await restart(loading: nil) }
    }

    /// Relaunch with the custom engine parameters set aside for that one
    /// launch. They stay saved; the launch after uses them again.
    func relaunchWithoutCustomParameters() {
        setAsideCustomParametersOnNextLaunch = true
        Task {
            await restart(loading: nil)
            // A refused restart never reached the spawn; do not let the flag
            // ambush some later, unrelated launch.
            setAsideCustomParametersOnNextLaunch = false
        }
    }

    // MARK: - Restart

    /// Quit the running engine and bring it back — with `newModel` when a model
    /// activation drives the restart, or with the same net (and the freshly
    /// persisted backend settings) when nil.
    ///
    /// - Parameter performingWhileStopped: work that must run with NO engine
    ///   alive — clearing the Core ML cache, running the routing probe. It runs
    ///   after both teardown waits (read loop parked, engine thread exited) and
    ///   before the replacement spawns, so nothing is using the artifacts it
    ///   touches. It does NOT run when the teardown fails; the caller must not
    ///   rely on it for cleanup.
    /// - Returns: true when the new engine answered its handshake.
    @discardableResult
    func restart(loading newModel: NeuralNetworkModel? = nil,
                 performingWhileStopped: (@MainActor () async -> Void)? = nil) async -> Bool {
        guard let session, let engineLifecycle else {
            engineLogger.error("restart refused: not configured")
            return false
        }
        guard Self.canRestart(from: phase) else {
            engineLogger.notice("restart refused from phase \(String(describing: self.phase), privacy: .public)")
            return false
        }
        engineLogger.info("restart: begin (newModel: \(newModel?.title ?? "same", privacy: .public))")
        phase = .stopping

        // ORDER IS LOAD-BEARING, twice over.
        //
        // 1. `stopRequested` is what the thread-exit classifier reads. An
        //    engine that dies during the teardown window below must read as the
        //    shutdown WE asked for, not as a crash — so it is set BEFORE the
        //    `quit` goes out, never after it.
        // 2. The board must stop claiming the engine agrees with it the instant
        //    the user asks for a different one, not seconds later when the
        //    handshake finally runs. `endEngineSession` shuts the command gate,
        //    clears `stones.isReady` and says *Launching*, all synchronously —
        //    and it runs immediately AFTER the teardown pair goes out, the same
        //    order visionOS, tvOS and macOS use. (The pair bypasses the gate
        //    either way, so the order is about one thing only: every host
        //    tearing an engine down in the same sequence.)
        session.stopRequested = true

        // Stop any streaming search, then quit — but ONLY when there is an
        // engine to receive them. `sendCommand` writes into the process-global
        // INPUT buffer, which nothing drains while no engine is running: a
        // `quit` sent to a thread that already died would sit there and be the
        // first thing the REPLACEMENT engine reads, killing it on arrival. That
        // is the Retry-after-a-crash path, and it would look exactly like a
        // second crash.
        if engineThreadRunning {
            // Lifecycle commands go straight to the transport: the command gate
            // is exactly what a teardown must not be blocked by.
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
        // These two waits are POLLED (`EngineRestartRules.untilSettled`), not
        // parked on a continuation. A `CheckedContinuation` cannot observe
        // cancellation, and `withTimeout` cannot rescue it either:
        // `withTaskGroup` awaits its remaining children after `cancelAll()`, so
        // a wait that never resumes would hold the whole restart in `.stopping`
        // forever — no phase, no status, no Retry. A deadline-checked poll
        // gives up on its own and reports it.
        engineLogger.info("restart: teardown sent, waiting for read loop to park")
        guard await waitForReadLoopPark(timeout: Self.readLoopParkTimeout) else {
            engineLogger.error("restart: read loop did not park")
            return fail("The engine did not shut down.")
        }

        // CRITICAL: also wait for the ENGINE THREAD itself to finish.
        // MainCmds::gtp keeps tearing down (deleting the engine, NN cleanup)
        // after its reply stream goes quiet; spawning the next runGtp while the
        // old one is still inside that epilogue overlaps two engines on the
        // process-global bridge state and dies with a C++ fatalError. An idle
        // engine tears down in milliseconds, but one that has just run a search
        // has been observed taking ~2 minutes — allow for it.
        engineLogger.info("restart: read loop parked, waiting for engine thread exit")
        guard await waitForEngineThreadExit(timeout: Self.engineThreadExitTimeout) else {
            engineLogger.error("restart: engine thread did not exit")
            return fail("The engine did not shut down.")
        }

        // The engine is fully down — read loop parked, thread exited. This is
        // the one window where heavy Core ML work is safe with a live session:
        // nothing holds the compiled artifacts, and the Neural Engine is idle.
        if let performingWhileStopped {
            engineLogger.info("restart: running stopped-window work")
            await performingWhileStopped()
            engineLogger.info("restart: stopped-window work done")
        }

        // The model swaps only after the old engine has fully torn down, so
        // every reader of `activeModel` sees the running engine's net.
        if let newModel {
            let resolved = Self.resolveLaunchModel(newModel, fileExists: Self.fileExists)
            activeModel = resolved.model
            session.engineStatus.note = resolved.note
        }
        guard let model = activeModel else {
            return fail("No network is selected.")
        }

        engineLifecycle.reset()
        spawnEngineThread(model: model)
        session.stopRequested = false
        phase = .starting
        session.engineStatus.availability = .launching
        session.engineStatus.actions = []

        // The restart handshake waits exactly as long as the BOOT handshake.
        //
        // It used to be capped at 120 s, copied from visionOS — where 120 s is
        // right because the restart there only ever swaps the Max Board Size on
        // a net that is already compiled. On iOS a restart is where a COLD
        // compile happens: before C5 a model switch tore the whole tree down and
        // came back through the boot path, so picking an uncompiled net got the
        // full 660 s. Every switch and every Retry now takes this path, and
        // 120 s is not enough to compile a large network on an A15 — it would
        // report "The engine did not come up" for an engine that was simply
        // still working. The wrapper carries the same number so neither can
        // outlive the other.
        let handshakeTimeout = Self.restartHandshakeTimeout
        let handshake: Bool? = await withTimeout(seconds: handshakeTimeout) {
            await session.handshake(selectedModelTitle: model.title,
                                    engineLifecycle: engineLifecycle,
                                    timeoutSeconds: handshakeTimeout) != nil
        }
        guard handshake == true else {
            // Leave the read loop parked: the engine's state is unknown, and a
            // reader racing the next handshake would eat its `version` reply.
            return fail("The engine did not come up.")
        }

        phase = .running
        sendLiveCustomParameters()
        // Arm the read loop when the BOOT handshake never did (a Retry after a
        // failed launch), resume it otherwise — arming an existing one would
        // re-key the host's `.task(id:)` and cancel the parked reader.
        if EngineRestartRules.shouldArmReadLoop(generation: readLoopGeneration) {
            readLoopGeneration = 1
        } else {
            readLoopPark?.resume()
            readLoopPark = nil
        }
        resyncAfterHandshake()
        drainQueuedModel()
        return true
    }

    /// Apply a model chosen while the controller was mid-transition. Runs after
    /// the transition settles, from whichever end it settled at.
    private func drainQueuedModel() {
        guard let queued = queuedModel else { return }
        queuedModel = nil
        guard queued.title != activeModel?.title else { return }
        Task { await restart(loading: queued) }
    }

    // MARK: - Read loop

    /// The read loop reports each `session.run` exit here, then parks until a
    /// restart has finished its handshake (during which the handshake must be
    /// the bridge's only reader).
    func noteRunLoopExited() async {
        readLoopParked = true
        await withCheckedContinuation { continuation in
            readLoopPark = continuation
        }
        readLoopParked = false
    }

    /// Waits for the read loop to stop reading the bridge, so the handshake can
    /// be its only reader. True when it settled, false when it did not.
    ///
    /// Returns at once when there is no loop yet (a failed BOOT never started
    /// one) or when it is already parked — the Retry-after-a-crash case: the
    /// engine died, `session.run` returned, and the loop parked itself.
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

    // MARK: - Held

    /// Re-evaluates *Held* for the board on screen: a ready engine whose NN
    /// buffer is smaller than this record cannot be fed it, and says so
    /// inline. The board still draws — Held is a status, never a screen.
    ///
    /// Held also SHUTS THE COMMAND GATE, which is the part that matters
    /// beyond the wording. `loadGame` already refuses to feed an oversized
    /// record, but navigation does not check board size: without the gate,
    /// scrubbing a 37x37 record on a 19-buffer engine would push `play` after
    /// `play` at an engine that was never told this board exists, and its
    /// refusals would end up claiming the board was in sync. Shutting the gate
    /// routes every one of those sends down the path a launching engine
    /// already uses — dropped, logged, and remembered as a debt.
    ///
    /// The rule and the EFFECT are both shared: `EngineHeldRule` decides that
    /// it happens, `GameSession.holdEngineSession`/`releaseEngineHold` are what
    /// happens. Four hand-written copies of the effect is how three of them
    /// ended up skipping `abortInFlightBoardCollection`.
    func applyHeldStatus(boardWidth: Int, boardHeight: Int) {
        guard let session else { return }
        let current = session.engineStatus.availability
        // The rule itself lives in the package (`EngineHeldRule`), shared with
        // macOS/visionOS/tvOS: one board-size answer, one place to change it.
        let next = EngineHeldRule.decide(
            current: current,
            boardWidth: boardWidth,
            boardHeight: boardHeight,
            maxBoardLength: maxBoardLength)
        // Assign only on a real change: an `@Observable` write invalidates
        // every reader even when the value is identical, and this runs on every
        // game switch, board resize and engine transition.
        guard next != current else { return }

        switch next {
        case .held(let maxBoardLength):
            // iOS seeds the remedy: the model picker is where both ways out
            // live (pick a net with a bigger cap, or Backend Settings ▸ Max
            // Board Size). Other platforms pass nothing and keep a bare line.
            session.holdEngineSession(maxBoardLength: maxBoardLength,
                                      actions: [.chooseModel])
        case .ready:
            session.releaseEngineHold(gameRecord: navigationContext?.selectedGameRecord)
        default:
            // Unreachable — `EngineHeldRule` only ever moves `.ready ↔ .held`,
            // and an unchanged verdict returned above.
            session.engineStatus.availability = next
        }
    }

    // MARK: - Timeouts

    /// How long a restart waits for the read loop to stop reading. It only has
    /// to notice a blank line the teardown already pushed through the bridge.
    static let readLoopParkTimeout: Double = 10

    /// How long a restart waits for `MainCmds::gtp` to return. An idle engine
    /// tears down in milliseconds, but one that has just run a search has been
    /// observed taking ~2 minutes — allow for it.
    static let engineThreadExitTimeout: Double = 240

    /// How long a RESTART waits for the replacement engine's `version` reply.
    ///
    /// The same bound the boot handshake uses, deliberately: on iOS a restart is
    /// where a cold Core ML compile happens (a model switch used to tear the
    /// tree down and come back through the boot path), so anything shorter turns
    /// a slow compile into a reported failure.
    static var restartHandshakeTimeout: Double { GameSession.defaultHandshakeTimeout }

    // MARK: - Pure decisions

    /// Whether a restart may begin from `phase` — `EngineRestartRules.canRestart`
    /// over the phase's shared kind, so the rule (and its `.failed` = the status
    /// line's Retry button clause) lives in one place for all three in-process
    /// controllers and is pinned by tests an app target cannot host.
    static func canRestart(from phase: Phase) -> Bool {
        EngineRestartRules.canRestart(from: phase.kind)
    }

    /// The net to actually launch, and what (if anything) the status line has
    /// to say about the substitution.
    ///
    /// A downloaded net can vanish between launches — the user deleted it, or
    /// the system evicted it. Falling back to the bundled net keeps the app
    /// usable; saying so keeps it honest, because otherwise the Settings sheet
    /// would name a network nobody chose.
    static func resolveLaunchModel(
        _ model: NeuralNetworkModel,
        fileExists: (NeuralNetworkModel) -> Bool
    ) -> (model: NeuralNetworkModel, note: String?) {
        // The built-in net's bytes are in the app bundle, never in Documents.
        if model.builtIn { return (model, nil) }
        if fileExists(model) { return (model, nil) }
        guard let builtIn = NeuralNetworkModel.builtInModel else { return (model, nil) }
        return (builtIn, "\(model.title) was removed — using the built-in network")
    }

    /// How an engine that stopped running should be reported.
    ///
    /// The disposition rule itself is shared with macOS/visionOS/tvOS
    /// (`EngineExitDisposition`); what is iOS-specific is the pair of ways out
    /// a failure offers, because iOS is the only platform with a model picker.
    static func exitOutcome(
        fatalError: String?,
        stopWasRequested: Bool
    ) -> (disposition: EngineExitDisposition, actions: [EngineStatusAction]) {
        let disposition = EngineExitDisposition.decide(fatalError: fatalError,
                                                       stopWasRequested: stopWasRequested)
        switch disposition {
        case .expected:
            return (disposition, [])
        case .failed:
            return (disposition, [.retry, .chooseModel])
        }
    }

    /// How the model picker may do heavy Core ML work right now — run the
    /// routing probe (which COMPILES a network on a miss) or clear the compiled
    /// cache out from under whatever is using it.
    enum HeavyCoreMLWorkPermission {
        /// No engine holds the artifacts: do the work right now, and nothing
        /// needs relaunching afterwards.
        case direct
        /// An engine is running off the artifacts. The work is still offered —
        /// the engine is unloaded first, the work runs while it is down, and it
        /// relaunches afterwards (`restart(performingWhileStopped:)`).
        case requiresUnload
        /// The engine is mid-launch — possibly mid-compile. Interrupting that
        /// is the one teardown path this app does not take; the work waits the
        /// transient out.
        case unavailable
    }

    /// The picker used to be reachable only with the engine stopped, which is
    /// why heavy work needed no guard at all. It is a sheet over a live board
    /// now: a compile competes with the engine for the same Neural Engine, and
    /// deleting the artifacts a running engine loaded from must not happen
    /// under it — so a running engine means *unload first*, never *blocked*.
    ///
    /// A nil availability — no status injected — reads as `.direct`, which is
    /// the behaviour every surface had before the status existed.
    static func heavyCoreMLWorkPermission(
        _ availability: EngineAvailability?
    ) -> HeavyCoreMLWorkPermission {
        guard let availability else { return .direct }
        switch availability {
        case .absent, .failed:
            return .direct
        case .ready, .held:
            return .requiresUnload
        case .launching:
            return .unavailable
        }
    }

    // MARK: - Spawn / teardown

    private static func fileExists(_ model: NeuralNetworkModel) -> Bool {
        guard let url = model.downloadedURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func spawnEngineThread(model: NeuralNetworkModel) {
        engineThreadRunning = true

        // Read this model's backend settings on the MainActor and record what
        // THIS engine is launched with, BEFORE the off-main thread starts, so
        // every gate reads a consistent value. The per-fileName keys make all
        // of it per-model automatically.
        var settings = BackendSettings(model: model)
        maxBoardLength = settings.effectiveMaxBoardLength
        session?.engineStatus.launchedMaxBoardLength = maxBoardLength
        // The feed refuses a record this engine cannot hold (an oversized board
        // aborts the engine fatally on its first analysis). Set here, at the
        // spawn, because this is the first moment the number is true.
        session?.gobanState.engineMaxBoardLength = maxBoardLength

        let saved = CustomParameterStore().load()
        let setAside = setAsideCustomParametersOnNextLaunch && !saved.isEmpty
        setAsideCustomParametersOnNextLaunch = false
        let launchedCustomParameters = setAside ? CustomParameters() : saved
        session?.engineStatus.launchedCustomParameters = launchedCustomParameters
        session?.engineStatus.customParametersSetAside = setAside
        var customOverrides = launchedCustomParameters.launchOverrides

        // PROTOTYPE (wayfinder #40), throwaway: the Core AI gate's stage 2 arms. The hidden key
        // `prototype.coreAI.arm` ("coreai" or "coreml", also settable as a launch argument
        // `-prototype.coreAI.arm coreai`) pins the gate's iPad config whatever the Backend sheet says:
        // one NN server thread on device 200 (Core AI) or 100 (CoreML/NE), the default search threads,
        // a 19x19 buffer, requireMaxBoardSize=false, and the human SL net off. Core AI loads
        // <bundle>/CoreAI/<n>x<n>.aimodel, or Library/CoreAI/ if devicectl copied the models there.
        let gateArm = UserDefaults.standard.string(forKey: "prototype.coreAI.arm")
        var deviceAssignments = settings.deviceAssignments
        var numSearchThreads = settings.numSearchThreads
        var requireExactNNLen = settings.requireExactNNLen
        var includeHumanNet = true
        if let gateArm, gateArm == "coreai" || gateArm == "coreml" {
            // The engine's stderr (backend load lines, fatal errors) goes to Library/CoreAI/engine.log,
            // which `devicectl device copy from` fetches.
            let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CoreAI")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            freopen(logDir.appendingPathComponent("engine.log").path, "a", stderr)
            setvbuf(stderr, nil, _IONBF, 0)
            deviceAssignments = gateArm == "coreai" ? [200] : [100]
            numSearchThreads = KataGoHelper.mlxNumSearchThreads
            requireExactNNLen = false
            includeHumanNet = false
            maxBoardLength = 19
            session?.engineStatus.launchedMaxBoardLength = 19
            session?.gobanState.engineMaxBoardLength = 19
            if gateArm == "coreai" {
                let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("CoreAI")
                let bundled = Bundle.main.resourceURL?.appendingPathComponent("CoreAI")
                let dir = FileManager.default.fileExists(atPath: library.path) ? library : (bundled ?? library)
                customOverrides.append("coreAIModelFile=\(dir.path)")
            }
            let note = "PROTOTYPE Core AI gate arm \(gateArm): devices \(deviceAssignments), "
                + "\(numSearchThreads) search threads, human SL off, overrides \(customOverrides)\n"
            FileHandle.standardError.write(Data(note.utf8))
        }
        let launchedMaxBoardLength = maxBoardLength
        let backend = settings.backend
        let tunerFull = settings.tunerFull
        let reTune = settings.reTune
        // Built-in → nil (runGtp resolves the bundled default_model);
        // downloaded → the Documents file.
        let modelPath = model.builtIn ? nil : model.downloadedURL?.path()

        // Arm the crash sentinel BEFORE the engine thread starts, for every
        // spawn (boot, model switch, backend restart alike). If the process
        // dies before the handshake's first GTP reply, the surviving value is
        // what stops the next launch from repeating the crash.
        modelSelection.pendingLoadModelTitle = model.title
        UserDefaults.standard.synchronize()

        let thread = Thread { [weak self] in
            KataGoHelper.runGtp(modelPath: modelPath,
                                deviceAssignments: deviceAssignments,
                                numSearchThreads: numSearchThreads,
                                maxBoardSizeForNNBuffer: launchedMaxBoardLength,
                                requireExactNNLen: requireExactNNLen,
                                includeHumanNet: includeHumanNet,
                                tunerFull: tunerFull,
                                reTune: reTune,
                                customOverrides: customOverrides)
            // MainCmds::gtp returned — the engine is fully torn down. Take the
            // fatal error here, on the thread that owns it, and hand it to the
            // MainActor with the exit.
            let exitError = KataGoHelper.takeLastFatalError()
            Task { @MainActor in
                self?.noteEngineThreadExited(fatalError: exitError)
            }
        }

        // Expand the stack size to resolve a stack overflow problem.
        thread.stackSize = 4096 * 256
        thread.start()

        // One-shot: consume a pending re-tune so it fires exactly once. Only a
        // backend that runs an MLX/GPU server thread (.mlxGPU or .mux) reads the
        // Winograd tuner flags, so the re-tune is consumed only then.
        if reTune && (backend == .mlxGPU || backend == .mux) {
            settings.reTune = false
        }
    }

    private func noteEngineThreadExited(fatalError: String?) {
        engineThreadRunning = false

        guard let session else { return }
        let outcome = Self.exitOutcome(fatalError: fatalError,
                                       stopWasRequested: session.stopRequested)
        // The session classifies the exit itself (the same rule, one owner) —
        // called BEFORE anything here touches a stop flag, so an engine that
        // died on its own can never be read as a teardown we asked for.
        session.noteEngineExit(fatalError: fatalError)
        switch outcome.disposition {
        case .expected:
            // A restart is driving; it owns the phase and is about to say
            // Launching itself.
            break
        case .failed(let reason):
            phase = .failed(reason)
            session.engineStatus.actions = outcome.actions
            session.engineStatus.offerCustomParameterRemedy()
        }
    }

    /// Waits for `MainCmds::gtp` to return. True when it did, false on timeout.
    private func waitForEngineThreadExit(timeout: Double) async -> Bool {
        await EngineRestartRules.untilSettled(timeout: timeout,
                                              pollInterval: .milliseconds(100)) { [weak self] in
            !(self?.engineThreadRunning ?? false)
        }
    }

    // MARK: - Post-handshake

    private func completeHandshake(model: NeuralNetworkModel) async {
        guard let session, let engineLifecycle else { return }
        // The BOOT handshake keeps the full `defaultHandshakeTimeout`: a cold
        // Core ML compile of two networks is legitimate work, and cutting it
        // short would report a failure that is really just an A15 doing its job.
        let reply = await session.handshake(selectedModelTitle: model.title,
                                            engineLifecycle: engineLifecycle)
        guard reply != nil else {
            // `handshake` already ended the session with its own reason; only
            // the phase and the second way out are ours to add.
            phase = .failed(Self.failedReason(session.engineStatus.availability))
            session.engineStatus.actions = [.retry, .chooseModel]
            session.engineStatus.offerCustomParameterRemedy()
            drainQueuedModel()
            return
        }
        phase = .running
        sendLiveCustomParameters()
        readLoopGeneration = 1
        resyncAfterHandshake()
        drainQueuedModel()
    }

    /// Live values edited while the engine was launching missed its
    /// -override-config; the current set goes in once it answers, before the
    /// feed. Not when this launch set them aside.
    private func sendLiveCustomParameters() {
        guard let session, !session.engineStatus.customParametersSetAside else { return }
        session.sendLiveCustomParameters(CustomParameterStore().load())
    }

    private static func failedReason(_ availability: EngineAvailability) -> String {
        if case .failed(let reason) = availability { return reason }
        return EngineExitDisposition.defaultReason
    }

    /// Feed the fresh engine the position the board is showing NOW. Every
    /// command sent while it was loading was dropped by the gate and recorded
    /// as a debt; this is where the debt is paid, from the LIVE record at the
    /// LIVE cursor (the user may have switched games twice while the model
    /// loaded — latest selection wins).
    ///
    /// The seam parks the turn as part of the feed, which is what re-arms
    /// analysis: a relaunch does not change whose move it is, so without the
    /// park the fresh engine's `showboard` would restate the colour the board
    /// already held and no turn edge would fire.
    private func resyncAfterHandshake() {
        guard let session else { return }
        session.gobanState.resyncEngineAfterHandshake(
            gameRecord: navigationContext?.selectedGameRecord,
            player: session.player,
            messageList: session.messageList,
            stones: session.stones,
            projector: session.recordPosition)
    }

    @discardableResult
    private func fail(_ reason: String) -> Bool {
        phase = .failed(reason)
        // Hand the stop flag back. `restart` raises it before the `quit` so a
        // teardown death is not misreported as a crash; leaving it raised after
        // a restart that gave up would make the NEXT death — a genuine one —
        // classify as `.expected` and pass in silence.
        session?.stopRequested = false
        session?.endEngineSession(.failed(reason: reason))
        session?.engineStatus.actions = [.retry, .chooseModel]
        session?.engineStatus.offerCustomParameterRemedy()
        drainQueuedModel()
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

// MARK: - PROTOTYPE (wayfinder #41): stage 2 visits/s on the iPad, throwaway

/// One launch = one arm block. For each position in Library/CoreAI/positions.json (name -> GTP
/// moves): wait for a nominal thermal state, clear_board, replay, `kata-analyze interval 100
/// rootInfo true`, and count root visits gained from t=10 s to t=70 s. One JSON line per position
/// goes to Library/CoreAI/bench.jsonl; then the process exits.
enum GateBench {
    static func run(arm: String, rep: Int, only: String?, rest: Double) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoreAI")
        let out = dir.appendingPathComponent("bench.jsonl")
        func emit(_ obj: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
            let line = data + Data("\n".utf8)
            if let h = try? FileHandle(forWritingTo: out) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: out)
            }
        }
        func reply(timeout: Double = 900) -> String? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                let l = KataGoHelper.getMessageLine(timeoutSeconds: 5)
                if l.hasPrefix("=") { return l }
                if l.hasPrefix("?") { emit(["arm": arm, "rep": rep, "error": l]); return nil }
            }
            emit(["arm": arm, "rep": rep, "error": "timeout"]); return nil
        }
        let t0Launch = Date()
        KataGoHelper.sendCommand("version")
        guard reply() != nil else { exit(2) }
        let loadS = Date().timeIntervalSince(t0Launch)
        guard let pdata = try? Data(contentsOf: dir.appendingPathComponent("positions.json")),
              let positions = try? JSONSerialization.jsonObject(with: pdata) as? [String: [String]] else {
            emit(["arm": arm, "rep": rep, "error": "no positions.json"]); exit(3)
        }
        for name in positions.keys.sorted() where only == nil || only == name {
            var thermalWait = 0.0
            while ProcessInfo.processInfo.thermalState != .nominal && thermalWait < 900 {
                Thread.sleep(forTimeInterval: 5); thermalWait += 5
            }
            // Protocol v2 (#41): after reaching nominal, rest a fixed time, then require nominal again.
            if rest > 0 {
                Thread.sleep(forTimeInterval: rest)
                while ProcessInfo.processInfo.thermalState != .nominal && thermalWait < 1800 {
                    Thread.sleep(forTimeInterval: 5); thermalWait += 5
                }
            }
            let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
            var thermalMax = thermalStart
            KataGoHelper.sendCommand("clear_board"); guard reply() != nil else { exit(4) }
            for m in positions[name]! {
                KataGoHelper.sendCommand("play " + m); guard reply() != nil else { exit(4) }
            }
            KataGoHelper.sendCommand("kata-analyze interval 100 rootInfo true"); guard reply() != nil else { exit(4) }
            let t0 = Date()
            var samples: [(Double, Int)] = []
            while true {
                let l = KataGoHelper.getMessageLine(timeoutSeconds: 5)
                let t = Date().timeIntervalSince(t0)
                let toks = l.split(separator: " ")
                if let i = toks.firstIndex(of: "rootInfo"),
                   let j = toks[i...].firstIndex(of: "visits"), j + 1 < toks.count, let v = Int(toks[j + 1]) {
                    samples.append((t, v))
                    thermalMax = max(thermalMax, ProcessInfo.processInfo.thermalState.rawValue)
                }
                if t >= 70 && !samples.isEmpty { break }
                if t >= 200 { break }
            }
            guard let s0 = samples.first(where: { $0.0 >= 10 }), let s1 = samples.last, s1.0 > s0.0 else {
                emit(["arm": arm, "rep": rep, "position": name, "error": "no samples"]); exit(5)
            }
            KataGoHelper.sendCommand("protocol_version"); _ = reply()
            emit(["arm": arm, "rep": rep, "position": name,
                  "vps": Double(s1.1 - s0.1) / (s1.0 - s0.0),
                  "t0": s0.0, "v0": s0.1, "t1": s1.0, "v1": s1.1, "load_s": loadS,
                  "thermal_wait_s": thermalWait, "thermal_start": thermalStart, "thermal_max": thermalMax,
                  "rest_s": rest, "void": thermalMax != 0,
                  "thermal_end": ProcessInfo.processInfo.thermalState.rawValue,
                  "wall": ISO8601DateFormatter().string(from: Date())])
        }
        KataGoHelper.sendCommand("quit")
        Thread.sleep(forTimeInterval: 2)
        exit(0)
    }
}
