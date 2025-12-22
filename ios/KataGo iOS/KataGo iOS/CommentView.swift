//
//  CommentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/9.
//

import SwiftUI
import FoundationModels

struct CommentView: View {
    var gameRecord: GameRecord
    @State var comment = ""
    @State private var isGenerating = false
    @State private var commentator: Commentator?
    @Environment(GobanState.self) var gobanState
    @Environment(Analysis.self) var analysis
    @Environment(Stones.self) var stones
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var turn

    var textArea: some View {
        ZStack {
            if gobanState.isEditing {
                TextField(
                    isGenerating ? "Generating..." : "Add your comment",
                    text: $comment,
                    axis: .vertical
                )
                .disabled(isGenerating)
                .contentTransition(.opacity)

                if (comment.isEmpty) && (isGenerating == false) {
                    VStack {
                        Spacer()
                        Button {
                            Task {
                                await wandAndSparklesAction()
                            }
                        } label: {
                            Image(systemName: "wand.and.sparkles")
                                .padding()
                        }
                        .sensoryFeedback(.success, trigger: isGenerating) { wasGenerating, isGenerating in
                            wasGenerating && !isGenerating
                        }
                    }
                }
            } else {
                Text(comment.isEmpty ? "(No comment)" : comment)
                    .foregroundStyle(comment.isEmpty ? .secondary : .primary)
            }

            if isGenerating {
                ProgressView()
            }
        }
    }

    var body: some View {
        ScrollViewReader { _ in
            ScrollView(.vertical) {
                textArea
            }
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
            .task {
                commentator = Commentator(
                    gameRecord: gameRecord,
                    turn: turn
                )
            }
        }
    }

    func wandAndSparklesAction() async {
        gobanState.maybeUpdateMoves(gameRecord: gameRecord, board: board)

        if gobanState.analysisStatus != .clear {
            gobanState.maybeUpdateAnalysisData(
                gameRecord: gameRecord,
                analysis: analysis,
                board: board,
                stones: stones
            )
        }

        if let useLLM = gameRecord.config?.useLLM, useLLM {
            isGenerating = true
            comment = await commentator?.generateImprovedComment() ?? ""
            isGenerating = false
        } else {
            comment = commentator?.generateNaturalComment() ?? ""
        }
    }
}
