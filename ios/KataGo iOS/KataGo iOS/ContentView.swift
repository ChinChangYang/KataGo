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

    init() {
        // Start a thread to run KataGo GTP
        Thread {
            KataGoHelper.runGtp()
        }.start()
    }

    var body: some View {
        if isInitialized {
            NavigationSplitView {
                GameListView(isInitialized: $isInitialized,
                             isEditorPresented: $isEditorPresented,
                             selectedGameRecord: $navigationContext.selectedGameRecord)
            } detail: {
                GobanView(isInitialized: $isInitialized,
                          isEditorPresented: $isEditorPresented)
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
        } else {
            UnselectedGameView()
                .task {
                    await initializationTask()
                }
        }
    }

    private func processChange(newSelectedGameRecord: GameRecord?) {
        gobanTab.isConfigPresented = false
        gobanTab.isCommandPresented = false
        player.nextColorForPlayCommand = .unknown
        if let config = newSelectedGameRecord?.config {
            maybeLoadSgf()
            KataGoHelper.sendCommand(config.getKataPlayoutDoublingAdvantageCommand())
            KataGoHelper.sendCommand(config.getKataAnalysisWideRootNoiseCommand())
            gobanState.maybeSendSymmetricHumanAnalysisCommands(config: config)
            KataGoHelper.sendCommand("showboard")
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
        gobanState.maybeSendSymmetricHumanAnalysisCommands(config: config)
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
           let blackStonesCaptured = Int(match.1) {
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
               let whiteStonesCaptured = Int(match.1) {
                withAnimation {
                    // Update the count of captured white stones
                    stones.whiteStonesCaptured = whiteStonesCaptured
                }
            }
        }
    }

    func parseBoardPoints() {
        // Arrays to store positions of black and white stones
        var blackStones: [BoardPoint] = []
        var whiteStones: [BoardPoint] = []
        // Dictionary to keep track of the order of moves
        var moveOrder: [BoardPoint: Character] = [:]

        // Calculate the height based on the number of lines in board text
        let height = CGFloat(boardText.count - 1)
        // Calculate the width based on the last line's character count
        let width = CGFloat((boardText.last?.dropFirst(2).count ?? 0) / 2)

        // Parse the board text to extract stone positions and moves
        _ = boardText.dropFirst().enumerated().flatMap { (lineIndex, line) -> [(BoardPoint, Character?)] in
            // Calculate the y-coordinate from line number
            let y = (Int(line.prefix(2).trimmingCharacters(in: .whitespaces)) ?? 1) - 1

            return line.dropFirst(3).enumerated().compactMap { (charIndex, char) -> (BoardPoint, Character)? in
                // Calculate the x-coordinate from the character index
                let xCoord = charIndex / 2
                // Create a point on the board
                let point = BoardPoint(x: xCoord, y: y)

                // Evaluate the character to determine stone color or move order
                if char == "X" { // Black stone
                    blackStones.append(point)
                    return nil
                } else if char == "O" { // White stone
                    whiteStones.append(point)
                    return nil
                } else if char.isNumber { // Move number
                    moveOrder[point] = char
                    return nil
                }
                return nil // For any other character, return nil
            }
        }

        // Assign the observable stones
        stones.blackPoints = blackStones
        stones.whitePoints = whiteStones
        // Animate the change of move order
        withAnimation(.spring) {
            stones.moveOrder = moveOrder
        }

        // Adjust the board dimensions if changed
        if width != board.width || height != board.height {
            // Clear previous analysis before resizing
            analysis.clear()
            // Update board dimensions
            board.width = width
            board.height = height
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
                                       yLabel: String(match.2)) {
            // Subtract 1 from y to make it 0-indexed
            return BoardPoint(x: coordinate.x, y: coordinate.y - 1)
        } else {
            return nil
        }
    }

    func matchMovePattern(dataLine: String) -> BoardPoint? {
        let pattern = /move (\w+\d+)/
        if let match = dataLine.firstMatch(of: pattern) {
            let move = String(match.1)
            if let point = moveToPoint(move: move) {
                return point
            }
        }

        return nil
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
