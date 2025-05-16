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

    var boardOptionalCommentView: some View {
        Group {
            if config.showComments {
                // Show comment and board views
                GeometryReader { geometry in
                    let dimensions = Dimensions(size: geometry.size,
                                                width: board.width,
                                                height: board.height,
                                                showCoordinate: config.showCoordinate,
                                                showPass: config.showPass)

                    commentBoardView(for: dimensions)
                }
            } else {
                // Only show the board view
                BoardView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
            }
        }
    }

    private func commentBoardView(for dimensions: Dimensions) -> some View {
        let commentView = CommentView(gameRecord: gameRecord)
            .focused($commentIsFocused)
            .frame(width: isHorizontalLayout ? max(dimensions.totalWidth - dimensions.gobanWidth, 200) : nil,
                   height: isHorizontalLayout ? nil : max(dimensions.totalHeight - dimensions.drawHeight, 100))

        let boardView = BoardView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)

        return Group {
            if isHorizontalLayout {
                HStack {
                    boardView
                    commentView
                        .padding(.horizontal)
                }
            } else {
                VStack {
                    commentView
                        .padding()
                    boardView
                }
            }
        }
        .onAppear {
            // Determine horizontal layout if horizontal space is greater than vertical space
            isHorizontalLayout = dimensions.gobanStartX > dimensions.capturedStonesStartY
        }
    }

    var body: some View {
        boardOptionalCommentView
            .toolbar {
                ToolbarItem(placement: .status) {
                    StatusToolbarItems(gameRecord: gameRecord)
                }
            }
    }
}
