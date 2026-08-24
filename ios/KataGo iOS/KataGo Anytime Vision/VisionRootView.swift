//
//  VisionRootView.swift
//  KataGo Anytime Vision
//
//  Always-alive root of the volume: owns the GameSession, the engine boot
//  sequence, the GTP run loop, and the analysis-stop lifecycle (like
//  TVRootView on tvOS — there is no per-game host controller on visionOS).
//

import OSLog
import SwiftUI
import SwiftData
import GameController
import WidgetKit
import KataGoUICore
import KataGoGameStore

private let recoveryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "KataGo Vision",
    category: "engine.recovery"
)

struct VisionRootView: View {
    @State private var session = GameSession()
    @State private var engineLifecycle = EngineLifecycle()
    @State private var engineController = VisionEngineController()
    @State private var modelSelection = ModelSelectionStore()
    @State private var cacheReadiness = CoreMLCacheReadiness()
    @State private var shell = VisionGameShell()
    @State private var navigationContext = NavigationContext()
    @State private var audioModel = AudioModel()
    @State private var aiMove: String? = nil
    @State private var ghost = GhostCursorModel()
    @State private var sceneModel = VisionBoardSceneModel()
    @State private var controllerInput = VisionControllerInput()
    @State private var deepLinkRouter = DeepLinkRouter()

