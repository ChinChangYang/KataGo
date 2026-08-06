//
//  WatchComplicationPushThrottleTests.swift
//  KataGo AnytimeTests
//
//  The phone-side rate-limit state for WatchSessionRelay's complication push
//  must survive a process relaunch, or WatchWidgetRefreshPolicy.shouldPush's
//  "nil previousKey means first push" rule reopens on every backgrounding —
//  iOS kills this app routinely, far more often than the user force-quits it.
//

import Testing
import Foundation
@testable import KataGo_Anytime

struct WatchComplicationPushThrottleTests {
    /// A throwaway suite, removed when the block returns. Never the real
    /// `.standard` domain — that would leak test state into the developer's
    /// own defaults.
    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "test.watchcomplicationpush.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        UserDefaults().removePersistentDomain(forName: name)
    }

    @Test func aFreshSuiteStartsWithNoThrottleState() {
        withSuite { defaults in
            let throttle = WatchComplicationPushThrottle(defaults: defaults)
            #expect(throttle.lastPushedKey == nil)
            #expect(throttle.lastPushedAt == nil)
        }
    }

    @Test func stateWrittenByOneInstanceIsSeenByAFreshOne() {
        // Simulates a process relaunch: the relay that pushed is gone, and a
        // brand-new WatchSessionRelay (and therefore a brand-new
        // WatchComplicationPushThrottle) is constructed on the next launch.
        // Plain in-memory properties would report nil here, silently
        // reopening the unthrottled first-push branch.
        withSuite { defaults in
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let first = WatchComplicationPushThrottle(defaults: defaults)
            first.recordPush(key: "abc123", at: now)

            let second = WatchComplicationPushThrottle(defaults: defaults)
            #expect(second.lastPushedKey == "abc123")
            #expect(second.lastPushedAt == now)
        }
    }

    @Test func recordingAgainOverwritesTheStoredKeyAndTime() {
        withSuite { defaults in
            let throttle = WatchComplicationPushThrottle(defaults: defaults)
            throttle.recordPush(key: "first", at: Date(timeIntervalSince1970: 1))
            throttle.recordPush(key: "second", at: Date(timeIntervalSince1970: 2))

            #expect(throttle.lastPushedKey == "second")
            #expect(throttle.lastPushedAt == Date(timeIntervalSince1970: 2))
        }
    }

    @Test func distinctSuitesDoNotShareState() {
        // Guards against a hard-coded key ever creeping back in: two
        // independently-injected suites (as two tests running concurrently
        // would use) must not observe each other's writes.
        withSuite { defaultsA in
            withSuite { defaultsB in
                let throttleA = WatchComplicationPushThrottle(defaults: defaultsA)
                throttleA.recordPush(key: "only-in-a", at: Date(timeIntervalSince1970: 1))

                let throttleB = WatchComplicationPushThrottle(defaults: defaultsB)
                #expect(throttleB.lastPushedKey == nil)
            }
        }
    }
}
