//
//  OwnershipBudget.swift
//  KataGoUICore
//
//  Write-time cap for the per-move ownership a GameRecord persists, so a single
//  record can never grow past CloudKit's ~1 MB per-record ceiling and wedge the
//  iCloud export queue.
//
//  Background (see project_mac_icloud_list_live_refresh): ownershipWhiteness and
//  ownershipScales are `[Int:[Float]]` keyed by move index, each value a
//  full-board (`width * height`) Float array, stored INLINE (not
//  `.externalStorage`). They grow linearly with the number of analyzed moves and
//  in one observed 14.7 MB record accounted for ~99% of the bloat (ownershipScales
//  9.7 MB + ownershipWhiteness 3.65 MB). The SwiftData @Model schema is frozen
//  (changing it corrupts CloudKit sync), so this bounds the DATA, not the field's
//  storage class.
//

import Foundation

/// Bounds the combined size of `GameRecord.ownershipWhiteness` /
/// `GameRecord.ownershipScales` by evicting the OLDEST move-indices first.
///
/// The two dictionaries share the same move-index keys and each value is a
/// `width * height` Float array. Keeping the most-recent indices is the right
/// trade-off: ownership matters most late in a game (endgame / scoring), while
/// opening ownership is near-uniform (≈0.5) and least useful. The reads that
/// consume these dictionaries (`GameRecord.getStones` /
/// `getSchrodingerStones`) all `guard let … else return nil`, so an evicted
/// index simply yields no overlay rather than a crash.
enum OwnershipBudget {

    /// Conservative upper bound on the encoded size of one `Float` inside the
    /// serialization the SwiftData store uses for `[Int:[Float]]` (full
    /// precision, e.g. `0.38999999`). Real on-disk games measured ≈5.25 B/float
    /// (a calm 294-move game) to ≈6.34 (a contested 188-move one), but those
    /// boards are mostly *settled* — ±1 / 0.5 encode in ~3 chars and pull the
    /// average down. A genuinely full-precision board (every point contested)
    /// serializes at ≈11.15 B/float, measured directly by
    /// `OwnershipBudgetTests.contestedBoardSerializesUnderCloudKitLimit` (which
    /// encodes a worst-case board as JSON; JSON ≥ the on-disk format, so it is a
    /// safe upper bound). 12 covers that worst case, so the estimate never
    /// *under*-counts and `combinedByteBudget` genuinely bounds real data —
    /// including the contested endgame this cap exists to protect.
    static let estimatedBytesPerFloat = 12

    /// Combined byte budget for `ownershipWhiteness` + `ownershipScales`. Held
    /// well under CloudKit's ~1 MB residual CKRecord ceiling (1,048,576 B) so
    /// that, even with the SGF, per-move stone lists, thumbnail and analysis
    /// scalars sharing the record, the whole thing stays uploadable. Tunable:
    /// raising it retains more historical ownership at the cost of CloudKit
    /// headroom. At this value with the estimate above: ~69 most-recent moves at
    /// 19×19, ~18 at 37×37.
    static let combinedByteBudget = 600_000

    /// Largest number of move-indices whose ownership (two `pointsPerMove`-length
    /// `Float` arrays) fits within `combinedByteBudget`. Always ≥ 1 so the move
    /// that was just analyzed is never evicted by its own write.
    static func maxRetainedIndices(pointsPerMove: Int) -> Int {
        guard pointsPerMove > 0 else { return .max }
        let bytesPerIndex = 2 * pointsPerMove * estimatedBytesPerFloat
        return max(1, combinedByteBudget / bytesPerIndex)
    }

    /// Returns the two dictionaries trimmed so their combined estimated size is
    /// within `combinedByteBudget`, keeping the most-recent move-indices and
    /// ALWAYS retaining `protectedIndex` (the move just analyzed, which may be an
    /// old index if the user scrubbed back and re-analyzed). Both dictionaries
    /// are trimmed to the same retained window: at the sole call site they always
    /// carry identical keys, so the results do too. (Should the inputs ever
    /// diverge, each is simply filtered to the window independently — the reads
    /// tolerate a missing index via `guard let`, so partial overlap is harmless.)
    ///
    /// When already within budget the inputs are returned unchanged (no
    /// allocation), so the common case is free and the caller can skip
    /// re-assigning the @Model properties (avoiding needless CloudKit churn).
    ///
    /// - Parameters:
    ///   - whiteness: current `ownershipWhiteness` contents
    ///   - scales: current `ownershipScales` contents
    ///   - pointsPerMove: board point count (`width * height`)
    ///   - protectedIndex: move index that must survive (the live `currentIndex`)
    static func pruned(
        whiteness: [Int: [Float]],
        scales: [Int: [Float]],
        pointsPerMove: Int,
        keeping protectedIndex: Int
    ) -> (whiteness: [Int: [Float]], scales: [Int: [Float]]) {
        let limit = maxRetainedIndices(pointsPerMove: pointsPerMove)

        // Fast path: nothing to evict unless a dictionary exceeds the cap.
        guard max(whiteness.count, scales.count) > limit else {
            return (whiteness, scales)
        }

        // Keep `protectedIndex` plus the (limit - 1) most-recent OTHER indices,
        // so the result holds at most `limit` keys and always the protected one.
        let allKeys = Set(whiteness.keys).union(scales.keys)
        let others = allKeys.subtracting([protectedIndex]).sorted()
        var keep = Set(others.suffix(max(0, limit - 1)))
        keep.insert(protectedIndex)

        return (
            whiteness.filter { keep.contains($0.key) },
            scales.filter { keep.contains($0.key) }
        )
    }
}
