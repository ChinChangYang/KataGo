//
//  LinePlotView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/7/14.
//

import SwiftUI
import Charts

struct Point {
    let x: Int
    let y: Float

    init(x: Int, y: Float) {
        self.x = x
        self.y = y
    }
}

struct LinePlotView: View {
    var gameRecord: GameRecord
    @Environment(\.colorScheme) private var colorScheme
    @Environment(GobanState.self) private var gobanState

    var scoreLeadPoints: [Point] {
        if gobanState.eyeStatus == .closed {
            return []
        } else {
            return gameRecord.scoreLeads?.keys.sorted().compactMap { key in
                    .init(x: key, y: gameRecord.scoreLeads?[key] ?? 0)
            } ?? []
        }
    }

    var minMove: Int {
        scoreLeadPoints.min(by: { $0.x < $1.x })?.x ?? 0
    }

    var maxMove: Int {
        scoreLeadPoints.max(by: { $0.x < $1.x })?.x ?? 0
    }

    var minScoreLead: Float {
        scoreLeadPoints.min(by: { $0.y < $1.y })?.y ?? 0
    }

    var maxScoreLead: Float {
        scoreLeadPoints.max(by: { $0.y < $1.y })?.y ?? 0
    }

    var minYDomain: Float {
        min(-10, minScoreLead)
    }

    var maxYDomain: Float {
        max(10, maxScoreLead)
    }

    var currentMoves: [Point] {
        if gobanState.eyeStatus == .closed {
            return []
        } else {
            return [Point(x: gameRecord.currentIndex, y: 0)]
        }
    }

    var body: some View {
        Chart {
            LinePlot(scoreLeadPoints,
                     x: .value("Move", \.x),
                     y: .value("Score Lead", \.y)
            )
            .foregroundStyle(colorScheme == .dark ? .white : .black)
            .interpolationMethod(.catmullRom)
            .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))

            RulePlot(currentMoves,
                     x: .value("Current", \.x))
            .foregroundStyle(.red)
            .lineStyle(.init(lineWidth: 2, dash: [4, 2]))
        }
        .chartXScale(domain: 0...maxMove)
        .chartYScale(domain: minYDomain...maxYDomain)
        .chartYAxisLabel("Black Score Lead")
        .onAppear {
            // Upgrade old game record to support score leads
            if gameRecord.scoreLeads == nil {
                gameRecord.scoreLeads = [:]
            }
        }
    }
}
