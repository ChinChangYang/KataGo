//
//  WatchWidgetDefaultsTests.swift
//  KataGo AnytimeTests
//
//  The watch-local IPC channel between the watch app and its complication.
//  Every test injects its own suite — never the real App Group, which the
//  simulator shares with anything else running.
//

import Testing
import Foundation
import KataGoAnalysisKit

struct WatchWidgetDefaultsTests {
    /// A throwaway suite, removed when the block returns.
    private func withSuite(_ body: (UserDefaults) -> Void) {
        let name = "test.watchwidget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        UserDefaults().removePersistentDomain(forName: name)
    }

    private var sample: WatchWidgetSnapshot {
        WatchWidgetSnapshot(gameID: "GAME-A", name: "Ladder Fight 3",
                            comment: "White cuts.", parkedIndex: 42,
                            mainlineMoveCount: 178, scoreLeadBlack: 3.5,
                            isBranch: false,
                            capturedAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func anEmptySuiteReadsAsAnEmptyRecordNotACrash() {
        withSuite { defaults in
            #expect(WatchWidgetDefaults.read(from: defaults).library == nil)
        }
    }

    @Test func aNilSuiteReadsAsAnEmptyRecord() {
        // `UserDefaults(suiteName:)` returns nil when the App Group is
        // unavailable; the widget must render a distinct state, not crash.
        #expect(WatchWidgetDefaults.read(from: nil).library == nil)
    }

    @Test func theRecordRoundTripsThroughTheSuite() {
        withSuite { defaults in
            let written = WatchWidgetRecord(library: sample)
            #expect(WatchWidgetDefaults.write(written, to: defaults))
            #expect(WatchWidgetDefaults.read(from: defaults) == written)
        }
    }

    @Test func datesSurviveTheRoundTripToTheSecond() {
        // The encoder pins secondsSince1970; a default strategy change here
        // would silently break `capturedAt` ordering.
        withSuite { defaults in
            WatchWidgetDefaults.write(WatchWidgetRecord(library: sample), to: defaults)
            #expect(WatchWidgetDefaults.read(from: defaults).library?.capturedAt
                    == sample.capturedAt)
        }
    }

    @Test func writingToANilSuiteFailsLoudlyRatherThanSilently() {
        #expect(!WatchWidgetDefaults.write(WatchWidgetRecord(library: sample), to: nil))
    }

    @Test func corruptDataReadsAsAnEmptyRecord() {
        withSuite { defaults in
            defaults.set(Data([0x00, 0x01]), forKey: WatchWidgetDefaults.recordsKey)
            #expect(WatchWidgetDefaults.read(from: defaults).library == nil)
        }
    }

    @Test func theLegacyScoreIsReadableForTheCutoverWindow() {
        // Immediately after the update nothing has written the new key yet,
        // and the watch app can go days unopened.
        withSuite { defaults in
            defaults.set(4.5, forKey: WatchWidgetDefaults.legacyScoreKey)
            #expect(WatchWidgetDefaults.legacyScoreLeadBlack(from: defaults) == 4.5)
        }
    }

    @Test func anAbsentLegacyScoreIsNilNotZero() {
        withSuite { defaults in
            #expect(WatchWidgetDefaults.legacyScoreLeadBlack(from: defaults) == nil)
        }
    }

    @Test func legacyKeysAreRemovedExactlyOnce() {
        withSuite { defaults in
            defaults.set(4.5, forKey: WatchWidgetDefaults.legacyScoreKey)
            defaults.set(Date(), forKey: WatchWidgetDefaults.legacyUpdatedAtKey)

            WatchWidgetDefaults.cleanLegacyKeysOnce(in: defaults)
            #expect(defaults.object(forKey: WatchWidgetDefaults.legacyScoreKey) == nil)
            #expect(defaults.object(forKey: WatchWidgetDefaults.legacyUpdatedAtKey) == nil)
            #expect(defaults.bool(forKey: WatchWidgetDefaults.legacyCleanupFlagKey))

            // A second pass must not wipe a key a later feature may have
            // legitimately reused.
            defaults.set(9.9, forKey: WatchWidgetDefaults.legacyScoreKey)
            WatchWidgetDefaults.cleanLegacyKeysOnce(in: defaults)
            #expect(defaults.double(forKey: WatchWidgetDefaults.legacyScoreKey) == 9.9)
        }
    }

    @Test func theWidgetKindIsTheLegacyIdentifier() {
        // Renaming it would orphan every placement testers have already made.
        #expect(WatchWidgetDefaults.widgetKind == "ScoreLeadWidget")
    }
}
