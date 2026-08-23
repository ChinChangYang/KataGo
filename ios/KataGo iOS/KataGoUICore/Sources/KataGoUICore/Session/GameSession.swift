//
//  GameSession.swift
//  KataGoUICore
//
//  Created by Chin-Chang Yang on 2026/6/15.
//

import SwiftUI
import SwiftData

/// View-independent owner of the engine-driven game state and the GTP message
/// loop. Extracted from `ContentView` so non-SwiftUI hosts (e.g. the macOS
/// AppKit app) can drive the same engine without an iOS view.
///
/// The methods here were moved verbatim from `ContentView`; the only changes
/// are `self.`-qualification of session-owned members and replacing the loop's
/// old `quitStatus` checks with `!stopRequested`. View/app-only collaborators
/// (`NavigationContext`, `AudioModel`, the `aiMove` binding, `gameRecords`,
/// `modelContext`, `EngineLifecycle`) are passed in as parameters rather than
/// owned here.
@Observable
@MainActor
public final class GameSession {
    public let stones = Stones()
    public let messageList = MessageList()
    public let board = BoardSize()
    public let player = Turn()
    public let analysis = Analysis()
    public let gobanState = GobanState()
    public let rootWinrate = Winrate()
    public let rootScore = Score()
    public let bookLookup = BookLookup()
    /// The one writer of the displayed board. Every driver of this session —
    /// the SwiftUI `recordPositionSync` modifier, macOS's
    /// `trackRecordPosition`, and `GobanState.loadGame` — projects through
    /// this instance, so they share both the replay cache and the key that
    /// says what is currently on screen.
    public let recordPosition = RecordPositionProjector()
    /// Engine availability, as the board displays it. Owned here because the
    /// handshake and the message loop are the only things that know whether an
    /// engine is listening; hosts inject it with `.environment(session.engineStatus)`
    /// and read it back as an OPTIONAL `@Environment(EngineStatus.self)`.
    public let engineStatus = EngineStatus()

    /// Drives the message loop's termination. Set to `true` by the host when it
    /// wants `run()` to stop: a teardown, or a restart about to respawn.
    public var stopRequested = false

    /// Out-of-band tap on every raw engine reply line, invoked from
    /// `messaging()` after the message is appended. The tvOS benchmark uses
    /// it to read kata-benchmark's result line (which no prefix-matcher
    /// recognizes) without adding a second reader on the engine bridge.
    /// Wiring, not observable UI state; default nil = no behavior change.
    @ObservationIgnored public var lineObserver: ((String) -> Void)?

    /// Transport to the engine. Defaults to the in-process C++ bridge
    /// (iOS/visionOS, and the default everywhere); the macOS app injects a
    /// per-window subprocess transport via `useEngine(_:)`.
    ///
    /// `nonisolated(unsafe)` rationale — concurrency invariant:
    /// - MUTATION: `engine` is only ever mutated by `useEngine(_:)`, which is
    ///   always called on the main actor **before** the message loop starts.
    ///   After that point, `engine` is read-only for the lifetime of the session.
    /// - READS: `MessageList.appendAndSend` reads `engine` (sometimes off the
    ///   main actor, from non-`@MainActor` `GobanState` call sites) but never
    ///   mutates it. Because there is no concurrent mutation, the
    ///   `nonisolated(unsafe)` opt-out is sound.
    /// - CAUTION: do NOT add `@MainActor` to `appendAndSend` to "fix" this.
    ///   It is intentionally callable off the main actor by `GobanState`, and
    ///   annotating it would break those call sites.
    @ObservationIgnored
    public nonisolated(unsafe) var engine: KataGoEngineIO = InProcessKataGoEngine()

    private var isShowingBoard = false
    private var boardText: [String] = []

    /// Set by `endEngineSession` so an in-flight `handshake` stops waiting for
    /// an engine that is already gone, instead of sitting out the (multi-minute)
    /// launch timeout. Cleared by each `handshake` on entry.
    /// `@ObservationIgnored` — control flow, not observable UI state.
    @ObservationIgnored private var handshakeAbandoned = false

