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

    var textArea: some View {
        ZStack {
            if gobanState.isEditing {
                TextField("Add your comment", text: $comment, axis: .vertical)

                if comment.isEmpty {
                    VStack {
                        Spacer()
                        Button {
                            comment = generateAnalysisText()
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
            let blackScoreText = lround(Double(blackScore) * 10) / 10
            let deadBlackPointsText = generateDeadBlackText()
            let deadWhitePointsText = generateDeadWhiteText()
            let aiMoveText = generateAIMoveText()

            return "Black Winrate: \(blackWinrateText)\n" +
            "Black Score Lead: \(blackScoreText)\n" +
            "Dead Black Stones: \(deadBlackPointsText)\n" +
            "Dead White Stones: \(deadWhitePointsText)\n" +
            "AI Move: \(aiMoveText)"
        } else {
            return "No analysis data."
        }
    }

    func generateDeadBlackText() -> String {
        let deadPoints = stones.blackPoints.filter { point in
            if let ownershipUnit = analysis.ownershipUnits.first(where: { $0.point == point }) {
                return ownershipUnit.whiteness > 0.9
            } else {
                return false
            }
        }

        var deadPointsText: String

        if deadPoints.isEmpty {
            deadPointsText = "None"
        } else {
            deadPointsText = deadPoints.reduce("") {
                if let xLabel = Coordinate.xLabelMap[$1.x] {
                    $0 + " " + xLabel + String($1.y + 1)
                } else {
                    $0
                }
            }
        }

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

        var deadPointsText: String

        if deadPoints.isEmpty {
            deadPointsText = "None"
        } else {
            deadPointsText = deadPoints.reduce("") {
                if let xLabel = Coordinate.xLabelMap[$1.x] {
                    let yLabel = String($1.y + 1)
                    return "\($0) \(xLabel)\(yLabel)"
                } else {
                    return $0
                }
            }
        }

        return deadPointsText
    }

    func generateAIMoveText() -> String {
        guard let firstInfo = analysis.info.first else { return "" }

        let bestMoveInfo = analysis.info.reduce(firstInfo) {
            if $0.value.utilityLcb < $1.value.utilityLcb {
                $1
            } else {
                $0
            }
        }

        guard let xLabel = Coordinate.xLabelMap[bestMoveInfo.key.x] else { return "" }
        let yLabel = String(bestMoveInfo.key.y + 1)
        
        return "\(xLabel)\(yLabel)"
    }
}
