import SwiftUI
import KataGoGameStore

/// Draws a WatchBoardFrame: the board at the largest size the page allows,
/// with a vertical winrate bar beside it and the score over it. Shared by the
/// live mirror and the offline browser so the two can never drift apart.
///
/// Layout, and why it is a padded overlay rather than an `HStack`:
///
///   board.aspectRatio(.fit)               <- sizes itself to the page
///        .padding(.leading, bar + gap)    <- reserves the gutter
///        .overlay(alignment: .leading)    <- bar, sized to the BOARD's height
///
/// In an `HStack` the bar would be a flexible-height sibling and stretch to
/// the STACK's height, which on a non-square board is taller than the board
/// itself — a bar hanging past both ends of a 13x9. Reserving the gutter with
/// `.padding` instead makes the overlay's bounds exactly the board's, so the
/// bar spans the wood and nothing else, on any width x height from 2x2 to
/// 37x37.
///
/// The board is HEIGHT-limited on every watch size (measured on watchOS 26.5:
/// a page inside `NavigationStack > TabView(.verticalPage)` with a visible
/// title gets 204x150 pt on a 46 mm), so the gutter costs no board area at
/// all — the leftover width was already going to be empty margin.
struct WatchFrameBoard: View {
    let frame: WatchBoardFrame
    /// Spoken text for the stale indicator; nil hides the indicator. Stored
    /// games never mirror anything, so they pass nothing.
    var staleAccessibilityLabel: Text? = nil
    /// Whether to blend the record's cached best move onto the board. Defaults
    /// to false so the live mirror is provably unaffected — live frames carry
    /// no `bestMove` anyway (`WatchBoardFrame.live` hard-codes it nil), and
    /// only the stored browser's Review toggle passes true.
    var showBestMove: Bool = false
    /// Hides the score readout while something else owns the bottom of the
    /// screen. The live mirror's rejection banner is bottom-anchored on the
    /// TabView in `WatchRootView`, so without this the two would stack.
    var suppressesScore: Bool = false

    private var isStale: Bool {
        frame.source == .live(stale: true)
    }

    var body: some View {
        board
            .padding(.leading, WatchBoardLayout.gutterWidth + WatchBoardLayout.gutterSpacing)
            .overlay(alignment: .leading) { winrateBar }
    }

    private var board: some View {
        WidgetBoardView(width: frame.boardWidth, height: frame.boardHeight,
                        blackVertices: frame.blackStones,
                        whiteVertices: frame.whiteStones,
                        candidateVertices: frame.candidateVertices,
                        lastMoveVertex: frame.lastMoveVertex,
                        bestMoveVertex: frame.bestMoveVertex(showBestMove: showBestMove),
                        // Off deliberately. The gate would let labels through
                        // at 19x19 and drop them at 37x37, and at this pitch
                        // they are 5 pt glyphs that cost ~12% of the cell —
                        // the opposite of what a watch board needs.
                        showCoordinates: false,
                        // The app's own board surface: the bundled Wood asset,
                        // opaque black grid, quarter-cell hoshi, the app's
                        // 0.95 stone diameter, and its solid red 0.3-cell
                        // last-move dot. On watchOS `usesShaderStones` is
                        // false, so the stones render as the spherical vector
                        // approximation via SphericalStoneLayer.
                        style: .classicGoban(drawsOwnWood: true))
            .aspectRatio(CGFloat(frame.boardWidth) / CGFloat(frame.boardHeight),
                         contentMode: .fit)
            .overlay(alignment: .bottomLeading) { statusCluster }
    }

    /// The two-tone bar, in the in-app board's orientation: White fills from
    /// the top, Black from the bottom (`WinrateBarView`).
    ///
    /// A `GeometryReader` because the split is proportional and SwiftUI has no
    /// proportional-stack primitive; `.frame(width:)` outside it means the
    /// reader is proposed the gutter width and the host's full height, so
    /// `geo.size.height` IS the board's height.
    private var winrateBar: some View {
        GeometryReader { geo in
            if let split = WatchBoardLayout.split(winrateBlack: frame.winrateBlack,
                                                  height: geo.size.height) {
                VStack(spacing: 0) {
                    Rectangle().fill(.white).frame(height: split.whiteHeight)
                    Rectangle().fill(.black).frame(height: split.blackHeight)
                }
            } else {
                // Nothing analyzed. The gutter stays reserved either way —
                // collapsing it would resize the board every time analysis
                // arrives, goes stale, or is paused — so draw a dim track
                // rather than nothing, which would read as a glitch.
                Rectangle().fill(.secondary.opacity(0.25))
            }
        }
        .frame(width: WatchBoardLayout.gutterWidth)
        // The iOS bar sits against the goban's wood, so both halves read
        // without help. Here the page background is BLACK, and at an even
        // game the bar's lower half vanished into it — the bar looked like a
        // short white stub floating beside the board rather than a full-height
        // two-tone gauge. A mid-gray hairline reads against both halves and
        // restores the bar's true extent.
        .overlay {
            Rectangle().strokeBorder(.gray.opacity(0.7), lineWidth: 0.5)
        }
        .animation(.easeInOut(duration: 0.25), value: frame.winrateBlack)
        .accessibilityElement()
        .accessibilityLabel(winrateAccessibilityLabel)
    }

    private var winrateAccessibilityLabel: Text {
        guard let winrate = frame.winrateBlack, winrate.isFinite else {
            return Text("Win rate unavailable")
        }
        return Text("Black win rate \(Int((winrate * 100).rounded())) percent")
    }

    /// Stale indicator and score, over the board's bottom-left corner — the
    /// least information-dense part of a Go position, and the only place left
    /// once the board takes the whole page.
    @ViewBuilder private var statusCluster: some View {
        let score = suppressesScore ? nil : frame.scoreLeadBlack
        if (isStale && staleAccessibilityLabel != nil) || score != nil {
            HStack(spacing: 3) {
                if isStale, let staleAccessibilityLabel {
                    Image(systemName: "wifi.slash")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .accessibilityLabel(staleAccessibilityLabel)
                }
                if let score {
                    Text(WatchBoardFrame.scoreText(score))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            // A flat capsule, not `.ultraThinMaterial`: it matches the pills
            // the watch already draws (`.orange.opacity(0.85)` for the status
            // pill, `.red.opacity(0.9)` for the rejection banner), and a blur
            // pass per frame is not worth paying for on a wrist while the
            // Crown is scrubbing.
            .background(.black.opacity(0.45), in: Capsule())
            .padding(2)
        }
    }
}
