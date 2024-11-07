//
//  ToolbarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/10/1.
//

import SwiftUI
import KataGoInterface
import AVKit

struct StatusToolbarItems: View {
    @State var audioModel = AudioModel()
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    @Environment(BoardSize.self) var board
    @Environment(MessageList.self) var messageList
    @Environment(BranchState.self) var branchState
    var gameRecord: GameRecord

    var config: Config {
        return gameRecord.concreteConfig
    }

    var body: some View {
        HStack {
            Button(action: backwardEndAction) {
                Image(systemName: "backward.end")
            }

            Button(action: backwardAction) {
                Image(systemName: "backward.frame")
            }

            if gobanState.analysisStatus == .pause {
                Button(action: stopAction) {
                    Image(systemName: "sparkle")
                }
                .contentTransition(.symbolEffect(.replace))
            } else if gobanState.analysisStatus == .run {
                Button(action: pauseAnalysisAction) {
                    Image(systemName: "sparkle")
                        .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                }
            } else {
                Button(action: startAnalysisAction) { 
                    Image("custom.sparkle.slash")
                        .foregroundColor(.red)
                }
            }

            Button(action: forwardAction) {
                Image(systemName: "forward.frame")
            }

            Button(action: forwardEndAction) {
                Image(systemName: "forward.end")
            }
        }
    }

    func backwardAction() {
        if branchState.isActive {
            branchState.undo()
        } else {
            gameRecord.undo()
        }
        messageList.appendAndSend(command: "undo")
        player.toggleNextColorForPlayCommand()
        gobanState.sendShowBoardCommand(messageList: messageList)
    }

    func startAnalysisAction() {
        gobanState.analysisStatus = .run
        gobanState.maybeRequestAnalysis(config: config,
                                        nextColorForPlayCommand: player.nextColorForPlayCommand,
                                        messageList: messageList)
    }

    func pauseAnalysisAction() {
        gobanState.maybePauseAnalysis()
    }

    func stopAction() {
        withAnimation {
            gobanState.analysisStatus = .clear
        }
        messageList.appendAndSend(command: "stop")
    }

    func forwardAction() {
        let currentIndex = branchState.isActive ? branchState.currentIndex : gameRecord.currentIndex
        let sgfHelper = SgfHelper(sgf: branchState.isActive ? branchState.sgf : gameRecord.sgf)
        if let nextMove = sgfHelper.getMove(at: currentIndex) {
            if let move = locationToMove(location: nextMove.location) {
                if branchState.isActive {
                    branchState.currentIndex = currentIndex + 1
                } else {
                    gameRecord.currentIndex = currentIndex + 1
                }
                let nextPlayer = nextMove.player == Player.black ? "b" : "w"
                messageList.appendAndSend(command: "play \(nextPlayer) \(move)")
                player.toggleNextColorForPlayCommand()
                audioModel.playPlaySound(soundEffect: config.soundEffect)
            }
        }

        gobanState.sendShowBoardCommand(messageList: messageList)
        gobanState.maybeRequestAnalysis(config: config,
                                        nextColorForPlayCommand: player.nextColorForPlayCommand,
                                        messageList: messageList)
        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    func forwardEndAction() {
        let sgfHelper = SgfHelper(sgf: branchState.isActive ? branchState.sgf : gameRecord.sgf)
        while let nextMove = sgfHelper.getMove(at: branchState.isActive ? branchState.currentIndex : gameRecord.currentIndex) {
            if let move = locationToMove(location: nextMove.location) {
                if branchState.isActive {
                    branchState.currentIndex = branchState.currentIndex + 1
                } else {
                    gameRecord.currentIndex = gameRecord.currentIndex + 1
                }
                let nextPlayer = nextMove.player == Player.black ? "b" : "w"
                messageList.appendAndSend(command: "play \(nextPlayer) \(move)")
                player.toggleNextColorForPlayCommand()
            }
        }

        gobanState.sendShowBoardCommand(messageList: messageList)
        gobanState.maybeRequestAnalysis(config: config,
                                        nextColorForPlayCommand: player.nextColorForPlayCommand,
                                        messageList: messageList)
        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    func backwardEndAction() {
        let sgfHelper = SgfHelper(sgf: branchState.isActive ? branchState.sgf : gameRecord.sgf)
        while sgfHelper.getMove(at: (branchState.isActive ? branchState.currentIndex : gameRecord.currentIndex) - 1) != nil {
            if branchState.isActive {
                branchState.undo()
            } else {
                gameRecord.undo()
            }
            messageList.appendAndSend(command: "undo")
            player.toggleNextColorForPlayCommand()
        }

        gobanState.sendShowBoardCommand(messageList: messageList)
        gobanState.maybeRequestAnalysis(config: config,
                                        nextColorForPlayCommand: player.nextColorForPlayCommand,
                                        messageList: messageList)
        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    func locationToMove(location: Location) -> String? {
        guard !location.pass else { return "pass" }
        let x = location.x
        let y = Int(board.height) - location.y

        guard (1...Int(board.height)).contains(y), (0..<Int(board.width)).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}
