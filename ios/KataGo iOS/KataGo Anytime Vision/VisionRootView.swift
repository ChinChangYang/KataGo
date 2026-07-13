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
        .onAppear {
            engineController.startInitial()
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
            if oldValue, !newValue, session.gobanState.analysisStatus == .pause {
                session.messageList.appendAndSend(command: "stop")
            }
        }
        .onChange(of: session.player.nextColorForPlayCommand) { _, _ in
            guard let config = navigationContext.selectedGameRecord?.concreteConfig else { return }
            session.gobanState.maybeStopAnalysisForPowerSaving(
                config: config,
                nextColorForPlayCommand: session.player.nextColorForPlayCommand
            )
        }
    }

    // MARK: - Content

    /// Temporary M4 readout; replaced by the RealityKit board scene in M5.
    private var readyContent: some View {
        VStack(spacing: 12) {
            Text("KataGo Vision")
                .font(.extraLargeTitle)
            Text(navigationContext.selectedGameRecord?.name ?? "No game")
                .font(.title2)
            Text("Black \(session.stones.blackPoints.count) — White \(session.stones.whitePoints.count)")
            Text("Next: \(String(describing: session.player.nextColorForPlayCommand))")
                .foregroundStyle(.secondary)
        }
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
    }

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
