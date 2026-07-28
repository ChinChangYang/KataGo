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

    @Test func secondsMatchTheAgreedCadence() {
        #expect(TVAutoPlaySpeed.slow.seconds == 3.0)
        #expect(TVAutoPlaySpeed.normal.seconds == 1.5)
        #expect(TVAutoPlaySpeed.fast.seconds == 0.7)
    }

    @Test func intervalMirrorsSeconds() {
        for speed in TVAutoPlaySpeed.allCases {
            #expect(speed.interval == .seconds(speed.seconds))
        }
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
}