    /// How long the handshake waits for the engine's `version` reply.
    /// 660 s is the Core ML loader's own launch fallback (600 s + 60 s,
    /// `CoreMLComputeHandleLoader.loadCoreMLHandleWithBridgeTimeout`), which
    /// bounds the longest work a launch can legitimately be doing: a cold
    /// compile of two networks. Every BOOT handshake uses it; iOS and macOS
    /// previously had no bound at all.
    ///
    /// The visionOS/tvOS RESTART paths pass 120 explicitly, to match the
    /// `withTimeout(seconds: 120)` they already wrap the call in. That wrapper
    /// is not a bound on its own: it cancels the child task, and a task group
    /// still awaits a cancelled child — so `restartEngine` cannot return until
    /// this loop does. The loop therefore honours `Task.isCancelled`, and the
    /// two agree on the same deadline so neither can outlive the other.
    public static let defaultHandshakeTimeout: Double = 660

    /// How long each individual read blocks. The loop re-checks the deadline
    /// and the abandon flag between reads, so this is the granularity at which
    /// a dead engine is noticed — not a poll of the engine itself.
    private static let handshakeReadInterval: Double = 0.5

    public init() {
        messageList.session = self
    }

    /// Routes this session's GTP I/O — reads happen here, sends go through
    /// `messageList` — through `engine`. Call BEFORE `initialize`. The macOS app
    /// uses this to drive a per-window `katago-engine` subprocess; iOS/visionOS
    /// keep the default in-process bridge.
    public func useEngine(_ engine: KataGoEngineIO) {
        self.engine = engine
    }

    /// Publishes `key`'s record position into this session's display models.
    /// Convenience over `recordPosition.project(...)` so hosts do not have to
    /// name all four models at every call site.
    @discardableResult
    public func projectRecordPosition(key: RecordPositionKey?) -> RecordPosition {
        recordPosition.project(key: key,
                               into: stones,
                               board: board,
                               analysis: analysis,
                               gobanState: gobanState)
    }

    // MARK: - Initialization

    /// Engine version/first-response handshake. Sends `version`, reads the
    /// reply line, clears the crash-loop sentinel via `EngineLifecycle` on a
    /// `= ` prefix, then sends the initial GTP commands for `config`.
    ///
    /// Returns the version line so the host can surface it (it lands on
    /// `engineStatus.engineVersion`, which the Settings sheet reads).
    ///
    /// NOTE: **no host calls this any more.** Every platform now calls
    /// `handshake` on its own and lets `EngineFeed.openingCommands` configure
    /// the engine, because `sendInitialCommands` states a board size before
    /// anything has decided whether the engine can hold it (`EngineHeldRule`)
    /// — and the feed is a strict superset of it, pinned by
    /// `EngineFeedInitialCommandsTests`. This pairing survives only as the
    /// subject of `GameSessionInitializeClearTests`; delete it together with
    /// those three call sites.
    @discardableResult
    public func initialize(
        selectedModelTitle: String,
        engineLifecycle: EngineLifecycle,
        config: Config?,
        timeoutSeconds: Double = GameSession.defaultHandshakeTimeout
    ) async -> String? {
        let version = await handshake(
            selectedModelTitle: selectedModelTitle,
            engineLifecycle: engineLifecycle,
            timeoutSeconds: timeoutSeconds
        )
        sendInitialCommands(config: config)
        return version
    }

