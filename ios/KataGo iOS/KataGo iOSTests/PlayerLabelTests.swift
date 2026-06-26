//
//  PlayerLabelTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// `Config.playerLabel(for:)` decides the name shown beside a color's
/// captured-stone count: a side with a positive per-move thinking time is the
/// engine (so we show its profile — "AI" by default, or a human-SL profile
/// like "9d"); a side with zero thinking time is a person ("Human").
struct PlayerLabelTests {

    @Test func blackWithZeroThinkingTimeIsHuman() {
        let config = Config(optionalBlackMaxTime: 0)
        #expect(config.playerLabel(for: .black) == "Human")
    }

    @Test func whiteWithZeroThinkingTimeIsHuman() {
        let config = Config(optionalWhiteMaxTime: 0)
        #expect(config.playerLabel(for: .white) == "Human")
    }

    @Test func blackWithPositiveThinkingTimeShowsAIProfileByDefault() {
        // Default profile is "AI", so an AI-driven black reads "AI".
        let config = Config(optionalBlackMaxTime: 1.0)
        #expect(config.playerLabel(for: .black) == "AI")
    }

    @Test func whiteWithPositiveThinkingTimeShowsAIProfileByDefault() {
        let config = Config(optionalWhiteMaxTime: 2.0)
        #expect(config.playerLabel(for: .white) == "AI")
    }

    @Test func blackWithPositiveThinkingTimeShowsItsHumanProfileName() {
        // humanSLProfile is the black profile accessor.
        let config = Config(humanSLProfile: "9d", optionalBlackMaxTime: 0.5)
        #expect(config.playerLabel(for: .black) == "9d")
    }

    @Test func whiteWithPositiveThinkingTimeShowsItsHumanProfileName() {
        let config = Config(optionalHumanProfileForWhite: "5k",
                            optionalWhiteMaxTime: 0.5)
        #expect(config.playerLabel(for: .white) == "5k")
    }

    @Test func exactlyZeroThinkingTimeIsHumanNotAI() {
        // 0 is the human sentinel; only strictly-positive time means AI.
        let config = Config(humanSLProfile: "9d",
                            optionalBlackMaxTime: 0.0)
        #expect(config.playerLabel(for: .black) == "Human")
    }

    @Test func eachColorIsIndependent() {
        // Black AI (1s) + White human (0s): labels must not bleed across colors.
        let config = Config(humanSLProfile: "3d",
                            optionalHumanProfileForWhite: "7d",
                            optionalBlackMaxTime: 1.0,
                            optionalWhiteMaxTime: 0.0)
        #expect(config.playerLabel(for: .black) == "3d")
        #expect(config.playerLabel(for: .white) == "Human")
    }

    @Test func unknownColorHasNoLabel() {
        let config = Config()
        #expect(config.playerLabel(for: .unknown) == "")
    }
}

/// `Config.toggledMaxTime(for:)` computes the per-move time a side gets when its
/// AI/Human label is tapped: human (0) → 0.5s, AI (>0) → 0. `.unknown` is a 0
/// no-op. The Config form can still set any other value; this is only the
/// quick-toggle default.
struct AIHumanToggleTests {

    @Test func humanBlackTogglesToHalfSecond() {
        let config = Config(optionalBlackMaxTime: 0)
        #expect(config.toggledMaxTime(for: .black) == 0.5)
    }

    @Test func aiBlackTogglesToZero() {
        let config = Config(optionalBlackMaxTime: 0.5)
        #expect(config.toggledMaxTime(for: .black) == 0)
    }

    @Test func aiBlackWithCustomTimeTogglesToZero() {
        // A custom time set via the Config form still toggles back to human.
        let config = Config(optionalBlackMaxTime: 3.0)
        #expect(config.toggledMaxTime(for: .black) == 0)
    }

    @Test func humanWhiteTogglesToHalfSecond() {
        let config = Config(optionalWhiteMaxTime: 0)
        #expect(config.toggledMaxTime(for: .white) == 0.5)
    }

    @Test func aiWhiteTogglesToZero() {
        let config = Config(optionalWhiteMaxTime: 2.0)
        #expect(config.toggledMaxTime(for: .white) == 0)
    }

    @Test func eachColorTogglesIndependently() {
        // Black AI (1s), White human (0): toggling black turns it off; white turns on.
        let config = Config(optionalBlackMaxTime: 1.0, optionalWhiteMaxTime: 0.0)
        #expect(config.toggledMaxTime(for: .black) == 0)
        #expect(config.toggledMaxTime(for: .white) == 0.5)
    }

    @Test func togglesUseTheNamedDefaultConstant() {
        let config = Config(optionalBlackMaxTime: 0)
        #expect(config.toggledMaxTime(for: .black) == Config.toggleAIThinkingTime)
    }

    @Test func unknownColorTogglesToZero() {
        let config = Config()
        #expect(config.toggledMaxTime(for: .unknown) == 0)
    }
}
