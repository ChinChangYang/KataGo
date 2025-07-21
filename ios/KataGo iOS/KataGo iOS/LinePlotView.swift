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
    @State var selectedMove: Int?
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

    var selectedScoreLead: Float? {
        if let selectedMove {
            return gameRecord.scoreLeads?[selectedMove]
        } else {
            return nil
        }
    }

    func minMove(scoreLeadPoints: [Point]) -> Int {
        scoreLeadPoints.min(by: { $0.x < $1.x })?.x ?? 0
    }

    func maxMove(scoreLeadPoints: [Point]) -> Int {
        scoreLeadPoints.max(by: { $0.x < $1.x })?.x ?? 0
    }

    func minScoreLead(scoreLeadPoints: [Point]) -> Float {
        scoreLeadPoints.min(by: { $0.y < $1.y })?.y ?? 0
    }

    func maxScoreLead(scoreLeadPoints: [Point]) -> Float {
        scoreLeadPoints.max(by: { $0.y < $1.y })?.y ?? 0
    }

    func minYDomain(scoreLeadPoints: [Point]) -> Float {
        min(-10, minScoreLead(scoreLeadPoints: scoreLeadPoints))
    }

    func maxYDomain(scoreLeadPoints: [Point]) -> Float {
        max(10, maxScoreLead(scoreLeadPoints: scoreLeadPoints))
    }

    var currentPoint: Point? {
        if gobanState.eyeStatus == .closed {
            return nil
        } else if let selectedMove, let selectedScoreLead {
            return Point(x: selectedMove, y: selectedScoreLead)
        } else if let scoreLead = gameRecord.scoreLeads?[gameRecord.currentIndex] {
            return Point(x: gameRecord.currentIndex, y: scoreLead)
        } else {
            return nil
        }
    }

    var body: some View {
        let scoreLeadPoints = self.scoreLeadPoints
        let minYDomain = self.minYDomain(scoreLeadPoints: scoreLeadPoints)
        let maxYDomain = self.maxYDomain(scoreLeadPoints: scoreLeadPoints)

        Chart {
            LinePlot(scoreLeadPoints,
                     x: .value("Move", \.x),
                     y: .value("Score Lead", \.y)
            )
            .foregroundStyle(colorScheme == .dark ? .white : .black)
            .interpolationMethod(.catmullRom)
            .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if let selectedMove, let selectedScoreLead {
                RuleMark(x: .value("Current", selectedMove))
                    .foregroundStyle(.red)
                    .lineStyle(.init(lineWidth: 2, dash: [4, 2]))
                .annotation(position: .top,
                            alignment: .center,
                            spacing: nil,
                            overflowResolution: .init(x: .fit(to: .chart),
                                                      y: .disabled)) {

                    let leadText = String(format: "%+.1f", selectedScoreLead)

                    VStack {
                        Text("Move \(selectedMove)")
                        Text("Lead \(leadText)")
                    }
                }

            } else if let currentPoint {
                RuleMark(x: .value("Current", currentPoint.x))
                    .foregroundStyle(.red)
                    .lineStyle(.init(lineWidth: 2, dash: [4, 2]))
            }
        }
        .chartXSelection(value: $selectedMove)
        .chartXScale(domain: 0...maxMove(scoreLeadPoints: scoreLeadPoints))
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
