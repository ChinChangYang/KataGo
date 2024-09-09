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

    var body: some View {
        if gameRecord.config.showComments {
            ScrollViewReader { _ in
                ScrollView(.vertical) {
                    TextField("Add your comment", text: $comment, axis: .vertical)
                        .padding(.horizontal)
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
}
