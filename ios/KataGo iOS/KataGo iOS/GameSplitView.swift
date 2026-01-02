//
//  GameSplitView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/12/8.
//

import SwiftUI
import KataGoInterface
import UniformTypeIdentifiers

struct GameSplitView: View {
    let selectedModel: NeuralNetworkModel
    let sgfType = UTType("ccy.KataGo-iOS.sgf")!

    @Binding var aiMove: String?
    @Binding var quitStatus: QuitStatus

    @State var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var isEditorPresented = false
    @State var isGameListViewAppeared = false

    @Environment(Stones.self) var stones
    @Environment(MessageList.self) var messageList
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var player
    @Environment(Analysis.self) var analysis
    @Environment(GobanState.self) var gobanState
    @Environment(Winrate.self) var rootWinrate
    @Environment(Score.self) var rootScore
    @Environment(NavigationContext.self) var navigationContext
    @Environment(ThumbnailModel.self) var thumbnailModel
    @Environment(AudioModel.self) var audioModel
    @Environment(TopUIState.self) var topUIState

    @Environment(\.scenePhase) var scenePhase
    @Environment(\.modelContext) private var modelContext

    @AppStorage("GlobalSettings.soundEffect") private var globalSoundEffect = false
    @AppStorage("GlobalSettings.hapticFeedback") private var globalHapticFeedback = false

