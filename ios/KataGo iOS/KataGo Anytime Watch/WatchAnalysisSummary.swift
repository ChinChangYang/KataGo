import SwiftUI
import KataGoGameStore

/// The analysis readouts that used to be drawn on the board.
///
/// The body is a set of sibling rows rather than a container, so a caller can
/// drop it straight into its own `List` and keep one flat list of rows.
///
/// Rows are omitted rather than zeroed when a value is absent — the watch
/// never invents a number.
struct WatchAnalysisSummary: View {
    let winrateBlack: Float?
    let scoreLeadBlack: Float?

    var body: some View {
        if let winrateBlack, winrateBlack.isFinite {
            LabeledContent("Black",
                           value: WatchBoardFrame.winratePercentText(winrateBlack))
        }
        if let scoreLeadBlack, scoreLeadBlack.isFinite {
            LabeledContent("Score", value: WatchBoardFrame.scoreText(scoreLeadBlack))
        }
    }
}
