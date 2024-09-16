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
    @State var messagesObject = MessageList()
    @State var board = BoardSize()
    @State var player = Turn()
    @State var analysis = Analysis()
    @State private var isShowingBoard = false
    @State private var boardText: [String] = []
    @Query(sort: \GameRecord.lastModificationDate, order: .reverse) var gameRecords: [GameRecord]
    @Environment(\.modelContext) private var modelContext
    @State var gobanState = GobanState()
    @State var winrate = Winrate()
    @State private var navigationContext = NavigationContext()
    @State private var isEditorPresented = false
    @State private var isInitialized = false
    @State private var gobanTab = GobanTab()
    @State var importing = false
    @State var toolbarUuid = UUID()
    @Environment(\.horizontalSizeClass) var horizontalSizeClass: UserInterfaceSizeClass?
    let sgfType = UTType("ccy.KataGo-iOS.sgf")!

    init() {
        // Start a thread to run KataGo GTP
        let katagoThread = Thread {
            KataGoHelper.runGtp()
        }

        // Expand the stack size to resolve a stack overflow problem
        katagoThread.stackSize = 4096 * 256
        katagoThread.start()
    }

    var body: some View {
        if isInitialized {
            NavigationSplitView {
                GameListView(isInitialized: $isInitialized,
                             isEditorPresented: $isEditorPresented,
                             selectedGameRecord: $navigationContext.selectedGameRecord,
                             importing: $importing)
                .toolbar {
                    ToolbarItem {
                        PlusMenuView(gameRecord: navigationContext.selectedGameRecord, importing: $importing)
                            .id(toolbarUuid)
                    }
                }
                .onChange(of: horizontalSizeClass) { _, _ in
                    toolbarUuid = UUID()
                }
            } detail: {
                GobanView(isInitialized: $isInitialized,
                          isEditorPresented: $isEditorPresented,
                          importing: $importing)
            }
            .environment(stones)
            .environment(messagesObject)
            .environment(board)
            .environment(player)
            .environment(analysis)
            .environment(gobanState)
            .environment(winrate)
            .environment(navigationContext)
            .environment(gobanTab)
            .task {
                // Get messages from KataGo and append to the list of messages
                await messageTask()
            }
            .onChange(of: navigationContext.selectedGameRecord) { _, newGameRecord in
                processChange(newSelectedGameRecord: newGameRecord)
            }
            .onChange(of: gobanState.waitingForAnalysis) { oldWaitingForAnalysis, newWaitingForAnalysis in
                processChange(oldWaitingForAnalysis: oldWaitingForAnalysis,
                              newWaitingForAnalysis: newWaitingForAnalysis)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [sgfType, .text]) { result in
                importFile(result: result)
            }
        } else {
            LoadingView()
                .task {
                    await initializationTask()
                }
        }
    }

    // Handles file import from the document picker
    private func importFile(result: Result<URL, any Error>) {
        // Ensure the result is a successful file URL and start accessing its security-scoped resource
        guard case .success(let file) = result, file.startAccessingSecurityScopedResource() else { return }

        // Attempt to read the contents of the file into a string; exit if reading fails
        guard let fileContents = try? String(contentsOf: file) else { return }

        // Initialize the SGF helper with the file contents
        let sgfHelper = SgfHelper(sgf: fileContents)

        // Get the index of the last move in the SGF file; exit if no valid moves are found
        guard let lastMoveIndex = sgfHelper.getLastMoveIndex() else { return }

        // Create a dictionary of comments for each move by filtering and mapping non-empty comments
        let comments = (0...lastMoveIndex + 1)
            .compactMap { index in sgfHelper.getComment(at: index).flatMap { !$0.isEmpty ? (index, $0) : nil } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }

        // Create a new game record with the SGF content, the current move index, and the comments
        let newGameRecord = GameRecord(sgf: fileContents, currentIndex: lastMoveIndex + 1, comments: comments)

        // Insert the new game record into the model context
        modelContext.insert(newGameRecord)

        // Update the selected game record in the navigation context
        navigationContext.selectedGameRecord = newGameRecord

        // Dismiss the command interface
        gobanTab.isCommandPresented = false

        // Dismiss the configuration interface
        gobanTab.isConfigPresented = false
    }

    private func processChange(newSelectedGameRecord: GameRecord?) {
        gobanTab.isConfigPresented = false
        gobanTab.isCommandPresented = false
        player.nextColorForPlayCommand = .unknown
        if let config = newSelectedGameRecord?.config {
            maybeLoadSgf()
            KataGoHelper.sendCommand(config.getKataPlayoutDoublingAdvantageCommand())
            KataGoHelper.sendCommand(config.getKataAnalysisWideRootNoiseCommand())
            KataGoHelper.sendCommands(config.getSymmetricHumanAnalysisCommands())
            KataGoHelper.sendCommand("showboard")
            KataGoHelper.sendCommand("printsgf")
        }
    }

    private func processChange(oldWaitingForAnalysis waitedForAnalysis: Bool,
                               newWaitingForAnalysis waitingForAnalysis: Bool) {
        if (waitedForAnalysis && !waitingForAnalysis) {
            if gobanState.analysisStatus == .pause {
                KataGoHelper.sendCommand("stop")
            } else {
                if let config = navigationContext.selectedGameRecord?.config {
                    KataGoHelper.sendCommand(config.getKataAnalyzeCommand())
                }
            }
        }
    }

    private func messagingLoop() async {
        let line = await Task.detached {
            // Get a message line from KataGo
            return KataGoHelper.getMessageLine()
        }.value

        // Create a message with the line
        let message = Message(text: line)

        // Append the message to the list of messages
        messagesObject.messages.append(message)

        // Collect board information
        maybeCollectBoard(message: line)

        // Collect analysis information
        maybeCollectAnalysis(message: line)

        // Collect SGF information
        maybeCollectSgf(message: line)

        // Remove when there are too many messages
        messagesObject.shrink()
    }

    private func sendInitialCommands(config: Config) {
        KataGoHelper.sendCommand(config.getKataBoardSizeCommand())
        KataGoHelper.sendCommand(config.getKataRuleCommand())
        KataGoHelper.sendCommand(config.getKataKomiCommand())
        // Disable friendly pass to avoid a memory shortage problem
        KataGoHelper.sendCommand("kata-set-rule friendlyPassOk false")
        KataGoHelper.sendCommand(config.getKataPlayoutDoublingAdvantageCommand())
        KataGoHelper.sendCommand(config.getKataAnalysisWideRootNoiseCommand())
        KataGoHelper.sendCommands(config.getSymmetricHumanAnalysisCommands())
    }

    @MainActor
    private func initializationTask() async {
        messagesObject.messages.append(Message(text: "Initializing..."))
        sendInitialCommands(config: gameRecords.first?.config ?? Config())
        navigationContext.selectedGameRecord = gameRecords.first
        maybeLoadSgf()
        KataGoHelper.sendCommand("showboard")
        KataGoHelper.sendCommand("printsgf")
        await messagingLoop()
        isInitialized = true
    }

    @MainActor
    private func messageTask() async {
        while true {
            await messagingLoop()
        }
    }

    func maybeLoadSgf() {
        if let gameRecord = navigationContext.selectedGameRecord {
            KataGoHelper.loadSgf(gameRecord.sgf)
        }
    }

    func maybeCollectBoard(message: String) {
        // Check if the board is not currently being shown
        guard isShowingBoard else {
            // If the message indicates a new move number
            if message.hasPrefix("= MoveNum") {
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
            parseBoardPoints()

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
        }
    }

    // Parses the board text to extract and classify positions of stones and moves
    func parseBoardPoints() {
        var blackStones: [BoardPoint] = [] // Stores positions of black stones
        var whiteStones: [BoardPoint] = [] // Stores positions of white stones
        var moveOrder: [BoardPoint: Character] = [:] // Tracks the order of moves

        let (height, width) = calculateBoardDimensions() // Get current board dimensions

        // Process each line of the board text to extract stone positions and moves
        _ = boardText.dropFirst().enumerated().flatMap { (lineIndex, line) in
            let y = calculateYCoordinate(from: line) // Calculate the y-coordinate from the line
            return parseLine(line, y: y, blackStones: &blackStones, whiteStones: &whiteStones, moveOrder: &moveOrder)
        }
        
        updateStones(blackStones, whiteStones, moveOrder) // Update the state of stones on the board
        adjustBoardDimensionsIfNeeded(width: width, height: height) // Adjust dimensions if they change
    }

    // Calculates the board dimensions based on the text representation
    private func calculateBoardDimensions() -> (CGFloat, CGFloat) {
        let height = CGFloat(boardText.count - 1) // Height is based on the number of lines in board text
        let width = CGFloat((boardText.last?.dropFirst(2).count ?? 0) / 2) // Width based on the character count of the last line
        return (height, width) // Return the dimensions as a tuple
    }

    // Calculates the y-coordinate for a given line of text
    private func calculateYCoordinate(from line: String) -> Int {
        return (Int(line.prefix(2).trimmingCharacters(in: .whitespaces)) ?? 1) - 1 // Extract and adjust y-coordinate
    }

    // Parses a single line of board text and updates stone positions and move order
    private func parseLine(_ line: String, y: Int, blackStones: inout [BoardPoint], whiteStones: inout [BoardPoint], moveOrder: inout [BoardPoint: Character]) -> [(BoardPoint, Character?)] {
        return line.dropFirst(3).enumerated().compactMap { (charIndex, char) -> (BoardPoint, Character)? in
            let xCoord = charIndex / 2 // Calculate the x-coordinate from character index
            let point = BoardPoint(x: xCoord, y: y) // Create point for the board

            // Classify the character as black stone, white stone, or move number
            if char == "X" {
                blackStones.append(point) // Add black stone position
                return nil
            } else if char == "O" {
                whiteStones.append(point) // Add white stone position
                return nil
            } else if char.isNumber {
                moveOrder[point] = char // Track move number
                return nil
            }
            return nil // Ignore any other character
        }
    }

    // Updates the stones displayed on the board and triggers animation
    private func updateStones(_ blackStones: [BoardPoint], _ whiteStones: [BoardPoint], _ moveOrder: [BoardPoint: Character]) {
        stones.blackPoints = blackStones // Update black stone positions
        stones.whitePoints = whiteStones // Update white stone positions
        withAnimation(.spring) {
            stones.moveOrder = moveOrder // Animate the change of move order using spring animation
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

    func getBlackWinrate() -> Float {
        if let rootInfo = analysis.rootInfo {
            let winrate = rootInfo.winrate
            let blackWinrate = (analysis.nextColorForAnalysis == .black) ? winrate : (1 - winrate)
            return blackWinrate
        } else {
            return 0.5
        }
    }

    func maybeCollectAnalysis(message: String) {
        if message.starts(with: /info/) {
            let splitData = message.split(separator: "info")

            withAnimation {
                let analysisInfo = splitData.map {
                    extractAnalysisInfo(dataLine: String($0))
                }

                analysis.info = analysisInfo.reduce([:]) {
                    $0.merging($1 ?? [:]) { (current, _) in
                        current
                    }
                }

                if let lastData = splitData.last {
                    let lastDataString = String(lastData)

                    analysis.rootInfo = extractRootInfo(message: lastDataString)
                    analysis.ownership = extractOwnership(message: lastDataString)
                }

                analysis.nextColorForAnalysis = player.nextColorFromShowBoard
                winrate.black = getBlackWinrate()
            }

            gobanState.waitingForAnalysis = false
        }
    }

    func extractRootInfo(message: String) -> AnalysisInfo? {
        let pattern = /rootInfo visits (\d+) utility ([-\d.eE]+) winrate ([-\d.eE]+) scoreMean ([-\d.eE]+)/
        if let match = message.firstMatch(of: pattern) {
            if let visits = Int(match.1),
               let utility = Float(match.2),
               let winrate = Float(match.3),
               let scoreMean = Float(match.4) {
                return AnalysisInfo(visits: visits,
                                    winrate: winrate,
                                    scoreLead: scoreMean,
                                    utilityLcb: utility)
            }
        }

        return nil
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
        if let match = dataLine.firstMatch(of: pattern) {
            let winrate = Float(match.1)
            return winrate
        }

        return nil
    }

    func matchScoreLeadPattern(dataLine: String) -> Float? {
        let pattern = /scoreLead ([-\d.eE]+)/
        if let match = dataLine.firstMatch(of: pattern) {
            let scoreLead = Float(match.1)
            return scoreLead
        }

        return nil
    }

    func matchUtilityLcbPattern(dataLine: String) -> Float? {
        let pattern = /utilityLcb ([-\d.eE]+)/
        if let match = dataLine.firstMatch(of: pattern) {
            let utilityLcb = Float(match.1)
            return utilityLcb
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

    func extractOwnership(message: String) -> [BoardPoint: Ownership] {
        let mean = extractOwnershipMean(message: message)
        let stdev = extractOwnershipStdev(message: message)
        if !mean.isEmpty && !stdev.isEmpty {
            var dictionary: [BoardPoint: Ownership] = [:]
            var i = 0
            for y in stride(from:Int(board.height - 1), through: 0, by: -1) {
                for x in 0..<Int(board.width) {
                    let point = BoardPoint(x: x, y: y)
                    dictionary[point] = Ownership(mean: mean[i], stdev: stdev[i])
                    i = i + 1
                }
            }
            return dictionary
        }

        return [:]
    }

    func maybeCollectSgf(message: String) {
        let sgfPrefix = "= (;FF[4]GM[1]"
        if message.hasPrefix(sgfPrefix) {
            if let startOfSgf = message.firstIndex(of: "(") {
                let sgfString = String(message[startOfSgf...])
                let lastMoveIndex = SgfHelper(sgf: sgfString).getLastMoveIndex() ?? -1
                let currentIndex = lastMoveIndex + 1
                if gameRecords.isEmpty {
                    // Automatically generate and select a new game when there are no games in the list
                    let newGameRecord = GameRecord(sgf: sgfString, currentIndex: currentIndex)
                    modelContext.insert(newGameRecord)
                    navigationContext.selectedGameRecord = newGameRecord
                } else if let gameRecord = navigationContext.selectedGameRecord {
                    gameRecord.sgf = sgfString
                    gameRecord.currentIndex = currentIndex
                    gameRecord.lastModificationDate = Date.now
                }
            }
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: GameRecord.self, configurations: config)

    return ContentView()
        .modelContainer(container)
}
