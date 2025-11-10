//
//  PlayView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/9.
//

import SwiftUI

struct PlayView: View {
    var gameRecord: GameRecord
    @State var isHorizontalLayout = false
    @Environment(BoardSize.self) var board
    @FocusState var commentIsFocused: Bool

    var config: Config { gameRecord.concreteConfig }

    func infoBoardView(for dimensions: Dimensions) -> some View {
        return VStack {
            if config.showCharts || config.showComments {
                InfoView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
                    .frame(height: max(dimensions.emptyHeight, InfoView.minHeight))
            }

            BoardView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
        }
    }

    var body: some View {
        VStack {
            GeometryReader { geometry in
                let dimensions = Dimensions(size: geometry.size,
                                            width: board.width,
                                            height: board.height,
                                            showCoordinate: config.showCoordinate,
                                            showPass: config.showPass)

                infoBoardView(for: dimensions)
            }

            StatusToolbarItems(gameRecord: gameRecord)
                .padding()
        }
    }
}

#Preview {
    struct PreviewHost: View {
        let gobanState = GobanState()
        let gameRecord: GameRecord = {
            let gr = GameRecord(config: Config())
            gr.currentIndex = 50
            var leads: [Int: Float] = [:]
            for i in 0...100 {
                leads[i] = Float(sin(Double(i) / 10.0) * 10.0)
            }
            gr.scoreLeads = leads
            gr.comments?[50] = "Hello, world!\nSecond line.\nThird line!"
            return gr
        }()
        @FocusState var commentIsFocused: Bool

        var body: some View {
            PlayView(gameRecord: gameRecord)
                .padding()
                .environment(gobanState)
                .environment(BoardSize())
                .environment(MessageList())
                .environment(Turn())
                .environment(Analysis())
                .environment(Stones())
                .environment(AudioModel())
                .environment(Winrate())
                .environment(Score())
        }
    }

    return PreviewHost()
}
