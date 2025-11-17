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
    @Environment(Analysis.self) var analysis
    @Environment(Stones.self) var stones
    @Environment(BoardSize.self) var board

    var textArea: some View {
        ZStack {
            if gobanState.isEditing {
                TextField("Add your comment", text: $comment, axis: .vertical)

                if comment.isEmpty &&
                    !gobanState.requestingClearAnalysis {
                    VStack {
                        Spacer()
                        Button {
                            gobanState.maybeUpdateAnalysisData(
                                gameRecord: gameRecord,
                                analysis: analysis,
                                board: board,
                                stones: stones
                            )

                            withAnimation {
                                comment = generateAnalysisText()
                            }
                        } label: {
                            Image(systemName: "wand.and.sparkles")
                        }
                    }
                }
            } else {
                Text(comment.isEmpty ? "(No comment)" : comment)
                    .foregroundStyle(comment.isEmpty ? .secondary : .primary)
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

    func generateAnalysisText() -> String {
        let colorToPlay = analysis.nextColorForAnalysis.name
        let bestMoveText = gameRecord.bestMoves?[gameRecord.currentIndex] ?? "Unknown"
        let blackWinrateText = generateBlackWinRateText()
        let blackScoreText = generateBlackScoreText()
        let deadBlackStonesText = gameRecord.deadBlackStones?[gameRecord.currentIndex] ?? "Unknown"
        let deadWhiteStonesText = generateDeadWhiteText()
        let sacrificableBlackStonesText = generateSacrificableBlackText()
        let sacrificableWhiteStonesText = generateSacrificableWhiteText()

        let analysisText =
"""
- Color to Play: \(colorToPlay)
- Best Move: \(bestMoveText)
- Black Winrate: \(blackWinrateText)
- Black Score Lead: \(blackScoreText)
- Dead Black Stones: \(deadBlackStonesText)
- Dead White Stones: \(deadWhiteStonesText)
- 50/50 Alive Black Stones: \(sacrificableBlackStonesText)
- 50/50 Alive White Stones: \(sacrificableWhiteStonesText)
"""

        return analysisText
    }

    func generateBlackWinRateText() -> String {
        guard let blackWinRate = analysis.blackWinrate else {
            return "Unknown"
        }

        let blackWinRateText = String(format: "%2.0f%%", (blackWinRate * 100).rounded())
        return blackWinRateText
    }

    func generateBlackScoreText() -> String {
        guard let blackScore = gameRecord.scoreLeads?[gameRecord.currentIndex] else {
            return "Unknown"
        }

        let blackScoreText = String(round(Double(blackScore) * 10) / 10.0)
        return blackScoreText
    }

    func generateDeadWhiteText() -> String {
        let points = stones.whitePoints.filter { point in
            if let ownershipUnit = analysis.ownershipUnits.first(where: { $0.point == point }) {
                return ownershipUnit.whiteness < 0.1
            } else {
                return false
            }
        }

        let text = BoardPoint.toString(
            points,
            width: Int(board.width),
            height: Int(board.height)
        )

        return text
    }

    func generateSacrificableBlackText() -> String {
        let points = stones.blackPoints.filter { point in
            if let ownershipUnit = analysis.ownershipUnits.first(where: { $0.point == point }) {
                return (abs(ownershipUnit.whiteness - 0.5) < 0.2) && ownershipUnit.scale > 0.4
            } else {
                return false
            }
        }

        let text = BoardPoint.toString(
            points,
            width: Int(board.width),
            height: Int(board.height)
        )

        return text
    }

    func generateSacrificableWhiteText() -> String {
        let points = stones.whitePoints.filter { point in
            if let ownershipUnit = analysis.ownershipUnits.first(where: { $0.point == point }) {
                return (abs(ownershipUnit.whiteness - 0.5) < 0.2) && ownershipUnit.scale > 0.4
            } else {
                return false
            }
        }

        let text = BoardPoint.toString(
            points,
            width: Int(board.width),
            height: Int(board.height)
        )

        return text
    }
}
