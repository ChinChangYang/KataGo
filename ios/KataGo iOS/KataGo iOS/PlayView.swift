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
                    .frame(height: max(dimensions.totalHeight - dimensions.drawHeight, 125))
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
