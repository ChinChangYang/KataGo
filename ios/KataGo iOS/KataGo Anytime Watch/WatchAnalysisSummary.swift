import SwiftUI
import KataGoGameStore

/// The analysis readouts that used to be drawn on the board. Shared by the
/// live mirror's Top Moves page and a stored game's Review page for the same
/// reason WatchFrameBoard is shared: the two worlds must not drift apart.
///
/// The body is a set of sibling rows rather than a container, so a caller can
/// drop it straight into its own `List` and keep one flat list of rows.
///
/// Rows are omitted rather than zeroed when a value is absent — the watch
/// never invents a number.
struct WatchAnalysisSummary: View {
    let winrateBlack: Float?
    let scoreLeadBlack: Float?
    /// When the phone was last heard from. Non-nil only on the live mirror and
    /// only once the connection has gone stale.
    var staleSince: Date? = nil

    var body: some View {
        if let winrateBlack, winrateBlack.isFinite {
            LabeledContent("Black",
                           value: WatchBoardFrame.winratePercentText(winrateBlack))
        }
        if let scoreLeadBlack, scoreLeadBlack.isFinite {
            LabeledContent("Score", value: WatchBoardFrame.scoreText(scoreLeadBlack))
        }
        if let staleSince {
            Label {
                Text("Last update \(staleSince, style: .relative) ago")
            } icon: {
                Image(systemName: "wifi.slash")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // The exact wording the deleted board glyph handed VoiceOver. The
            // visible row can be terse because the reader has just come from
            // the board page, whose title said "Offline"; the spoken one
            // repeats that, because VoiceOver does not read a page's title
            // alongside every row it announces.
            .accessibilityElement()
            .accessibilityLabel(
                Text("Not receiving updates; last update \(staleSince, style: .relative) ago"))
        }
    }
}
