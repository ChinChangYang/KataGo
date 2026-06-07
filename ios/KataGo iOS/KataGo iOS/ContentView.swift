//
//  ContentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/7/2.
//

import SwiftUI
import SwiftData
import KataGoInterface

struct ContentView: View {
    @Binding var selectedModel: NeuralNetworkModel?
    let engineLifecycle: EngineLifecycle
    let maxBoardLength: Int

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
    @State private var isInitialized = false
    @State var isGameListViewAppeared = false
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    @State var version: String?
    @State var thumbnailModel = ThumbnailModel()
    @State var audioModel = AudioModel()
    @State var quitStatus: QuitStatus = .none
    @State private var topUIState = TopUIState()
    @State var aiMove: String? = nil
    @State var bookLookup = BookLookup()

    var body: some View {
        if isInitialized {
            GameSplitView(
                selectedModel: $selectedModel,
                aiMove: $aiMove,
                quitStatus: $quitStatus,
                maxBoardLength: maxBoardLength
            )
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
            .environment(bookLookup)
            .task {
                // Get messages from KataGo and append to the list of messages
                await messageTask()
            }
        } else if let model = selectedModel {
            LoadingView(version: $version, selectedModel: model)
                .task {
                    await initializationTask()
                }
        }
    }

    private func initializationTask() async {
        messageList.messages.append(Message(text: "Initializing..."))
        messageList.appendAndSend(command: "version")

        version = await Task.detached {
            // Get a message line from KataGo
            return KataGoHelper.getMessageLine()
        }.value

        // Crash-loop recovery signal: the first line Swift sees from KataGo is
        // the engine's reply to `version`, which proves model loading finished
        // and the GTP loop is running. Clearing the sentinel here (via
        // `EngineLifecycle`) is what tells `ModelRunnerView` the load
        // succeeded. This relies on `KataGoCpp.cpp` redirecting only `cout`
        // (not `cerr`/logger) — any future change that lets KataGo print to
        // `cout` before the GTP loop would need to re-validate this check.
        // Long-term fix: run the engine out-of-process via XPC so a crash
        // can't take the app down at all.
        if let response = version, response.hasPrefix("= ") {
            engineLifecycle.markFirstResponse(modelTitle: selectedModel?.title ?? "")
        }

        sendInitialCommands(config: gameRecords.first?.concreteConfig)
        navigationContext.selectedGameRecord = gameRecords.first
        navigationContext.selectedGameRecord?.updateToLatestVersion()
        if gameRecords.first?.concreteConfig.isBookCompatible == true {
            bookLookup.loadIfNeeded()
        }

        gobanState.maybeLoadSgf(
            gameRecord: navigationContext.selectedGameRecord,
            messageList: messageList
        )
        
        gobanState.sendShowBoardCommand(messageList: messageList)
        messageList.appendAndSend(command: "printsgf")
        await messaging()
        try? await Task.sleep(for: .seconds(3))
        isInitialized = true
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

    func messaging() async {
        let line = await Task.detached {
            // Get a message line from KataGo
            return KataGoHelper.getMessageLine()
        }.value

        if quitStatus == .none {
            // Create a message with the line
            let message = Message(text: line)

            // Append the message to the list of messages
            messageList.messages.append(message)

            // Handle GTP error responses by resetting all pending states
            if line.hasPrefix("? ") {
                gobanState.resetPendingStatesOnError(stones: stones)
            }

            // Collect board information
            await maybeCollectBoard(message: line)

            // Collect analysis information
            await maybeCollectAnalysis(message: line)

            // Collect SGF information
            maybeCollectSgf(message: line)

            // Collect play information
            maybeCollectPlay(message: line)

            // Collect check-move response
            maybeCollectCheckMove(message: line)

            // Remove when there are too many messages
            messageList.shrink()
        }
    }

    @MainActor
    private func messageTask() async {
        while quitStatus != .quitted {
            await messaging()
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

            let rootVisits = Analysis.parseRootVisits(from: message)
            let sampleTime = ProcessInfo.processInfo.systemUptime

            withAnimation {
                analysis.info = analysisInfo.reduce([:]) {
                    $0.merging($1) { (current, _) in
                        current
                    }
                }

                analysis.ownershipUnits = ownershipUnits
                analysis.nextColorForAnalysis = player.nextColorFromShowBoard

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

    func maybeCollectPlay(message: String) {
        let playPrefix = "play "
        if message.hasPrefix(playPrefix) {
            postProcessAIMove(message: message)
        }
    }

    func maybeCollectCheckMove(message: String) {
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
