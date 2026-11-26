//
//  InfoView.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/11/9.
//

import SwiftUI
import KataGoUICore

enum InfoTabs {
    case chart
    case comments
}

struct InfoView: View {
    static let minHeight: CGFloat = 150
    static let buttonHeight: CGFloat = 25
    var gameRecord: GameRecord
    // Owned by PlayView so the selection survives full-screen round-trips
    // (this view unmounts while the board is full screen).
    @Binding var selectedTab: InfoTabs
    @FocusState<Bool>.Binding var commentIsFocused: Bool
    @Environment(GobanState.self) private var gobanState
    /// Optional so the previews, which mount no session, still build a pane.
    @Environment(GameSession.self) private var session: GameSession?
    /// The record's move count, read off the projector's replay whenever the
    /// record's SGF changes — never in `body`, which must not run a replay.
    /// Nil until read, and for a record that cannot be parsed.
    @State private var moveCount: Int?

    private var offersStartCard: Bool {
        FreshBoard.isFresh(moveCount: moveCount,
                           config: gameRecord.concreteConfig,
                           gobanState: gobanState)
    }

    var body: some View {
        ZStack {
            VStack {
                Group {
                    if selectedTab == .chart {
                        if offersStartCard {
                            // A fresh board has no chart to draw; offer a
                            // game where the empty axes would be.
                            PlayKataGoCard()
                                // A card, not a banner: on an iPad the
                                // pane is as wide as the board.
                                .frame(maxWidth: 520)
                                .padding(.horizontal)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        } else {
                            LinePlotView(gameRecord: gameRecord)
                                .padding()
                        }
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
                    createButton("Chart", systemImage: "chart.xyaxis.line") {
                        withAnimation {
                            selectedTab = .chart
                        }
                    }

                    createButton("Comments", systemImage: "text.rectangle") {
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
        .animation(.snappy, value: offersStartCard)
        .onChange(of: gameRecord.sgf, initial: true) { _, sgf in
            moveCount = session?.recordPosition.withReplay(for: sgf) { $0.moveCount }
        }
    }

    func createButton(
        _ title: String,
        systemImage: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.glass)
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
        @State var selectedTab: InfoTabs = .chart

        var body: some View {
            InfoView(gameRecord: gameRecord,
                     selectedTab: $selectedTab,
                     commentIsFocused: $commentIsFocused)
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
