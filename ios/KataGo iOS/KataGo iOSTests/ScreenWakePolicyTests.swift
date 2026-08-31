//
//  ScreenWakePolicyTests.swift
//  KataGo iOSTests
//
//  The keep-awake window's boundaries. The numbers are the owner's: a 5 s
//  tail after the AI's stone lands and a 65 s ceiling on any one hold.
//

import Testing
@testable import KataGoUICore

struct ScreenWakePolicyTests {
    private func hold(enabled: Bool = true,
                      owes: Bool = false,
                      sinceMove: Double? = nil,
                      autoPlaying: Bool = false,
                      active: Bool = true,
                      age: Double? = nil) -> Bool {
        ScreenWakePolicy.shouldHold(enabled: enabled,
                                    engineOwesMove: owes,
                                    secondsSinceAIMove: sinceMove,
                                    isAutoPlaying: autoPlaying,
                                    isActive: active,
                                    holdAge: age)
    }

    @Test func theSettingIsOnByDefault() {
        #expect(ScreenWakePolicy.defaultEnabled)
        #expect(ScreenWakePolicy.tailSeconds == 5)
        #expect(ScreenWakePolicy.ceilingSeconds == 65)
    }

    @Test func disabledNeverHolds() {
        #expect(!hold(enabled: false, owes: true, age: 0))
        #expect(!hold(enabled: false, sinceMove: 1, age: 1))
        #expect(!hold(enabled: false, autoPlaying: true, age: 0))
    }

    @Test func anInactiveSceneNeverHolds() {
        #expect(!hold(owes: true, active: false, age: 0))
        #expect(!hold(sinceMove: 1, active: false, age: 1))
        #expect(!hold(autoPlaying: true, active: false, age: 0))
    }

    @Test func owingAMoveHolds() {
        #expect(hold(owes: true, age: 0))
        #expect(hold(owes: true, age: 64.9))
    }

    @Test func theTailReleasesAtFiveSecondsExactly() {
        #expect(hold(sinceMove: 0, age: 0))
        #expect(hold(sinceMove: 4.9, age: 4.9))
        #expect(!hold(sinceMove: 5.0, age: 5.0))
        #expect(!hold(sinceMove: 30, age: 30))
    }

    @Test func autoPlayHoldsWithoutOwingAMove() {
        #expect(hold(autoPlaying: true, age: 0))
        #expect(hold(autoPlaying: true, age: 60))
    }

    @Test func theCeilingReleasesEvenWhileStillOwing() {
        #expect(hold(owes: true, age: 64.9))
        #expect(!hold(owes: true, age: 65.0))
        #expect(!hold(autoPlaying: true, age: 65.0))
        // A fresh activity event resets the age and the hold resumes.
        #expect(hold(owes: true, age: 0))
    }

    @Test func nothingHappeningHoldsNothing() {
        #expect(!hold())
        #expect(!hold(age: 0))
    }
}
