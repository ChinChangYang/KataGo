//
//  WatchWidgetRefreshPolicy.swift
//  KataGoAnalysisKit
//
//  When a change is worth a timeline reload.
//
//  Every decision here is keyed on the DISPLAYED content, with time only ever
//  acting as a floor. The complication this replaces gated its reload on a
//  half-point score move, which was defensible for a tile that showed only a
//  score and is exactly wrong for one that shows a name and a comment: those
//  change while the score sits still.
//
//  There is no push half any more. The phone used to spend one of its ~50
//  daily complication transfers to wake this watch app in the background; the
//  watch no longer talks to the phone at all, so the only writer left is the
//  watch's own library mirror, which runs in the foreground.
//

import Foundation

public enum WatchWidgetRefreshPolicy {
    /// Minimum spacing between timeline reloads. A floor, never a trigger.
    public static let reloadFloor: TimeInterval = 30

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

    public static func nextReloadDate(after date: Date) -> Date {
        date.addingTimeInterval(timelineRefreshInterval)
    }
}