    /// The version/first-response exchange alone — no config commands. The iOS
    /// host calls this directly so it can resolve WHICH game seeds the engine
    /// AFTER the blocking version read: that read spans the engine's model
    /// load (seconds), which is also the window where the system delivers a
    /// cold-launch `open-game` URL. Reading `DeepLinkRouter.pendingGameID`
    /// before this await raced the URL delivery and lost on the Release
    /// auto-restore path (Debug always shows the model picker, masking it).
    /// - Parameter timeoutSeconds: how long to wait for the reply before
    ///   declaring the launch failed. Defaults to `defaultHandshakeTimeout`.
    /// - Returns: the reply line, or nil when the engine never answered (a
    ///   timeout, or a teardown that abandoned this handshake).
    @discardableResult
    public func handshake(
        selectedModelTitle: String,
        engineLifecycle: EngineLifecycle,
        timeoutSeconds: Double = GameSession.defaultHandshakeTimeout
    ) async -> String? {
        // A launch is in progress, and — until it lands — nothing may be sent.
        engineStatus.availability = .launching
        messageList.isAcceptingCommands = false
        // A fresh engine agrees with nothing: drop every signal that says the
        // PREVIOUS one did, before this one is asked anything. A leftover
        // outstanding-ack count in particular would keep the board from ever
        // reporting in sync again.
        gobanState.resetForFreshEngine(stones: stones)
        abortInFlightBoardCollection()
        handshakeAbandoned = false

        // Discard any stale output the transport buffered from a PRIOR engine
        // run before this fresh handshake. The in-process bridge's output buffer
        // is process-global and survives a relaunch (Quit -> re-select a model),
        // so it holds leftover `kata-analyze` "info" lines, the `=` reply to
        // `quit`, and the newline nudge from QuitButton. Without this, the read
        // below returns one of those stale lines IMMEDIATELY instead of waiting
        // for the relaunched engine's real `version` reply — mounting the board
        // before the model finishes loading (the empty-board flash on second
        // entry), and letting a stale `= ` line wrongly fire `markFirstResponse`
        // (clearing the OOM crash-loop sentinel). No-op for the subprocess
        // transport, which gets a fresh stream per engine run.
        engine.clearPendingOutput()
        messageList.messages.append(Message(text: "Initializing..."))
        // A lifecycle command: it goes to the transport directly, because the
        // gate it would otherwise face is — by construction — shut right now.
        sendLifecycleCommand("version")

        let engine = self.engine
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var reply: String? = nil
        var giveUpReason = "The engine did not answer."

        // A BOUNDED loop rather than one unbounded read. An unbounded read
        // cannot notice that the engine thread died mid-launch, and — worse —
        // it stays parked on the process-global bridge, where it would eat the
        // NEXT engine's `version` reply and wedge the relaunch forever.
        //
        // Cancellation is honoured because a caller's own bound (visionOS and
        // tvOS wrap the restart handshake in `withTimeout(seconds: 120)`) is
        // only real if this loop stops: a task group awaits its cancelled
        // child, so the wrapper cannot return before this does.
        while !handshakeAbandoned, !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let slice = min(Self.handshakeReadInterval, remaining)
            let line = await Task.detached {
                engine.getMessageLine(timeoutSeconds: slice)
            }.value
            if handshakeAbandoned { break }
            if Task.isCancelled { break }
            if line.isEmpty {
                // "" is "nothing yet" for every transport — except a subprocess
                // whose child has exited, where it means the engine is gone.
                if engine.hasReachedEOF {
                    // The helper died mid-launch. Say what happened, not that
                    // it was slow — this is the string macOS users see.
                    giveUpReason = EngineExitDisposition.defaultReason
                    break
                }
                // A transport with no timed primitive falls back to the
                // unbounded read, which can return "" immediately; without this
                // the loop would spin hot for the whole timeout. Noise next to
                // the half-second slice a real timed read already consumed.
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            if line.hasPrefix("= ") || line.hasPrefix("? ") {
                reply = line
                break
            }
            // Anything else is output the drain above did not catch. Keep it in
            // the transcript — it is the only record of a misbehaving launch —
            // and keep reading for the actual reply.
            messageList.messages.append(Message(text: line))
        }

        if Task.isCancelled, reply == nil {
            giveUpReason = "The engine did not answer in time."
        }

        guard let reply else {
            // An abandoned handshake already has its cause recorded by whoever
            // abandoned it (a thread exit, an EOF observed by the message loop);
            // every other way out has to name itself.
            if !handshakeAbandoned {
                endEngineSession(.failed(reason: giveUpReason))
            }
            return nil
        }

        beginEngineSession(version: reply,
                           modelTitle: selectedModelTitle,
                           engineLifecycle: engineLifecycle)
        return reply
    }

    /// Send a command that must reach the engine even while the command gate is
    /// shut: `version` (the handshake itself) and the `stop`/`quit` pair every
    /// restart path uses to bring an engine down. Everything else goes through
    /// `MessageList.appendAndSend`, which drops while unavailable.
    ///
    /// The transcript still shows these, in the same shape as any other command
    /// — a teardown that leaves no trace is a teardown nobody can debug.
    public func sendLifecycleCommand(_ command: String) {
        messageList.appendCommandEcho(command)
        engine.sendCommand(command)
    }

