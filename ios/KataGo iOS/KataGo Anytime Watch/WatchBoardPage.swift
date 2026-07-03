import SwiftUI
import KataGoGameStore

struct WatchBoardPage: View {
    @Environment(WatchLiveModel.self) private var model
    @State private var crownIndex: Double = 0

    var body: some View {
        let peek = model.peek
        let shown = peek.current
        let previous = peek.viewIndex > 0 ? peek.entries[peek.viewIndex - 1] : nil

        VStack(spacing: 2) {
            if let s = shown {
                WidgetBoardView(
                    width: s.boardWidth, height: s.boardHeight,
                    blackVertices: s.blackStones, whiteVertices: s.whiteStones,
                    candidateVertices: peek.isLive ? s.candidates.prefix(3).map(\.vertex) : [],
                    lastMoveVertex: WatchPeekBuffer.lastMoveVertex(previous: previous, current: s))
                .aspectRatio(CGFloat(s.boardWidth) / CGFloat(s.boardHeight), contentMode: .fit)

                // Two-tone winrate bar (Black share from the left) + score lead.
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(.black)
                            .frame(width: geo.size.width * CGFloat(s.rootWinrateBlack))
                        Rectangle().fill(.white)
                    }
                }
                .frame(height: 4)
                .clipShape(Capsule())

                Text(scoreText(s.rootScoreLeadBlack))
                    .font(.system(.headline, design: .monospaced))
            }
        }
        .overlay(alignment: .top) {
            if model.isStale, let at = model.receivedAt ?? shown.map(\.hostTimestamp) {
                // Date interpolation with a style only exists on Text, so
                // compose the Label from Text parts (a plain string can't do it).
                Label { Text("Stale ") + Text(at, style: .relative) }
                    icon: { Image(systemName: "wifi.slash") }
                    .font(.caption2).padding(3)
                    .background(.red.opacity(0.85), in: Capsule())
            } else if !peek.isLive {
                Text("\(peek.movesBehindLive) behind live")
                    .font(.caption2).padding(3)
                    .background(.orange.opacity(0.85), in: Capsule())
                    .onTapGesture { peek.viewIndex = peek.entries.count - 1 }
            }
        }
        .focusable()
        .digitalCrownRotation($crownIndex,
                              from: 0, through: Double(max(peek.entries.count - 1, 0)),
                              by: 1, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crownIndex) { _, newValue in
            peek.viewIndex = Int(newValue.rounded())
        }
        .onChange(of: peek.viewIndex) { _, newValue in
            // Keep the crown in sync when ingest re-pins the live index.
            if Int(crownIndex.rounded()) != newValue { crownIndex = Double(newValue) }
        }
    }

    private func scoreText(_ scoreLeadBlack: Float) -> String {
        scoreLeadBlack >= 0 ? String(format: "B+%.1f", scoreLeadBlack)
                            : String(format: "W+%.1f", -scoreLeadBlack)
    }
}
