//
//  ContentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import SwiftUI
import SwiftData
import KataGoInterface
import UniformTypeIdentifiers

struct ContentView: View {
    @State var stones = Stones()
    @State var messageList = MessageList()
    @State var board = BoardSize()
    @State var player = Turn()
    @State var analysis = Analysis()
    @State private var isShowingBoard = false
    @State private var boardText: [String] = []
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext
    @State var gobanState = GobanState()
    @State var rootWinrate = Winrate()
    @State var rootScore = Score()
    @State private var navigationContext = NavigationContext()
    @State private var isEditorPresented = false
    @State private var isInitialized = false
    @State var isGameListViewAppeared = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.scenePhase) var scenePhase
    @State var version: String?
    @State var thumbnailModel = ThumbnailModel()
    @State var audioModel = AudioModel()
    @State var quitStatus: QuitStatus = .none
    @State var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var topUIState = TopUIState()
    @State var aiMove: String? = nil
    let sgfType = UTType("ccy.KataGo-iOS.sgf")!
    let selectedModel: NeuralNetworkModel

    var body: some View {
        if isInitialized {
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
                            playAIMove(gameRecord: gameRecord, turn: turn)
                        }
                    }

                    Button("Cancel", role: .cancel) {
                        gobanState.confirmingAIOverwrite = false
                        gobanState.analysisStatus = .clear
                    }
                }
            }
            .environment(stones)
            .environment(messageList)
            .environment(board)
            .environment(player)
            .environment(analysis)
            .environment(gobanState)
            .environment(rootWinrate)
            .environment(rootScore)
            .environment(navigationContext)
            .environment(thumbnailModel)
            .environment(audioModel)
            .environment(topUIState)
            .task {
                // Get messages from KataGo and append to the list of messages
                await messageTask()
            }
            .onChange(of: navigationContext.selectedGameRecord) { oldGameRecord, newGameRecord in
                createThumbnail(for: oldGameRecord)
                processChange(oldGameRecord: oldGameRecord, newGameRecord: newGameRecord)
            }
            .onChange(of: gobanState.waitingForAnalysis) { oldWaitingForAnalysis, newWaitingForAnalysis in
                processChange(oldWaitingForAnalysis: oldWaitingForAnalysis,
                              newWaitingForAnalysis: newWaitingForAnalysis)
            }
            .fileImporter(isPresented: $topUIState.importing,
                          allowedContentTypes: [sgfType, .text],
                          allowsMultipleSelection: true) { result in
                importFiles(result: result)
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
        } else {
            LoadingView(version: $version, selectedModel: selectedModel)
                .task {
                    await initializationTask()
                }
        }
    }

    func processStonesReadyChange(oldValue: Bool, newValue: Bool) {
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

    func processIsAutoPlayingChange(oldIsAutoPlaying: Bool,
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
            }
        }
    }

    func processIsEditingChange(oldIsEditing: Bool, newIsEditing: Bool) {
        if !newIsEditing {
            gobanState.isAutoPlaying = false
            gobanState.isAutoPlayed = false
        }
    }

    func processChange(oldIsGameListViewAppeared: Bool,
                       newIsGameListViewAppeared: Bool) {
        if !oldIsGameListViewAppeared && newIsGameListViewAppeared && gobanState.isShownBoard {
            createThumbnail(for: navigationContext.selectedGameRecord)
        }
    }

    func createThumbnail(for gameRecord: GameRecord?) {
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
            maybeLoadSgf()
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
                        audioModel.playPlaySound(soundEffect: gameRecord.config?.soundEffect ?? false)
                        gobanState.isAutoPlayed = true
                    } else {
                        gobanState.isAutoPlaying = false
                        gobanState.isAutoPlayed = false
                    }
                }
            }
        }
    }

    private func processChange(newScenePhase: ScenePhase) {
        if newScenePhase == .background {
            createThumbnail(for: navigationContext.selectedGameRecord)
            gobanState.maybePauseAnalysis()
        }
    }

    private func processChange(oldBranchStateSgf: String, newBranchStateSgf: String) {
        if (oldBranchStateSgf.isActiveSgf) &&
            (!newBranchStateSgf.isActiveSgf) {
            processChange(oldGameRecord: nil, newGameRecord: navigationContext.selectedGameRecord)
        }
    }

    private func messaging() async {
        let line = await Task.detached {
            // Get a message line from KataGo
            return KataGoHelper.getMessageLine()
        }.value

        if quitStatus == .none {
            // Create a message with the line
            let message = Message(text: line)

            // Append the message to the list of messages
            messageList.messages.append(message)

            // Collect board information
            await maybeCollectBoard(message: line)

            // Collect analysis information
            await maybeCollectAnalysis(message: line)

            // Collect SGF information
            maybeCollectSgf(message: line)

            // Collect play information
            maybeCollectPlay(message: line)

            // Remove when there are too many messages
            messageList.shrink()
        }
    }

    private func sendInitialCommands(config: Config?) {
        // If a config is not available, initialize KataGo with a default config.
        let config = config ?? Config()
        messageList.appendAndSend(command: config.getKataBoardSizeCommand())
        messageList.appendAndSend(commands: config.ruleCommands)
        messageList.appendAndSend(command: config.getKataKomiCommand())
        // Disable friendly pass to avoid a memory shortage problem
        messageList.appendAndSend(command: "kata-set-rule friendlyPassOk false")
        messageList.appendAndSend(command: config.getKataPlayoutDoublingAdvantageCommand())
        messageList.appendAndSend(command: config.getKataAnalysisWideRootNoiseCommand())
        messageList.appendAndSend(commands: config.getSymmetricHumanAnalysisCommands())
    }

    @MainActor
    private func initializationTask() async {
        messageList.messages.append(Message(text: "Initializing..."))
        messageList.appendAndSend(command: "version")

        version = await Task.detached {
            // Get a message line from KataGo
            return KataGoHelper.getMessageLine()
        }.value

        sendInitialCommands(config: gameRecords.first?.concreteConfig)
        navigationContext.selectedGameRecord = gameRecords.first
        navigationContext.selectedGameRecord?.updateToLatestVersion()
        maybeLoadSgf()
        gobanState.sendShowBoardCommand(messageList: messageList)
        messageList.appendAndSend(command: "printsgf")
        await messaging()
        try? await Task.sleep(for: .seconds(3))
        isInitialized = true
    }

    @MainActor
    private func messageTask() async {
        while quitStatus != .quitted {
            await messaging()
        }
    }

    func maybeLoadSgf() {
        if let sgf = gobanState.getSgf(gameRecord: navigationContext.selectedGameRecord) {
            messageList.maybeLoadSgf(sgf: sgf)
        }
    }

    func maybeCollectBoard(message: String) async {
        // Check if the board is not currently being shown
        guard isShowingBoard else {
            // If the message indicates a new move number
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
            // Parse the current board state
            await parseBoardPoints(boardText: boardText)

            // Determine the next player color based on the message content
            player.nextColorForPlayCommand = message.contains("Black") ? .black : .white
            // Set the next player's color from showing board
            player.nextColorFromShowBoard = player.nextColorForPlayCommand
        }

        // Append the current message to the board text
        boardText.append(message)

        // Check for captured black stones in the message
        if let match = message.firstMatch(of: /B stones captured: (\d+)/),
           let blackStonesCaptured = Int(match.1),
           stones.blackStonesCaptured != blackStonesCaptured {
            withAnimation {
                // Update the count of captured black stones
                stones.blackStonesCaptured = blackStonesCaptured
            }
        }

        // Check for the end of the board show with captured white stones
        if message.hasPrefix("W stones captured") {
            // Set the flag to stop showing the board
            isShowingBoard = false
            // Capture the count of white stones captured
            if let match = message.firstMatch(of: /W stones captured: (\d+)/),
               let whiteStonesCaptured = Int(match.1),
               stones.whiteStonesCaptured != whiteStonesCaptured {
                withAnimation {
                    // Update the count of captured white stones
                    stones.whiteStonesCaptured = whiteStonesCaptured
                }
            }

            stones.isReady = true
        }
    }

    func parseStones(boardText: [String]) async -> (width: CGFloat, height: CGFloat, blackStones: [BoardPoint], whiteStones: [BoardPoint], moveOrder: [BoardPoint: Character]) {
        let (height, width) = calculateBoardDimensions(boardText: boardText) // Get current board dimensions
        var blackStones: [BoardPoint] = [] // Stores positions of black stones
        var whiteStones: [BoardPoint] = [] // Stores positions of white stones
        var moveOrder: [BoardPoint: Character] = [:] // Tracks the order of moves

        // Process each line of the board text to extract stone positions and moves
        for (_, line) in boardText.dropFirst().enumerated() {
            let y = calculateYCoordinate(from: line) // Calculate the y-coordinate from the line
            parseLine(line, y: y, blackStones: &blackStones, whiteStones: &whiteStones, moveOrder: &moveOrder)
        }

        return (width, height, blackStones, whiteStones, moveOrder)
    }

    // Parses the board text to extract and classify positions of stones and moves
    func parseBoardPoints(boardText: [String]) async {
        let (width, height, blackStones, whiteStones, moveOrder) = await parseStones(boardText: boardText)

        withAnimation(.none) {
            stones.blackPoints = blackStones // Update black stone positions
            stones.whitePoints = whiteStones // Update white stone positions
            adjustBoardDimensionsIfNeeded(width: width, height: height) // Adjust dimensions if they change
        } completion: {
            withAnimation(.spring) {
                stones.moveOrder = moveOrder // Animate the change of move order using spring animation
            }
        }
    }

    // Calculates the board dimensions based on the text representation
    private func calculateBoardDimensions(boardText: [String]) -> (CGFloat, CGFloat) {
        let height = CGFloat(boardText.count - 1) // Height is based on the number of lines in board text
        let width = CGFloat((boardText.last?.dropFirst(2).count ?? 0) / 2) // Width based on the character count of the last line
        return (height, width) // Return the dimensions as a tuple
    }

    // Calculates the y-coordinate for a given line of text
    private func calculateYCoordinate(from line: String) -> Int {
        return (Int(line.prefix(2).trimmingCharacters(in: .whitespaces)) ?? 1) - 1 // Extract and adjust y-coordinate
    }

    // Parses a single line of board text and updates stone positions and move order
    private func parseLine(_ line: String, y: Int, blackStones: inout [BoardPoint], whiteStones: inout [BoardPoint], moveOrder: inout [BoardPoint: Character]) {
        for (charIndex, char) in line.dropFirst(3).enumerated() {
            let xCoord = charIndex / 2 // Calculate the x-coordinate from character index
            let point = BoardPoint(x: xCoord, y: y) // Create point for the board

            // Classify the character as black stone, white stone, or move number
            if char == "X" {
                blackStones.append(point) // Add black stone position
            } else if char == "O" {
                whiteStones.append(point) // Add white stone position
            } else if char.isNumber {
                moveOrder[point] = char // Track move number
            }
        }
    }

    // Adjusts the board dimensions if they differ from the current settings
    private func adjustBoardDimensionsIfNeeded(width: CGFloat, height: CGFloat) {
        // Check if the new dimensions differ from the current dimensions
        if width != board.width || height != board.height {
            analysis.clear() // Clear previous analysis data to reset
            board.width = width // Update the board's width
            board.height = height // Update the board's height
        }
    }

    func collectAnalysisInfo(message: String) async -> ([[BoardPoint: AnalysisInfo]], String.SubSequence?) {
        let splitData = message.split(separator: "info")
        let analysisInfo = splitData.compactMap {
            extractAnalysisInfo(dataLine: String($0))
        }

        return (analysisInfo, splitData.last)
    }

    func computeDefiniteness(_ whiteness: Float) -> Float {
        return Swift.abs(whiteness - 0.5) * 2
    }

    func computeOpacity(scale x: Float) -> Float {
        let a = 100.0
        let b = 0.25
        let opacity = Float(0.8 / (1.0 + exp(-a * (Double(x) - b))))
        return opacity
    }

    func extractOwnershipUnits(lastData: String.SubSequence?, nextColorFromShowBoard: PlayerColor, width: Int, height: Int) async -> [OwnershipUnit] {
        guard let lastData else { return [] }
        let message = String(lastData)
        let mean = extractOwnershipMean(message: message)
        let stdev = extractOwnershipStdev(message: message)
        guard !mean.isEmpty && !stdev.isEmpty else { return [] }
        var ownershipUnits: [OwnershipUnit] = []
        var i = 0

        for y in stride(from:(height - 1), through: 0, by: -1) {
            for x in 0..<width {
                let point = BoardPoint(x: x, y: y)
                let whiteness = (mean[i] + 1) / 2
                // digitize for performance
                let digit: Float = 5
                let digitizedWhiteness = (whiteness * digit).rounded() / digit
                let digitizedStdev = (stdev[i] * digit).rounded() / digit
                let definiteness = computeDefiniteness(digitizedWhiteness)
                // Show a black or white square if definiteness is high and stdev is low
                // Show nothing if definiteness is low and stdev is low
                // Show a square with linear gradient of black and white if definiteness is low and stdev is high
                let scale = max(definiteness, digitizedStdev) * 0.65
                let opacity = computeOpacity(scale: scale)

                ownershipUnits.append(
                    OwnershipUnit(
                        point: point,
                        whiteness: digitizedWhiteness,
                        scale: scale,
                        opacity: opacity
                    )
                )

                i = i + 1
            }
        }

        return ownershipUnits
    }

    func maybeCollectAnalysis(message: String) async {
        guard gobanState.showBoardCount == 0 else { return }
        if message.starts(with: /info/) {
            let (analysisInfo, lastData) = await collectAnalysisInfo(message: message)

            let ownershipUnits = await extractOwnershipUnits(lastData: lastData, nextColorFromShowBoard: player.nextColorFromShowBoard, width: Int(board.width), height: Int(board.height))

            withAnimation {
                analysis.info = analysisInfo.reduce([:]) {
                    $0.merging($1) { (current, _) in
                        current
                    }
                }

                analysis.ownershipUnits = ownershipUnits
                analysis.nextColorForAnalysis = player.nextColorFromShowBoard

                if let blackWinrate = analysis.blackWinrate {
                    rootWinrate.black = blackWinrate
                }

                rootScore.black = analysis.blackScore ?? 0
            }

            gobanState.waitingForAnalysis = analysisInfo.isEmpty
        }
    }

    func moveToPoint(move: String) -> BoardPoint? {
        let pattern = /([^\d\W]+)(\d+)/
        if let match = move.firstMatch(of: pattern),
           let coordinate = Coordinate(xLabel: String(match.1),
                                       yLabel: String(match.2),
                                       width: Int(board.width),
                                       height: Int(board.height)) {
            // Subtract 1 from y to make it 0-indexed
            return BoardPoint(x: coordinate.x, y: coordinate.y - 1)
        } else {
            return nil
        }
    }

    // Matches a move pattern in the provided data line, returning the corresponding BoardPoint if found
    func matchMovePattern(dataLine: String) -> BoardPoint? {
        let movePattern = /move (\w+\d+)/ // Regular expression to match standard moves
        let passPattern = /move pass/ // Regular expression to match "pass" moves

        // Search for a standard move pattern in the data line
        if let match = dataLine.firstMatch(of: movePattern) {
            let move = String(match.1) // Extract the move string
            if let point = moveToPoint(move: move) { // Translate the move into a BoardPoint
                return point // Return the corresponding BoardPoint
            }
            // Check if the data line indicates a "pass" move
        } else if dataLine.firstMatch(of: passPattern) != nil {
            return BoardPoint.pass(width: Int(board.width), height: Int(board.height)) // Return a pass move
        }

        return nil // Return nil if no valid move pattern is matched
    }

    func matchVisitsPattern(dataLine: String) -> Int? {
        let pattern = /visits (\d+)/
        if let match = dataLine.firstMatch(of: pattern) {
            let visits = Int(match.1)
            return visits
        }

        return nil
    }

    func matchWinratePattern(dataLine: String) -> Float? {
        let pattern = /winrate ([-\d.eE]+)/
        if let match = dataLine.firstMatch(of: pattern),
           let winrate = Float(match.1) {
            if player.nextColorFromShowBoard == .black {
                return 1.0 - winrate
            } else {
                return winrate
            }
        }

        return nil
    }

    func matchScoreLeadPattern(dataLine: String) -> Float? {
        let pattern = /scoreLead ([-\d.eE]+)/
        if let match = dataLine.firstMatch(of: pattern),
           let scoreLead = Float(match.1) {
            if player.nextColorFromShowBoard == .black {
                return -scoreLead
            } else {
                return scoreLead
            }
        }

        return nil
    }

    func matchUtilityLcbPattern(dataLine: String) -> Float? {
        let pattern = /utilityLcb ([-\d.eE]+)/
        if let match = dataLine.firstMatch(of: pattern),
           let utilityLcb = Float(match.1) {
            if player.nextColorFromShowBoard == .black {
                return -utilityLcb
            } else {
                return utilityLcb
            }
        }

        return nil
    }

    func extractAnalysisInfo(dataLine: String) -> [BoardPoint: AnalysisInfo]? {
        let point = matchMovePattern(dataLine: dataLine)
        let visits = matchVisitsPattern(dataLine: dataLine)
        let winrate = matchWinratePattern(dataLine: dataLine)
        let scoreLead = matchScoreLeadPattern(dataLine: dataLine)
        let utilityLcb = matchUtilityLcbPattern(dataLine: dataLine)

        if let point, let visits, let winrate, let scoreLead, let utilityLcb {
            // Winrate is 0.5 when visits = 0, so skip those analysis to let win rate bar stable.
            guard visits > 0 || winrate != 0.5 else { return nil }
            let analysisInfo = AnalysisInfo(visits: visits, winrate: winrate, scoreLead: scoreLead, utilityLcb: utilityLcb)

            return [point: analysisInfo]
        }

        return nil
    }

    func extractOwnershipMean(message: String) -> [Float] {
        let pattern = /ownership ([-\d\s.eE]+)/
        if let match = message.firstMatch(of: pattern) {
            let mean = match.1.split(separator: " ").compactMap { Float($0)
            }
            // Return mean if it is valid
            if mean.count == Int(board.width * board.height) {
                return mean
            }
        }

        return []
    }

    func extractOwnershipStdev(message: String) -> [Float] {
        let pattern = /ownershipStdev ([-\d\s.eE]+)/
        if let match = message.firstMatch(of: pattern) {
            let stdev = match.1.split(separator: " ").compactMap { Float($0)
            }
            // Check stdev if it is valid
            if stdev.count == Int(board.width * board.height) {
                return stdev
            }
        }

        return []
    }

    func maybeCollectSgf(message: String) {
        let sgfPrefix = "= (;FF[4]GM[1]"
        if message.hasPrefix(sgfPrefix) {
            if let startOfSgf = message.firstIndex(of: "(") {
                let sgfString = String(message[startOfSgf...])
                let sgfHelper = SgfHelper(sgf: sgfString)
                let currentIndex = sgfHelper.moveSize ?? 0
                if gameRecords.isEmpty {
                    // Automatically generate and select a new game when there are no games in the list
                    let newGameRecord = GameRecord.createGameRecord(sgf: sgfString, currentIndex: currentIndex)
                    modelContext.insert(newGameRecord)
                    navigationContext.selectedGameRecord = newGameRecord
                    gobanState.isEditing = true
                } else if gobanState.isBranchActive {
                    gobanState.branchSgf = sgfString
                    gobanState.branchIndex = currentIndex
                } else if let gameRecord = navigationContext.selectedGameRecord {
                    gameRecord.sgf = sgfString
                    gameRecord.currentIndex = currentIndex
                    gameRecord.lastModificationDate = Date.now
                    gobanState.maybeUpdateMoves(gameRecord: gameRecord, board: board, sgfHelper: sgfHelper)
                }
            }
        }
    }

    func postProcessAIMove(message: String) {
        let pattern = /play (pass|\w+\d+)/
        if let match = message.firstMatch(of: pattern),
           let turn = player.nextColorSymbolForPlayCommand {
            let move = String(match.1)
            aiMove = move
            if let gameRecord = navigationContext.selectedGameRecord {
                if gobanState.isOverwriting(gameRecord: gameRecord) {
                    gobanState.confirmingAIOverwrite = true
                } else {
                    playAIMove(gameRecord: gameRecord, turn: turn)
                }
            }
        }
    }

    func playAIMove(gameRecord: GameRecord, turn: String) {
        guard let aiMove = aiMove else { return }

        if gobanState.isEditing {
            gameRecord.clearData(after: gameRecord.currentIndex)

            gobanState.maybeUpdateAnalysisData(
                gameRecord: gameRecord,
                analysis: analysis,
                board: board,
                stones: stones
            )
        } else if !gobanState.isBranchActive {
            gobanState.branchSgf = gameRecord.sgf
            gobanState.branchIndex = gameRecord.currentIndex
        }

        gobanState.play(turn: turn, move: aiMove, messageList: messageList, stones: stones)
        player.toggleNextColorForPlayCommand()
        gobanState.sendShowBoardCommand(messageList: messageList)
        messageList.appendAndSend(command: "printsgf")
        if let config = gameRecord.config {
            audioModel.playPlaySound(soundEffect: config.soundEffect)
        }
    }

    func maybeCollectPlay(message: String) {
        let playPrefix = "play "
        if message.hasPrefix(playPrefix) {
            postProcessAIMove(message: message)
        }
    }
}