    /// The engine answered: it takes commands, and the board's status line
    /// reports Ready (i.e. reports nothing).
    public func beginEngineSession(version: String,
                                   modelTitle: String,
                                   engineLifecycle: EngineLifecycle) {
        messageList.isAcceptingCommands = true
        engineStatus.availability = .ready
        engineStatus.actions = []
        engineStatus.modelTitle = modelTitle
        engineStatus.engineVersion = version

        // Crash-loop recovery signal: the first line Swift sees from KataGo is
        // the engine's reply to `version`, which proves model loading finished
        // and the GTP loop is running. Clearing the sentinel here (via
        // `EngineLifecycle`) is what tells `ModelRunnerView` the load
        // succeeded. This relies on `KataGoCpp.cpp` redirecting only `cout`
        // (not `cerr`/logger) — any future change that lets KataGo print to
        // `cout` before the GTP loop would need to re-validate this check.
        // Long-term fix: run the engine out-of-process via XPC so a crash
        // can't take the app down at all.
        //
        // A `? ` reply proves the loop is running too, so it opens the gate —
        // but it is NOT a successful load, so the sentinel stays armed.
        if version.hasPrefix("= ") {
            engineLifecycle.markFirstResponse(modelTitle: modelTitle)
        }
    }

    /// The engine process/thread ended. Ends the session the way the exit
    /// deserves: a restart WE asked for (model switch, Max Board Size, Quit —
    /// all of which set `stopRequested` before sending `quit`) is *expected* and
    /// offers no Retry, because nothing went wrong; anything else is a failure
    /// the user has to be told about.
    ///
    /// Expected exits land in `.launching`, not `.ready`: the gate is shut
    /// either way, and every expected exit is either followed by a relaunch
    /// (which sets `.launching` itself a moment later) or by the app going away.
    /// Leaving `.ready` standing over a shut gate would be the worse lie.
    ///
    /// - Parameter fatalError: `KataGoHelper.takeLastFatalError()` on the
    ///   in-process paths; nil where no such channel exists (the macOS
    ///   subprocess EOF).
    public func noteEngineExit(fatalError: String?) {
        switch EngineExitDisposition.decide(fatalError: fatalError,
                                            stopWasRequested: stopRequested) {
        case .expected:
            endEngineSession(.launching)
        case .failed(let reason):
            endEngineSession(.failed(reason: reason))
        }
    }

    /// The engine is gone (a failed launch, a crash, a teardown). Shuts the
    /// command gate, abandons any handshake still waiting on it, and drops every
    /// signal that claims the board and the engine agree.
    ///
    /// `actions` is seeded with `.retry` on a failure — the one way out every
    /// platform has. A host may add `.chooseModel` where a picker exists.
    public func endEngineSession(_ availability: EngineAvailability) {
        handshakeAbandoned = true
        messageList.isAcceptingCommands = false
        abortInFlightBoardCollection()
        gobanState.resetForFreshEngine(stones: stones)
        engineStatus.availability = availability
        if case .failed = availability {
            engineStatus.actions = [.retry]
        } else {
            engineStatus.actions = []
        }
    }

    /// The initial GTP commands for `config` (board size, rules, komi, human
    /// profiles). Public so the iOS host can send them separately after a
    /// `handshake()`-then-resolve sequence; `initialize` bundles both.
    public func sendInitialCommands(config: Config?) {
        // If a config is not available, initialize KataGo with a default config.
        let config = config ?? Config()
        messageList.appendAndSend(command: GtpCommandBuilder.boardSizeCommand(width: config.boardWidth, height: config.boardHeight))
        messageList.appendAndSend(commands: GtpCommandBuilder.ruleCommandsBundle(ko: config.koRuleText, scoring: config.scoringRuleText, tax: config.taxRuleText, multiStoneSuicide: config.multiStoneSuicideLegal, hasButton: config.hasButton, whiteHandicapBonus: config.whiteHandicapBonusRuleText))
        messageList.appendAndSend(command: GtpCommandBuilder.komiCommand(config.komi))
        // Disable friendly pass to avoid a memory shortage problem
        messageList.appendAndSend(command: "kata-set-rule friendlyPassOk false")
        messageList.appendAndSend(command: GtpCommandBuilder.playoutDoublingAdvantageCommand(config.playoutDoublingAdvantage))
        messageList.appendAndSend(command: GtpCommandBuilder.analysisWideRootNoiseCommand(config.analysisWideRootNoise))
        messageList.appendAndSend(commands: GtpCommandBuilder.symmetricHumanAnalysisCommands(humanSLProfile: config.effectiveHumanProfileForBlack, humanProfileForWhite: config.effectiveHumanProfileForWhite, humanRatioForBlack: config.humanRatioForBlack, humanRatioForWhite: config.humanRatioForWhite))
    }

