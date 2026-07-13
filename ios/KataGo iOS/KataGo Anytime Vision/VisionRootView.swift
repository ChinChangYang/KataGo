//
//  VisionRootView.swift
//  KataGo Anytime Vision
//
//  Always-alive root of the volume: owns the GameSession, the engine boot
//  sequence, the GTP run loop, and the analysis-stop lifecycle (like
//  TVRootView on tvOS — there is no per-game host controller on visionOS).
//

import SwiftUI
import SwiftData
import KataGoUICore

struct VisionRootView: View {
    @State private var session = GameSession()
    @State private var engineLifecycle = EngineLifecycle()
    @State private var engineController = VisionEngineController()
    @State private var shell = VisionGameShell()
    @State private var navigationContext = NavigationContext()
    @State private var audioModel = AudioModel()
    @State private var aiMove: String? = nil
    @State private var isReady = false
    @State private var ghost = GhostCursorModel()
    @State private var sceneModel = VisionBoardSceneModel()
    @State private var controllerInput = VisionControllerInput()

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse)
    private var gameRecords: [GameRecord]

    var body: some View {
        Group {
            switch shell.phase {
            case .booting:
                ProgressView("Loading engine")
                    .controlSize(.extraLarge)
            case .ready:
                readyContent
            case .unsupportedBoard(let width, let height):
                unsupportedBoardView(width: width, height: height)
            }
        }
        // Volumetric scenes are fixed-scale (~1360 pt/m): 1088 x 816 x 1088 pt
        // ≈ 0.8 x 0.6 x 0.8 m. The window adopts this via .contentSize.
        .frame(width: 1088, height: 816)
        .frame(depth: 1088)
        .ornament(attachmentAnchor: .scene(.bottomFront), contentAlignment: .center) {
            if isReady {
                VisionControlOrnament(
                    session: session,
                    shell: shell,
                    controllerInput: controllerInput,
                    navigationContext: navigationContext,
                    onNewGame: { startNewGame(size: $0) },
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
                VisionSettingsOrnament(shell: shell) {
                    shell.showingSettings = false
                }
            } else if isReady, shell.showingControllerHelp {
                VisionControllerLegend {
                    shell.showingControllerHelp = false
                }
            }
        }
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 0, y: 0.5, z: 1)),
                  contentAlignment: .trailing) {
            if isReady, shell.showingGameList {
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
            engineController.startInitial()
            controllerInput.onEvent = { handleControllerEvent($0) }
        }
        .task {
            await initializationTask()
        }
        // The GTP read loop — parses board/analysis lines into the models.
        // Must not run concurrently with the handshake (the bridge's sole
        // reader), so it arms only once initialization finished.
        .task(id: isReady) {
            guard isReady else { return }
            while !Task.isCancelled {
                await session.run(gameRecords: gameRecords,
                                  modelContext: modelContext,
                                  navigationContext: navigationContext,
                                  audioModel: audioModel,
                                  aiMove: $aiMove)
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
    }

    // MARK: - Content

    private var readyContent: some View {
        VisionBoardRealityView(session: session,
                               ghost: ghost,
                               sceneModel: sceneModel,
                               controllerInput: controllerInput,
                               shell: shell)
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
                .candidateMoves(width: width, height: height, limit: 10)
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
        // may be nil or stale, and only this gate is authoritative. An
        // unsupported board must never reach the engine (fatal on first
        // analysis past the NN buffer; no 3D asset below it).
        record.updateToLatestVersion()
        let config = record.concreteConfig
        guard visionBoardIsSupported(width: config.boardWidth, height: config.boardHeight),
              boardFits(width: config.boardWidth, height: config.boardHeight,
                        maxBoardLength: engineController.maxBoardLength) else {
            // The old game stays loaded but unmounted — silence its stream.
            session.messageList.appendAndSend(command: "stop")
            shell.phase = .unsupportedBoard(width: config.boardWidth,
                                            height: config.boardHeight)
            return
        }

        switchGame(to: record)
        shell.phase = .ready
    }

    private func startNewGame(size: Int) {
        let record = GameRecord.createGameRecord(
            sgf: GameRecord.makeDefaultSgf(boardSize: size))
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
            Text("This game uses a \(width)×\(height) board, which isn't available on Apple Vision yet. Start a new 9×9, 13×13, or 19×19 game.")
        }
    }

    // MARK: - Boot

    private func initializationTask() async {
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

        // Blocks on the engine's `version` reply (i.e. until the b18 net has
        // finished loading).
        _ = await session.handshake(
            selectedModelTitle: NeuralNetworkModel.builtInModel?.title ?? "",
            engineLifecycle: engineLifecycle
        )

        // Most recently modified synced game, else a fresh default game.
        let record: GameRecord
        if let existing = try? GameRecord.fetchGameRecords(
            container: modelContext.container, fetchLimit: 1).first {
            record = existing
        } else {
            let created = GameRecord.createGameRecord()
            modelContext.insert(created)
            try? modelContext.save()
            record = created
        }
        record.updateToLatestVersion()

        // Gate BEFORE any engine load: an unsupported board must never reach
        // maybeLoadSgf — the engine fatally aborts on the first analysis of a
        // board larger than its NN buffer, and smaller unsupported sizes have
        // no 3D asset to render.
        let config = record.concreteConfig
        guard visionBoardIsSupported(width: config.boardWidth, height: config.boardHeight),
              boardFits(width: config.boardWidth, height: config.boardHeight,
                        maxBoardLength: engineController.maxBoardLength) else {
            isReady = true
            shell.phase = .unsupportedBoard(width: config.boardWidth, height: config.boardHeight)
            return
        }

        switchGame(to: record)

        // One collection round (the printsgf reply) before the run loop arms,
        // mirroring ContentView.initializationTask.
        await session.messaging(
            gameRecords: gameRecords,
            modelContext: modelContext,
            navigationContext: navigationContext,
            audioModel: audioModel,
            aiMove: $aiMove
        )

        isReady = true
        shell.phase = .ready

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
