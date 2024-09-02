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
    var gameRecord: GameRecord

    var config: Config {
        return gameRecord.config
    }

    var body: some View {
        HStack {
            Button(action: clearBoardAction) {
                Image(systemName: "backward.end")
            }

            Button(action: backwardAction) {
                Image(systemName: "backward.frame")
            }

            if gobanState.analysisStatus == .pause {
                Button(action: stopAction) {
                    Image(systemName: "sparkle")
                }
            } else if gobanState.analysisStatus == .run {
                Button(action: pauseAnalysisAction) {
                    Image(systemName: "sparkle")
                        .symbolEffect(.variableColor.iterative.reversing, isActive: true)
                }
            } else {
                Button(action: startAnalysisAction) { 
                    Image(systemName: "sparkle")
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
        gameRecord.undo()
        KataGoHelper.sendCommand("undo")
        player.toggleNextColorForPlayCommand()
        KataGoHelper.sendCommand("showboard")
    }

    func startAnalysisAction() {
        gobanState.analysisStatus = .run
        gobanState.maybeRequestAnalysis(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    func pauseAnalysisAction() {
        gobanState.analysisStatus = .pause
        KataGoHelper.sendCommand("stop")
    }

    func stopAction() {
        gobanState.analysisStatus = .clear
        KataGoHelper.sendCommand("stop")
    }

    func forwardAction() {
        let currentIndex = gameRecord.currentIndex
        let sgfHelper = SgfHelper(sgf: gameRecord.sgf)
        if let nextMove = sgfHelper.getMove(at: currentIndex) {
            if let move = locationToMove(location: nextMove.location) {
                gameRecord.currentIndex = currentIndex + 1
                let nextPlayer = nextMove.player == Player.black ? "b" : "w"
                KataGoHelper.sendCommand("play \(nextPlayer) \(move)")
                player.toggleNextColorForPlayCommand()
                audioModel.playPlaySound(soundEffect: config.soundEffect)
            }
        }

        KataGoHelper.sendCommand("showboard")
        gobanState.maybeRequestAnalysis(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    func forwardEndAction() {
        let sgfHelper = SgfHelper(sgf: gameRecord.sgf)
        while let nextMove = sgfHelper.getMove(at: gameRecord.currentIndex) {
            if let move = locationToMove(location: nextMove.location) {
                gameRecord.currentIndex = gameRecord.currentIndex + 1
                let nextPlayer = nextMove.player == Player.black ? "b" : "w"
                KataGoHelper.sendCommand("play \(nextPlayer) \(move)")
                player.toggleNextColorForPlayCommand()
            }
        }

        KataGoHelper.sendCommand("showboard")
        gobanState.maybeRequestAnalysis(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
        gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
    }

    func clearBoardAction() {
        gameRecord.currentIndex = 0
        player.nextColorForPlayCommand = .unknown
        KataGoHelper.sendCommand("clear_board")
        KataGoHelper.sendCommand("showboard")
    }

    func locationToMove(location: Location) -> String? {
        guard !location.pass else { return "pass" }
        let x = location.x
        let y = Int(board.height) - location.y

        guard (1...Int(board.height)).contains(y), (0..<Int(board.width)).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}
