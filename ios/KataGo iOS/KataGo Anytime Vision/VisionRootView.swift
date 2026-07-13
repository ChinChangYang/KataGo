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
                    onPass: { playPass() },
                    onUndo: { undoOneMove() },
                    onToggleEye: { toggleEye() },
                    onToggleAI: { toggleAI(for: $0) },
                    onDismissIllegalMove: {
                        session.gobanState.confirmingIllegalMove = false
                        session.gobanState.clearPendingMove()
                    }
                )
            }
        }
        .ornament(attachmentAnchor: .scene(UnitPoint3D(x: 1, y: 0.5, z: 1)),
                  contentAlignment: .leading) {
            if isReady, shell.showingControllerHelp {
                VisionControllerLegend {
                    shell.showingControllerHelp = false
                }
            }
        }
        .onChange(of: controllerInput.isConnected) { _, connected in
            if !connected {
                ghost.reset()
            } else if !shell.hasAutoShownControllerHelp {
                // First controller of this run: teach the mapping once.
                shell.hasAutoShownControllerHelp = true
                shell.showingControllerHelp = true
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
            // Continuous-analysis re-arm (mirrors GameSplitView.processChange):
            // any command sent mid-stream (a play, showboard, ...) halts the
            // kata-analyze stream and drives this true→false edge. Unless the
            // engine is about to gen-move, either stop for good (paused /
            // power-saving) or RE-SEND the continuous bundle — without this,
            // analysis freezes after the first human move.
            guard oldValue, !newValue else { return }
            guard let config = navigationContext.selectedGameRecord?.concreteConfig,
                  !session.gobanState.shouldGenMove(config: config, player: session.player)
            else { return }
            if session.gobanState.analysisStatus == .pause
                || session.gobanState.isAnalysisHiddenForPowerSaving(
                    config: config,
                    nextColorForPlayCommand: session.player.nextColorForPlayCommand) {
                session.messageList.appendAndSend(command: "stop")
            } else if session.gobanState.analysisStatus == .run {
                session.messageList.appendAndSend(commands: GtpCommandBuilder.continuousAnalyzeCommands(
                    interval: config.analysisInterval, maxMoves: config.maxAnalysisMoves))
            }
        }
        .onChange(of: session.player.nextColorForPlayCommand) { _, _ in
            guard let config = navigationContext.selectedGameRecord?.concreteConfig else { return }
            session.gobanState.maybeStopAnalysisForPowerSaving(
                config: config,
                nextColorForPlayCommand: session.player.nextColorForPlayCommand
            )
        }
        // 2D boards clear stale candidates in AnalysisView.onAppear; the 3D
        // scene has no such lifecycle hook, so honor the request here.
        .onChange(of: session.gobanState.requestingClearAnalysis) { _, requesting in
            if requesting {
                session.analysis.clear()
                session.gobanState.requestingClearAnalysis = false
            }
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
        case .dismiss:
            ghost.reset()
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

    private func startNewGame(size: Int) {
        let record = GameRecord.createGameRecord(
            sgf: GameRecord.makeDefaultSgf(boardSize: size))
        modelContext.insert(record)
        try? modelContext.save()

        ghost.reset()

        // loadGame is the central reload entry (used by macOS selectGame and
        // tvOS review): it deactivates any branch, clears pending moves, and
        // reloads the SGF. Send the engine config first, as the boot does.
        session.sendInitialCommands(config: record.concreteConfig)
        let previous = navigationContext.selectedGameRecord
        navigationContext.selectedGameRecord = record
        session.gobanState.loadGame(gameRecord: record,
                                    previous: previous,
                                    player: session.player,
                                    bookLookup: session.bookLookup,
                                    messageList: session.messageList,
                                    board: session.board,
                                    stones: session.stones)
        session.gobanState.sendShowBoardCommand(messageList: session.messageList)
        session.messageList.appendAndSend(command: "printsgf")
        session.gobanState.sendPostExecutionCommands(config: record.concreteConfig,
                                                     messageList: session.messageList,
                                                     player: session.player)
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

    private func toggleEye() {
        session.gobanState.eyeStatus =
            session.gobanState.eyeStatus == .opened ? .closed : .opened
        // Closing the eye during a human-vs-AI human turn should also stop
        // the stream (power saving); reopening re-requests analysis.
        guard let config = navigationContext.selectedGameRecord?.concreteConfig else { return }
        if session.gobanState.eyeStatus == .opened {
            session.gobanState.maybeRequestAnalysis(
                config: config,
                nextColorForPlayCommand: session.player.nextColorForPlayCommand,
                messageList: session.messageList)
        } else {
            session.gobanState.maybeStopAnalysisForPowerSaving(
                config: config,
                nextColorForPlayCommand: session.player.nextColorForPlayCommand)
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

        loadIntoEngine(record)

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
            shell.showingControllerHelp = true
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
        }
    }
    #endif

    /// Sends the full load sequence for a (pre-validated) game record and
    /// jumps to the latest position. Also the path New Game takes.
    private func loadIntoEngine(_ record: GameRecord) {
        session.sendInitialCommands(config: record.concreteConfig)
        navigationContext.selectedGameRecord = record

        session.gobanState.maybeLoadSgf(
            gameRecord: record,
            messageList: session.messageList
        )
        session.gobanState.sendShowBoardCommand(messageList: session.messageList)
        session.messageList.appendAndSend(command: "printsgf")

        // Jump to the tip (v1 semantic: Vision always plays at the latest
        // position; a play on a locked synced game forms a branch). Its
        // trailing sendPostExecutionCommands kicks off analysis — and the
        // genmove bundle when an AI side is to move.
        session.gobanState.forwardMoves(
            limit: nil,
            gameRecord: record,
            board: session.board,
            messageList: session.messageList,
            player: session.player,
            audioModel: nil,
            stones: session.stones
        )
    }
}
