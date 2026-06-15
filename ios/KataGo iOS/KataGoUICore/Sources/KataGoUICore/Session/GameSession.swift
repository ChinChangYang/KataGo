//
//  GameSession.swift
//  KataGoUICore
//
//  Created by Chin-Chang Yang on 2026/6/15.
//

import SwiftUI
import SwiftData

/// View-independent owner of the engine-driven game state and the GTP message
/// loop. Extracted from `ContentView` so non-SwiftUI hosts (e.g. the macOS
/// AppKit app) can drive the same engine without an iOS view.
///
/// The methods here were moved verbatim from `ContentView`; the only changes
/// are `self.`-qualification of session-owned members and replacing the loop's
/// `quitStatus` checks with `!stopRequested`. View/app-only collaborators
/// (`NavigationContext`, `AudioModel`, the `aiMove` binding, `gameRecords`,
/// `modelContext`, `EngineLifecycle`) are passed in as parameters rather than
/// owned here.
@Observable
@MainActor
public final class GameSession {
    public let stones = Stones()
    public let messageList = MessageList()
    public let board = BoardSize()
    public let player = Turn()
    public let analysis = Analysis()
    public let gobanState = GobanState()
    public let rootWinrate = Winrate()
    public let rootScore = Score()
    public let bookLookup = BookLookup()

    /// Drives the message loop's termination. Set to `true` by the host when it
    /// wants `run()` to stop (mirrors `quitStatus == .quitted`).
    public var stopRequested = false

    private var isShowingBoard = false
    private var boardText: [String] = []

    public init() {}

    // MARK: - Initialization

    /// Engine version/first-response handshake. Sends `version`, reads the
    /// reply line, clears the crash-loop sentinel via `EngineLifecycle` on a
    /// `= ` prefix, then sends the initial GTP commands for `config`.
    ///
    /// Returns the version line so the host can surface it (the iOS app binds
    /// it into `LoadingView`).
    @discardableResult
    public func initialize(
        selectedModelTitle: String,
        engineLifecycle: EngineLifecycle,
        config: Config?
    ) async -> String? {
        messageList.messages.append(Message(text: "Initializing..."))
        messageList.appendAndSend(command: "version")

        let version = await Task.detached {
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
        if version.hasPrefix("= ") {
            engineLifecycle.markFirstResponse(modelTitle: selectedModelTitle)
        }

        sendInitialCommands(config: config)
        return version
    }

    public func sendInitialCommands(config: Config?) {
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

    // MARK: - Message loop

    public func messaging(
        gameRecords: [GameRecord],
        modelContext: ModelContext,
        navigationContext: NavigationContext,
        audioModel: AudioModel,
        aiMove: Binding<String?>
    ) async {
        let line = await Task.detached {
            // Get a message line from KataGo
            return KataGoHelper.getMessageLine()
        }.value

        if !stopRequested {
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
            maybeCollectSgf(
                message: line,
                gameRecords: gameRecords,
                modelContext: modelContext,
                navigationContext: navigationContext
            )

            // Collect play information
            maybeCollectPlay(
                message: line,
                navigationContext: navigationContext,
                audioModel: audioModel,
                aiMove: aiMove
            )

            // Collect check-move response
            maybeCollectCheckMove(
                message: line,
                navigationContext: navigationContext,
                audioModel: audioModel
            )

            // Remove when there are too many messages
            messageList.shrink()
        }
    }

    public func run(
        gameRecords: [GameRecord],
        modelContext: ModelContext,
        navigationContext: NavigationContext,
        audioModel: AudioModel,
        aiMove: Binding<String?>
    ) async {
        while !stopRequested {
            await messaging(
                gameRecords: gameRecords,
                modelContext: modelContext,
                navigationContext: navigationContext,
                audioModel: audioModel,
                aiMove: aiMove
            )
        }
    }

    // MARK: - Collectors

    public func maybeCollectBoard(message: String) async {
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
            parseBoardPoints(boardText: boardText)

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

    // Parses the board text to extract and classify positions of stones and moves
    public func parseBoardPoints(boardText: [String]) {
        let parsed = BoardTextParser.parse(boardText)

        withAnimation(.none) {
            self.stones.blackPoints = parsed.blackStones
            self.stones.whitePoints = parsed.whiteStones
            self.adjustBoardDimensionsIfNeeded(width: parsed.width, height: parsed.height)
        } completion: {
            withAnimation(.spring) {
                self.stones.moveOrder = parsed.moveOrder
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

    public func maybeCollectAnalysis(message: String) async {
        guard gobanState.showBoardCount == 0 else { return }
        if message.starts(with: /info/) {
            let sampleTime = ProcessInfo.processInfo.systemUptime

            let parser = AnalysisLineParser(boardWidth: Int(board.width),
                                            boardHeight: Int(board.height),
                                            nextColor: player.nextColorFromShowBoard)
            let parsed = parser.parse(message: message)
            let rootVisits = Analysis.parseRootVisits(from: message)

            withAnimation {
                analysis.info = parsed.info
                analysis.ownershipUnits = parsed.ownershipUnits
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

            gobanState.waitingForAnalysis = parsed.info.isEmpty
        }
    }

    public func maybeCollectSgf(
        message: String,
        gameRecords: [GameRecord],
        modelContext: ModelContext,
        navigationContext: NavigationContext
    ) {
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

    public func postProcessAIMove(
        message: String,
        navigationContext: NavigationContext,
        audioModel: AudioModel,
        aiMove: Binding<String?>
    ) {
        let pattern = /play (pass|\w+\d+)/
        if let match = message.firstMatch(of: pattern),
           let turn = player.nextColorSymbolForPlayCommand {
            let move = String(match.1)
            aiMove.wrappedValue = move
            if let gameRecord = navigationContext.selectedGameRecord {
                if gobanState.isOverwriting(gameRecord: gameRecord) {
                    gobanState.confirmingAIOverwrite = true
                } else {
                    gobanState.playAIMove(
                        aiMove: aiMove.wrappedValue,
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

    public func maybeCollectPlay(
        message: String,
        navigationContext: NavigationContext,
        audioModel: AudioModel,
        aiMove: Binding<String?>
    ) {
        let playPrefix = "play "
        if message.hasPrefix(playPrefix) {
            postProcessAIMove(
                message: message,
                navigationContext: navigationContext,
                audioModel: audioModel,
                aiMove: aiMove
            )
        }
    }

    public func maybeCollectCheckMove(
        message: String,
        navigationContext: NavigationContext,
        audioModel: AudioModel
    ) {
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
