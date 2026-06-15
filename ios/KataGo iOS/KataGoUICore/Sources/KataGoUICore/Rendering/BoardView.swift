//
//  BoardView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import AVKit

public struct BoardView: View {
    @Environment(AudioModel.self) var audioModel
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(Stones.self) var stones
    @Environment(MessageList.self) var messageList
    @Environment(Analysis.self) var analysis
    @Environment(BookLookup.self) var bookLookup
    @Environment(Winrate.self) var rootWinrate
    @Environment(Score.self) var rootScore
    var gameRecord: GameRecord
    @FocusState<Bool>.Binding var commentIsFocused: Bool
    @State private var confirmingOverwrite: Bool = false
    @State private var gestureLocation: CGPoint?

    public init(gameRecord: GameRecord, commentIsFocused: FocusState<Bool>.Binding) {
        self.gameRecord = gameRecord
        self._commentIsFocused = commentIsFocused
    }

    var config: Config {
        gameRecord.concreteConfig
    }

    var shouldShowWinrateBar: Bool {
        gobanState.showWinrateBar && (gobanState.eyeStatus == .opened || (gobanState.eyeStatus == .book && bookLookup.isInBook))
    }

    public var body: some View {
        VStack {
#if os(macOS)
            Spacer(minLength: 20)
#endif
            GeometryReader { geometry in
                let dimensions = Dimensions(size: geometry.size,
                                            width: board.width,
                                            height: board.height,
                                            showCoordinate: gobanState.showCoordinate,
                                            showPass: gobanState.showPass)
                ZStack {
                    BoardLineView(dimensions: dimensions,
                                  showPass: gobanState.showPass,
                                  verticalFlip: gobanState.verticalFlip)

                    StoneView(
                        dimensions: dimensions,
                        isClassicStoneStyle: gobanState.isClassicStoneStyle,
                        verticalFlip: gobanState.verticalFlip,
                        speedText: speedText
                    )

                    drawNextMove(dimensions: dimensions,
                                 verticalFlip: gobanState.verticalFlip)

                    AnalysisView(config: config, dimensions: dimensions)
                    BookAnalysisView(config: config, dimensions: dimensions)
                    MoveNumberView(dimensions: dimensions,
                                   verticalFlip: gobanState.verticalFlip,
                                   style: gobanState.moveNumberStyleChoice,
                                   moveNumbers: gobanState.getMoveNumbers(gameRecord: gameRecord))

                    if gobanState.isBranchActive {
                        // Reminder that branch stones are temporary; geometry
                        // matches BoardLineView.drawBoardBackground's wood rect.
                        Rectangle()
                            .stroke(.red, lineWidth: max(2, dimensions.squareLengthDiv16))
                            .frame(width: dimensions.gobanWidth, height: dimensions.gobanHeight)
                            .position(x: dimensions.gobanStartX + (dimensions.gobanWidth / 2),
                                      y: dimensions.gobanStartY + (dimensions.gobanHeight / 2))
                    }

                    if shouldShowWinrateBar {
                        WinrateBarView(dimensions: dimensions)
                            .transition(.opacity)
                    }
                }
                .onTapGesture { location in
                    commentIsFocused = false
                    gestureLocation = location

                    if stones.isReady && !gobanState.isAutoPlaying && (gobanState.pendingMoveTurn == nil || gobanState.isPendingMoveStale),
                       let coordinate = locationToCoordinate(location: location, dimensions: dimensions),
                       let point = coordinate.point,
                       let move = coordinate.move,
                       let turn = player.nextColorSymbolForPlayCommand,
                       !stones.blackPoints.contains(point) && !stones.whitePoints.contains(point),
                       !gobanState.shouldGenMove(config: config, player: player) {

                        if gobanState.isPendingMoveStale {
                            gobanState.clearPendingMove()
                        }

                        if gobanState.isOverwriting(gameRecord: gameRecord) {
                            confirmingOverwrite = true
                        } else {
                            gobanState.sendCheckMoveCommand(
                                turn: turn,
                                move: move,
                                messageList: messageList
                            )
                        }
                    }
                }
                .confirmationDialog(
                    "Are you sure you want to overwrite this move?",
                    isPresented: $confirmingOverwrite,
                    titleVisibility: .visible
                ) {
                    Button("Overwrite", role: .destructive) {
                        if let gestureLocation,
                           let coordinate = locationToCoordinate(location: gestureLocation, dimensions: dimensions),
                           let move = coordinate.move,
                           let turn = player.nextColorSymbolForPlayCommand {
                            gobanState.sendCheckMoveCommand(
                                turn: turn,
                                move: move,
                                messageList: messageList
                            )
                        }
                    }

                    Button("Cancel", role: .cancel) {
                        confirmingOverwrite = false
                    }
                }
            }
            .onAppear {
                player.nextColorForPlayCommand = .unknown
                gobanState.sendShowBoardCommand(messageList: messageList)
            }
            .onChange(of: config.maxAnalysisMoves) { _, _ in
                gobanState.maybeRequestAnalysis(
                    config: config,
                    nextColorForPlayCommand: player.nextColorForPlayCommand,
                    messageList: messageList)
            }
            .onChange(of: player.nextColorForPlayCommand) { oldValue, newValue in
                if oldValue != newValue {
                    gobanState.maybeSendAsymmetricHumanAnalysisCommands(nextColorForPlayCommand: newValue,
                                                                        config: config,
                                                                        messageList: messageList)

                    gobanState.maybeRequestAnalysis(
                        config: config,
                        nextColorForPlayCommand: newValue,
                        messageList: messageList)

                    gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: newValue)
                }
            }
            .onChange(of: stones.blackStonesCaptured) { oldValue, newValue in
                if oldValue < newValue {
                    audioModel.playCaptureSound(soundEffect: gobanState.soundEffect)
                }
            }
            .onChange(of: stones.whiteStonesCaptured) { oldValue, newValue in
                if oldValue < newValue {
                    audioModel.playCaptureSound(soundEffect: gobanState.soundEffect)
                }
            }
            .onChange(of: gobanState.eyeStatus) {
                updateWinrateFromBook()
            }
            .onChange(of: bookLookup.currentPositionId) {
                updateWinrateFromBook()
            }
            .onDisappear {
                gobanState.maybePauseAnalysis()
            }
        }
    }

    private func updateWinrateFromBook() {
        guard gobanState.eyeStatus == .book else { return }
        withAnimation {
            if let wr = bookLookup.bestBlackWinrate {
                rootWinrate.black = wr
            }
            if let sc = bookLookup.bestBlackScore {
                rootScore.black = sc
            }
        }
    }

    /// The visits/s text to show beside the captured-stone counts, or nil when hidden.
    private var speedText: String? {
        guard gobanState.showVisitsPerSecond,
              gobanState.analysisStatus == .run,
              analysis.visitsPerSecond > 0 else { return nil }
        return analysis.visitsPerSecondText
    }

    private func drawNextMove(dimensions: Dimensions, verticalFlip: Bool) -> some View {
        Group {
            if let nextMove = gobanState.getNextMove(gameRecord: gameRecord) {
                let stoneColor: Color = (nextMove.player == .black) ? .black : Color(white: 1.0)

                let boardPoint = BoardPoint(
                    location: nextMove.location,
                    width: Int(board.width),
                    height: Int(board.height)
                )

                let x = boardPoint.x
                let y = boardPoint.getPositionY(height: dimensions.height, verticalFlip: verticalFlip)

                Circle()
                    .stroke(stoneColor, lineWidth: 2)
                    .frame(width: dimensions.stoneLength, height: dimensions.stoneLength)
                    .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                              y: dimensions.boardLineStartY + y * dimensions.squareLength)
            }
        }
    }

    func locationToCoordinate(location: CGPoint, dimensions: Dimensions) -> Coordinate? {
        // Function to calculate the board coordinate based on the provided point, margin, and square length
        func calculateCoordinate(from point: CGFloat, margin: CGFloat, length: CGFloat) -> Int {
            return Int(round((point - margin) / length))
        }

        let boardY = calculateCoordinate(from: location.y, margin: dimensions.boardLineStartY, length: dimensions.squareLength) + 1
        let boardX = calculateCoordinate(from: location.x, margin: dimensions.boardLineStartX, length: dimensions.squareLength)
        let height = Int(board.height)
        let verticalFlipWithPass = gobanState.verticalFlip || ((boardY - 1) == BoardPoint.passY(height: height))
        let adjustedY = verticalFlipWithPass ? boardY : (height - boardY + 1)
        return Coordinate(x: boardX, y: adjustedY, width: Int(board.width), height: height)
    }
}

