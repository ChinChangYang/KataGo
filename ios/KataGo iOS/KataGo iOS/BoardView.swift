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
    @State var audioModel = AudioModel()
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(Stones.self) var stones
    @Environment(MessageList.self) var messageList
    @Environment(BranchState.self) var branchState
    var gameRecord: GameRecord
    @FocusState<Bool>.Binding var commentIsFocused: Bool

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

                    StoneView(dimensions: dimensions,
                              isClassicStoneStyle: config.isClassicStoneStyle,
                              verticalFlip: config.verticalFlip)

                    AnalysisView(config: config, dimensions: dimensions)
                    MoveNumberView(dimensions: dimensions, verticalFlip: config.verticalFlip)
                    WinrateBarView(dimensions: dimensions)
                }
                .onTapGesture { location in
                    commentIsFocused = false
                    if gobanState.showBoardCount == 0,
                       let coordinate = locationToCoordinate(location: location, dimensions: dimensions),
                       let point = coordinate.point,
                       let move = coordinate.move,
                       let turn = player.nextColorSymbolForPlayCommand,
                       !stones.blackPoints.contains(point) && !stones.whitePoints.contains(point) {
                        if gobanState.isEditing {
                            gameRecord.clearComments(after: gameRecord.currentIndex)
                        } else if !branchState.isActive {
                            branchState.sgf = gameRecord.sgf
                            branchState.currentIndex = gameRecord.currentIndex
                        }
                        messageList.appendAndSend(command: "play \(turn) \(move)")
                        player.toggleNextColorForPlayCommand()
                        gobanState.sendShowBoardCommand(messageList: messageList)
                        messageList.appendAndSend(command: "printsgf")
                        audioModel.playPlaySound(soundEffect: config.soundEffect)
                    }
                }
            }
            .onAppear {
                player.nextColorForPlayCommand = .unknown
                gobanState.sendShowBoardCommand(messageList: messageList)
            }
            .onChange(of: config.maxAnalysisMoves) { _, _ in
                gobanState.maybeRequestAnalysis(config: config,
                                                nextColorForPlayCommand: player.nextColorForPlayCommand,
                                                messageList: messageList)
            }
            .onChange(of: player.nextColorForPlayCommand) { oldValue, newValue in
                if oldValue != newValue {
                    maybeSendAsymmetricHumanAnalysisCommands(nextColorForPlayCommand: newValue)
                    gobanState.maybeRequestAnalysis(config: config,
                                                    nextColorForPlayCommand: newValue,
                                                    messageList: messageList)
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

    func maybeSendAsymmetricHumanAnalysisCommands(nextColorForPlayCommand: PlayerColor) {
        if !config.isEqualBlackWhiteHumanSettings {
            if nextColorForPlayCommand == .black {
                messageList.appendAndSend(command: "kata-set-param humanSLProfile \(config.humanSLProfile)")
                messageList.appendAndSend(command: "kata-set-param humanSLRootExploreProbWeightful \(config.humanSLRootExploreProbWeightful)")
            } else if nextColorForPlayCommand == .white {
                messageList.appendAndSend(command: "kata-set-param humanSLProfile \(config.humanProfileForWhite)")
                messageList.appendAndSend(command: "kata-set-param humanSLRootExploreProbWeightful \(config.humanRatioForWhite)")
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
        let verticalFlipWithPass = config.verticalFlip || ((boardY - 1) == BoardPoint.passY(height: height))
        let adjustedY = verticalFlipWithPass ? boardY : (height - boardY + 1)
        return Coordinate(x: boardX, y: adjustedY, width: Int(board.width), height: height)
    }
}

