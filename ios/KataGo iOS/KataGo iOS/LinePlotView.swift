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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(BoardSize.self) var board
    @Environment(MessageList.self) var messageList
    @Environment(Turn.self) var player

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
            if let scoreLeads = gameRecord.scoreLeads {
                if let scoreLead = scoreLeads[selectedMove] {
                    return scoreLead
                } else {
                    // Search for the nearest index with a non-nil score lead
                    guard scoreLeads.count >= 1 else { return nil }
                    for offset in 1...scoreLeads.count {
                        if selectedMove - offset >= 0,
                           let scoreLead = scoreLeads[selectedMove - offset] {
                            return scoreLead
                        }
                        if selectedMove + offset < scoreLeads.count,
                           let scoreLead = scoreLeads[selectedMove + offset] {
                            return scoreLead
                        }
                    }
                }
            }
        }

        return nil
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

    var yAxisLabel: String {
        dynamicTypeSize <= .large ? "Black Score Lead" : ""
    }

    var chart: some View {
        let scoreLeadPoints = self.scoreLeadPoints
        let minYDomain = self.minYDomain(scoreLeadPoints: scoreLeadPoints)
        let maxYDomain = self.maxYDomain(scoreLeadPoints: scoreLeadPoints)

        return Chart {
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
                        .font(.footnote)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: colorScheme == .dark ? 0.1 : 0.9).opacity(0.9)))
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
        .chartYAxisLabel(yAxisLabel)
        .chartYAxis {
            dynamicTypeSize <= .large ? AxisMarks() : nil
        }
        .onAppear {
            // Upgrade old game record to support score leads
            if gameRecord.scoreLeads == nil {
                gameRecord.scoreLeads = [:]
            }
        }
        .onChange(of: gameRecord) { _, _ in
            // Upgrade old game record to support score leads
            if gameRecord.scoreLeads == nil {
                gameRecord.scoreLeads = [:]
            }
        }
        .onChange(of: selectedMove) { _, newSelectedMove in
            if !gobanState.isAutoPlaying, let newSelectedMove {
                gobanState.go(
                    to: newSelectedMove,
                    gameRecord: gameRecord,
                    board: board,
                    messageList: messageList,
                    player: player,
                    audioModel: nil
                )
            }
        }
    }

    var body: some View {
        ZStack {
            chart

            if gobanState.isEditing ||
                (gameRecord.scoreLeads?.isEmpty == true) {
                VStack {
                    Spacer()
                    Button {
                        gobanState.isEditing = true
                        gobanState.isAutoPlaying.toggle()
                    } label: {
                        let systemName = gobanState.isAutoPlaying ? "stop.circle" : "wand.and.sparkles"
                        Image(systemName: systemName)
                            .foregroundStyle(.red)
                            .padding()
                    }
                }
            }
        }
    }
}

#Preview("Minimal preview") {
    struct PreviewHost: View {
        let gobanState = GobanState()
        let gameRecord: GameRecord = {
            let gr = GameRecord(config: Config())
            gr.currentIndex = 50
            var leads: [Int: Float] = [:]
            for i in 0...100 {
                leads[i] = Float(sin(Double(i) / 10.0) * 10.0)
            }
            gr.scoreLeads = leads
            return gr
        }()

        var body: some View {
            LinePlotView(gameRecord: gameRecord)
                .frame(height: 125)
                .padding()
                .environment(gobanState)
                .environment(BoardSize())
                .environment(MessageList())
                .environment(Turn())
                .environment(Analysis())
                .environment(Stones())
        }
    }

    return PreviewHost()
        .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("No data preview") {
    struct PreviewHost: View {
        let gobanState = GobanState()
        let gameRecord = GameRecord(config: Config())

        var body: some View {
            LinePlotView(gameRecord: gameRecord)
                .frame(height: 125)
                .padding()
                .environment(gobanState)
                .environment(BoardSize())
                .environment(MessageList())
                .environment(Turn())
                .environment(Analysis())
                .environment(Stones())
        }
    }

    return PreviewHost()
        .environment(\.dynamicTypeSize, .accessibility5)
}