    // MARK: - Message loop

    public func messaging(
        gameRecords: [GameRecord],
        modelContext: ModelContext,
        navigationContext: NavigationContext,
        audioModel: AudioModel,
        aiMove: Binding<String?>
    ) async {
        let engine = self.engine
        let line = await Task.detached {
            // Get a message line from KataGo
            return engine.getMessageLine()
        }.value

        // A subprocess engine reports EOF when it exits (a clean `quit` or a
        // crash). Stop the loop instead of busy-spinning on empty EOF reads. The
        // in-process bridge never reports EOF (its global buffer has no EOF), so
        // iOS/visionOS are unaffected. A normal blank GTP line is NOT EOF.
        if line.isEmpty && engine.hasReachedEOF {
            // Classify BEFORE flipping our own stop flag, or a helper that
            // crashed on its own would read as a teardown we asked for.
            noteEngineExit(fatalError: nil)
            stopRequested = true
            return
        }

        if !stopRequested {
            // Create a message with the line
            let message = Message(text: line)

            // Append the message to the list of messages
            messageList.messages.append(message)

            // Tap for raw engine lines the prefix-matchers below ignore (the
            // tvOS benchmark reads kata-benchmark's result through it). There
            // must never be a second reader on the engine bridge, so this is
            // the only way to observe replies out-of-band. Default nil — no
            // behavior change anywhere else.
            lineObserver?(line)

            // Handle GTP error responses by resetting all pending states
            maybeResetPendingStatesOnError(message: line)

            // Collect the engine-in-sync acknowledgement
            await maybeCollectSync(message: line)

            // Collect analysis information
            await maybeCollectAnalysis(message: line)

            // Collect SGF information
            maybeCollectSgf(
                message: line,
                gameRecords: gameRecords,
                modelContext: modelContext,
                navigationContext: navigationContext
            )

            // Collect play information
            maybeCollectPlay(
                message: line,
                navigationContext: navigationContext,
                audioModel: audioModel,
                aiMove: aiMove
            )

            // Collect check-move response
            maybeCollectCheckMove(
                message: line,
                navigationContext: navigationContext,
                audioModel: audioModel
            )

            // Remove when there are too many messages
            messageList.shrink()
        }
    }

    public func run(
        gameRecords: [GameRecord],
        modelContext: ModelContext,
        navigationContext: NavigationContext,
        audioModel: AudioModel,
        aiMove: Binding<String?>
    ) async {
        while !stopRequested {
            await messaging(
                gameRecords: gameRecords,
                modelContext: modelContext,
                navigationContext: navigationContext,
                audioModel: audioModel,
                aiMove: aiMove
            )
        }
    }

    // MARK: - Collectors

    /// A `? ` reply clears everything waiting on an answer that will never come
    /// — but only from an engine we are still talking to.
    ///
    /// `resetPendingStatesOnError` forces `stones.isReady = true`, i.e. "the
    /// engine holds this position". A `?` from a dying helper, or one arriving
    /// while a relaunch is in flight, holds nothing — and letting it claim sync
    /// is exactly how analysis ends up collected for a board the engine never
    /// saw.
    func maybeResetPendingStatesOnError(message: String) {
        guard message.hasPrefix("? ") else { return }
        guard messageList.isAcceptingCommands else { return }
        gobanState.resetPendingStatesOnError(stones: stones)
    }

    /// Drops a half-parsed showboard block (a game switch can race the read
    /// loop mid-block). The block's remaining lines then fall through the
    /// isShowingBoard guard as ordinary messages, so a superseded navigation's
    /// "Next player" line — and, crucially, its trailing `stones.isReady = true`
    /// — can never land after the switch reset it to false. It no longer
    /// protects any STONE write: the board is record-owned and `showboard` does
    /// not write stones any more. showBoardCount bookkeeping is unaffected: the
    /// block's "= MoveNum" was already consumed.
    public func abortInFlightBoardCollection() {
        isShowingBoard = false
        boardText = []
    }

