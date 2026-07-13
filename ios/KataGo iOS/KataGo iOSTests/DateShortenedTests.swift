//
//  DateShortenedTests.swift
//  KataGo AnytimeTests
//
//  Pins Date.shortened(now:) after its move from the iOS game list into
//  KataGoUICore (the visionOS Games picker reuses it): newer than 24 hours
//  ago shows time-only, older shows the numeric date only. Expectations are
//  computed with the same formatted(...) API in-test, so they hold in any
//  locale/time zone.
//

import Foundation
import Testing
@testable import KataGoUICore

struct DateShortenedTests {
    private let now = Date.now

    @Test func recentDateUsesTimeOnly() {
        let date = now.addingTimeInterval(-60 * 60)
        #expect(date.shortened(now: now) == date.formatted(date: .omitted, time: .shortened))
    }

    @Test func olderDateUsesNumericDateOnly() {
        let date = now.addingTimeInterval(-48 * 60 * 60)
        #expect(date.shortened(now: now) == date.formatted(date: .numeric, time: .omitted))
    }

    @Test func boundaryAroundTwentyFourHours() {
        let justInside = now.addingTimeInterval(-24 * 60 * 60 + 60)
        let justOutside = now.addingTimeInterval(-24 * 60 * 60 - 60)
        #expect(justInside.shortened(now: now) == justInside.formatted(date: .omitted, time: .shortened))
        #expect(justOutside.shortened(now: now) == justOutside.formatted(date: .numeric, time: .omitted))
    }
}
