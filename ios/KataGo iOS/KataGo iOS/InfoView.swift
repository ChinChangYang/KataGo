//
//  InfoView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/11/9.
//

import SwiftUI

enum InfoTabs {
    case chart
    case comments
}

struct InfoView: View {
    var gameRecord: GameRecord
    @State private var selectedTab: InfoTabs = .chart
    @FocusState<Bool>.Binding var commentIsFocused: Bool

    var body: some View {
        ZStack {
            VStack {
                Group {
                    if selectedTab == .chart {
                        LinePlotView(gameRecord: gameRecord)
                            .padding()
                    } else {
                        CommentView(gameRecord: gameRecord)
                            .padding(.horizontal)
                            .focused($commentIsFocused)
                    }
                }

                Spacer(minLength: 5)
            }

            VStack {
                Spacer()

                HStack {
                    Button {
                        selectedTab = .chart
                    } label: {
                        Image(systemName: "chart.xyaxis.line")
                            .resizable()
                            .scaledToFit()
                    }

                    Button {
                        selectedTab = .comments
                    } label: {
                        Image(systemName: "text.rectangle")
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 25)
                .foregroundStyle(.primary)
                .buttonStyle(.glass)
            }

        }
    }
}

#Preview {
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
        @FocusState var commentIsFocused: Bool

        var body: some View {
            InfoView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
                .frame(height: 125)
                .padding()
                .environment(gobanState)
                .environment(BoardSize())
                .environment(MessageList())
                .environment(Turn())
        }
    }

    return PreviewHost()
        .environment(\.dynamicTypeSize, .accessibility5)
}
