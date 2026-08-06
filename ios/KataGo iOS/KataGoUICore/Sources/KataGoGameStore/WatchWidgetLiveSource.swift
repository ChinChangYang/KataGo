//
//  WatchWidgetLiveSource.swift
//  KataGoGameStore
//
//  The phone's live frame, as the record the complication renders.
//
//  There is no comment fallback here on purpose: when both mirrors describe
//  the same game, `WatchWidgetRecords.merged` already lends the library's
//  comment to a live record that has none, and only when the two agree on the
//  index. Duplicating that here would be a second, untested copy of the rule.
//

import Foundation

public enum WatchWidgetLiveSource {
    /// nil when the frame cannot honestly name a game, in which case the
    /// caller must leave the stored record untouched.
    ///
    /// A frame with no `hostGameID` is normal, not malformed: `WatchSnapshotBuilder`
    /// fills the host fields only when it has a `GameRecord`, and the relay
    /// passes an Optional `selectedGameRecord`. Storing one would put a
    /// nameless record with a fresh clock ahead of a perfectly good library
    /// record, and no tap URL could be built from it.
    public static func snapshot(from frame: WatchSnapshot,
                                fallbackName: String?,
                                capturedAt: Date) -> WatchWidgetSnapshot? {
        guard let gameID = frame.hostGameID, !gameID.isEmpty else { return nil }

        let candidates = [frame.gameName, fallbackName]
        guard let name = candidates
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }

        let onBranch = frame.isBranch ?? false
        let parkedIndex = frame.hostMoveIndex ?? 0
        return WatchWidgetSnapshot(
            gameID: gameID,
            name: name,
            // Suppressed on a branch: the index addresses a different line
            // from the one the saved comments are keyed to.
            comment: onBranch ? nil : WatchWidgetSnapshot.cappedComment(frame.positionComment),
            parkedIndex: parkedIndex,
            mainlineMoveCount: frame.hostMoveCount ?? parkedIndex,
            scoreLeadBlack: Double(frame.rootScoreLeadBlack),
            isBranch: onBranch,
            // The WATCH's clock, deliberately: `hostTimestamp` is a 2 Hz
            // heartbeat, not an edit time.
            capturedAt: capturedAt,
            source: .live)
    }

    /// The content key this frame WOULD produce, for the phone's push gate.
    ///
    /// Reuses the record builder rather than recomputing a key, so the gate
    /// cannot drift from what the watch will actually store — and it returns
    /// nil for exactly the frames the watch would refuse, which is precisely
    /// when a transfer would be wasted. `capturedAt` is irrelevant here:
    /// `contentKey` excludes it.
    public static func pushKey(for frame: WatchSnapshot) -> String? {
        snapshot(from: frame, fallbackName: nil, capturedAt: .distantPast)?.contentKey
    }
}
