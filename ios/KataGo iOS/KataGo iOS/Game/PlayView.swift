//
//  PlayView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/9/9.
//

import SwiftUI
import KataGoUICore

struct PlayView: View {
    var gameRecord: GameRecord
    @Environment(BoardSize.self) var board
    @Environment(GobanState.self) var gobanState
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @FocusState var commentIsFocused: Bool
    // Lives here (not in InfoView) so the selected tab survives the pane
    // unmounting during full-screen board mode.
    @State private var selectedInfoTab: InfoTabs = .chart

    /// Phone landscape has width to spare and almost no height, so stacking
    /// the pane above the board starves the board: measured on an iPhone 17,
    /// the 150 pt `InfoView.minHeight` floor left the board 73 pt of a 231 pt
    /// lane and a 19x19 rendered at 2.35 pt per cell — against the 7.34 pt its
    /// row numbers need to stay intact — while ~640 pt of width went unused.
    /// Side by side, the board takes the height it needs and the pane takes
    /// the width nothing else wanted.
    ///
    /// Compact height is the phone-landscape signal specifically: iPad
    /// landscape stays regular and keeps the stacked layout, which fits there.
    private var usesSideBySideLayout: Bool {
        verticalSizeClass == .compact && gobanState.isInfoPaneVisible
    }

    @ViewBuilder
    func infoBoardView(for dimensions: Dimensions, in size: CGSize) -> some View {
        if usesSideBySideLayout {
            HStack(spacing: 0) {
                // The board is square and height-bound in this layout, so it
                // needs only about its own height in width. The half-width cap
                // keeps the pane usable on a destination that is short AND
                // narrow, where the board would otherwise take the whole lane.
                BoardView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
                    .frame(width: min(size.height, size.width / 2))

                InfoView(gameRecord: gameRecord,
                         selectedTab: $selectedInfoTab,
                         commentIsFocused: $commentIsFocused)
            }
        } else {
            VStack {
                if gobanState.isInfoPaneVisible {
                    InfoView(gameRecord: gameRecord,
                             selectedTab: $selectedInfoTab,
                             commentIsFocused: $commentIsFocused)
                        .frame(height: max(dimensions.emptyHeight, InfoView.minHeight))
                }

                BoardView(gameRecord: gameRecord, commentIsFocused: $commentIsFocused)
            }
        }
    }

    var body: some View {
        VStack {
            GeometryReader { geometry in
                let dimensions = Dimensions(size: geometry.size,
                                            width: board.width,
                                            height: board.height,
                                            showCoordinate: gobanState.showCoordinate,
                                            showPass: gobanState.showPass)

                infoBoardView(for: dimensions, in: geometry.size)
            }

            StatusToolbarItems(gameRecord: gameRecord)
                .padding()
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
            PlayView(gameRecord: gameRecord)
                .padding()
                .environment(gobanState)
                .environment(BoardSize())
                .environment(MessageList())
                .environment(Turn())
                .environment(Analysis())
                .environment(Stones())
                .environment(AudioModel())
                .environment(Winrate())
                .environment(Score())
        }
    }

    return PreviewHost()
}
