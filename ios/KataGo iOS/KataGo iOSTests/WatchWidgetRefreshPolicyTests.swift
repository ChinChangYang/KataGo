//
//  WatchWidgetRefreshPolicyTests.swift
//  KataGo AnytimeTests
//
//  When a changed record is worth a timeline reload.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetRefreshPolicyTests {
    // MARK: reload

    @Test func anUnchangedKeyNeverReloads() {
        #expect(!WatchWidgetRefreshPolicy.shouldReload(
            previousKey: "same", nextKey: "same", elapsed: 10_000))
    }

    @Test func aChangedKeyReloadsOnceTheFloorHasPassed() {
        #expect(WatchWidgetRefreshPolicy.shouldReload(
            previousKey: "a", nextKey: "b",
            elapsed: WatchWidgetRefreshPolicy.reloadFloor))
    }

    @Test func aChangedKeyInsideTheFloorWaits() {
        #expect(!WatchWidgetRefreshPolicy.shouldReload(
            previousKey: "a", nextKey: "b", elapsed: 5))
    }

    @Test func theFirstRecordEverAlwaysReloads() {
        // No previous key means nothing has ever been rendered; making the
        // very first record wait out a floor would leave the tile on its
        // placeholder for half a minute after setup.
        #expect(WatchWidgetRefreshPolicy.shouldReload(
            previousKey: nil, nextKey: "a", elapsed: 0))
    }

    @Test func aCommentChangeAloneIsEnoughToReload() {
        // The regression this policy exists to prevent: the old gate required
        // a half-point score move, so a new comment never reached the tile.
        // Any two distinct strings exercise this policy — the content key's
        // actual (length-prefixed) shape is pinned by WatchWidgetSnapshotTests.
        let before = "no comment yet"
        let after  = "no comment yet, but now White cuts."
        #expect(WatchWidgetRefreshPolicy.shouldReload(
            previousKey: before, nextKey: after,
            elapsed: WatchWidgetRefreshPolicy.reloadFloor))
    }

    // MARK: timeline

    @Test func theTimelineSchedulesABoundedRefresh() {
        // Never `.never`: a tile showing a three-day-old sentence with no
        // self-healing path reads as truth.
        let now = Date(timeIntervalSince1970: 0)
        #expect(WatchWidgetRefreshPolicy.nextReloadDate(after: now)
                == now.addingTimeInterval(WatchWidgetRefreshPolicy.timelineRefreshInterval))
    }
}
