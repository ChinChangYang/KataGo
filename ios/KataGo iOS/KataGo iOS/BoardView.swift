//
//  BoardView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/12.
//

import SwiftUI
import KataGoInterface

struct BoardView: View {
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var player
    @Environment(GobanState.self) var gobanState
    var config: Config

    var body: some View {
        GeometryReader { geometry in
            let dimensions = Dimensions(size: geometry.size,
                                        width: board.width,
                                        height: board.height,
                                        showCoordinate: config.showCoordinate)
            ZStack {
                BoardLineView(dimensions: dimensions)

                StoneView(dimensions: dimensions,
                          isClassicStoneStyle: config.isClassicStoneStyle)

                if gobanState.shouldRequestAnalysis(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand) {
                    AnalysisView(config: config, dimensions: dimensions)
                }

                MoveNumberView(dimensions: dimensions)
                WinrateBarView(dimensions: dimensions)
            }
            .onTapGesture() { location in
                if let move = locationToMove(location: location, dimensions: dimensions),
                   let turn = player.nextColorSymbolForPlayCommand {
                    KataGoHelper.sendCommand("play \(turn) \(move)")
                    player.toggleNextColorForPlayCommand()
                    KataGoHelper.sendCommand("showboard")
                    KataGoHelper.sendCommand("printsgf")
                }
            }
        }
        .onAppear() {
            player.nextColorForPlayCommand = .unknown
            KataGoHelper.sendCommand("showboard")
        }
        .onChange(of: config.maxAnalysisMoves) { _, _ in
            gobanState.maybeRequestAnalysis(config: config, nextColorForPlayCommand: player.nextColorForPlayCommand)
        }
        .onChange(of: player.nextColorForPlayCommand) { oldValue, newValue in
            if oldValue != newValue {
                gobanState.maybeSendAsymmetricHumanAnalysisCommands(config: config, nextColorForPlayCommand: newValue)
                gobanState.maybeRequestAnalysis(config: config, nextColorForPlayCommand: newValue)
                gobanState.maybeRequestClearAnalysisData(config: config, nextColorForPlayCommand: newValue)
            }
        }
        .onDisappear() {
            KataGoHelper.sendCommand("stop")
        }
    }

    func locationToMove(location: CGPoint, dimensions: Dimensions) -> String? {
        let calculateCoordinate = { (point: CGFloat, margin: CGFloat, length: CGFloat) -> Int in
            return Int(round((point - margin) / length))
        }

        let y = calculateCoordinate(location.y, dimensions.boardLineStartY, dimensions.squareLength) + 1
        let x = calculateCoordinate(location.x, dimensions.boardLineStartX, dimensions.squareLength)

        guard (1...Int(board.height)).contains(y), (0..<Int(board.width)).contains(x) else { return nil }

        return Coordinate.xLabelMap[x].map { "\($0)\(y)" }
    }
}

