//
//  CommentView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/9.
//

import SwiftUI
#if canImport(FoundationModels)
import FoundationModels   // Apple's on-device LLM — unavailable on tvOS
#endif

public struct CommentView: View {
    var gameRecord: GameRecord
    @State var comment = ""
    @State private var isGenerating = false
    @State private var commentator: Commentator?
    @Environment(GobanState.self) var gobanState
    @Environment(Analysis.self) var analysis
    @Environment(Stones.self) var stones
    @Environment(BoardSize.self) var board
    @Environment(Turn.self) var turn

    public init(gameRecord: GameRecord) {
        self.gameRecord = gameRecord
    }

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
#if !os(tvOS)
                .sensoryFeedback(.impact, trigger: isGenerating) { wasGenerating, isGenerating in
                    wasGenerating && !isGenerating && gobanState.hapticFeedback
                }
#endif

                if (comment.isEmpty) && (isGenerating == false) {
                    VStack {
                        Spacer()
                        Button {
                            Task {
                                await wandAndSparklesAction()
                            }
                        } label: {
                            Label("Generate Comment", systemImage: "text.bubble")
                                .labelStyle(.iconOnly)
                        }
#if !os(visionOS) && !os(tvOS)
                        .buttonStyle(.glass)   // visionOS/tvOS don't support .glass (see InfoView.createButton)
#endif
                        .padding()
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

    public var body: some View {
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
                    CommentPersistence.store(comment, at: oldIndex, in: gameRecord)
                    comment = gameRecord.comments?[newIndex] ?? ""
                }
            }
            .onChange(of: gameRecord.comments?[gameRecord.currentIndex]) { _, newValue in
                // External writers (e.g. the Deep Report's Copy to Comment)
                // update the record directly; without this re-sync the pane's
                // stale @State would clobber their text on the next save.
                if let newValue, newValue != comment {
                    comment = newValue
                }
            }
            // Flush while the pane is still on screen. `.task(id:)` IS the
            // debounce: SwiftUI cancels the running task on every keystroke, so
            // the countdown restarts and only completes once typing stops.
            // Without this the record — and therefore the watch widget, the iOS
            // widget, and Shortcuts — would not see a comment until the pane
            // disappeared.
            .task(id: comment) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                CommentPersistence.store(comment, at: gameRecord.currentIndex, in: gameRecord)
            }
            .onDisappear {
                CommentPersistence.store(comment, at: gameRecord.currentIndex, in: gameRecord)
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
        // Generation finishes in one shot, so persist immediately rather than
        // waiting out the typing debounce: the whole point of the button is
        // that the text is now real.
        CommentPersistence.store(comment, at: gameRecord.currentIndex, in: gameRecord)
    }
}
