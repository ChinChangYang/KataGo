//
//  WatchWidgetLibrarySource.swift
//  KataGoGameStore
//
//  The newest library row, as the record the complication renders.
//
//  Split deliberately: a thin @MainActor fetch that this file keeps as small
//  as possible, and pure functions holding every decision, because the watch
//  target has no test bundle and a rule buried in a SwiftData call site cannot
//  be pinned.
//

import Foundation
import SwiftData

public enum WatchWidgetLibrarySource {
    /// What a GameRecord knows that its `WatchLibraryRow` does not.
    public struct Extras: Equatable, Sendable {
        public var parkedIndex: Int
        public var comment: String?
        public var scoreLeadBlack: Double?

        public init(parkedIndex: Int, comment: String?, scoreLeadBlack: Double?) {
            self.parkedIndex = parkedIndex
            self.comment = comment
            self.scoreLeadBlack = scoreLeadBlack
        }
    }

    /// Pure derivation, so the lookup rule is testable without a store.
    /// Delegates to `WatchStoredAnalysis.at` rather than reimplementing the
    /// lookup, so this, `WatchGameView`, and the phone's comment pane
    /// cannot drift apart on what "the comment at index N" means.
    public static func extras(currentIndex: Int,
                              comments: [Int: String]?,
                              scoreLeads: [Int: Float]?) -> Extras {
        let stored = WatchStoredAnalysis.at(index: currentIndex,
                                            winRates: nil,
                                            scoreLeads: scoreLeads,
                                            bestMoves: nil,
                                            comments: comments)
        return Extras(parkedIndex: currentIndex,
                      comment: WatchWidgetSnapshot.cappedComment(stored.comment),
                      scoreLeadBlack: stored.scoreLeadBlack.map(Double.init))
    }

    /// One bounded, single-record fetch.
    ///
    /// `propertiesToFetch` lists EXACTLY what is read below. Reading a
    /// property absent from that list faults the ENTIRE row — the ownership
    /// dictionaries and the HEIC thumbnail included — which for a
    /// well-analyzed game is precisely the footprint the watch avoids
    /// everywhere else. In particular `mainlineMoveCount` is NOT taken from
    /// here: it needs `sgf`, and the caller already has it memoized on the
    /// library store.
    @MainActor
    public static func extras(gameID: String, container: ModelContainer) -> Extras? {
        guard let uuid = UUID(uuidString: gameID) else { return nil }
        let target: UUID? = uuid
        var descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate { $0.uuid == target },
            sortBy: [.init(\.lastModificationDate, order: .reverse)])
        descriptor.fetchLimit = 1
        descriptor.propertiesToFetch = [\.uuid, \.currentIndex, \.comments, \.scoreLeads]
        guard let record = try? container.mainContext.fetch(descriptor).first else { return nil }
        return extras(currentIndex: record.currentIndex,
                      comments: record.comments,
                      scoreLeads: record.scoreLeads)
    }

    /// Clamped into the mainline it is about to be rendered against, so the
    /// tile can never construct "Move 200 of 178".
    public static func snapshot(row: WatchLibraryRow,
                                moveCount: Int,
                                extras: Extras,
                                capturedAt: Date) -> WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: row.id,
                            name: row.name,
                            comment: extras.comment,
                            parkedIndex: min(max(extras.parkedIndex, 0), moveCount),
                            mainlineMoveCount: moveCount,
                            scoreLeadBlack: extras.scoreLeadBlack,
                            // Always false: a saved record's currentIndex is
                            // frozen at its divergence point and is never
                            // itself a branch. Retained as a hard-coded
                            // constant rather than dropped, for App-Group
                            // blob shape stability.
                            isBranch: false,
                            capturedAt: capturedAt)
    }
}
