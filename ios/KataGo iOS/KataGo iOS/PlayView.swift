//
//  PlayView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/9.
//

import SwiftUI

struct PlayView: View {
    var gameRecord: GameRecord
    @FocusState var commentIsFocused: Bool

    var body: some View {
        VStack {
            CommentView(gameRecord: gameRecord)
                .focused($commentIsFocused)

            ZStack {
                BoardView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                StatusToolbarItems(gameRecord: gameRecord)
            }
        }
    }
}