    /// Consumes a `showboard` block as the ENGINE-IN-SYNC acknowledgement it
    /// now is: the side to move and `stones.isReady`, nothing else. Stones,
    /// board size, capture counts and move numbers all come from the record
    /// via `RecordPositionProjector`.
    ///
    /// A block is only entered when `consumeShowBoardResponse` returns true —
    /// i.e. when `showBoardCount` reached 0 — so an intermediate block from a
    /// superseded navigation falls through as ordinary lines and can never
    /// flip the turn or claim sync.
    func maybeCollectSync(message: String) async {
        // Only an engine we are still talking to can acknowledge anything. A
        // block still draining out of a dying helper, or one arriving while a
        // relaunch is in flight, must never claim the board is in sync with it.
        guard messageList.isAcceptingCommands else { return }

        // Check if the board is not currently being shown
        guard isShowingBoard else {
            // If this is the LAST outstanding showboard's move-number line
            if gobanState.consumeShowBoardResponse(response: message) {
                // Reset the board text for a new position
                boardText = []
                // Set the flag to showing the board
                isShowingBoard = true
            }
            // Exit the function early
            return
        }

        // If the message indicates which player's turn it is
        if message.hasPrefix("Next player") {
#if DEBUG
            // Diagnostic only, never a mutation: a self-heal here would hide
            // exactly the bug it is meant to expose.
            logEngineRecordDivergence(boardText: boardText)
#endif
            // Determine the next player color based on the message content
            player.nextColorForPlayCommand = message.contains("Black") ? .black : .white
            // Set the next player's color from showing board
            player.nextColorFromShowBoard = player.nextColorForPlayCommand
        }

        // Append the current message to the board text
        boardText.append(message)

        // The trailing capture line ends the block: the engine has now caught
        // up with the position the record already put on screen.
        if message.hasPrefix("W stones captured") {
            // Set the flag to stop showing the board
            isShowingBoard = false
            stones.isReady = true
        }
    }

#if DEBUG
    /// Logs one line when the engine's `showboard` ASCII disagrees with the
    /// stones the record projected. The record wins by design — this is how a
    /// feed bug becomes visible instead of silently drawing the wrong board.
    private func logEngineRecordDivergence(boardText: [String]) {
        let parsed = BoardTextParser.parse(boardText)
        guard Set(parsed.blackStones) != Set(stones.blackPoints)
                || Set(parsed.whiteStones) != Set(stones.whitePoints) else { return }
        printError("engine/record divergence: engine B=\(parsed.blackStones.count) W=\(parsed.whiteStones.count) \(Int(parsed.width))x\(Int(parsed.height)); record B=\(stones.blackPoints.count) W=\(stones.whitePoints.count) \(Int(board.width))x\(Int(board.height))")
    }
#endif

    func maybeCollectAnalysis(message: String) async {
        // Deep Report probes own the info stream: the report collector reads it
        // via lineObserver; the live Analysis/edge machinery must not see it.
        guard !gobanState.reportGenerationActive else { return }
        // Only from an engine we are still talking to. `info` lines outlive the
        // moment they were asked for: a search keeps streaming for a second or
        // more after the gate shuts (a restart's teardown, or a board the engine
        // cannot hold going *Held*), and every one of those lines would be
        // stamped `collectedForKey = recordPosition.currentKey` — i.e. filed
        // against the position on screen, which is precisely the position they
        // do NOT describe. `showBoardCount == 0` cannot catch it, because the
        // fresh-engine reset zeroes that counter on the way down.
        guard messageList.isAcceptingCommands else { return }
        guard gobanState.showBoardCount == 0 else { return }
        if message.starts(with: /info/) {
            let sampleTime = ProcessInfo.processInfo.systemUptime

            let parser = AnalysisLineParser(boardWidth: Int(board.width),
                                            boardHeight: Int(board.height),
                                            nextColor: player.nextColorFromShowBoard)
            let parsed = parser.parse(message: message)
            let rootVisits = Analysis.parseRootVisits(from: message)

            withAnimation {
                analysis.info = parsed.info
                analysis.ownershipUnits = parsed.ownershipUnits
                analysis.nextColorForAnalysis = player.nextColorFromShowBoard
                // Stamp the position these numbers belong to — the one the
                // session is displaying right now. `maybeUpdateAnalysisData`
                // refuses to persist them into any other index.
                analysis.collectedForKey = recordPosition.currentKey

                if let rootVisits {
                    analysis.updateVisitsPerSecond(rootVisits: rootVisits, at: sampleTime)
                }

                if gobanState.eyeStatus != .book {
                    if let blackWinrate = analysis.blackWinrate {
                        rootWinrate.black = blackWinrate
                    }
                    rootScore.black = analysis.blackScore ?? 0
                }
            }

            gobanState.waitingForAnalysis = parsed.info.isEmpty
        }
    }

