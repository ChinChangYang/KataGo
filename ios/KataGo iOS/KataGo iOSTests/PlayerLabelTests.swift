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
/// like "rank_9d"); a side with zero thinking time is a person ("Human").
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
        let config = Config(humanSLProfile: "rank_9d", optionalBlackMaxTime: 0.5)
        #expect(config.playerLabel(for: .black) == "rank_9d")
    }

    @Test func whiteWithPositiveThinkingTimeShowsItsHumanProfileName() {
        let config = Config(optionalHumanProfileForWhite: "preaz_5k",
                            optionalWhiteMaxTime: 0.5)
        #expect(config.playerLabel(for: .white) == "preaz_5k")
    }

    @Test func exactlyZeroThinkingTimeIsHumanNotAI() {
        // 0 is the human sentinel; only strictly-positive time means AI.
        let config = Config(humanSLProfile: "rank_9d",
                            optionalBlackMaxTime: 0.0)
        #expect(config.playerLabel(for: .black) == "Human")
    }

    @Test func eachColorIsIndependent() {
        // Black AI (1s) + White human (0s): labels must not bleed across colors.
        let config = Config(humanSLProfile: "rank_3d",
                            optionalHumanProfileForWhite: "rank_7d",
                            optionalBlackMaxTime: 1.0,
                            optionalWhiteMaxTime: 0.0)
        #expect(config.playerLabel(for: .black) == "rank_3d")
        #expect(config.playerLabel(for: .white) == "Human")
    }

    @Test func unknownColorHasNoLabel() {
        let config = Config()
        #expect(config.playerLabel(for: .unknown) == "")
    }
}
