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
                    !analysis.info.isEmpty &&
                    !gobanState.requestingClearAnalysis {
                    VStack {
                        Spacer()
                        Button {
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
        if let blackWinrate = analysis.blackWinrate,
           let blackScore = analysis.blackScore {
            let blackWinrateText = String(format: "%2.0f%%", (blackWinrate * 100).rounded())
            let blackScoreText = round(Double(blackScore) * 10) / 10.0
            let deadBlackPointsText = generateDeadBlackText()
            let deadWhitePointsText = generateDeadWhiteText()
            let aiMoveText = generateAIMoveText()

            return "Black Winrate: \(blackWinrateText)\n" +
            "Black Score Lead: \(blackScoreText)\n" +
            "Dead Black Stones: \(deadBlackPointsText)\n" +
            "Dead White Stones: \(deadWhitePointsText)\n" +
            "AI Move: \(aiMoveText)"
        } else {
            return ""
        }
    }

    func boardPointsToString(_ points: [BoardPoint]) -> String {
        var text: String

        if points.isEmpty {
            text = "None"
        } else {
            text = points.reduce("") {
                let coordinate = Coordinate(
                    x: $1.x,
                    y: $1.y + 1,
                    width: Int(board.width),
                    height: Int(board.height)
                )

                if let move = coordinate?.move {
                    return "\($0) \(move)"
                } else {
                    return $0
                }
            }
        }

        return text
    }

    func generateDeadBlackText() -> String {
        let deadPoints = stones.blackPoints.filter { point in
            if let ownershipUnit = analysis.ownershipUnits.first(where: { $0.point == point }) {
                return ownershipUnit.whiteness > 0.9
            } else {
                return false
            }
        }

        let deadPointsText = boardPointsToString(deadPoints)

        return deadPointsText
    }

    func generateDeadWhiteText() -> String {
        let deadPoints = stones.whitePoints.filter { point in
            if let ownershipUnit = analysis.ownershipUnits.first(where: { $0.point == point }) {
                return ownershipUnit.whiteness < 0.1
            } else {
                return false
            }
        }

        let deadPointsText = boardPointsToString(deadPoints)

        return deadPointsText
    }

    func generateAIMoveText() -> String {
        guard let firstInfo = analysis.info.first else { return "Unknown" }

        let bestMoveInfo = analysis.info.reduce(firstInfo) {
            if $0.value.utilityLcb < $1.value.utilityLcb {
                $1
            } else {
                $0
            }
        }

        let coordinate = Coordinate(
            x: bestMoveInfo.key.x,
            y: bestMoveInfo.key.y + 1,
            width: Int(board.width),
            height: Int(board.height)
        )

        return coordinate?.move ?? "Unknown"
    }
}
