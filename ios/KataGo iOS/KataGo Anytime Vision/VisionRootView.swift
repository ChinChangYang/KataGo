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
    @State private var isReady = false
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

    /// The volumetric content, every ornament, and the boot/run-loop
    /// infrastructure.
    private var bootChrome: some View {
        Group {
            if case .ready = shell.phase {
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
        // Phase messaging (loading/blocked) lives in a front-anchored glass
        // ornament: plain 2D content inside a volumetric window lies flat on
        // the base plate, where it is unreadable (nearly edge-on and unlit) —
        // ornaments always face the viewer, like the settings card.
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 0.5, y: 0.55, z: 1)),
                  contentAlignment: .center) {
            Group {
                switch shell.phase {
                case .ready:
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
                    }
                case .booting:
                    // Shared spinning-icon loading view (iOS/Mac/TV parity). It
                    // sizes via GeometryReader, so the ornament must bound it.
                    EngineLoadingView(caption: "Loading engine",
                                      secondaryFont: .callout,
                                      icon: Image(.loadingIcon),
                                      iconSizing: .fixed(220),
                                      status: engineLaunchStatus)
                        .frame(width: 460, height: 420)
                        .padding(20)
                        .glassBackgroundEffect()
                case .choosingModel:
                    // iOS picker design: a surviving load sentinel defers the
                    // launch to the user. The regular Models card doubles as
                    // the chooser (neutral — no crash wording, no marked rows);
                    // picking a net boots it.
                    VisionModelsOrnament(engine: engineController,
                                         readiness: cacheReadiness,
                                         isBootChooser: true,
                                         onActivate: { model in
                                             shell.phase = .booting
                                             launchEngine(model: model)
                                         },
                                         onDismiss: {})
                case .unsupportedBoard(let width, let height):
                    unsupportedBoardView(width: width, height: height)
                        .frame(width: 460)
                        .padding(20)
                        .glassBackgroundEffect()
                case .boardTooLarge(let width, let height):
                    boardTooLargeView(width: width, height: height)
                        .frame(width: 460)
                        .padding(20)
                        .glassBackgroundEffect()
                }
            }
            // Ornaments are separately hosted hierarchies — claim gamepad
            // events on each content root too (see the root modifier).
            .handlesGameControllerEvents(matching: .gamepad)
        }
        // Hidden while `.booting` (initial boot has isReady false; a
        // Max-Board-Size restart re-enters .booting with isReady true) so no
        // pinch can send commands at a down engine. The Models card stays
        // up — its gear view shows the restart progress and the disabled
        // picker.
        .ornament(attachmentAnchor: .scene(.bottomFront), contentAlignment: .center) {
            if isReady, shell.phase != .booting {
                VisionControlOrnament(
                    session: session,
                    shell: shell,
                    controllerInput: controllerInput,
                    navigationContext: navigationContext,
                    onSparkle: { sparkleAnalysisAction() },
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
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 1, y: 0.5, z: 1)),
                  contentAlignment: .leading) {
            Group {
                if isReady, shell.showingSettings {
                    VisionSettingsOrnament(shell: shell,
                                           engine: engineController,
                                           onShowModels: { shell.presentModels() },
                                           onShowLicenses: { shell.presentLicenses() },
                                           onDismiss: { shell.showingSettings = false })
                } else if isReady, shell.showingLicenses {
                    VisionLicensesOrnament(onDismiss: { shell.showingLicenses = false })
                } else if isReady, shell.showingModels {
                    VisionModelsOrnament(engine: engineController,
                                         readiness: cacheReadiness,
                                         onActivate: { activateModel($0) },
                                         onMaxBoardSizeRestart: { restartEngineForMaxBoardSize() },
                                         onDismiss: { shell.showingModels = false })
                } else if isReady, shell.showingControllerHelp {
                    VisionControllerLegend {
                        shell.showingControllerHelp = false
                    }
                } else if isReady, shell.showingNewGamePanel, shell.phase != .booting {
                    VisionNewGamePanel(
                        maxBoardLength: engineController.maxBoardLength,
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
            if isReady, shell.showingGameList, shell.phase != .booting {
                VisionGameListOrnament(
                    gameRecords: gameRecords,
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
                                       modelSelection: modelSelection)
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
                shell.phase = .choosingModel
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
        // reader), so it arms only once initialization finished. `isReady`
        // stays true across a Max-Board-Size restart: `session.run` exits on
        // `stopRequested`, and `noteRunLoopExited` parks this loop until the
        // restarted engine's handshake completes (TVRootView's discipline —
        // without the park, the exited `run` would busy-spin here).
        .task(id: isReady) {
            guard isReady else { return }
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
                  isReady, shell.phase == .ready,
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
        guard isReady, shell.phase == .ready else { return }
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

    /// Games-picker entry point: same board gate as boot, then the shared
    /// switch path. A stale printsgf reply from the old game landing after
    /// the selection swap would be written into the new record (one-reply
    /// window, identical exposure to the iOS sidebar switch) — our own
    /// printsgf self-heals the SGF, so this is accepted for v1.
    private func openGame(_ record: GameRecord) {
        guard record.persistentModelID
                != navigationContext.selectedGameRecord?.persistentModelID
        else { return }

        // Re-derive width/height from the SGF: the picker row's stored size
        // may be nil or stale, and only this gate is authoritative. A blocked
        // board must never reach the engine (fatal on first analysis past the
        // NN buffer; no renderable geometry outside 2...37).
        record.updateToLatestVersion()
        let config = record.concreteConfig
        guard let blocked = blockedPhase(width: config.boardWidth,
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
    /// the Games picker. Applying is allowed from the blocked phases too
    /// (`.unsupportedBoard`/`.boardTooLarge`): like the picker, a widget tap
    /// must be a way out of them — only an in-flight boot keeps the latch.
    private func applyPendingDeepLink() {
        let isBooting = shell.phase == .booting || shell.phase == .choosingModel
        let disposition = VisionDeepLinkFlow.disposition(
            hasPending: deepLinkRouter.pendingGameID != nil,
            isReady: isReady,
            isBooting: isBooting)
        #if DEBUG
        NSLog("VisionDeepLink apply pending=%@ isReady=%d isBooting=%d disposition=%@",
              deepLinkRouter.pendingGameID?.uuidString ?? "nil",
              isReady ? 1 : 0, isBooting ? 1 : 0, String(describing: disposition))
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

    /// The blocked phase for a board, or nil when it can mount: outside the
    /// renderable 2...37 range -> unsupported; renderable but over the
    /// launched NN buffer -> too large (raise Max Board Size in Settings).
    private func blockedPhase(width: Int, height: Int) -> VisionGameShell.Phase? {
        guard visionBoardIsSupported(width: width, height: height) else {
            return .unsupportedBoard(width: width, height: height)
        }
        guard boardFits(width: width, height: height,
                        maxBoardLength: engineController.maxBoardLength) else {
            return .boardTooLarge(width: width, height: height)
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

    /// openGame's gate for a replacement the user did not pick: mount when
    /// the board fits, else silence the stream and surface the blocked
    /// phase — clearing the selection first, so the doomed record is never
    /// left selected (the Games list stays up as the way out).
    private func mountReplacement(_ record: GameRecord) {
        record.updateToLatestVersion()
        let config = record.concreteConfig
        if let blocked = blockedPhase(width: config.boardWidth,
                                      height: config.boardHeight) {
            session.messageList.appendAndSend(command: "stop")
            navigationContext.selectedGameRecord = nil
            shell.phase = blocked
            return
        }
        switchGame(to: record)
        shell.phase = .ready
    }

    /// Deleting the whole library: create and mount a fresh game sized to
    /// the engine cap (resolveAndMountCurrentGame's create arm — always
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
        guard session.stones.isReady, !isAITurn,
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
        guard session.stones.isReady, !isAITurn else { return }
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
        guard session.stones.isReady, !isAITurn else { return }
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
        guard session.stones.isReady, !isAITurn else { return }
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

    private func boardTooLargeView(width: Int, height: Int) -> some View {
        // A capped net (nnLen below the board) can never be raised far
        // enough — the honest exit is switching the neural net, and both
        // controls live in Settings.
        let cap = engineController.activeModel.nnLen
        let raisable = boardFits(width: width, height: height, maxBoardLength: cap)
        return ContentUnavailableView {
            Label("Board Too Large", systemImage: "square.grid.3x3.square")
        } description: {
            if raisable {
                Text("This game uses a \(width)×\(height) board, larger than the current Max Board Size (\(engineController.maxBoardLength)×\(engineController.maxBoardLength)). Raise Max Board Size under Settings ▸ Neural Net, then reopen the game.")
            } else {
                Text("This game uses a \(width)×\(height) board, larger than the current neural net supports (\(cap)×\(cap)). Switch the neural net in Settings, then reopen the game.")
            }
        } actions: {
            Button("Open Settings") {
                shell.showingSettings = true
                shell.showingControllerHelp = false
                shell.showingNewGamePanel = false
            }
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

        // Blocks on the engine's `version` reply (i.e. until the net has
        // finished loading). The title must be the booted net's: it is what
        // markFirstResponse hands the lastLoadedModelTitle observer to
        // persist as the last-good selection.
        _ = await session.handshake(
            selectedModelTitle: engineController.activeModel.title,
            engineLifecycle: engineLifecycle
        )
        engineController.noteInitialHandshakeComplete()

        if resolveAndMountCurrentGame() {
            // One collection round (the printsgf reply) before the run loop
            // arms, mirroring ContentView.initializationTask. Boot-only: after
            // a restart the live read loop already owns the bridge, and a
            // second reader would corrupt it.
            await session.messaging(
                gameRecords: gameRecords,
                modelContext: modelContext,
                navigationContext: navigationContext,
                audioModel: audioModel,
                aiMove: $aiMove
            )
            shell.phase = .ready
        }

        isReady = true

        // One-shot drain for a deep link delivered mid-boot: after
        // resolveAndMountCurrentGame consumed a (possibly nil) latch but
        // before the ready handshake above, onOpenURL can still land — the
        // iOS Release-only cold-launch race, closed the same way here. Must
        // run AFTER `.ready`/`isReady` so the disposition gate opens.
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
    /// synced record, else a fresh default sized to the engine cap — gate it
    /// against the launched NN buffer, and mount it via the shared switch
    /// path. Shared by boot and the Max-Board-Size restart; the caller owns
    /// `isReady`, `.ready`, and any boot-only messaging round. Returns false
    /// with the blocked phase set when the board cannot mount.
    ///
    /// The gate runs BEFORE any engine load: a too-large board must never be
    /// fed to the engine — it fatally aborts on the first analysis of a board
    /// larger than its NN buffer, and unsupported sizes have no 3D asset to
    /// render.
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
        if let blocked = blockedPhase(width: config.boardWidth,
                                      height: config.boardHeight) {
            shell.phase = blocked
            return false
        }

        switchGame(to: record)
        return true
    }

    /// The model detail's gear view changed the ACTIVE model's Max Board
    /// Size (already persisted): quit → respawn the engine with the new NN
    /// buffer behind the loading view, then re-gate and re-mount the current
    /// game. `.booting` hides the board and the command-sending ornaments;
    /// the read loop parks itself in `noteRunLoopExited` while the engine is
    /// down. On failure the phase stays `.booting` and the gear view shows
    /// the failure text.
    private func restartEngineForMaxBoardSize() {
        Task {
            shell.phase = .booting
            guard await engineController.restartEngine() else { return }
            if resolveAndMountCurrentGame() {
                shell.phase = .ready
            }
        }
    }

    /// Models-card activation: the Max-Board-Size restart flow with a model
    /// swap — quit → respawn with the new net behind the loading card, then
    /// re-gate and re-mount the current game. A board over the new net's
    /// effective buffer (its own per-model Max Board Size, clamped to its
    /// nnLen) lands in .boardTooLarge; the Settings picker then edits the
    /// NEW model's key, so raising it there is a working exit. Persistence
    /// happens via the lastLoadedModelTitle observer once the handshake
    /// lands — an activation that dies mid-load leaves the sentinel armed
    /// and the next boot falls back to the built-in.
    private func activateModel(_ model: NeuralNetworkModel) {
        guard engineController.phase == .running,
              model.title != engineController.activeModel.title else { return }
        Task {
            shell.phase = .booting
            guard await engineController.restartEngine(loading: model) else { return }
            if resolveAndMountCurrentGame() {
                shell.phase = .ready
            }
        }
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
