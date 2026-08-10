//
//  TVAutoPlaySpeedTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct TVAutoPlaySpeedTests {
    @Test func casesAreOrderedSlowestFirstForTheSegmentedPicker() {
        #expect(TVAutoPlaySpeed.allCases == [.slow, .normal, .fast])
    }

    @Test func rawValuesRoundTrip() {
        for speed in TVAutoPlaySpeed.allCases {
            #expect(TVAutoPlaySpeed(rawValue: speed.rawValue) == speed)
        }
    }

    /// The store/@AppStorage fallback path depends on an unknown raw value
    /// failing to decode rather than trapping.
    @Test func unknownRawValueDecodesToNil() {
        #expect(TVAutoPlaySpeed(rawValue: "garbage") == nil)
    }

    @Test func defaultIsNormalAndTheKeyIsNamespaced() {
        #expect(TVAutoPlaySpeed.defaultValue == .normal)
        #expect(TVAutoPlaySpeed.defaultsKey == "TVSettings.autoPlaySpeed")
    }

    @Test func labelsAreTheUserFacingStrings() {
        #expect(TVAutoPlaySpeed.slow.label == "Slow")
        #expect(TVAutoPlaySpeed.normal.label == "Normal")
        #expect(TVAutoPlaySpeed.fast.label == "Fast")
    }

    @Test("Slow replay pacing is live-broadcast parity")
    func slowPacingIsLive() {
        #expect(TVAutoPlaySpeed.slow.broadcastPacing == BroadcastPacing.live)
        #expect(BroadcastPacing.live.charactersPerSecond == BroadcastConstants.charactersPerSecond)
        #expect(BroadcastPacing.live.dwellSeconds == BroadcastConstants.dwellSeconds)
        #expect(BroadcastPacing.live.minimumSlideSeconds == BroadcastConstants.minimumSlideSeconds)
        #expect(BroadcastPacing.live.maxSlideCount == Int.max)
    }

    @Test("Normal and fast pacing tighten monotonically; fast is best-slide-only")
    func fasterProfilesTighten() {
        let slow = TVAutoPlaySpeed.slow.broadcastPacing
        let normal = TVAutoPlaySpeed.normal.broadcastPacing
        let fast = TVAutoPlaySpeed.fast.broadcastPacing
        #expect(normal.charactersPerSecond > slow.charactersPerSecond)
        #expect(fast.charactersPerSecond > normal.charactersPerSecond)
        #expect(normal.dwellSeconds < slow.dwellSeconds)
        #expect(fast.dwellSeconds < normal.dwellSeconds)
        #expect(normal.minimumSlideSeconds < slow.minimumSlideSeconds)
        #expect(fast.minimumSlideSeconds < normal.minimumSlideSeconds)
        #expect(normal.maxSlideCount == Int.max)
        #expect(fast.maxSlideCount == 1)
    }

    @Test("current reads the defaults key, falling back to the default")
    func currentReadsDefaults() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: TVAutoPlaySpeed.defaultsKey)
        defer {
            if let saved { defaults.set(saved, forKey: TVAutoPlaySpeed.defaultsKey) }
            else { defaults.removeObject(forKey: TVAutoPlaySpeed.defaultsKey) }
        }
        defaults.removeObject(forKey: TVAutoPlaySpeed.defaultsKey)
        #expect(TVAutoPlaySpeed.current == TVAutoPlaySpeed.defaultValue)
        defaults.set(TVAutoPlaySpeed.fast.rawValue, forKey: TVAutoPlaySpeed.defaultsKey)
        #expect(TVAutoPlaySpeed.current == .fast)
        defaults.set("garbage", forKey: TVAutoPlaySpeed.defaultsKey)
        #expect(TVAutoPlaySpeed.current == TVAutoPlaySpeed.defaultValue)
    }
}