    /// Routes a `printsgf` reply into the active branch line or the selected
    /// record. It can no longer CREATE anything: the first game is created by
    /// the launch path (`GameRecord.resolveOrCreateInitialSelection`), engine-free,
    /// so no reply ever inserts into a model context.
    ///
    /// `gameRecords` and `modelContext` are consequently unused. They stay on
    /// the signature because `messaging(gameRecords:modelContext:…)` — a public
    /// entry point every host calls — still threads them; dropping them is a
    /// signature change across five app targets, and belongs with the later
    /// commits that rework those hosts.
    func maybeCollectSgf(
        message: String,
        gameRecords: [GameRecord],
        modelContext: ModelContext,
        navigationContext: NavigationContext
    ) {
        let sgfPrefix = "= (;FF[4]GM[1]"
        if message.hasPrefix(sgfPrefix) {
            if let startOfSgf = message.firstIndex(of: "(") {
                let sgfString = String(message[startOfSgf...])
                let sgfHelper = SgfOperations(sgf: sgfString)
                let currentIndex = sgfHelper.moveSize ?? 0
                if gobanState.isBranchActive {
                    gobanState.branchSgf = sgfString
                    gobanState.branchIndex = currentIndex
                } else if let gameRecord = navigationContext.selectedGameRecord,
                          !gobanState.forcesBranchOnPlay {
                    // Under forcesBranchOnPlay (tvOS review) the record must
                    // never be written: every legitimate printsgf there is
                    // branch-routed above; anything reaching this arm is a
                    // stray reply that would overwrite a synced game.
                    //
                    // Assign only on a real change. SwiftData dirties a record
                    // when a property is set even to its existing value, and a
                    // dirtied record is saved and exported to CloudKit — so the
                    // launch echo, which re-states the SGF verbatim, used to
                    // push an identical record to iCloud on every cold launch.
                    if gameRecord.sgf != sgfString {
                        gameRecord.sgf = sgfString
                    }
                    if gameRecord.currentIndex != currentIndex {
                        gameRecord.currentIndex = currentIndex
                    }
                    gameRecord.lastModificationDate = Date.now
                    gobanState.maybeUpdateMoves(gameRecord: gameRecord, board: board, sgfHelper: sgfHelper)
                }
            }
        }
    }

    func postProcessAIMove(
        message: String,
        navigationContext: NavigationContext,
        audioModel: AudioModel,
        aiMove: Binding<String?>
    ) {
        // A kata-search_analyze_cancellable that runs to completion prints
        // "play <vertex>" (the engine never plays it on its own board); one
        // interrupted by ANY queued line — kata-check-move, a replay burst,
        // "stop" — prints the literal "play cancelled", which the vertex
        // regex below ignores. A completed reply can still arrive stale:
        // while the session is a spectator or paused (suppressesGenMove),
        // replaying (isAutoPlaying — the wand's command burst cancelled the
        // in-flight gen-move, and a stray reply would truncate the record
        // via the editing path), or a user pick is mid-legality-check
        // (pendingMoveTurn set), it must not be played into the record.
        // shouldGenMove forbids issuing gen-moves in all three states, so no
        // legitimate reply is ever dropped here.
        // The tvOS broadcast licenses exactly ONE gen-move reply through the
        // suppression guard (suppressesGenMove stays true for its whole
        // lifetime). The license is consumed on ANY "play " line — including
        // "play cancelled" — even when a later guard drops it: the broadcast
        // re-issues per cycle, and a stale license must never leak a future
        // stray reply through. The license also auto-confirms an overwrite:
        // a paused-interactive Undo rewinds currentIndex while the demo
        // record's SGF keeps the undone move, so the resumed cycle's reply
        // lands mid-record — and no tvOS view renders the confirmation
        // dialog, so latching confirmingAIOverwrite would spend the license
        // with no move, no turn toggle, and the broadcast parked in
        // .awaitingMove forever. playAIMove's editing path truncates the
        // stale tail (clearData + printsgf) — the same call the iOS
        // "Overwrite" button makes.
        let broadcastLicensed = gobanState.broadcastGenMovePending
        gobanState.broadcastGenMovePending = false
        guard broadcastLicensed || !gobanState.suppressesGenMove,
              !gobanState.isAutoPlaying,
              gobanState.pendingMoveTurn == nil else { return }

        let pattern = /play (pass|\w+\d+)/
        if let match = message.firstMatch(of: pattern),
           let turn = player.nextColorSymbolForPlayCommand {
            let move = String(match.1)
            aiMove.wrappedValue = move
            if let gameRecord = navigationContext.selectedGameRecord {
                if gobanState.isOverwriting(gameRecord: gameRecord), !broadcastLicensed {
                    gobanState.confirmingAIOverwrite = true
                } else {
                    gobanState.playAIMove(
                        aiMove: aiMove.wrappedValue,
                        gameRecord: gameRecord,
                        turn: turn,
                        analysis: analysis,
                        board: board,
                        stones: stones,
                        messageList: messageList,
                        player: player,
                        audioModel: audioModel
                    )

                    // Advance book for AI move
                    if let point = BoardPoint(move: move, width: Int(board.width), height: Int(board.height)) {
                        withAnimation {
                            bookLookup.advanceMove(
                                appPoint: point,
                                boardWidth: Int(board.width),
                                boardHeight: Int(board.height)
                            )
                        }
                    }
                }
            }
        }
    }

