//
//  WatchWidgetRefreshPolicy.swift
//  KataGoAnalysisKit
//
//  When a change is worth a reload, and when it is worth a transfer.
//
//  Every decision here is keyed on the DISPLAYED content, with time only ever
//  acting as a floor. The complication this replaces gated its reload on a
//  half-point score move, which was defensible for a tile that showed only a
//  score and is exactly wrong for one that shows a name and a comment: those
//  change while the score sits still.
//

import Foundation

public enum WatchWidgetRefreshPolicy {
    /// Minimum spacing between timeline reloads driven by the live mirror.
    /// A floor, never a trigger. A background wake bypasses it deliberately —
    /// refreshing the tile is the entire purpose of that wake.
    public static let reloadFloor: TimeInterval = 30

    /// Minimum spacing between phone complication transfers. The budget is
    /// roughly 50 a day and drops to zero the moment the tile is not on an
    /// active watch face, so this is far coarser than the local floor.
    public static let pushInterval: TimeInterval = 5 * 60

    /// How long a rendered entry stays valid before WidgetKit re-asks. Mirrors
    /// `WidgetReloadPolicy.refreshInterval` on the phone side.
    public static let timelineRefreshInterval: TimeInterval = 60 * 60

    /// A nil `previousKey` means nothing has ever been rendered, so the first
    /// record is never made to wait out a floor.
    public static func shouldReload(previousKey: String?,
                                    nextKey: String,
                                    elapsed: TimeInterval,
                                    floor: TimeInterval = reloadFloor) -> Bool {
        guard let previousKey else { return true }
        guard previousKey != nextKey else { return false }
        return elapsed >= floor
    }

    public static func shouldPush(previousKey: String?,
                                  nextKey: String,
                                  elapsed: TimeInterval,
                                  minInterval: TimeInterval = pushInterval) -> Bool {
        guard let previousKey else { return true }
        guard previousKey != nextKey else { return false }
        return elapsed >= minInterval
    }

    public static func nextReloadDate(after date: Date) -> Date {
        date.addingTimeInterval(timelineRefreshInterval)
    }
}
