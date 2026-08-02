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

    // Mutated from `frame`'s getter to keep the memoized checkpoints (see
    // below). That mutation is only legal because this is unobserved: `frame`
    // is itself read during body evaluation, so an OBSERVED write here would
    // re-invalidate the view on every access and loop forever.
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
            var scanned = SgfReplay(scan: scan)
            // Force a full replay now, at open, rather than discovering
            // SgfReplay.anomalyIndex lazily as the user scrubs into it:
            // anomalyIndex only becomes non-nil once the offending index has
            // actually been replayed, so a lazy check would let the user
            // stare at a confidently-wrong board for every index BEFORE the
            // anomaly, and only flip to "can't read this game" once they
            // scrub past it. A known-bad mainline (a compressed range this
            // scan cannot expand, a mid-game AB/AW node the scan applies at
            // index 0, ...) should gate the WHOLE game unreadable, not just
            // its tail. The cost is one bounded walk of the mainline (same
            // work `position(at: moveCount)` would do anyway), done once.
            _ = scanned.position(at: scanned.moveCount)
            replay = scanned
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

    /// False when the SGF could not be scanned at all, OR the replay hit a
    /// mainline move the board refused (`SgfReplay.anomalyIndex`). Rendering
    /// a board that is confidently wrong is worse than the unavailable view.
    var isReadable: Bool { replay != nil && replay?.anomalyIndex == nil }

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

    // NOT GameRecord.fetchGameRecord(uuid:container:): its propertiesToFetch is
    // bounded for the WIDGET's readers (uuid, name, comments, width, height,
    // blackStones, whiteStones, currentIndex, lastModificationDate) — it does
    // not include winRates/scoreLeads/bestMoves. Reading an unfetched property
    // on a partial fault faults in the ENTIRE row (ownershipWhiteness,
    // ownershipScales, thumbnail, moves, the dead-stone dictionaries, ...),
    // which for a well-analyzed game is exactly the footprint this model
    // exists to avoid. Fetch exactly the properties `init` reads instead. A
    // future reader may be tempted to "simplify" this back to the shared
    // helper — don't; that reintroduces the object fault this exists to dodge.
    private static func record(for row: WatchLibraryRow,
                               container: ModelContainer) -> GameRecord? {
        guard let uuid = UUID(uuidString: row.id) else { return nil }
        let target: UUID? = uuid
        // Sort newest-first to match fetchGameRecord's tie-break, should the
        // (read-only, not-yet-repaired) store ever hold a duplicate uuid.
        var descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate { $0.uuid == target },
            sortBy: [.init(\.lastModificationDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [
            \.uuid, \.currentIndex, \.winRates, \.scoreLeads, \.bestMoves, \.comments
        ]
        return try? container.mainContext.fetch(descriptor).first
    }
}