    func maybeCollectPlay(
        message: String,
        navigationContext: NavigationContext,
        audioModel: AudioModel,
        aiMove: Binding<String?>
    ) {
        let playPrefix = "play "
        if message.hasPrefix(playPrefix) {
            postProcessAIMove(
                message: message,
                navigationContext: navigationContext,
                audioModel: audioModel,
                aiMove: aiMove
            )
        }
    }

    func maybeCollectCheckMove(
        message: String,
        navigationContext: NavigationContext,
        audioModel: AudioModel
    ) {
        guard gobanState.pendingMoveTurn != nil else { return }
        guard message.hasPrefix("= {") else { return }

        let jsonString = String(message.dropFirst(2))
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return  // Malformed JSON — not our response
        }

        // The "isLegal" key uniquely identifies kata-check-move responses.
        // Other JSON-returning GTP commands do not include this key:
        //   - kata-get-rules returns rule fields (ko, scoring, tax, etc.)
        //   - kata-get-params returns search parameter fields
        //   - kata-get-models returns a JSON array ("= ["), not an object
        // The vertex/color validation below further guards against any
        // hypothetical future command that might include an "isLegal" key.
        guard let isLegal = json["isLegal"] as? Bool else {
            return  // Different JSON command response — leave pending state intact
        }

        // Validate that vertex and color match the pending move to avoid consuming stale responses
        // Compare case-insensitively: Swift stores "b"/"w", C++ returns "B"/"W"
        let vertex = json["vertex"] as? String
        let color = json["color"] as? String
        guard vertex?.lowercased() == gobanState.pendingMoveVertex?.lowercased(),
              color?.lowercased() == gobanState.pendingMoveTurn?.lowercased() else {
            return  // Stale or mismatched response
        }

        if isLegal {
            if let gameRecord = navigationContext.selectedGameRecord {
                // Capture move info for book tracking before clearPendingMove()
                let moveVertex = gobanState.pendingMoveVertex
                gobanState.playPendingHumanMove(
                    gameRecord: gameRecord,
                    analysis: analysis,
                    board: board,
                    stones: stones,
                    messageList: messageList,
                    player: player,
                    audioModel: audioModel
                )

                // Advance book for the played move
                if let move = moveVertex,
                   let point = BoardPoint(move: move, width: Int(board.width), height: Int(board.height)) {
                    withAnimation {
                        bookLookup.advanceMove(
                            appPoint: point,
                            boardWidth: Int(board.width),
                            boardHeight: Int(board.height)
                        )
                    }
                }
            } else {
                gobanState.clearPendingMove()
            }
        } else {
            let reason = json["reason"] as? String
            // Only show "Play Anyway" dialog for rule-based illegalities where
            // overriding makes sense. For occupied/out_of_bounds/wrong_turn,
            // the engine would reject the play command anyway.
            if reason == "ko" || reason == "superko" || reason == "suicide" {
                gobanState.illegalMoveReason = reason
                gobanState.confirmingIllegalMove = true
            } else {
                gobanState.clearPendingMove()
            }
        }
    }
}
