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

    @Environment(\.modelContext) private var modelContext
    @Environment(EngineLaunchStatus.self) private var engineLaunchStatus
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse)
    private var gameRecords: [GameRecord]

    var body: some View {
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
        // Phase messaging (loading/blocked) lives in a front-anchored glass
        // ornament: plain 2D content inside a volumetric window lies flat on
        // the base plate, where it is unreadable (nearly edge-on and unlit) —
        // ornaments always face the viewer, like the settings card.
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 0.5, y: 0.55, z: 1)),
                  contentAlignment: .center) {
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
        // Hidden while `.booting` (initial boot has isReady false; a
        // Max-Board-Size restart re-enters .booting with isReady true) so no
        // pinch can send commands at a down engine. The settings card stays
        // up — it shows the restart progress and the disabled picker.
        .ornament(attachmentAnchor: .scene(.bottomFront), contentAlignment: .center) {
            if isReady, shell.phase != .booting {
                VisionControlOrnament(
                    session: session,
                    shell: shell,
                    controllerInput: controllerInput,
                    navigationContext: navigationContext,
                    maxBoardLength: engineController.maxBoardLength,
                    onNewGame: { startNewGame(size: $0) },
                    onCustomGame: { shell.toggleNewGamePanel() },
                    onSparkle: { sparkleAnalysisAction() },
                    onToggleAI: { toggleAI(for: $0) },
                    onDismissIllegalMove: {
                        session.gobanState.confirmingIllegalMove = false
                        session.gobanState.clearPendingMove()
                    }
                )
            }
        }
        // Settings and the controller legend share the right anchor — one
        // closure, settings first, and the shell's toggle helpers keep the
        // flags mutually exclusive.
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 1, y: 0.5, z: 1)),
                  contentAlignment: .leading) {
            if isReady, shell.showingSettings {
                VisionSettingsOrnament(shell: shell,
                                       engine: engineController,
                                       onShowModels: { shell.presentModels() },
                                       onRestart: { restartEngineForMaxBoardSize() },
                                       onDismiss: { shell.showingSettings = false })
            } else if isReady, shell.showingModels {
                VisionModelsOrnament(engine: engineController,
                                     readiness: cacheReadiness,
                                     onActivate: { activateModel($0) },
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
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 0, y: 0.5, z: 1)),
                  contentAlignment: .trailing) {
            if isReady, shell.showingGameList, shell.phase != .booting {
                VisionGameListOrnament(
                    gameRecords: gameRecords,
                    maxBoardLength: engineController.maxBoardLength,
                    navigationContext: navigationContext,
                    onOpenGame: { openGame($0) },
                    onDismiss: { shell.showingGameList = false }
                )
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
            if resolution.fellBackFromIncompleteLoad {
                recoveryLogger.error(
                    "Previous launch did not finish loading model: \(modelSelection.pendingLoadModelTitle, privacy: .public). Booting the built-in net."
                )
            }
            engineController.startInitial(model: resolution.model)
            controllerInput.onEvent = { handleControllerEvent($0) }
        }
        .task {
            await initializationTask()
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
            session.gobanState.maybeSendAsymmetricHumanAnalysisCommands(
                nextColorForPlayCommand: newValue,
                config: config,
                messageList: session.messageList)
            session.gobanState.maybeRequestAnalysis(
                config: config,
                nextColorForPlayCommand: newValue,
                messageList: session.messageList)
            session.gobanState.maybeRequestClearAnalysisData(
                config: config,
                nextColorForPlayCommand: newValue)
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
        // tip — deliberate on Vision (no forward-navigation input; iOS's
        // divergence-point landing would strand the user after a Discard) —
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
        case .cycle(let forward):
            let candidates = session.analysis
                .candidateMoves(width: width, height: height,
                                limit: VisionBoardSceneModel.candidateMoveLimit)
                .map(\.point)
            ghost.cycle(through: candidates, forward: forward)
        case .play:
            playAtGhost()
        case .undo:
            undoOneMove()
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
        NSLog("VisionPlay ghost=%@ geom=%d stonesReady=%d pending=%@ aiTurn=%d",
              ghost.point.map { "(\($0.x),\($0.y))" } ?? "nil",
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

    /// Any width x height in 2...cap (the Custom panel's steppers enforce the
    /// bounds; the quick 9/13/19 buttons disable above the cap). Default komi
    /// and rules — the square path produces makeDefaultSgf byte-for-byte.
    private func startNewGame(width: Int, height: Int) {
        let record = GameRecord.createGameRecord(
            sgf: GameRecord.makeSgf(width: width, height: height, komi: 7.0,
                                    ruleString: "koSIMPLEscoreAREAtaxNONEsui0whbN"))
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
        guard session.stones.isReady, !isAITurn else { return }
        session.gobanState.undoIndex(gameRecord: gameRecord)
        session.gobanState.undo(messageList: session.messageList, stones: session.stones)
        session.player.toggleNextColorForPlayCommand()
        session.gobanState.sendShowBoardCommand(messageList: session.messageList)
    }

    private func unsupportedBoardView(width: Int, height: Int) -> some View {
        ContentUnavailableView {
            Label("Board Size Not Supported", systemImage: "cube.transparent")
        } description: {
            Text("This game uses a \(width)×\(height) board. Apple Vision supports boards from 2×2 to 37×37.")
        }
    }

    private func boardTooLargeView(width: Int, height: Int) -> some View {
        ContentUnavailableView {
            Label("Board Too Large", systemImage: "square.grid.3x3.square")
        } description: {
            Text("This game uses a \(width)×\(height) board, larger than the current Max Board Size (\(engineController.maxBoardLength)×\(engineController.maxBoardLength)). Raise Max Board Size in Settings, then reopen the game.")
        } actions: {
            Button("Open Settings") {
                shell.showingSettings = true
                shell.showingControllerHelp = false
                shell.showingNewGamePanel = false
            }
        }
    }

    // MARK: - Boot

    private func initializationTask() async {
        // Arm the CoreML cache-readiness signal (the Models card's green
        // checkmarks) — idempotent, and independent of the engine.
        await cacheReadiness.start()

        // Session-level flags BEFORE the handshake completes, so no engine
        // reply can precede them (tvOS discipline).
        session.autoCreatesGameOnEmptyLibrary = false
        session.gobanState.verticalFlip = false
        session.gobanState.soundEffect = true
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
    /// The gate runs BEFORE any engine load: a too-large board must never
    /// reach maybeLoadSgf — the engine fatally aborts on the first analysis
    /// of a board larger than its NN buffer, and unsupported sizes have no
    /// 3D asset to render.
    @discardableResult
    private func resolveAndMountCurrentGame() -> Bool {
        let record: GameRecord
        if let selected = navigationContext.selectedGameRecord {
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

    /// The settings card's Max Board Size picker changed (already persisted):
    /// quit → respawn the engine with the new NN buffer behind the loading
    /// view, then re-gate and re-mount the current game. `.booting` hides the
    /// board and the command-sending ornaments; the read loop parks itself in
    /// `noteRunLoopExited` while the engine is down. On failure the phase
    /// stays `.booting` and the settings card shows the failure text.
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
            try? await Task.sleep(for: .seconds(5))
            let width = Int(session.board.width)
            let height = Int(session.board.height)
            ghost.activate(width: width, height: height)
            handleControllerEvent(.play)

            try? await Task.sleep(for: .seconds(5))
            ghost.activate(width: width, height: height)
            handleControllerEvent(.dpad(.up))
            handleControllerEvent(.dpad(.right))
            handleControllerEvent(.play)

            // Exercise the New Game board-swap path (19x19 -> 9x9) and play
            // one move on the fresh board.
            try? await Task.sleep(for: .seconds(6))
            startNewGame(size: 9)
            try? await Task.sleep(for: .seconds(5))
            ghost.activate(width: 9, height: 9)
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
            ghost.activate(width: 9, height: 9)
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
            ghost.activate(width: Int(session.board.width),
                           height: Int(session.board.height))
            handleControllerEvent(.play)
        }
    }
    #endif

    /// The one switch-to-game path shared by boot, New Game, and the Games
    /// picker (the caller owns the gate and the phase). loadGame is the
    /// central reload entry (used by macOS selectGame and tvOS review): it
    /// deactivates any branch, clears pending moves, resets the player to
    /// .unknown, and reloads the SGF. Pre-setting currentIndex to the move
    /// count makes loadGame's undo loop a no-op, so the engine lands at the
    /// tip (v1 semantic: Vision always plays at the latest position; a play
    /// on a locked synced game forms a branch).
    ///
    /// Stale-reply safety: switching mid-genmove cancels the running search,
    /// which still prints its best-so-far "play <vertex>" — postProcessAIMove
    /// drops it while the player is .unknown (nil symbol). The showboard
    /// reply then resolves the side to move, and the turn-change hook arms
    /// analysis (or the genmove bundle) for the new game.
    private func switchGame(to record: GameRecord) {
        ghost.reset()
        session.sendInitialCommands(config: record.concreteConfig)
        record.currentIndex = SgfOperations(sgf: record.sgf).moveSize ?? 0

        let previous = navigationContext.selectedGameRecord
        navigationContext.selectedGameRecord = record
        session.gobanState.loadGame(gameRecord: record,
                                    previous: previous,
                                    player: session.player,
                                    bookLookup: session.bookLookup,
                                    messageList: session.messageList,
                                    board: session.board,
                                    stones: session.stones)
        session.messageList.appendAndSend(command: "printsgf")
        session.gobanState.sendPostExecutionCommands(config: record.concreteConfig,
                                                     messageList: session.messageList,
                                                     player: session.player)
    }
}
