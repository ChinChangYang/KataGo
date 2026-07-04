import Foundation
import Observation

/// Watch-local ring buffer of recent positions for Crown scrubbing ("local
/// peek"): zero host mutation, per the v0 spec. Frames are appended only when
/// the POSITION changes (`positionKey`), so analysis-churn frames just refresh
/// the live entry's numbers in place. When the user is pinned to live
/// (`viewIndex` at the end) new frames follow; while scrubbed back, new frames
/// append without yanking the view.
@Observable
@MainActor
public final class WatchPeekBuffer {
    public static let capacity = 50

    public private(set) var entries: [WatchSnapshot] = []
    public var viewIndex: Int = 0

    public init() {}

    public var current: WatchSnapshot? {
        entries.indices.contains(viewIndex) ? entries[viewIndex] : nil
    }

    public var isLive: Bool { viewIndex >= entries.count - 1 }

    public var movesBehindLive: Int { max(entries.count - 1 - viewIndex, 0) }

    public func ingest(_ snapshot: WatchSnapshot) {
        let wasLive = isLive
        if let last = entries.last, last.positionKey == snapshot.positionKey {
            entries[entries.count - 1] = snapshot   // same position: refresh analysis numbers
        } else {
            entries.append(snapshot)
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
                viewIndex = max(viewIndex - 1, 0)   // account for the dropped head
            }
        }
        if wasLive { viewIndex = entries.count - 1 }
    }

    /// Latest cached frame for a host mainline index — the shared-cursor
    /// render cache (instant optimistic board while the iPhone catches up).
    public func entry(forHostIndex index: Int) -> WatchSnapshot? {
        entries.last(where: { $0.hostMoveIndex == index })
    }

    /// The last move is the single stone present in `current` but not in
    /// `previous`. Captures/undos change counts by ≠ +1 → nil (no ring) rather
    /// than guessing wrong.
    nonisolated public static func lastMoveVertex(previous: WatchSnapshot?,
                                                  current: WatchSnapshot) -> String? {
        guard let previous else { return nil }
        let prev = Set(previous.blackStones + previous.whiteStones)
        let cur = Set(current.blackStones + current.whiteStones)
        let added = cur.subtracting(prev)
        guard added.count == 1, cur.count == prev.count + 1 else { return nil }
        return added.first
    }
}
