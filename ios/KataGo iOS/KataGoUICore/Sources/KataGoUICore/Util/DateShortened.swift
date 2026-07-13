//
//  DateShortened.swift
//  KataGoUICore
//
//  Compact one-line date for game-list rows (iOS game list, visionOS Games
//  picker): newer than 24 hours ago shows the time only, older shows the
//  numeric date only. `now` is injectable for tests; call sites use the
//  default.
//

import Foundation

public extension Date {
    func timeIntervalSinceYesterday(now: Date = .now) -> TimeInterval {
        let yesterday = now.addingTimeInterval(-24 * 60 * 60)
        return timeIntervalSince(yesterday)
    }

    func shortened(now: Date = .now) -> String {
        if timeIntervalSinceYesterday(now: now) > 0 {
            return formatted(date: .omitted, time: .shortened)
        } else {
            return formatted(date: .numeric, time: .omitted)
        }
    }
}