    @Environment(\.modelContext) private var modelContext
    @Environment(EngineLaunchStatus.self) private var engineLaunchStatus
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse)
    private var gameRecords: [GameRecord]

    var body: some View {
        // Independently type-checked pieces — the combined ~380-line
        // modifier chain blew the compiler's expression budget once the
        // stone-animation hooks landed.
        captureSoundHooks(engineEventHooks(bootChrome))
    }

    /// What the volume draws and what it lets the user drive, at this engine
    /// availability. The shared rule (`VisionEngineChrome`) so the boot, every
    /// restart and every failure answer it identically — and so a regression
    /// that puts a loading screen back in front of the goban fails a test.
    ///
    /// `.unsupportedBoard` is the one genuine gate left (no bundled asset for
    /// that size, so nothing CAN be drawn). A board that renders but is larger
    /// than the engine's NN buffer is *Held* — drawn, with the status saying
    /// why analysis is off.
    private var chrome: VisionEngineChrome {
        let renderable: Bool
        if case .unsupportedBoard = shell.phase { renderable = false } else { renderable = true }
        return VisionEngineChrome.make(
            hasMountedGame: navigationContext.selectedGameRecord != nil,
            isGeometryRenderable: renderable,
            availability: session.engineStatus.availability)
    }

    /// Whether the goban is on screen — for as long as a game is mounted and
    /// its geometry is renderable, through boot, the model chooser, every
    /// restart and every failure.
    private var isBoardMounted: Bool { chrome.showsBoard }

    /// The volumetric content, every ornament, and the boot/run-loop
    /// infrastructure.
    private var bootChrome: some View {
        Group {
            if isBoardMounted {
                readyContent
            } else {
                Color.clear
            }
        }
        // Volumetric scenes are fixed-scale (~1360 pt/m); the window adopts
        // this size via .contentSize. See VisionVolumeMetrics for why
        // 0.9 x 0.95 x 0.9 m (a 37x37 board must fit both orientations).
        .frame(width: VisionVolumeMetrics.widthPoints,
               height: VisionVolumeMetrics.heightPoints)
        .frame(depth: VisionVolumeMetrics.depthPoints)
        // The Info.plist's GCSupportsControllerUserInteraction otherwise
        // makes visionOS convert controller button presses into pinches on
        // the gazed-at view (GCEventInteraction semantics), so presses died
        // whenever gaze rested on anything interactive. Claim gamepad events
        // for VisionControllerInput's handlers instead — here and on every
        // ornament content root (ornaments are separately hosted
        // hierarchies, so the root application alone may not cover them).
        .handlesGameControllerEvents(matching: .gamepad)
        // Engine status and the branch cards live in a front-anchored glass
        // ornament: plain 2D content inside a volumetric window lies flat on
        // the base plate, where it is unreadable (nearly edge-on and unlit) —
        // ornaments always face the viewer, like the settings card. It sits
        // OVER the goban; it never replaces it.
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 0.5, y: 0.55, z: 1)),
                  contentAlignment: .center) {
            Group {
                switch shell.phase {
                case .booting, .ready:
                    // The whole branch chooser/confirm flow renders HERE as
                    // glass cards (never as .confirmationDialog — an
                    // ornament-hosted dialog's button dismissal blanks the
                    // volume's render tree; see VisionControlOrnament). The
                    // flags have no isPresented binding, so every action
                    // clears them explicitly.
                    if session.gobanState.confirmingBranchDeactivation {
                        VisionBranchChooserCard(
                            onReplace: {
                                session.gobanState.confirmingBranchDeactivation = false
                                session.gobanState.confirmingBranchReplace = true
                            },
                            onDiscard: {
                                session.gobanState.confirmingBranchDeactivation = false
                                session.gobanState.confirmingBranchDiscard = true
                            },
                            onCancel: {
                                session.gobanState.confirmingBranchDeactivation = false
                            })
                    } else if session.gobanState.confirmingBranchReplace {
                        VisionBranchConfirmCard(
                            confirm: .make(kind: .replace),
                            onConfirm: {
                                session.gobanState.confirmingBranchReplace = false
                                if let gameRecord = navigationContext.selectedGameRecord {
                                    session.gobanState.commitBranch(gameRecord: gameRecord)
                                } else {
                                    // No game to replace (unreachable in practice):
                                    // exit branch mode anyway so confirming never
                                    // leaves the branch stuck, mirroring Discard.
                                    session.gobanState.deactivateBranch()
                                }
                            },
                            onCancel: {
                                session.gobanState.confirmingBranchReplace = false
                            })
                    } else if session.gobanState.confirmingBranchDiscard {
                        VisionBranchConfirmCard(
                            confirm: .make(kind: .discard),
                            onConfirm: {
                                session.gobanState.confirmingBranchDiscard = false
                                session.gobanState.deactivateBranch()
                            },
                            onCancel: {
                                session.gobanState.confirmingBranchDiscard = false
                            })
                    } else {
                        // Launching only (ADR 0010): the transient wait, with
                        // the compile caption when a compile is genuinely
                        // running. The resting states — Failed, Held, the
                        // built-in-fallback note — surface through the
                        // sparkle's badge and the Models card's status header
                        // instead of covering the goban.
                        engineStatusCard
                    }
                case .choosingModel:
                    // iOS picker design: a surviving load sentinel defers the
                    // launch to the user. The regular Models card doubles as
                    // the chooser (neutral — no crash wording, no marked rows);
                    // picking a net boots it.
                    VisionModelsOrnament(engine: engineController,
                                         readiness: cacheReadiness,
                                         engineStatus: session.engineStatus,
                                         launchStatus: engineLaunchStatus,
                                         board: session.board,
                                         isBootChooser: true,
                                         onActivate: { model in
                                             // Dismiss the chooser. The board is
                                             // already up behind it (the resolver
                                             // ran before this card appeared), so
                                             // this is `.ready` unless there was
                                             // nothing to mount.
                                             shell.phase = isBoardMounted ? .ready : .booting
                                             launchEngine(model: model)
                                         },
                                         onDismiss: {})
                case .unsupportedBoard(let width, let height):
                    unsupportedBoardView(width: width, height: height)
                        .frame(width: 460)
                        .padding(20)
                        .glassBackgroundEffect()
                }
            }
            // Ornaments are separately hosted hierarchies — claim gamepad
            // events on each content root too (see the root modifier).
            .handlesGameControllerEvents(matching: .gamepad)
        }
        // Up for as long as the board is. The ornament disables its own
        // command-SENDING controls while the engine is unavailable (the
        // sparkle, the Human/AI chips); Games, the lock slot and the two cards
        // it opens are engine-free and stay live — navigation never waits.
        .ornament(attachmentAnchor: .scene(.bottomFront), contentAlignment: .center) {
            if isBoardMounted {
                VisionControlOrnament(
                    session: session,
                    isEngineReady: chrome.allowsEngineCommands,
                    shell: shell,
                    controllerInput: controllerInput,
                    navigationContext: navigationContext,
                    onSparkle: { sparkleAnalysisAction() },
                    onOpenModels: {
                        // The tap said "I want analysis": remember it, so a
                        // model activated from this open arms a cleared
                        // preference (ADR 0010; the flag expires with the
                        // card).
                        shell.modelsPresentedFromAnalysisControl = true
                        shell.presentModels()
                    },
                    onToggleAI: { toggleAI(for: $0) },
                    onDismissIllegalMove: {
                        session.gobanState.confirmingIllegalMove = false
                        session.gobanState.clearPendingMove()
                    }
                )
                .handlesGameControllerEvents(matching: .gamepad)
            }
        }
        // Settings and the controller legend share the right anchor — one
        // closure, settings first, and the shell's toggle helpers keep the
        // flags mutually exclusive.
        //
        // None of these waits for the engine, and the Models card in particular
        // MUST NOT: it is where a failed launch is retried and where another net
        // is chosen. The one control in here that touches a running engine —
        // the model detail's Max Board Size picker — gates itself on
        // `engine.canRestartNow` (VisionBoardSizeSetting.pickerDisabled).
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 1, y: 0.5, z: 1)),
                  contentAlignment: .leading) {
            Group {
                if shell.showingSettings {
                    VisionSettingsOrnament(shell: shell,
                                           engine: engineController,
                                           onShowModels: { shell.presentModels() },
                                           onShowLicenses: { shell.presentLicenses() },
                                           onDismiss: { shell.showingSettings = false })
                } else if shell.showingLicenses {
                    VisionLicensesOrnament(onDismiss: { shell.showingLicenses = false })
                } else if shell.showingModels {
                    VisionModelsOrnament(engine: engineController,
                                         readiness: cacheReadiness,
                                         engineStatus: session.engineStatus,
                                         launchStatus: engineLaunchStatus,
                                         board: session.board,
                                         onActivate: { activateModel($0) },
                                         onMaxBoardSizeRestart: { restartEngineForMaxBoardSize() },
                                         onDismiss: { shell.showingModels = false })
                } else if shell.showingControllerHelp {
                    VisionControllerLegend {
                        shell.showingControllerHelp = false
                    }
                } else if shell.showingNewGamePanel {
                    VisionNewGamePanel(
                        maxBoardLength: engineController.maxBoardLength,
                        // Creating a game is a command-sender, and it is sized
                        // by a buffer a launching engine has not settled yet.
                        // Only the Create button is gated — a card whose close
                        // button was disabled with it could not be dismissed —
                        // and Held is deliberately allowed through: a smaller
                        // board is the way out of a hold.
                        canCreateGame: chrome.allowsNewGame,
                        onCreate: { width, height in
                            shell.showingNewGamePanel = false
                            startNewGame(width: width, height: height)
                        },
                        onDismiss: { shell.showingNewGamePanel = false })
                }
            }
            .handlesGameControllerEvents(matching: .gamepad)
        }
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 0, y: 0.5, z: 1)),
                  contentAlignment: .trailing) {
            if shell.showingGameList {
                // Opening a game is navigation: it needs no engine, so the list
                // stays live through a launch. Only its New Game menu is gated,
                // for the same reason the Custom panel's Create is.
                VisionGameListOrnament(
                    gameRecords: gameRecords,
                    canCreateGame: chrome.allowsNewGame,
                    maxBoardLength: engineController.maxBoardLength,
                    modelBoardCap: engineController.activeModel.nnLen,
                    navigationContext: navigationContext,
                    onOpenGame: { openGame($0) },
                    onNewGame: { startNewGame(size: $0) },
                    onCustomGame: { shell.toggleNewGamePanel() },
                    onDeleteGames: { deleteGames(ids: $0) },
                    onDismiss: { shell.showingGameList = false }
                )
                .handlesGameControllerEvents(matching: .gamepad)
            }
        }
        .onChange(of: controllerInput.isConnected) { _, connected in
            if !connected {
                ghost.reset()
            } else if !shell.hasAutoShownControllerHelp {
                // First controller of this run: teach the mapping once.
                shell.hasAutoShownControllerHelp = true
                shell.presentControllerHelp()
            }
        }
        .onAppear {
            engineController.configure(session: session,
                                       engineLifecycle: engineLifecycle,
                                       modelSelection: modelSelection,
                                       navigationContext: navigationContext)
            // Resolve the boot model BEFORE startInitial arms the crash
            // sentinel — the resolver must see the PREVIOUS run's sentinel,
            // not this run's (iOS ModelRunnerView / Mac decideRecovery
            // ordering).
            #if DEBUG
            let isDebug = true
            #else
            let isDebug = false
            #endif
            let resolution = VisionModelBootResolver.resolve(
                pendingLoadModelTitle: modelSelection.pendingLoadModelTitle,
                selectedModelTitle: modelSelection.selectedModelTitle,
                isDebug: isDebug,
                isFileDownloaded: { model in
                    guard let url = model.downloadedURL else { return false }
                    return FileManager.default.fileExists(atPath: url.path)
                })
            switch resolution {
            case .boot(let model):
                launchEngine(model: model)
            case .chooseModel:
                // A surviving load sentinel: iOS picker design — no engine
                // until the user picks from the Models chooser (auto-
                // restoring a net whose load just crashed would loop).
                recoveryLogger.error(
                    "Previous launch did not finish loading model: \(modelSelection.pendingLoadModelTitle, privacy: .public). Presenting the model chooser."
                )
                // The board comes up anyway, behind the chooser: it needs no
                // engine, and a volume showing nothing at all would be a worse
                // answer to "which net?" than one showing the user's game.
                // The volume gate reads the SELECTION, not the phase, so
                // `.choosingModel` can own the front ornament regardless — and
                // it must: the chooser is the only way to get an engine at all.
                // A record the volume cannot draw leaves the selection nil (the
                // resolver never mounts it), so the goban simply stays empty.
                resolveAndMountCurrentGame()
                shell.phase = .choosingModel
                // Absent, not Launching: nothing is loading until the user picks.
                session.endEngineSession(.absent)
            }
            // The chooser's green cache-ready checkmarks need this before
            // any engine exists (idempotent; engine-independent).
            Task { await cacheReadiness.start() }
            controllerInput.onEvent = { handleControllerEvent($0) }
            // Scene-driven sound (gobanState.soundEffect stays false here):
            // the scene model cues both the click and the capture rattle at
            // the stone's landing.
            sceneModel.playStoneSound = { audioModel.playPlaySound(soundEffect: true) }
            sceneModel.playCaptureSound = { audioModel.playCaptureSound(soundEffect: true) }
        }
        // The GTP read loop — parses board/analysis lines into the models.
        // Must not run concurrently with the handshake (the bridge's sole
        // reader), so it arms only once the FIRST handshake has landed.
        //
        // Keyed on a generation that bumps exactly once, so a restart does not
        // re-key (and therefore cancel) this task: `session.run` exits on
        // `stopRequested`, and `noteRunLoopExited` parks this loop until the
        // restarted engine's handshake completes (without the park, the exited
        // `run` would busy-spin here).
        .task(id: engineController.readLoopGeneration) {
            guard engineController.readLoopGeneration > 0 else { return }
            while !Task.isCancelled {
                await session.run(gameRecords: gameRecords,
                                  modelContext: modelContext,
                                  navigationContext: navigationContext,
                                  audioModel: audioModel,
                                  aiMove: $aiMove)
                await engineController.noteRunLoopExited()
            }
        }
    }

    /// Engine and gameplay event hooks: analysis lifecycle, the per-move
    /// engine driver, stone-animation intents, and the ghost anchor.
    private func engineEventHooks(_ content: some View) -> some View {
        content
        // Analysis stop lifecycle (mirrors TVRootView): without these the
        // engine would keep streaming kata-analyze after analysis turns off,
        // and the power-saving pause could never halt the search.
        .onChange(of: session.gobanState.analysisStatus) { _, newValue in
            if newValue == .clear {
                session.messageList.appendAndSend(command: "stop")
            }
        }
        .onChange(of: session.gobanState.waitingForAnalysis) { oldValue, newValue in
            // Stop half of the analysis lifecycle: when a freshly-armed wait
            // resolves (first info line) while the user has paused or
            // power-saving hides the overlay, halt the stream.
            guard oldValue, !newValue else { return }
            let powerHidden = navigationContext.selectedGameRecord.map {
                session.gobanState.isAnalysisHiddenForPowerSaving(
                    config: $0.concreteConfig,
                    nextColorForPlayCommand: session.player.nextColorForPlayCommand)
            } ?? false
            if session.gobanState.analysisStatus == .pause || powerHidden {
                session.messageList.appendAndSend(command: "stop")
            }
        }
        // THE per-move engine driver (mirrors BoardView's turn-change hook,
        // which never mounts on Vision): every play/undo toggles the turn;
        // re-establish the side-to-move's human-SL profile, then request
        // either the gen-move bundle (AI's turn — the auto-reply) or the next
        // continuous kata-analyze stream (the post-move analysis restart),
        // and clear stale overlay data when nothing will stream.
        .onChange(of: session.player.nextColorForPlayCommand) { oldValue, newValue in
            guard oldValue != newValue,
                  let config = navigationContext.selectedGameRecord?.concreteConfig
            else { return }
            session.gobanState.handleTurnChange(to: newValue,
                                                config: config,
                                                messageList: session.messageList)
        }
        // Stone-animation intent hooks — rationale on each method.
        .onChange(of: aiMove) { _, newValue in
            captureAIMoveIntent(newValue)
        }
        .onChange(of: session.gobanState.confirmingAIOverwrite) { _, confirming in
            autoDeclineAIOverwrite(confirming)
        }
        .onChange(of: session.gobanState.confirmingIllegalMove) { _, confirming in
            retractRejectedPlayIntent(confirming)
        }
        // 2D boards clear stale candidates in AnalysisView.onAppear; the 3D
        // scene has no such lifecycle hook, so honor the request here.
        .onChange(of: session.gobanState.requestingClearAnalysis) { _, requesting in
            if requesting {
                session.analysis.clear()
                session.gobanState.requestingClearAnalysis = false
            }
        }
        // Settings-card writes land on the shell (which persists them);
        // mirror into gobanState, which is what the scene reads.
        .onChange(of: shell.analysisInformation) { _, newValue in
            session.gobanState.analysisInformation = newValue
        }
        .onChange(of: shell.showOwnership) { _, newValue in
            session.gobanState.showOwnership = newValue
        }
        // Persist the last-good selection and clear the crash sentinel once
        // the handshake's first GTP reply lands (iOS ModelRunnerView parity).
        // One observer serves boot, model switches, and Max-Board-Size
        // restarts — the handshake title is always the engine's activeModel.
        .onChange(of: engineLifecycle.lastLoadedModelTitle) { _, newValue in
            guard let newValue else { return }
            modelSelection.selectedModelTitle = newValue
            modelSelection.pendingLoadModelTitle = ""
        }
        // Branch-end reload (iOS GameSplitView / Mac branch-observer parity):
        // when Replace/Discard deactivates the branch, remount the selected
        // game so the board leaves the branch line. switchGame lands at the
        // tip — deliberate on Vision (one consistent landing spot, unlike
        // iOS's divergence-point landing; L1/R1 step through history from
        // there) —
        // and loadGame consumes commitBranch's one-shot unlockEditingOnReload,
        // so Replace lands unlocked. Game switches that discard a branch via
        // loadGame's own deactivateBranch re-enter switchGame once more here;
        // idempotent, same accepted double-reload as iOS/Mac.
        .onChange(of: session.gobanState.branchSgf) { oldValue, newValue in
            guard oldValue.isActiveSgf, !newValue.isActiveSgf,
                  isBoardMounted,
                  let record = navigationContext.selectedGameRecord
            else { return }
            switchGame(to: record)
        }
        // Ghost anchor: reveal (and follow) the cursor at the board's last
        // move — players expect to answer near it. Keyed on the exact inputs
        // of MoveNumbers.derive so passes and step/jump navigation retrigger even
        // though the stones don't change; the O(moves) SGF walk runs once per
        // position, never on the glide frame path. (Not getMoveNumbers — it
        // returns .empty under the last-3-moves display setting.)
        .onChange(of: lastMoveKey, initial: true) { _, newValue in
            let lastPoint = newValue?.lastPoint
            #if DEBUG
            NSLog("VisionAnchor index=%@ lastPoint=%@ sgfLen=%@",
                  newValue.map { String($0.index) } ?? "nil",
                  lastPoint.map { "(\($0.x),\($0.y))" } ?? "nil",
                  newValue.map { String($0.sgf.count) } ?? "nil")
            #endif
            ghost.setAnchor(lastPoint,
                            width: Int(session.board.width),
                            height: Int(session.board.height))
        }
        // The board is record-owned: publish the position the record holds and
        // persist it into that record. The Saved Game widget renders
        // blackStones/whiteStones[currentIndex]; without this hook a game
        // played on Vision has empty stone dictionaries and its widget shows
        // a bare board. Engine-free — it no longer waits for a showboard.
        .recordPositionSync(session: session,
                            gameRecord: navigationContext.selectedGameRecord) { position, key in
            guard let key, let gameRecord = navigationContext.selectedGameRecord else { return }
            RecordStoneCache.write(position: position, key: key, into: gameRecord)
        }
        // Widget/URL taps. Latch only open-game links (visionOS has no SGF
        // import or Messages spool) and funnel every delivery window through
        // applyPendingDeepLink: this onChange is the warm path; the boot
        // resolver consumes the latch on a cold launch; and the post-ready
        // drain in initializationTask covers a mid-boot delivery.
        .onOpenURL { url in
            #if DEBUG
            NSLog("VisionDeepLink onOpenURL url=%@ parsed=%@",
                  url.absoluteString,
                  GameDeepLink.gameID(from: url)?.uuidString ?? "nil")
            #endif
            guard let id = GameDeepLink.gameID(from: url) else { return }
            deepLinkRouter.pendingGameID = id
        }
        .onChange(of: deepLinkRouter.pendingGameID) { _, newValue in
            guard newValue != nil else { return }
            applyPendingDeepLink()
        }
    }

    /// Capture rattle (BoardView's capture-count observers, which never
    /// mount on Vision) — a capturing move plays this on top of the scene's
    /// landing click, iOS-style. Detection stays count-driven, so R2 jumps
    /// over captures rattle too, but the TIMING is handed to the scene: these
    /// counters move at showboard-parse time, a whole flight before the
    /// capturing stone touches the board, so playing here would rattle before
    /// the stone was placed. `noteCapture` holds it until the landing.
    private func captureSoundHooks(_ content: some View) -> some View {
        content
        .onChange(of: session.stones.blackStonesCaptured) { oldValue, newValue in
            if oldValue < newValue {
                sceneModel.noteCapture()
            }
        }
        .onChange(of: session.stones.whiteStonesCaptured) { oldValue, newValue in
            if oldValue < newValue {
                sceneModel.noteCapture()
            }
        }
    }

    // MARK: - Ghost anchor

    /// Branch-aware last-move derivation inputs; reading them in body keeps
    /// the onChange armed for own moves, AI replies, step/jump and branch
    /// navigation, passes, and game switches.
    private var lastMoveKey: LastMoveKey? {
        let gameRecord = navigationContext.selectedGameRecord
        guard let sgf = session.gobanState.getSgf(gameRecord: gameRecord),
              let index = session.gobanState.getCurrentIndex(gameRecord: gameRecord)
        else { return nil }
        return LastMoveKey(sgf: sgf, index: index)
    }

    // MARK: - Content

    private var readyContent: some View {
        VisionBoardRealityView(session: session,
                               ghost: ghost,
                               sceneModel: sceneModel,
                               controllerInput: controllerInput,
                               shell: shell,
                               hiddenAnalysisVisitRatio:
                                navigationContext.selectedGameRecord?.concreteConfig
                                    .hiddenAnalysisVisitRatio
                                ?? Config.defaultHiddenAnalysisVisitRatio)
    }

    // MARK: - Controller events

    private func handleControllerEvent(_ event: ControllerEvent) {
        // A mounted board is all this needs. Stepping, jumping and the ghost are
        // record-owned; the two events that DO need an engine (play, pass) check
        // `stones.isReady` for themselves.
        guard isBoardMounted else { return }
        let width = Int(session.board.width)
        let height = Int(session.board.height)

        switch event {
        case .dpad(let direction):
            ghost.step(direction, width: width, height: height)
        case .toggleAnalysisVisibility:
            toggleEye()
        case .play:
            playAtGhost()
        case .undo:
            undoOneMove()
        case .forward:
            forwardOneMove()
        case .backwardToStart:
            backwardToStart()
        case .forwardToEnd:
            forwardToEnd()
        case .pass:
            // Immediate — no confirmation bar (a controller can't drive the
            // pinch-only ornament, and Undo is the safety net anyway).
            playPass()
        }
    }

    private var isAITurn: Bool {
        guard let config = navigationContext.selectedGameRecord?.concreteConfig else { return false }
        return session.gobanState.shouldGenMove(config: config, player: session.player)
    }

    private func playAtGhost() {
        #if DEBUG
        NSLog("VisionPlay ghost=%@ anchor=%@ geom=%d stonesReady=%d pending=%@ aiTurn=%d",
              ghost.point.map { "(\($0.x),\($0.y))" } ?? "nil",
              ghost.anchor.map { "(\($0.x),\($0.y))" } ?? "nil",
              sceneModel.geometry?.size ?? -1,
              session.stones.isReady ? 1 : 0,
              session.gobanState.pendingMoveTurn ?? "nil",
              isAITurn ? 1 : 0)
        #endif
        guard let point = ghost.point,
              let vertex = sceneModel.geometry?.vertex(for: point),
              let turn = session.player.nextColorSymbolForPlayCommand,
              session.stones.isReady,
              session.gobanState.pendingMoveTurn == nil,   // one pick in flight
              !isAITurn,
              !session.stones.blackPoints.contains(point),
              !session.stones.whitePoints.contains(point)
        else { return }
        // The stone about to land flies in; an illegal-move rejection leaves
        // a stale intent that the planner scavenges on the next real diff.
        sceneModel.expectStoneAnimation(.place(point))
        // Legality + play flow through the engine's kata-check-move reply
        // (GameSession.maybeCollectCheckMove → playPendingHumanMove), the same
        // path the 2D board tap and TVReviewScreen.pick use.
        session.gobanState.sendCheckMoveCommand(turn: turn,
                                                move: vertex,
                                                messageList: session.messageList)
        ghost.reset()
    }

    /// Games-picker entry point: the geometry gate, then the shared switch
    /// path. A stale printsgf reply from the old game landing after the
    /// selection swap would be written into the new record (one-reply window,
    /// identical exposure to the iOS sidebar switch) — our own printsgf
    /// self-heals the SGF, so this is accepted for v1.
    ///
    /// A board LARGER than the engine's buffer is no longer refused here: it
    /// mounts, draws, and reports *Held* (`switchGame` decides that, and shuts
    /// the command gate so the engine is never told this board exists).
    private func openGame(_ record: GameRecord) {
        guard record.persistentModelID
                != navigationContext.selectedGameRecord?.persistentModelID
        else { return }

        // Re-derive width/height from the SGF: the picker row's stored size
        // may be nil or stale, and only this gate is authoritative. There is no
        // geometry to render outside 2...37, which is the one thing the volume
        // genuinely cannot show.
        record.updateToLatestVersion()
        let config = record.concreteConfig
        guard let blocked = unsupportedPhase(width: config.boardWidth,
                                             height: config.boardHeight) else {
            switchGame(to: record)
            shell.phase = .ready
            return
        }
        // The old game stays loaded but unmounted — silence its stream.
        session.messageList.appendAndSend(command: "stop")
        shell.phase = blocked
    }

    /// Applies a latched open-game deep link through the same gated path as
    /// the Games picker. Applying is allowed from `.unsupportedBoard` too:
    /// like the picker, a widget tap must be a way out of it. Only the frames
    /// before a selection exists at all keep the latch.
    private func applyPendingDeepLink() {
        // The only thing a tap waits for is a resolved selection — never the
        // engine. `resolveAndMountCurrentGame` consumes the latch itself on a
        // cold launch, so applying before it ran would race that consumption.
        let hasSelection = navigationContext.selectedGameRecord != nil
        let disposition = VisionDeepLinkFlow.disposition(
            hasPending: deepLinkRouter.pendingGameID != nil,
            hasResolvedSelection: hasSelection)
        #if DEBUG
        NSLog("VisionDeepLink apply pending=%@ hasSelection=%d disposition=%@",
              deepLinkRouter.pendingGameID?.uuidString ?? "nil",
              hasSelection ? 1 : 0, String(describing: disposition))
        #endif
        switch disposition {
        case .nothingPending, .keepLatched:
            return
        case .apply:
            break
        }
        guard let id = deepLinkRouter.pendingGameID else { return }
        deepLinkRouter.pendingGameID = nil
        guard let match = GameRecord.resolveDeepLinkTarget(
            id: id, container: modelContext.container) else { return }
        #if DEBUG
        NSLog("VisionDeepLink openGame uuid=%@", match.uuid?.uuidString ?? "nil")
        #endif
        if match.persistentModelID
            == navigationContext.selectedGameRecord?.persistentModelID {
            // openGame's identity guard would swallow the tap. Fine when the
            // board is up — but from a blocked card (the user browsed into a
            // too-large game; the picker's blocked arm keeps the PREVIOUS game
            // selected and loaded) the tap must still be a way out: re-gate
            // and remount the selection. Same-record switchGame is the
            // branch-end reload's accepted double-reload.
            guard shell.phase != .ready else { return }
            mountReplacement(match)
            return
        }
        openGame(match)
    }

    /// The blocking phase for a board, or nil when it can mount. Only ONE
    /// thing blocks now: a size outside the renderable 2...37 range, for which
    /// no board asset exists. Size against the engine's NN buffer used to block
    /// here too; it is *Held* instead — the board draws and the status says why
    /// analysis is off.
    private func unsupportedPhase(width: Int, height: Int) -> VisionGameShell.Phase? {
        guard visionBoardIsSupported(width: width, height: height) else {
            return .unsupportedBoard(width: width, height: height)
        }
        return nil
    }

    private func startNewGame(size: Int) {
        startNewGame(width: size, height: size)
    }

    /// Games-list deletion (single or bulk). The replacement is decided and
    /// MOUNTED before anything dies: the doomed open game must stay alive
    /// until the new one is loaded (the Mac dangling-record pitfall) — only
    /// then bulkDelete. Fallout order rides the root @Query's reverse
    /// lastModificationDate sort (the same "newest" boot's fetch resolves).
    private func deleteGames(ids: Set<PersistentIdentifier>) {
        switch VisionGameDeleteFlow.fallout(
            orderedNewestFirst: gameRecords.map(\.persistentModelID),
            deleting: ids,
            currentID: navigationContext.selectedGameRecord?.persistentModelID) {
        case .keepCurrent:
            break
        case .switchTo(let id):
            if let replacement = gameRecords.first(
                where: { $0.persistentModelID == id }) {
                mountReplacement(replacement)
            } else {
                // The fallout ID came from gameRecords, so this is
                // unreachable in practice — but never risk leaving a doomed
                // record mounted.
                createAndMountFreshGame()
            }
        case .createFresh:
            createAndMountFreshGame()
        }
        _ = modelContext.bulkDelete(gameIDs: ids)
        // A widget configured for a deleted game must fall back to
        // most-recent now, not at the next hourly reload (iOS parity).
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// openGame's gate for a replacement the user did not pick: mount when the
    /// board is renderable, else silence the stream and surface the unsupported
    /// card — clearing the selection first, so the doomed record is never left
    /// selected (the Games list stays up as the way out).
    private func mountReplacement(_ record: GameRecord) {
        record.updateToLatestVersion()
        let config = record.concreteConfig
        if let blocked = unsupportedPhase(width: config.boardWidth,
                                          height: config.boardHeight) {
            session.messageList.appendAndSend(command: "stop")
            navigationContext.selectedGameRecord = nil
            shell.phase = blocked
            // Nothing is selected any more, so nothing can be "too large":
            // release a Held left over from the record that just went away.
            engineController.applyHeldStatus()
            return
        }
        switchGame(to: record)
        shell.phase = .ready
    }

    /// Deleting the whole library: create and mount a fresh game sized to
    /// the engine buffer (resolveAndMountCurrentGame's create arm — always
    /// mountable, no gate needed).
    private func createAndMountFreshGame() {
        let created = GameRecord.createGameRecord(
            maxBoardLength: engineController.maxBoardLength)
        modelContext.insert(created)
        try? modelContext.save()
        switchGame(to: created)
        shell.phase = .ready
    }

    /// Any width x height in 2...cap (the Custom panel's steppers enforce the
    /// bounds; the quick 9/13/19 buttons disable above the cap). Default komi
    /// and rules (ADR 0001) — the square path produces makeDefaultSgf
    /// byte-for-byte.
    private func startNewGame(width: Int, height: Int) {
        let record = GameRecord.createGameRecord(
            sgf: GameRecord.makeSgf(width: width, height: height, komi: Config.defaultKomi,
                                    ruleString: GameRecord.defaultRuleString))
        modelContext.insert(record)
        try? modelContext.save()

        // A game the user just created is theirs to edit. editingAfterLoad
        // only auto-unlocks the 19x19 defaultSgf, so a fresh 9x9/13x13 would
        // land LOCKED and its plays would branch-route — never persisting
        // (they vanished on relaunch). The one-shot unlock seam is exactly
        // for a reload that should land unlocked; loadGame consumes it.
        session.gobanState.unlockEditingOnReload = true
        switchGame(to: record)
        shell.phase = .ready
    }

    private func playPass() {
        guard let turn = session.player.nextColorSymbolForPlayCommand,
              session.stones.isReady,
              session.gobanState.pendingMoveTurn == nil,
              !isAITurn
        else { return }
        // A pass changes no stones, so the scene-driven sound never fires
        // for it — click here instead (a pass is always legal, so the
        // kata-check-move round cannot retract this).
        audioModel.playPlaySound(soundEffect: true)
        session.gobanState.sendCheckMoveCommand(turn: turn,
                                                move: "pass",
                                                messageList: session.messageList)
        ghost.reset()
    }

    /// Flip a side between Human and AI from its ornament chip (same seam as
    /// the iOS captured-stone-capsule tap): writes the live Config, replaces
    /// the human-SL bundle, and re-arms analysis so enabling the side to move
    /// gen-moves immediately.
    private func toggleAI(for color: PlayerColor) {
        guard let config = navigationContext.selectedGameRecord?.concreteConfig else { return }
        switch color {
        case .black:
            ConfigEngineSync.setBlackMaxTime(config.toggledMaxTime(for: .black),
                                             config: config,
                                             gobanState: session.gobanState,
                                             player: session.player,
                                             messageList: session.messageList)
        case .white:
            ConfigEngineSync.setWhiteMaxTime(config.toggledMaxTime(for: .white),
                                             config: config,
                                             gobanState: session.gobanState,
                                             player: session.player,
                                             messageList: session.messageList)
        case .unknown:
            break
        }
    }

    /// Eye = overlay VISIBILITY only (never touches analysisStatus). Its only
    /// engine side effect is the power-saving pause/resume, exactly like the
    /// iOS eye (GameSplitView's eye-status handler).
    private func toggleEye() {
        session.gobanState.eyeStatus =
            session.gobanState.eyeStatus == .opened ? .closed : .opened
        guard let config = navigationContext.selectedGameRecord?.concreteConfig else { return }
        if session.gobanState.eyeStatus == .opened {
            if session.gobanState.analysisStatus == .run,
               !session.gobanState.shouldGenMove(config: config, player: session.player) {
                session.gobanState.maybeRequestAnalysis(
                    config: config,
                    nextColorForPlayCommand: session.player.nextColorForPlayCommand,
                    messageList: session.messageList)
            }
        } else {
            session.gobanState.maybeStopAnalysisForPowerSaving(
                config: config,
                nextColorForPlayCommand: session.player.nextColorForPlayCommand)
        }
    }

    /// Ported from the iOS toolbar's sparkle button: cycles the analysis
    /// ENGINE state — run → pause → off → run. (The eye only hides it.)
    private func sparkleAnalysisAction() {
        switch session.gobanState.analysisStatus {
        case .run:
            session.gobanState.maybePauseAnalysis()
        case .pause:
            withAnimation {
                session.gobanState.analysisStatus = .clear
            }
        case .clear:
            session.gobanState.analysisStatus = .run
            // Measure visits/s from this enable point so the prior pause
            // doesn't drag the displayed rate down.
            session.analysis.resetVisitsPerSecondSession()
            guard let config = navigationContext.selectedGameRecord?.concreteConfig else { return }
            session.gobanState.maybeRequestAnalysis(
                config: config,
                nextColorForPlayCommand: session.player.nextColorForPlayCommand,
                messageList: session.messageList)
        }
    }

    /// Mirrors StatusToolbarItems.backwardFrameAction.
    private func undoOneMove() {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        session.gobanState.maybeUpdateAnalysisData(
            gameRecord: gameRecord,
            analysis: session.analysis,
            board: session.board,
            stones: session.stones,
            all: false
        )
        // canStepBackward gates the branch floor: this path sends the engine
        // `undo` itself, so it must stop at the divergence (an ungated undo of a
        // pre-branch move desyncs board vs engine). It comes BEFORE the
        // expectStoneAnimation(.remove) derivation below — a clamped undo must
        // not enqueue a phantom remove-intent a later unrelated diff could
        // consume.
        // Deliberately NOT gated on `stones.isReady` ("the engine acknowledged
        // this position"). The cursor is record-owned: it moves whether or not
        // an engine is listening, and the `undo` this sends is dropped by the
        // gate and repaid in full by the handshake's resync. Waiting for the ack
        // would freeze X/L1 for the whole of a launch or a restart.
        guard !isAITurn,
              session.gobanState.canStepBackward(gameRecord: gameRecord) else { return }
        // The tip stone flies off (nothing to animate after a pass); derive
        // it before undoIndex moves the cursor. Same derivation as the ghost
        // anchor, so the animated point always matches the mounted stone.
        if let sgf = session.gobanState.getSgf(gameRecord: gameRecord),
           let index = session.gobanState.getCurrentIndex(gameRecord: gameRecord),
           let tip = MoveNumbers.derive(sgf: sgf, currentIndex: index).lastPoint {
            sceneModel.expectStoneAnimation(.remove(tip))
        }
        session.gobanState.undoIndex(gameRecord: gameRecord)
        session.gobanState.undo(messageList: session.messageList, stones: session.stones)
        session.player.toggleNextColorForPlayCommand()
        session.gobanState.sendShowBoardCommand(messageList: session.messageList)
    }

    /// Mirrors StatusToolbarItems.forwardFrameAction (maybeForwardMoves with
    /// limit 1). forwardMoves sends the post-execution commands itself — the
    /// iOS asymmetry (backward never requests analysis, forward does) is
    /// kept, and the turn-change hook re-arms analysis on the toggle either
    /// way. At the tip it re-sends those commands and moves nothing.
    private func forwardOneMove() {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        session.gobanState.maybeUpdateAnalysisData(
            gameRecord: gameRecord,
            analysis: session.analysis,
            board: session.board,
            stones: session.stones,
            all: false
        )
        // Engine-free, exactly like the undo above.
        guard !isAITurn else { return }
        // The recorded next stone flies in; stepping over a pass diffs no
        // stone, so its click plays here (the commit-time sound it had).
        if let next = session.gobanState.getNextMove(gameRecord: gameRecord) {
            if next.location.pass {
                audioModel.playPlaySound(soundEffect: true)
            } else {
                sceneModel.expectStoneAnimation(.place(
                    BoardPoint(location: next.location,
                               width: Int(session.board.width),
                               height: Int(session.board.height))))
            }
        }
        session.gobanState.forwardMoves(limit: 1,
                                        gameRecord: gameRecord,
                                        board: session.board,
                                        messageList: session.messageList,
                                        player: session.player,
                                        audioModel: audioModel,
                                        stones: session.stones)
    }

    /// AI reply → fly-in intent, then consume the binding (onChange never
    /// fires for equal consecutive values, and the AI can reply with the
    /// same vertex in a later position). postProcessAIMove writes the
    /// binding at command time, before its showboard reply diffs the
    /// stones, so the intent always precedes the diff. Skipped when the
    /// reply was never played: the overwrite path latches
    /// confirmingAIOverwrite (still latched here — autoDeclineAIOverwrite
    /// resets it a runloop later), and nothing plays without a selected
    /// record. NB: BoardPoint(move: "pass") yields the off-board pass
    /// SENTINEL, not nil — the explicit pass check is required.
    private func captureAIMoveIntent(_ newValue: String?) {
        guard let move = newValue else { return }
        if !session.gobanState.confirmingAIOverwrite,
           navigationContext.selectedGameRecord != nil {
            if move == "pass" {
                // An AI pass commits with no stone diff, so the scene-driven
                // sound never fires — click here (playPass covers the human
                // pass).
                audioModel.playPlaySound(soundEffect: true)
            } else if let point = BoardPoint(move: move,
                                             width: Int(session.board.width),
                                             height: Int(session.board.height)) {
                sceneModel.expectStoneAnimation(.place(point))
            }
        }
        aiMove = nil
    }

    /// Vision has no AI-overwrite confirmation dialog (iOS GameSplitView,
    /// Mac alert), so an auto-genmove landing mid-record in an unlocked
    /// game would latch the flag forever — and the controller with it,
    /// since every game action guards on !isAITurn while shouldGenMove
    /// stays true. Auto-decline exactly like the iOS Cancel button: the
    /// reply is already dropped, and analysisStatus = .clear turns gen-move
    /// off (shouldGenMove needs .run), unlocking navigation. The sparkle
    /// re-arms the AI; a human play truncates the record and makes the tip
    /// current again. The reset hops one runloop so same-transaction
    /// onChanges (the aiMove capture) still see the latched flag.
    private func autoDeclineAIOverwrite(_ confirming: Bool) {
        guard confirming else { return }
        Task { @MainActor in
            session.gobanState.confirmingAIOverwrite = false
            session.gobanState.analysisStatus = .clear
        }
    }

    /// An illegal-move rejection means playAtGhost's fly-in intent will
    /// never see its diff; withdraw it so it cannot satisfy a later,
    /// unrelated diff (e.g. an undo restoring a capture at the rejected ko
    /// point). Vision never plays rejected moves (the ornament row only
    /// dismisses), so retraction is always correct here.
    private func retractRejectedPlayIntent(_ confirming: Bool) {
        guard confirming,
              let vertex = session.gobanState.pendingMoveVertex,
              let point = BoardPoint(move: vertex,
                                     width: Int(session.board.width),
                                     height: Int(session.board.height))
        else { return }
        sceneModel.retractStoneAnimation(.place(point))
    }

    /// Mirrors StatusToolbarItems.backwardEndAction (backwardMoves, limit
    /// nil): rewinds to the starting position. backwardMoves ends with
    /// sendPostExecutionCommands, so the board refreshes and analysis
    /// re-arms even when an even-length rewind leaves the side to move
    /// unchanged and the turn-change hook never fires.
    private func backwardToStart() {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        session.gobanState.maybeUpdateAnalysisData(
            gameRecord: gameRecord,
            analysis: session.analysis,
            board: session.board,
            stones: session.stones,
            all: false
        )
        guard !isAITurn else { return }
        sceneModel.clearStoneAnimationIntents()
        session.gobanState.backwardMoves(limit: nil,
                                         gameRecord: gameRecord,
                                         messageList: session.messageList,
                                         player: session.player,
                                         stones: session.stones)
    }

    /// Mirrors StatusToolbarItems.forwardEndAction (forwardMoves, limit nil):
    /// replays the record to the tip. At the tip it re-sends the
    /// post-execution commands and moves nothing.
    private func forwardToEnd() {
        guard let gameRecord = navigationContext.selectedGameRecord else { return }
        session.gobanState.maybeUpdateAnalysisData(
            gameRecord: gameRecord,
            analysis: session.analysis,
            board: session.board,
            stones: session.stones,
            all: false
        )
        guard !isAITurn else { return }
        sceneModel.clearStoneAnimationIntents()
        // A jump whose remaining tail is all passes (finished games end
        // pass-pass) diffs no stones, so the scene-driven batch click never
        // fires — click here, like forwardOneMove's recorded-pass click.
        if let sgf = session.gobanState.getSgf(gameRecord: gameRecord),
           let start = session.gobanState.getCurrentIndex(gameRecord: gameRecord) {
            let sgfHelper = SgfOperations(sgf: sgf)
            var index = start
            var tailIsOnlyPasses = false
            while let move = sgfHelper.getMove(at: index) {
                guard move.location.pass else { tailIsOnlyPasses = false; break }
                tailIsOnlyPasses = true
                index += 1
            }
            if tailIsOnlyPasses {
                audioModel.playPlaySound(soundEffect: true)
            }
        }
        session.gobanState.forwardMoves(limit: nil,
                                        gameRecord: gameRecord,
                                        board: session.board,
                                        messageList: session.messageList,
                                        player: session.player,
                                        audioModel: audioModel,
                                        stones: session.stones)
    }

    private func unsupportedBoardView(width: Int, height: Int) -> some View {
        ContentUnavailableView {
            Label("Board Size Not Supported", systemImage: "cube.transparent")
        } description: {
            Text("This game uses a \(width)×\(height) board. Apple Vision supports boards from 2×2 to 37×37.")
        }
    }

    /// The one engine state still drawn over the visible board (ADR 0010):
    /// LAUNCHING, the transient wait, with ADR 0007's compile caption when a
    /// compile is genuinely running. Every resting state — Failed, Held, the
    /// built-in-fallback note — surfaces through the sparkle's badge and the
    /// Models card's status header, so the goban stays unobstructed.
    @ViewBuilder
    private var engineStatusCard: some View {
        if session.engineStatus.availability == .launching {
            EngineStatusView(status: session.engineStatus,
                             launchStatus: engineLaunchStatus,
                             style: .ornament)
                .frame(width: 460)
                .padding(20)
                .glassBackgroundEffect()
        }
    }

    // MARK: - Boot

    /// Spawns the engine on `model` and runs the one-shot boot
    /// initialization. Called from onAppear for a headless boot, and from
    /// the pre-boot Models chooser when a surviving load sentinel deferred
    /// the launch to the user (shell.phase == .choosingModel until then).
    private func launchEngine(model: NeuralNetworkModel) {
        engineController.startInitial(model: model)
        Task { await initializationTask() }
    }

    private func initializationTask() async {
        // Session-level flags BEFORE the handshake completes, so no engine
        // reply can precede them (tvOS discipline). soundEffect stays false:
        // on this platform the placement sound is scene-driven — the scene
        // model cues it when the flying stone lands, not at GTP commit time
        // (the pass paths, which never diff a stone, click for themselves).
        session.gobanState.verticalFlip = false
        session.gobanState.continuousAnalysisUsesConfigInterval = true
        session.gobanState.analysisStatus = .run
        // Persisted display settings (the shell owns the VisionSettings.*
        // keys; rendering reads gobanState — the onChange mirrors keep them
        // in sync after the settings card writes the shell).
        session.gobanState.analysisInformation = shell.analysisInformation
        session.gobanState.showOwnership = shell.showOwnership

        // THE BOARD FIRST. Mounting is engine-free: `loadGame` replays the
        // record's own SGF onto the goban, and the feed it offers is dropped by
        // the still-shut command gate and remembered as a debt. So the user is
        // looking at their game within the first frames, while the net is still
        // loading behind it.
        if resolveAndMountCurrentGame() {
            shell.phase = .ready
        }

        // Blocks on the engine's `version` reply (i.e. until the net has
        // finished loading). The title must be the booted net's: it is what
        // markFirstResponse hands the lastLoadedModelTitle observer to
        // persist as the last-good selection.
        let reply = await session.handshake(
            selectedModelTitle: engineController.activeModel.title,
            engineLifecycle: engineLifecycle
        )
        if reply == nil {
            // `handshake` already ended the session `.failed` with its reason
            // and seeded the Retry action; the phase is what lets Retry through.
            // The read loop is left unarmed — there is nothing to read, and a
            // reader would eat the retry handshake's reply. The board stays
            // exactly where it is, with the failure reported over it.
            engineController.noteInitialHandshakeFailed()
        } else {
            engineController.noteInitialHandshakeComplete()
            // Held BEFORE the debt is paid, and before any other command: a
            // board larger than this engine's NN buffer must never be described
            // to it — `NNEvaluator::evaluate` aborts the process on the first
            // analysis past the buffer. Going Held shuts the gate, so the resync
            // below sends nothing at all and the board reports why analysis is
            // off. (There are no separate "initial commands" to worry about:
            // the feed states board size, rules, komi and every move itself.)
            engineController.applyHeldStatus()
            // Pay the debt: feed the engine the position on screen NOW — the
            // user may have switched games or scrubbed while the model loaded,
            // and latest selection wins.
            engineController.resyncAfterHandshake()
        }

        // One-shot drain for a deep link delivered mid-boot: after
        // resolveAndMountCurrentGame consumed a (possibly nil) latch but
        // before the handshake returned, onOpenURL can still land — the iOS
        // Release-only cold-launch race, closed the same way here.
        applyPendingDeepLink()

        // onChange(of: isConnected) never fires for a controller that was
        // already paired before launch (the common simulator case).
        if controllerInput.isConnected, !shell.hasAutoShownControllerHelp {
            shell.hasAutoShownControllerHelp = true
            shell.presentControllerHelp()
        }

        #if DEBUG
        autoplaySmokeIfRequested()
        #endif
    }

    /// Resolve the game to mount — the current selection, else the newest
    /// synced record, else a fresh default sized to the engine buffer — check
    /// that its geometry is renderable, and mount it via the shared switch
    /// path. The caller owns `.ready`. Returns false with `.unsupportedBoard`
    /// set when there is nothing that can be drawn.
    ///
    /// Runs BEFORE the handshake: the board is record-owned, so there is
    /// nothing here that needs an engine. A board too large for the engine's
    /// buffer mounts like any other and reports *Held* — `switchGame` decides
    /// that and shuts the command gate, so such a board is never described to
    /// the engine (it aborts fatally on the first analysis past its buffer).
    @discardableResult
    private func resolveAndMountCurrentGame() -> Bool {
        // A deep link latched before or during boot (a widget tap on a cold
        // launch) overrides the default selection. Consume unconditionally:
        // a stale latch must never re-fire on a later Max-Board-Size or
        // model-swap restart, which re-enters this resolver.
        let pendingID = deepLinkRouter.pendingGameID
        deepLinkRouter.pendingGameID = nil

        let record: GameRecord
        if let pendingID,
           let match = GameRecord.resolveDeepLinkTarget(
               id: pendingID, container: modelContext.container) {
            record = match
        } else if let selected = navigationContext.selectedGameRecord {
            record = selected
        } else if let existing = try? GameRecord.fetchGameRecords(
            container: modelContext.container, fetchLimit: 1).first {
            record = existing
        } else {
            let created = GameRecord.createGameRecord(
                maxBoardLength: engineController.maxBoardLength)
            modelContext.insert(created)
            try? modelContext.save()
            record = created
        }
        record.updateToLatestVersion()

        let config = record.concreteConfig
        if let blocked = unsupportedPhase(width: config.boardWidth,
                                          height: config.boardHeight) {
            shell.phase = blocked
            return false
        }

        switchGame(to: record)
        return true
    }

    /// The model detail's gear view changed the ACTIVE model's Max Board Size
    /// (already persisted): quit → respawn the engine with the new NN buffer.
    ///
    /// The BOARD DOES NOT MOVE. `shell.phase` is not touched, the game stays
    /// mounted, and L1/R1/L2/R2 keep stepping through it while the engine is
    /// down (their sends are dropped and repaid by the resync). What the user
    /// sees is the status card over the goban: Launching, then nothing — or
    /// Failed with a Retry button if the restart gives up anywhere. The
    /// controller re-decides Held (the buffer just changed) and re-feeds the
    /// position itself once the new engine answers; the read loop parks in
    /// `noteRunLoopExited` in the meantime.
    private func restartEngineForMaxBoardSize() {
        Task { await engineController.restartEngine() }
    }

    /// Models-card activation: the Max-Board-Size restart flow with a model
    /// swap — quit → respawn with the new net, board never leaving the screen.
    /// A board over the new net's effective buffer (its own per-model Max Board
    /// Size, clamped to its nnLen) reports *Held*; the Settings picker then
    /// edits the NEW model's key, so raising it there is a working exit.
    /// Persistence happens via the lastLoadedModelTitle observer once the
    /// handshake lands — an activation that dies mid-load leaves the sentinel
    /// armed and the next boot falls back to the built-in.
    ///
    /// Allowed from a FAILED engine too (`canRestart`), which is how the Models
    /// card doubles as the way out of a launch that never came up.
    private func activateModel(_ model: NeuralNetworkModel) {
        guard engineController.canRestartNow,
              model.title != engineController.activeModel.title else { return }
        // The sparkle's remedy tap opened the Models card wanting analysis: a
        // pick arms a cleared preference back to run. `.pause`/`.run` are left
        // alone — the preference is the user's, and the post-restart resync
        // auto-resumes anything that is not `.clear` (ADR 0010).
        if shell.modelsPresentedFromAnalysisControl {
            shell.modelsPresentedFromAnalysisControl = false
            if session.gobanState.analysisStatus == .clear {
                session.gobanState.analysisStatus = .run
                session.analysis.resetVisitsPerSecondSession()
            }
        }
        Task { await engineController.restartEngine(loading: model) }
    }

    #if DEBUG
    /// `simctl launch … vision-autoplay-smoke` drives the exact controller
    /// event path (activate → step → A-play) headlessly, so the sim can
    /// verify ghost → kata-check-move → stone rendering without a physical
    /// game controller.
    private func autoplaySmokeIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("vision-autoplay-smoke") else { return }
        Task {
            // Explicit center reveals throughout: the script's step sequences
            // were tuned against center starts, and the anchor (the game's
            // last move) would shift the landings onto occupied points.
            try? await Task.sleep(for: .seconds(5))
            let width = Int(session.board.width)
            let height = Int(session.board.height)
            let center = BoardPoint(x: width / 2, y: height / 2)
            ghost.activate(width: width, height: height, at: center)
            handleControllerEvent(.play)

            try? await Task.sleep(for: .seconds(5))
            ghost.activate(width: width, height: height, at: center)
            handleControllerEvent(.dpad(.up))
            handleControllerEvent(.dpad(.right))
            handleControllerEvent(.play)

            // Single-step probe (X/L1 back, R1 forward; both sides still
            // human, default game unlocked on a fresh sim): backward removes
            // the stone just played, forward replays it — the same stone
            // must vanish and return.
            try? await Task.sleep(for: .seconds(3))
            handleControllerEvent(.undo)
            try? await Task.sleep(for: .seconds(2))
            handleControllerEvent(.forward)

            // Exercise the New Game board-swap path (19x19 -> 9x9) and play
            // one move on the fresh board.
            try? await Task.sleep(for: .seconds(6))
            startNewGame(size: 9)
            try? await Task.sleep(for: .seconds(5))
            ghost.activate(width: 9, height: 9, at: BoardPoint(x: 4, y: 4))
            handleControllerEvent(.play)

            // Flip the side to move to AI: the toggle's re-arm must gen-move
            // immediately (a stone appears with no play event).
            try? await Task.sleep(for: .seconds(4))
            toggleAI(for: session.player.nextColorForPlayCommand)

            // Stand the board up (wall-demonstration orientation).
            try? await Task.sleep(for: .seconds(4))
            shell.isBoardStanding = true

            // Feedback-1 regression probe: with White now AI, a second human
            // Black move must draw an AUTOMATIC White reply (a stone with no
            // VisionPlay log line) via the turn-change hook.
            try? await Task.sleep(for: .seconds(3))
            ghost.activate(width: 9, height: 9, at: BoardPoint(x: 4, y: 4))
            handleControllerEvent(.dpad(.down))
            handleControllerEvent(.dpad(.down))
            handleControllerEvent(.play)

            // B toggles the overlay off and back on.
            try? await Task.sleep(for: .seconds(4))
            handleControllerEvent(.toggleAnalysisVisibility)
            try? await Task.sleep(for: .seconds(2))
            handleControllerEvent(.toggleAnalysisVisibility)

            // Games-picker probe: while White is AI (possibly mid-genmove),
            // switch back to the previous game via the exact openGame path
            // the ornament drives, then play one move on the switched board.
            // A stone that no VisionPlay/VisionScene log line accounts for
            // would betray a stale cancelled-search reply leaking in.
            try? await Task.sleep(for: .seconds(4))
            if let other = gameRecords.first(where: {
                $0.persistentModelID
                    != navigationContext.selectedGameRecord?.persistentModelID
            }) {
                openGame(other)
            }
            try? await Task.sleep(for: .seconds(6))
            let switchedWidth = Int(session.board.width)
            let switchedHeight = Int(session.board.height)
            ghost.activate(width: switchedWidth, height: switchedHeight,
                           at: BoardPoint(x: switchedWidth / 2,
                                          y: switchedHeight / 2))
            handleControllerEvent(.play)

            // Feedback-2 regression probe: a reveal WITHOUT an explicit
            // origin must anchor at the game's last move, not the center.
            // This game's tip is the white stone at (10,10), so the first
            // D-pad press only reveals there, the second steps right, and
            // the play lands at (11,10) — a center reveal would log
            // VisionPlay ghost=(10,9) instead.
            try? await Task.sleep(for: .seconds(3))
            ghost.reset()
            handleControllerEvent(.dpad(.right))
            handleControllerEvent(.dpad(.right))
            handleControllerEvent(.play)
        }
    }
    #endif

    /// The one switch-to-game path shared by boot, New Game, and the Games
    /// picker (the caller owns the gate and the phase). loadGame is the
    /// central reload entry (used by macOS selectGame and tvOS review): it
    /// deactivates any branch, clears pending moves, resets the player to
    /// .unknown, projects the record position onto the board, and feeds the
    /// engine that position move by move. The game opens at its SAVED cursor:
    /// the old pre-set-to-tip was an engine recipe (it made the `loadsgf` undo
    /// loop a no-op), and Vision renders the overwrite dialog, so there is no
    /// product reason to move the user's cursor on their behalf.
    ///
    /// Stale-reply safety: switching mid-genmove cancels the running search,
    /// which prints the literal "play cancelled" (dropped by
    /// postProcessAIMove's vertex regex); a search that completed just
    /// before the switch prints a real "play <vertex>", which
    /// postProcessAIMove drops while the player is .unknown (nil symbol).
    /// The showboard reply then resolves the side to move, and the
    /// turn-change hook arms analysis (or the genmove bundle) for the new
    /// game.
    private func switchGame(to record: GameRecord) {
        ghost.reset()
        // The remount is a batch diff — no stone of it should animate or
        // click (loading a game is not a move). Aborting a half-parsed
        // showboard block keeps the OLD game's stones from diffing after
        // this reset (which would consume the silence flag and let the
        // remount click).
        sceneModel.prepareForGameSwitch()
        session.abortInFlightBoardCollection()

        navigationContext.selectedGameRecord = record
        session.gobanState.loadGame(gameRecord: record,
                                    player: session.player,
                                    bookLookup: session.bookLookup,
                                    messageList: session.messageList,
                                    board: session.board,
                                    stones: session.stones,
                                    analysis: session.analysis,
                                    projector: session.recordPosition)
        // Held, decided HERE and synchronously — between the projection that
        // settled the new board size and the post-execution commands below.
        // An observer would fire a runloop too late, and those commands (a
        // `kata-analyze` among them) would already have gone out for a board
        // this engine was never told about. Entering Held sends `stop`, shuts
        // the command gate and resets; leaving it reopens the gate and re-states
        // the whole position.
        engineController.applyHeldStatus()
        // No `printsgf` echo: the record is the source of the position now, so
        // reading it back out of the engine would only risk overwriting it (and
        // re-sorting the library) with what the engine happened to hold.
        session.gobanState.sendPostExecutionCommands(config: record.concreteConfig,
                                                     messageList: session.messageList,
                                                     player: session.player)
        // A configured widget shows the game's current position, and the switch
        // is what makes that position the live one.
        WidgetCenter.shared.reloadAllTimelines()
    }
}
