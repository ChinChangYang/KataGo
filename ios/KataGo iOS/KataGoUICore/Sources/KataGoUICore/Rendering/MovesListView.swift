//
//  MovesListView.swift
//  KataGo Anytime
//
//  Phase 4 Task 3: the Inspector "Moves" tab. A flat ordered list of the
//  ACTIVE line (no variation tree). Each row shows the move number, the
//  player glyph (● black / ○ white), the coordinate, and the per-move
//  win% / score. Win%/score are always shown; rows whose metric isn't
//  populated yet render a blank placeholder ("—"), because the stored
//  dictionaries are sparse (filled lazily during navigation / auto-play).
//
//  Tapping a row navigates the board to that move via `GobanState.go(to:)`,
//  mirroring `LinePlotView`'s `.onChange(of: selectedMove)` jump.
//
//  Off-by-one mapping (verified): the stored dictionaries are keyed so that
//  key `i` is the position AFTER `i` moves, while `SgfHelper.getMove(at: i)`
//  returns the move whose move-number is `i + 1`. So for the i-th 0-based
//  move (`getMove(at: i)`):
//    - displayNumber = i + 1
//    - metrics are at winRates[i + 1] / scoreLeads[i + 1]
//    - tapping it calls go(to: i + 1)
//  Example (2-move game): row 0 -> displayNumber 1 (getMove(at:0)),
//  metrics at winRates[1]/scoreLeads[1]; row 1 -> displayNumber 2
//  (getMove(at:1)), metrics at winRates[2]/scoreLeads[2]; tapping row 2
//  calls go(to: 2). This matches `go(to:)`'s move-number semantics that
//  `LinePlotView` relies on (its `selectedMove` is a move number).
//
//  Metric perspective: values are stored from BLACK's perspective. Each row
//  displays them from the perspective of the player who JUST moved on that
//  row (`move.player`), which is the convention chosen here:
//    winForMover   = (player == .black) ? blackWR    : (1 - blackWR)
//    scoreForMover = (player == .black) ? blackScore : -blackScore
//

import SwiftUI

/// One precomputed row of the active line. Built in a plain-Swift helper
/// (not inside the SwiftUI body) to keep the view's type-checking simple.
struct MoveRow: Identifiable {
    /// Display move-number (1-based). Also the index passed to `go(to:)` and
    /// the key used to look up this row's metrics in the stored dictionaries.
    let displayNumber: Int
    let player: Player
    let coordinate: String
    /// Win% for the just-moved player, already formatted; nil when unpopulated.
    let winText: String?
    /// Score lead for the just-moved player, already formatted; nil when unpopulated.
    let scoreText: String?

    var id: Int { displayNumber }
}

public struct MovesListView: View {
    let gameRecord: GameRecord

    @Environment(GobanState.self) private var gobanState
    @Environment(BoardSize.self) private var board
    @Environment(MessageList.self) private var messageList
    @Environment(Turn.self) private var player
    @Environment(Stones.self) private var stones

    public init(gameRecord: GameRecord) {
        self.gameRecord = gameRecord
    }

    /// Builds the flat row list for the active line in plain Swift. Reads the
    /// active-line SGF from `GobanState` (so a live branch is reflected),
    /// falling back to the saved `gameRecord.sgf` only if that is nil.
    private func makeRows() -> [MoveRow] {
        let sgf = gobanState.getSgf(gameRecord: gameRecord) ?? gameRecord.sgf
        let helper = SgfHelper(sgf: sgf)
        let count = helper.moveSize ?? 0
        let winRates = gameRecord.winRates
        let scoreLeads = gameRecord.scoreLeads

        var rows: [MoveRow] = []
        rows.reserveCapacity(count)

        for i in 0..<count {
            guard let move = helper.getMove(at: i) else { continue }
            let displayNumber = i + 1
            let coordinate = board.locationToMove(location: move.location) ?? "?"

            // Stored values are Black's perspective; show the just-moved
            // player's perspective.
            let winText: String?
            if let blackWR = winRates?[displayNumber] {
                let winForMover = (move.player == .black) ? blackWR : (1 - blackWR)
                winText = String(format: "%.0f%%", winForMover * 100)
            } else {
                winText = nil
            }

            let scoreText: String?
            if let blackScore = scoreLeads?[displayNumber] {
                let scoreForMover = (move.player == .black) ? blackScore : -blackScore
                scoreText = String(format: "%+.1f", scoreForMover)
            } else {
                scoreText = nil
            }

            rows.append(
                MoveRow(
                    displayNumber: displayNumber,
                    player: move.player,
                    coordinate: coordinate,
                    winText: winText,
                    scoreText: scoreText
                )
            )
        }

        return rows
    }

    public var body: some View {
        let rows = makeRows()
        // Observable read -> the highlight auto-updates as you navigate.
        let currentIndex = gobanState.getCurrentIndex(gameRecord: gameRecord)

        ScrollViewReader { proxy in
            List {
                ForEach(rows) { row in
                    MoveRowView(row: row, isCurrent: row.displayNumber == currentIndex)
                        .id(row.displayNumber)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            jump(to: row.displayNumber)
                        }
                }
            }
            .onChange(of: currentIndex) { _, newValue in
                if let newValue {
                    withAnimation {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .onAppear {
                if let currentIndex {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
    }

    /// Navigate the board to the given move number, guarded exactly like
    /// `LinePlotView`'s jump.
    private func jump(to targetIndex: Int) {
        guard !gobanState.isAutoPlaying else { return }
        gobanState.go(
            to: targetIndex,
            gameRecord: gameRecord,
            board: board,
            messageList: messageList,
            player: player,
            audioModel: nil,
            stones: stones
        )
    }
}

/// A single row: fixed-width number, player glyph, coordinate, then
/// right-aligned win% / score with monospaced digits. Uses semantic colors
/// so it reads on both light and dark.
private struct MoveRowView: View {
    let row: MoveRow
    let isCurrent: Bool

    private var glyph: String { row.player == .black ? "●" : "○" }

    private static let placeholder = "—"

    var body: some View {
        HStack(spacing: 8) {
            Text("\(row.displayNumber)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Text(glyph)
                .frame(width: 16)

            Text(row.coordinate)
                .frame(width: 44, alignment: .leading)

            Spacer(minLength: 8)

            Text(row.winText ?? Self.placeholder)
                .font(.body.monospacedDigit())
                .foregroundStyle(row.winText == nil ? .secondary : .primary)
                .frame(width: 56, alignment: .trailing)

            Text(row.scoreText ?? Self.placeholder)
                .font(.body.monospacedDigit())
                .foregroundStyle(row.scoreText == nil ? .secondary : .primary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}
