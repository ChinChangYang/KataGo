import SwiftUI
import KataGoGameStore

/// Draws a WatchBoardFrame: board, winrate bar, score line. Shared by the
/// live mirror and the offline browser so the two can never drift apart.
struct WatchFrameBoard: View {
    let frame: WatchBoardFrame
    /// Spoken text for the stale indicator; nil hides the indicator. Stored
    /// games never mirror anything, so they pass nothing.
    var staleAccessibilityLabel: Text? = nil

    private var isStale: Bool {
        frame.source == .live(stale: true)
    }

    var body: some View {
        WidgetBoardView(width: frame.boardWidth, height: frame.boardHeight,
                        blackVertices: frame.blackStones,
                        whiteVertices: frame.whiteStones,
                        candidateVertices: frame.candidateVertices,
                        lastMoveVertex: frame.lastMoveVertex)
            .aspectRatio(CGFloat(frame.boardWidth) / CGFloat(frame.boardHeight),
                         contentMode: .fit)

        if let winrate = frame.winrateBlack {
            // Two-tone winrate bar (Black share from the left).
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(.black)
                        .frame(width: geo.size.width * CGFloat(winrate))
                    Rectangle().fill(.white)
                }
            }
            .frame(height: 4)
            .clipShape(Capsule())
        }

        HStack(spacing: 4) {
            if isStale, let staleAccessibilityLabel {
                Image(systemName: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityLabel(staleAccessibilityLabel)
            }
            // Browsing shows where you are in the game; the live mirror
            // already has that in its status pill.
            if frame.source == .stored,
               let index = frame.moveIndex, let count = frame.moveCount {
                Text("\(index) / \(count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let score = frame.scoreLeadBlack {
                Text(WatchBoardFrame.scoreText(score))
                    .font(.system(.headline, design: .monospaced))
            }
        }
    }
}
