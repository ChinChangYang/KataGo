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
    static let minHeight: CGFloat = 150
    static let buttonHeight: CGFloat = 25
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

                Spacer(minLength: InfoView.buttonHeight)
            }

            VStack {
                Spacer()

                HStack {
                    createButton(systemImage: "chart.xyaxis.line") {
                        withAnimation {
                            selectedTab = .chart
                        }
                    }

                    createButton(systemImage: "text.rectangle") {
                        withAnimation {
                            selectedTab = .comments
                        }
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: InfoView.buttonHeight
                )
                .foregroundStyle(.primary)
            }
        }
    }

    func createButton(
        systemImage: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Group {
#if os(visionOS)
            // visionOS doesn't support glass button style
            Button(action: action) {
                Image(systemName: systemImage)
            }
#else
            Button(action: action) {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
            }
            .buttonStyle(.glass)
#endif
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
            gr.comments?[50] = "Hello, world!\nSecond line.\nThird line!"
            return gr
        }()
        @FocusState var commentIsFocused: Bool

        var body: some View {
            InfoView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
                .frame(height: InfoView.minHeight)
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
