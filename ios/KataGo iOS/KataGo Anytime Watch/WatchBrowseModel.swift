import Foundation
import Observation
import SwiftData
import GoRulesKit
import KataGoAnalysisKit
import KataGoGameStore

/// Drives one game the watch is browsing offline: replay for the board,
/// the record's cached dictionaries for the numbers. Read-only throughout —
/// nothing here inserts, deletes, or saves.
@Observable
@MainActor
final class WatchBrowseModel {
    let row: WatchLibraryRow
    /// The scrub position, 0...moveCount.
    var index: Int = 0

    @ObservationIgnored private var replay: SgfReplay?
    // The record's cached review data, read ONCE when the game opens. Scrubbing
    // must not hit SwiftData: `frame` is recomputed on every Crown detent and
    // every body evaluation, and a predicate fetch at that rate is what makes
    // scrubbing feel bad on watch hardware. One game's four dictionaries are a
    // small, bounded cost — the footprint rule that keeps them out of the
    // library list is about a hundred rows, not one open game.
    @ObservationIgnored private let winRates: [Int: Float]?
    @ObservationIgnored private let scoreLeads: [Int: Float]?
    @ObservationIgnored private let bestMoves: [Int: String]?
    @ObservationIgnored private let comments: [Int: String]?

    init(row: WatchLibraryRow, container: ModelContainer) {
        self.row = row
        if let scan = SgfHeaderScan(sgf: row.sgf) {
            replay = SgfReplay(scan: scan)
        }

        let record = Self.record(for: row, container: container)
        winRates = record?.winRates
        scoreLeads = record?.scoreLeads
        bestMoves = record?.bestMoves
        comments = record?.comments

        // Open where the game itself sits, so the watch lands on the same
        // position the phone last showed.
        index = min(max(record?.currentIndex ?? 0, 0), moveCount)
    }

    /// False when the SGF could not be scanned at all.
    var isReadable: Bool { replay != nil }

    var moveCount: Int { replay?.moveCount ?? 0 }

    var frame: WatchBoardFrame? {
        guard var replay = self.replay else { return nil }
        let position = replay.position(at: index)
        self.replay = replay   // keep the memoized checkpoints
        let analysis = storedAnalysis()
        return WatchBoardFrame.stored(
            title: row.name,
            boardWidth: replay.width, boardHeight: replay.height,
            blackStones: position.blackVertices,
            whiteStones: position.whiteVertices,
            lastMoveVertex: position.lastMoveVertex,
            moveIndex: index, moveCount: replay.moveCount,
            winrateBlack: analysis.winrateBlack,
            scoreLeadBlack: analysis.scoreLeadBlack,
            bestMove: analysis.bestMove,
            comment: analysis.comment)
    }

    /// The review data the record cached at the scrubbed index. Pure lookup —
    /// the dictionaries were read once in `init`.
    private func storedAnalysis() -> WatchStoredAnalysis {
        WatchStoredAnalysis.at(index: index,
                               winRates: winRates,
                               scoreLeads: scoreLeads,
                               bestMoves: bestMoves,
                               comments: comments)
    }

    private static func record(for row: WatchLibraryRow,
                               container: ModelContainer) -> GameRecord? {
        guard let uuid = UUID(uuidString: row.id) else { return nil }
        return try? GameRecord.fetchGameRecord(uuid: uuid, container: container)
    }
}
