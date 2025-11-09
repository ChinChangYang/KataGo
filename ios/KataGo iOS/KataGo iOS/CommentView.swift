//
//  CommentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/9.
//

import SwiftUI

struct CommentView: View {
    var gameRecord: GameRecord
    @State var comment = ""
    @Environment(GobanState.self) var gobanState

    var textArea: some View {
        Group {
            if gobanState.isEditing {
                TextField("Add your comment", text: $comment, axis: .vertical)
            } else {
                Text(comment == "" ? "(No comment)" : comment)
                    .foregroundStyle(comment == "" ? .secondary : .primary)
            }
        }
    }

    var body: some View {
        ScrollViewReader { _ in
            ScrollView(.vertical) {
                textArea
                    .onAppear {
                        if gameRecord.comments == nil {
                            gameRecord.comments = [:]
                        }

                        comment = gameRecord.comments?[gameRecord.currentIndex] ?? ""
                    }
                    .onChange(of: gameRecord.currentIndex) { oldIndex, newIndex in
                        if oldIndex != newIndex {
                            gameRecord.comments?[oldIndex] = comment
                            comment = gameRecord.comments?[newIndex] ?? ""
                        }
                    }
                    .onDisappear {
                        gameRecord.comments?[gameRecord.currentIndex] = comment
                    }
            }
        }
    }
}
