//
//  BoardView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import KataGoInterface
import AVKit

struct BoardView: View {
    @Environment(AudioModel.self) var audioModel
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(Stones.self) var stones
    @Environment(MessageList.self) var messageList
    @Environment(Analysis.self) var analysis
    var gameRecord: GameRecord
    @FocusState<Bool>.Binding var commentIsFocused: Bool
    @State private var confirmingOverwrite: Bool = false
    @State private var gestureLocation: CGPoint?

    var config: Config {
        gameRecord.concreteConfig
    }

    var body: some View {
        VStack {
#if os(macOS)
            Spacer(minLength: 20)
#endif
            GeometryReader { geometry in
                let dimensions = Dimensions(size: geometry.size,
                                            width: board.width,
                                            height: board.height,
                                            showCoordinate: config.showCoordinate,
                                            showPass: config.showPass)
                ZStack {
                    BoardLineView(dimensions: dimensions,
                                  showPass: config.showPass,
                                  verticalFlip: config.verticalFlip)

                    StoneView(
                        dimensions: dimensions,
                        isClassicStoneStyle: config.isClassicStoneStyle,
                        verticalFlip: config.verticalFlip
                    )

                    drawNextMove(dimensions: dimensions,
                                 verticalFlip: config.verticalFlip)

                    AnalysisView(config: config, dimensions: dimensions)
                    MoveNumberView(dimensions: dimensions, verticalFlip: config.verticalFlip)

                    if config.showWinrateBar && (gobanState.eyeStatus == .opened) {
                        WinrateBarView(dimensions: dimensions)
                    }
                }
                .onTapGesture { location in
                    commentIsFocused = false
                    gestureLocation = location

                    if stones.isReady && !gobanState.isAutoPlaying,
                       let coordinate = locationToCoordinate(location: location, dimensions: dimensions),
                       let point = coordinate.point,
                       let move = coordinate.move,
                       let turn = player.nextColorSymbolForPlayCommand,
                       !stones.blackPoints.contains(point) && !stones.whitePoints.contains(point),
                       !gobanState.shouldGenMove(config: config, player: player) {

                        if gobanState.isOverwriting(gameRecord: gameRecord) {
                            confirmingOverwrite = true
                        } else {
                            processGesureLocation(
                                location: location,
                                dimensions: dimensions,
                                turn: turn,
                                move: move
                            )
                        }
                    }
                }
                .confirmationDialog(
                    "Are you sure you want to overwrite this move?",
                    isPresented: $confirmingOverwrite,
                    titleVisibility: .visible
                ) {
                    Button("Overwite", role: .destructive) {
                        if let gestureLocation,
                           let coordinate = locationToCoordinate(location: gestureLocation, dimensions: dimensions),
                           let move = coordinate.move,
                           let turn = player.nextColorSymbolForPlayCommand {
                            processGesureLocation(
                                location: gestureLocation,
                                dimensions: dimensions,
                                turn: turn,
                                move: move
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
                    messageList: messageList,
                    gameRecord: gameRecord)
            }
            .onChange(of: player.nextColorForPlayCommand) { oldValue, newValue in
                if oldValue != newValue {
                    gobanState.maybeSendAsymmetricHumanAnalysisCommands(nextColorForPlayCommand: newValue,
                                                                        config: config,
                                                                        messageList: messageList)

                    gobanState.maybeRequestAnalysis(
                        config: config,
                        nextColorForPlayCommand: newValue,
                        messageList: messageList,
                        gameRecord: gameRecord)

                    gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: newValue)
                }
            }
            .onChange(of: stones.blackStonesCaptured) { oldValue, newValue in
                if oldValue < newValue {
                    audioModel.playCaptureSound(soundEffect: config.soundEffect)
                }
            }
            .onChange(of: stones.whiteStonesCaptured) { oldValue, newValue in
                if oldValue < newValue {
                    audioModel.playCaptureSound(soundEffect: config.soundEffect)
                }
            }
            .onDisappear {
                gobanState.maybePauseAnalysis()
            }
        }
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

    func processGesureLocation(
        location: CGPoint,
        dimensions: Dimensions,
        turn: String,
        move: String
    ) {
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

        gobanState.play(
            turn: turn,
            move: move,
            messageList: messageList,
            stones: stones
        )

        player.toggleNextColorForPlayCommand()
        gobanState.sendShowBoardCommand(messageList: messageList)
        messageList.appendAndSend(command: "printsgf")
        audioModel.playPlaySound(soundEffect: config.soundEffect)
    }

    func locationToCoordinate(location: CGPoint, dimensions: Dimensions) -> Coordinate? {
        // Function to calculate the board coordinate based on the provided point, margin, and square length
        func calculateCoordinate(from point: CGFloat, margin: CGFloat, length: CGFloat) -> Int {
            return Int(round((point - margin) / length))
        }

        let boardY = calculateCoordinate(from: location.y, margin: dimensions.boardLineStartY, length: dimensions.squareLength) + 1
        let boardX = calculateCoordinate(from: location.x, margin: dimensions.boardLineStartX, length: dimensions.squareLength)
        let height = Int(board.height)
        let verticalFlipWithPass = config.verticalFlip || ((boardY - 1) == BoardPoint.passY(height: height))
        let adjustedY = verticalFlipWithPass ? boardY : (height - boardY + 1)
        return Coordinate(x: boardX, y: adjustedY, width: Int(board.width), height: height)
    }
}