    var body: some View {
        @Bindable var navigationContext = navigationContext
        @Bindable var gobanState = gobanState
        @Bindable var topUIState = topUIState

        NavigationSplitView(columnVisibility: $columnVisibility) {
            GameListView(isEditorPresented: $isEditorPresented,
                         selectedGameRecord: $navigationContext.selectedGameRecord,
                         isGameListViewAppeared: $isGameListViewAppeared)
            .toolbar {
                GameListToolbar(
                    gameRecord: navigationContext.selectedGameRecord,
                    maxBoardLength: selectedModel.nnLen,
                    quitStatus: $quitStatus
                )
            }
        } detail: {
            GobanView(isEditorPresented: $isEditorPresented,
                      maxBoardLength: selectedModel.nnLen,
                      columnVisibility: $columnVisibility)
            .confirmationDialog(
                "Do you allow AI overwriting this move?",
                isPresented: $gobanState.confirmingAIOverwrite,
                titleVisibility: .visible
            ) {
                Button("Overwrite", role: .destructive) {
                    if let gameRecord = navigationContext.selectedGameRecord,
                       let turn = player.nextColorSymbolForPlayCommand {
                        gobanState.playAIMove(
                            aiMove: aiMove,
                            gameRecord: gameRecord,
                            turn: turn,
                            analysis: analysis,
                            board: board,
                            stones: stones,
                            messageList: messageList,
                            player: player,
                            audioModel: audioModel
                        )
                    }
                }

                Button("Cancel", role: .cancel) {
                    gobanState.confirmingAIOverwrite = false
                    gobanState.analysisStatus = .clear
                }
            }
        }
        .onAppear {
            gobanState.soundEffect = globalSoundEffect
            gobanState.hapticFeedback = globalHapticFeedback
        }
        .onChange(of: gobanState.soundEffect) { oldValue, newValue in
            globalSoundEffect = newValue
        }
        .onChange(of: gobanState.hapticFeedback) { oldValue, newValue in
            globalHapticFeedback = newValue
        }
        .onChange(of: navigationContext.selectedGameRecord) { oldGameRecord, newGameRecord in
            createThumbnail(for: oldGameRecord)
            processChange(oldGameRecord: oldGameRecord, newGameRecord: newGameRecord)
        }
        .onChange(of: gobanState.waitingForAnalysis) { oldWaitingForAnalysis, newWaitingForAnalysis in
            processChange(oldWaitingForAnalysis: oldWaitingForAnalysis,
                          newWaitingForAnalysis: newWaitingForAnalysis)
        }
        .onOpenURL { url in
            importUrl(url: url)
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            processChange(newScenePhase: newScenePhase)
        }
        .onChange(of: gobanState.branchSgf) { oldBranchStateSgf, newBranchStateSgf in
            processChange(oldBranchStateSgf: oldBranchStateSgf,
                          newBranchStateSgf: newBranchStateSgf)
        }
        .onChange(of: isGameListViewAppeared) { oldIsGameListViewAppeared, newIsGameListViewAppeared in
            processChange(oldIsGameListViewAppeared: oldIsGameListViewAppeared,
                          newIsGameListViewAppeared: newIsGameListViewAppeared)
        }
        .onChange(of: gobanState.isEditing) { oldIsEditing, newIsEditing in
            processIsEditingChange(oldIsEditing: oldIsEditing, newIsEditing: newIsEditing)
        }
        .onChange(of: gobanState.isAutoPlaying) { oldIsAutoPlaying, newIsAutoPlaying in
            processIsAutoPlayingChange(
                oldIsAutoPlaying: oldIsAutoPlaying,
                newIsAutoPlaying: newIsAutoPlaying
            )
        }
        .onChange(of: stones.isReady) { oldValue, newValue in
            processStonesReadyChange(
                oldValue: oldValue,
                newValue: newValue
            )
        }
        .onChange(of: gobanState.analysisStatus) { oldValue, newValue in
            if newValue == .clear {
                messageList.appendAndSend(command: "stop")
            }
        }
        .confirmationDialog(
            "Are you sure you want to delete this game? THIS ACTION IS IRREVERSIBLE!",
            isPresented: $topUIState.confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let gameRecord = navigationContext.selectedGameRecord {
                    navigationContext.selectedGameRecord = nil
                    modelContext.safelyDelete(gameRecord: gameRecord)
                }
            }

            Button("Cancel", role: .cancel) {
                topUIState.confirmingDeletion = false
            }
        }
        .fileImporter(
            isPresented: $topUIState.importing,
            allowedContentTypes: [sgfType, .text],
            allowsMultipleSelection: true
        ) { result in
            importFiles(result: result)
        }
    }

    private func processChange(newScenePhase: ScenePhase) {
        if newScenePhase == .background {
            createThumbnail(for: navigationContext.selectedGameRecord)
            gobanState.maybePauseAnalysis()
        }
    }

    private func processStonesReadyChange(oldValue: Bool, newValue: Bool) {
        if !oldValue && newValue,
           let gameRecord = navigationContext.selectedGameRecord {

            let currentIndex = gameRecord.currentIndex

            gameRecord.blackStones?[currentIndex] = BoardPoint.toString(
                stones.blackPoints,
                width: Int(board.width),
                height: Int(board.height)
            )

            gameRecord.whiteStones?[currentIndex] = BoardPoint.toString(
                stones.whitePoints,
                width: Int(board.width),
                height: Int(board.height)
            )

            if gobanState.isAutoPlayed {
                gameRecord.currentIndex += 1
            }
        }
    }

    private func processIsAutoPlayingChange(oldIsAutoPlaying: Bool,
                                            newIsAutoPlaying: Bool) {
        if gobanState.isAutoPlaying,
           let gameRecord = navigationContext.selectedGameRecord {
            gobanState.analysisStatus = .pause
            gobanState.eyeStatus = .opened
            gobanState.deactivateBranch()

            let sgfHelper = SgfHelper(sgf: gameRecord.sgf)
            while sgfHelper.getMove(at: gameRecord.currentIndex - 1) != nil {
                gameRecord.undo()
                gobanState.undo(messageList: messageList, stones: stones)
                player.toggleNextColorForPlayCommand()
            }

            // auto-play analysis by best AI profile
            if let humanSLModel = HumanSLModel(profile: "AI") {
                messageList.appendAndSend(commands: humanSLModel.commands)
                messageList.appendAndSend(command: "kata-set-param playoutDoublingAdvantage 0")
                messageList.appendAndSend(command: "kata-set-param analysisWideRootNoise 0")
            }

            gobanState.sendPostExecutionCommands(
                config: gameRecord.concreteConfig,
                messageList: messageList,
                player: player,
                gameRecord: gameRecord
            )
        } else {
            withAnimation {
                gobanState.analysisStatus = .clear
            }

            // restore human profile for the next player
            if let gameRecord = navigationContext.selectedGameRecord,
               let config = gameRecord.config {
                gobanState.maybeSendAsymmetricHumanAnalysisCommands(
                    nextColorForPlayCommand: player.nextColorForPlayCommand,
                    config: config,
                    messageList: messageList)

                messageList.appendAndSend(command: config.getKataPlayoutDoublingAdvantageCommand())
                messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())

                // current index might not be correct, recover it
                gobanState.forwardMoves(
                    limit: nil,
                    gameRecord: gameRecord,
                    board: board,
                    messageList: messageList,
                    player: player,
                    audioModel: audioModel,
                    stones: stones)
            }
        }
    }

    private func processIsEditingChange(oldIsEditing: Bool, newIsEditing: Bool) {
        if !newIsEditing {
            gobanState.isAutoPlaying = false
            gobanState.isAutoPlayed = false
        }
    }

    private func processChange(oldIsGameListViewAppeared: Bool,
                               newIsGameListViewAppeared: Bool) {
        if !oldIsGameListViewAppeared && newIsGameListViewAppeared && gobanState.isShownBoard {
            createThumbnail(for: navigationContext.selectedGameRecord)
        }
    }

    private func createThumbnail(for gameRecord: GameRecord?) {
        if let gameRecord {
            let maxBoardLength = max(board.width + 1, board.height + 1)
            let maxCGLength: CGFloat = ThumbnailModel.largeSize
            let cgWidth = (board.width + 1) / maxBoardLength * maxCGLength
            let cgHeight = (board.height + 1) / maxBoardLength * maxCGLength
            let cgSize = CGSize(width: cgWidth, height: cgHeight)
            let isDrawingCapturedStones = false
            let dimensions = Dimensions(size: cgSize,
                                        width: board.width,
                                        height: board.height,
                                        showCoordinate: false,
                                        showPass: false,
                                        isDrawingCapturedStones: isDrawingCapturedStones)

            let config = gameRecord.concreteConfig
            let content = ZStack {
                BoardLineView(dimensions: dimensions,
                              showPass: false,
                              verticalFlip: config.verticalFlip)

                StoneView(dimensions: dimensions,
                          isClassicStoneStyle: config.isClassicStoneStyle,
                          verticalFlip: config.verticalFlip,
                          isDrawingCapturedStones: isDrawingCapturedStones)

                AnalysisView(config: config, dimensions: dimensions)
            }
                .environment(board)
                .environment(stones)
                .environment(analysis)
                .environment(gobanState)
                .environment(player)

            let renderer = ImageRenderer(content: content)
#if os(macOS)
            if let nsImage = renderer.nsImage,
               let tiffData = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                gameRecord.thumbnail = pngData
            }
#else
            gameRecord.thumbnail = renderer.uiImage?.heicData()
#endif
        }
    }

    // Handles file import from the document picker
    private func importFiles(result: Result<[URL], any Error>) {
        // Ensure the result is a successful file URL and start accessing its security-scoped resource
        guard case .success(let files) = result else { return }

        files.forEach { file in
            if let newGameRecord = GameRecord.createGameRecord(from: file) {
                // Insert the new game record into the model context
                modelContext.insert(newGameRecord)

                // Update the selected game record in the navigation context
                navigationContext.selectedGameRecord = newGameRecord
            }
        }
    }

    private func importUrl(url: URL) {
        if let newGameRecord = GameRecord.createGameRecord(from: url) {
            // Insert the new game record into the model context
            modelContext.insert(newGameRecord)

            // Update the selected game record in the navigation context
            navigationContext.selectedGameRecord = newGameRecord
        }
    }

    private func processChange(oldGameRecord: GameRecord?, newGameRecord: GameRecord?) {
        player.nextColorForPlayCommand = .unknown
        gobanState.deactivateBranch()

        if let newGameRecord {
            newGameRecord.updateToLatestVersion()
            gobanState.isAutoPlaying = false
            gobanState.isAutoPlayed = false
            if newGameRecord.sgf == GameRecord.defaultSgf {
                gobanState.isEditing = true
            } else {
                gobanState.isEditing = false
            }
            let currentIndex = newGameRecord.currentIndex
            let sgfHelper = SgfHelper(sgf: newGameRecord.sgf)
            newGameRecord.currentIndex = sgfHelper.moveSize ?? 0

            gobanState.maybeLoadSgf(
                gameRecord: newGameRecord,
                messageList: messageList
            )

            while newGameRecord.currentIndex > currentIndex {
                newGameRecord.undo()
                gobanState.undo(messageList: messageList, stones: stones)
            }
            let config = newGameRecord.concreteConfig
            config.koRule = sgfHelper.rules.koRule
            config.scoringRule = sgfHelper.rules.scoringRule
            config.taxRule = sgfHelper.rules.taxRule
            config.multiStoneSuicideLegal = sgfHelper.rules.multiStoneSuicideLegal
            config.hasButton = sgfHelper.rules.hasButton
            config.whiteHandicapBonusRule = sgfHelper.rules.whiteHandicapBonusRule
            config.komi = sgfHelper.rules.komi

            if let oldGameRecord,
               oldGameRecord.concreteConfig.boardWidth != config.boardWidth ||
                oldGameRecord.concreteConfig.boardHeight != config.boardHeight {
                placeLoadingBoard(width: config.boardWidth, height: config.boardHeight)
            }

            messageList.appendAndSend(commands: config.ruleCommands)
            messageList.appendAndSend(command: config.getKataKomiCommand())
            messageList.appendAndSend(command: config.getKataPlayoutDoublingAdvantageCommand())
            messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())
            messageList.appendAndSend(commands: config.getSymmetricHumanAnalysisCommands())
            gobanState.sendShowBoardCommand(messageList: messageList)
        }
    }

    private func processChange(oldWaitingForAnalysis: Bool,
                               newWaitingForAnalysis: Bool) {
        if (oldWaitingForAnalysis && !newWaitingForAnalysis) {
            if let gameRecord = navigationContext.selectedGameRecord,
               let config = gameRecord.config,
               !gobanState.shouldGenMove(config: config, player: player) {
                if gobanState.analysisStatus == .pause {
                    messageList.appendAndSend(command: "stop")
                } else {
                    messageList.appendAndSend(command: config.getKataAnalyzeCommand())
                }

                if gobanState.isAutoPlaying && !analysis.info.isEmpty && stones.isReady {
                    gobanState.maybeUpdateAnalysisData(
                        gameRecord: gameRecord,
                        analysis: analysis,
                        board: board,
                        stones: stones
                    )

                    // forward move
                    let sgfHelper = SgfHelper(sgf: gameRecord.sgf)

                    if let nextMove = sgfHelper.getMove(at: gameRecord.currentIndex),
                       let move = board.locationToMove(location: nextMove.location) {
                        let nextPlayer = nextMove.player == Player.black ? "b" : "w"

                        gobanState.play(
                            turn: nextPlayer,
                            move: String(move),
                            messageList: messageList,
                            stones: stones
                        )

                        player.toggleNextColorForPlayCommand()
                        gobanState.sendShowBoardCommand(messageList: messageList)
                        audioModel.playPlaySound(soundEffect: globalSoundEffect)
                        gobanState.isAutoPlayed = true
                    } else {
                        gobanState.isAutoPlaying = false
                        gobanState.isAutoPlayed = false
                    }
                }
            }
        }
    }

    private func processChange(oldBranchStateSgf: String, newBranchStateSgf: String) {
        if (oldBranchStateSgf.isActiveSgf) &&
            (!newBranchStateSgf.isActiveSgf) {
            processChange(oldGameRecord: nil, newGameRecord: navigationContext.selectedGameRecord)
        }
    }

    private func placeLoadingBoard(width: Int, height: Int) {
        withAnimation {
            board.width = CGFloat(width)
            board.height = CGFloat(height)
            stones.blackPoints.removeAll()
            stones.whitePoints.removeAll()
            stones.moveOrder.removeAll()
            stones.blackStonesCaptured = 0
            stones.whiteStonesCaptured = 0
            stones.isReady = false
        }
    }
}
