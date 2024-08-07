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
    @State var messagesObject = MessagesObject()
    @State var board = ObservableBoard()
    @State var player = PlayerObject()
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

    init() {
        // Start a thread to run KataGo GTP
        Thread {
            KataGoHelper.runGtp()
        }.start()
    }

    var body: some View {
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
    }

    private func processChange(newSelectedGameRecord: GameRecord?) {
        if let config = newSelectedGameRecord?.config {
            maybeLoadSgf()
            KataGoHelper.sendCommand(config.getKataPlayoutDoublingAdvantageCommand())
            KataGoHelper.sendCommand(config.getKataAnalysisWideRootNoiseCommand())
            KataGoHelper.sendCommand("kata-set-param humanSLProfile \(config.humanSLProfile)")
            KataGoHelper.sendCommand("kata-set-param humanSLRootExploreProbWeightful \(config.humanSLRootExploreProbWeightful)")
            KataGoHelper.sendCommand("showboard")
            if (gobanState.analysisStatus == .run) {
                gobanState.requestAnalysis(config: config)
            }
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

    @MainActor
    private func messageTask() async {
        let defaultConfig = Config()
        messagesObject.messages.append(Message(text: "Initializing..."))
        KataGoHelper.sendCommand(defaultConfig.getKataBoardSizeCommand())
        KataGoHelper.sendCommand(defaultConfig.getKataRuleCommand())
        KataGoHelper.sendCommand(defaultConfig.getKataKomiCommand())
        // Disable friendly pass to avoid a memory shortage problem
        KataGoHelper.sendCommand("kata-set-rule friendlyPassOk false")
        KataGoHelper.sendCommand(defaultConfig.getKataPlayoutDoublingAdvantageCommand())
        KataGoHelper.sendCommand(defaultConfig.getKataAnalysisWideRootNoiseCommand())
        navigationContext.selectedGameRecord = gameRecords.first
        maybeLoadSgf()
        KataGoHelper.sendCommand("showboard")
        KataGoHelper.sendCommand("printsgf")
        gobanState.requestAnalysis(config: defaultConfig)

        while true {
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

            isInitialized = true
        }
    }

    func maybeLoadSgf() {
        if let gameRecord = navigationContext.selectedGameRecord {
            let sgf = gameRecord.sgf

            let supportDirectory =
            try? FileManager.default.url(for: .documentDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true)

            if let supportDirectory {
                let file = supportDirectory.appendingPathComponent("temp.sgf")
                do {
                    try sgf.write(to: file, atomically: false, encoding: .utf8)
                    let path = file.path()
                    KataGoHelper.sendCommand("loadsgf \(path)")
                } catch {
                    // Do nothing
                }
            }
        }
    }

    func maybeCollectBoard(message: String) {
        if isShowingBoard {
            if message.prefix("Next player".count) == "Next player" {
                isShowingBoard = false
                var newBoardWidth: CGFloat
                var newBoardHeight: CGFloat
                (stones.blackPoints, stones.whitePoints, newBoardWidth, newBoardHeight, stones.moveOrder) = parseBoardPoints(board: boardText)
                if (newBoardWidth != board.width) || (newBoardHeight != board.height) {
                    analysis.clear()
                }
                board.width = newBoardWidth
                board.height = newBoardHeight
                if message.prefix("Next player: Black".count) == "Next player: Black" {
                    player.nextColorForPlayCommand = .black
                    player.nextColorFromShowBoard = .black
                } else {
                    player.nextColorForPlayCommand = .white
                    player.nextColorFromShowBoard = .white
                }
            } else {
                boardText.append(message)
            }
        } else {
            if message.prefix("= MoveNum".count) == "= MoveNum" {
                boardText = []
                isShowingBoard = true
            }
        }
    }

    func parseBoardPoints(board: [String]) -> ([BoardPoint], [BoardPoint], CGFloat, CGFloat, [Character: BoardPoint]) {
        var blackStones: [BoardPoint] = []
        var whiteStones: [BoardPoint] = []

        let height = CGFloat(board.count - 1)  // Subtracting 1 to exclude the header
        let width = CGFloat((board.last?.dropFirst(2).count ?? 0) / 2)  // Drop the first 2 characters for the y-coordinate and divide by 2 because of spaces between cells
        var moveOrder: [Character: BoardPoint] = [:]

        // Start from index 1 to skip the header line
        for (lineIndex, line) in board.enumerated() where lineIndex > 0 {
            // Get y-coordinate from the beginning of the line, and subtract 1 to start from 0
            let y = (Int(line.prefix(2).trimmingCharacters(in: .whitespaces)) ?? 1) - 1

            // Start parsing after the space that follows the y-coordinate
            for (charIndex, char) in line.dropFirst(3).enumerated() where char == "X" || char == "O" || char.isNumber {
                let xCoord = charIndex / 2
                if char == "X" {
                    blackStones.append(BoardPoint(x: xCoord, y: y))
                } else if char == "O" {
                    whiteStones.append(BoardPoint(x: xCoord, y: y))
                } else {
                    if char.isNumber {
                        moveOrder[char] = BoardPoint(x: xCoord, y: y)
                    }
                }
            }
        }

        return (blackStones, whiteStones, width, height, moveOrder)
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
