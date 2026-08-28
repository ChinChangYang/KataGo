//
//  ConfigModelTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/18.
//

import SwiftData
import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct ConfigModelTests {

    // 1. Initialization Tests
    @Test func testDefaultInitialization() async throws {
        let config = Config()

        #expect(config.boardWidth == Config.defaultBoardWidth)
        #expect(config.boardHeight == Config.defaultBoardHeight)
        #expect(config.rule == Config.defaultRule)
        #expect(config.komi == Config.defaultKomi)
        #expect(config.playoutDoublingAdvantage == Config.defaultPlayoutDoublingAdvantage)
        #expect(config.analysisWideRootNoise == Config.defaultAnalysisWideRootNoise)
        #expect(config.maxAnalysisMoves == Config.defaultMaxAnalysisMoves)
        #expect(config.analysisInterval == Config.defaultAnalysisInterval)
        #expect(config.analysisInformation == Config.defaultAnalysisInformation)
        #expect(config.hiddenAnalysisVisitRatio == Config.defaultHiddenAnalysisVisitRatio)
        #expect(config.stoneStyle == Config.defaultStoneStyle)
        #expect(config.showCoordinate == Config.defaultShowCoordinate)
        #expect(config.humanRatioForBlack == Config.defaultHumanRatio)
        #expect(config.humanSLProfile == Config.defaultHumanSLProfile)
        #expect(config.optionalAnalysisForWhom == Config.defaultAnalysisForWhom)
        #expect(config.optionalShowOwnership == Config.defaultShowOwnership)
        #expect(config.optionalHumanRatioForWhite == Config.defaultHumanRatio)
        #expect(config.optionalHumanProfileForWhite == Config.defaultHumanSLProfile)
        #expect(config.optionalSoundEffect == Config.defaultSoundEffect)
        #expect(config.optionalShowComments == Config.defaultShowComments)
    }

    @Test func testCustomInitialization() async throws {
        let customConfig = Config(
            boardWidth: 13,
            boardHeight: 13,
            rule: 2,
            komi: 6.5,
            playoutDoublingAdvantage: 1.0,
            analysisWideRootNoise: 0.05,
            maxAnalysisMoves: 100,
            analysisInterval: 20,
            analysisInformation: 1,
            hiddenAnalysisVisitRatio: 0.05,
            stoneStyle: 1,
            showCoordinate: true,
            humanSLRootExploreProbWeightful: 0.1,
            humanSLProfile: "custom_profile",
            optionalAnalysisForWhom: 2,
            optionalShowOwnership: false,
            optionalHumanRatioForWhite: 0.2,
            optionalHumanProfileForWhite: "custom_white_profile",
            optionalSoundEffect: false,
            optionalShowComments: true
        )

        #expect(customConfig.boardWidth == 13)
        #expect(customConfig.boardHeight == 13)
        #expect(customConfig.rule == 2)
        #expect(customConfig.komi == 6.5)
        #expect(customConfig.playoutDoublingAdvantage == 1.0)
        #expect(customConfig.analysisWideRootNoise == 0.05)
        #expect(customConfig.maxAnalysisMoves == 100)
        #expect(customConfig.analysisInterval == 20)
        #expect(customConfig.analysisInformation == 1)
        #expect(customConfig.hiddenAnalysisVisitRatio == 0.05)
        #expect(customConfig.stoneStyle == 1)
        #expect(customConfig.showCoordinate == true)
        #expect(customConfig.humanRatioForBlack == 0.1)
        #expect(customConfig.humanSLProfile == "custom_profile")
        #expect(customConfig.optionalAnalysisForWhom == 2)
        #expect(customConfig.optionalShowOwnership == false)
        #expect(customConfig.optionalHumanRatioForWhite == 0.2)
        #expect(customConfig.optionalHumanProfileForWhite == "custom_white_profile")
        #expect(customConfig.optionalSoundEffect == false)
        #expect(customConfig.optionalShowComments == true)
    }

    // 1b. Opening-book eligibility (pure config: square board, size 2...15 —
    // the KBOK format's whole range, not just the catalog's 6...9)
    @Test func isBookEligibleForSquareSmallBoards() {
        for n in 2...15 {
            #expect(Config(boardWidth: n, boardHeight: n).isBookEligible,
                    "square \(n)x\(n) should be book-eligible")
        }
    }

    @Test func isBookEligibleFalseForLargeAndNonSquareBoards() {
        #expect(Config(boardWidth: 19, boardHeight: 19).isBookEligible == false)
        #expect(Config(boardWidth: 16, boardHeight: 16).isBookEligible == false)
        #expect(Config(boardWidth: 1, boardHeight: 1).isBookEligible == false)
        #expect(Config(boardWidth: 6, boardHeight: 9).isBookEligible == false)
        #expect(Config(boardWidth: 9, boardHeight: 13).isBookEligible == false)
    }

    @Test func isBookEligibleIndependentOfRuleAndKomi() {
        // Eligibility depends only on board dimensions, not rules/komi.
        let c = Config(boardWidth: 7, boardHeight: 7, rule: 1, komi: 9.0)
        #expect(c.isBookEligible)
    }

    // 2. Getter and Setter Tests
    @Test func testOptionalProperties() async throws {
        let config = Config()

        // Test default values
        #expect(config.analysisForWhom == Config.defaultAnalysisForWhom)
        #expect(config.showOwnership == Config.defaultShowOwnership)
        #expect(config.humanRatioForWhite == Config.defaultHumanRatio)
        #expect(config.humanProfileForWhite == Config.defaultHumanSLProfile)
        #expect(config.soundEffect == Config.defaultSoundEffect)
        #expect(config.showComments == Config.defaultShowComments)

        // Set new values
        config.analysisForWhom = 1
        #expect(config.analysisForWhom == 1)

        config.showOwnership = false
        #expect(config.showOwnership == false)

        config.humanRatioForWhite = 0.5
        #expect(config.humanRatioForWhite == 0.5)

        config.humanProfileForWhite = "new_profile"
        #expect(config.humanProfileForWhite == "new_profile")

        config.soundEffect = false
        #expect(config.soundEffect == false)

        config.showComments = true
        #expect(config.showComments == true)
    }

    @Test func testIsEqualBlackWhiteHumanSettings() async throws {
        let config = Config()

        // Initially equal
        #expect(config.isEqualBlackWhiteHumanSettings == true)

        // Change one property
        config.humanRatioForWhite = 0.1
        #expect(config.isEqualBlackWhiteHumanSettings == false)

        // Revert and change another property
        config.humanRatioForWhite = Config.defaultHumanRatio
        config.humanProfileForWhite = "different_profile"
        #expect(config.isEqualBlackWhiteHumanSettings == false)

        // Make all properties equal again
        config.humanProfileForWhite = Config.defaultHumanSLProfile
        #expect(config.isEqualBlackWhiteHumanSettings == true)
    }

    @Test func testEffectiveHumanProfileFollowsHumanAIState() async throws {
        let config = Config()
        config.humanProfileForBlack = "5k"
        config.humanProfileForWhite = "Pro 2000"

        // Both sides Human (thinking time 0): analysis must use the strongest net,
        // so the effective profile is "AI" regardless of the configured profile.
        config.blackMaxTime = 0
        config.whiteMaxTime = 0
        #expect(config.effectiveHumanProfileForBlack == "AI")
        #expect(config.effectiveHumanProfileForWhite == "AI")

        // A side enabled for AI (thinking time > 0) keeps its human-style profile.
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.whiteMaxTime = 1.0
        #expect(config.effectiveHumanProfileForBlack == "5k")
        #expect(config.effectiveHumanProfileForWhite == "Pro 2000")
    }

    @Test func testIsEqualBlackWhiteEffectiveHumanSettings() async throws {
        let config = Config()
        config.humanProfileForBlack = "5k"
        config.humanProfileForWhite = "Pro 2000"

        // Both Human → both effective "AI" → equal, despite different raw profiles.
        config.blackMaxTime = 0
        config.whiteMaxTime = 0
        #expect(config.isEqualBlackWhiteEffectiveHumanSettings == true)

        // One Human, one AI with a real profile → effective profiles differ.
        config.whiteMaxTime = Config.toggleAIThinkingTime
        #expect(config.isEqualBlackWhiteEffectiveHumanSettings == false)

        // Both AI with the same profile → equal again.
        config.blackMaxTime = Config.toggleAIThinkingTime
        config.humanProfileForBlack = "Pro 2000"
        #expect(config.isEqualBlackWhiteEffectiveHumanSettings == true)
    }

    // 4. Computed Properties Tests
    @Test func testAnalysisInformationComputedProperties() async throws {
        let config = Config()

        // Default is "All" (index 2)
        #expect(config.isAnalysisInformationWinrate == false)
        #expect(config.isAnalysisInformationScore == false)

        // Set to "Score" (assuming index 1)
        config.analysisInformation = 1
        #expect(config.isAnalysisInformationWinrate == false)
        #expect(config.isAnalysisInformationScore == true)

        // Set to an invalid index (e.g., 3) to ensure no false positives
        config.analysisInformation = 3
        #expect(config.isAnalysisInformationWinrate == false)
        #expect(config.isAnalysisInformationScore == false)
    }

    @Test func testStoneStyleComputedProperties() async throws {
        let config = Config()

        // Default is "Classic" (index 1)
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == true)

        // Set to "Fast" (index 0)
        config.stoneStyle = 0
        #expect(config.isFastStoneStyle == true)
        #expect(config.isClassicStoneStyle == false)

        // Set to an invalid index (e.g., 2) to ensure no false positives
        config.stoneStyle = 2
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == false)
    }

    /// Pins the SHIPPING default. Fast held this slot from 829a9dbd
    /// (2024-07-11) purely for render cost; the `Canvas`-of-symbols rewrite in
    /// `StoneView` removed that reason, and Classic is the better-looking
    /// board. A future change back to Fast should fail here rather than ship.
    @Test func defaultStoneStyleIsClassic() async throws {
        #expect(Config.defaultStoneStyleText == Config.classicStoneStyle)
        #expect(Config().isClassicStoneStyle == true)
        #expect(Config().isFastStoneStyle == false)
    }

    /// The index form, used by the surfaces that read the raw
    /// `GlobalSettings.stoneStyle` key instead of holding a `Config`: the photo
    /// import preview and the GIF exporter. Neither can be reached from a unit
    /// test (both are SwiftUI views), so the shared helper is the testable seam.
    @Test func isClassicStoneStyleAtIndex() async throws {
        #expect(Config.isClassicStoneStyle(atIndex: 0) == false)
        #expect(Config.isClassicStoneStyle(atIndex: 1) == true)

        // Out of range reports false rather than trapping — these indices come
        // from UserDefaults and SwiftData, so a stale or corrupt value is
        // reachable input, not a programmer error.
        #expect(Config.isClassicStoneStyle(atIndex: -1) == false)
        #expect(Config.isClassicStoneStyle(atIndex: Config.stoneStyles.count) == false)

        // Guards future divergence, and verifies nothing today: the instance
        // property currently *is* a call to this function, so both sides are
        // the same expression. It earns its place only if someone re-inlines
        // the instance property — the exact duplication this helper removed.
        // (It does still pin that the property forwards `stoneStyle` rather
        // than a constant.) The assertions above carry the real signal.
        for index in Config.stoneStyles.indices {
            #expect(Config(stoneStyle: index).isClassicStoneStyle
                    == Config.isClassicStoneStyle(atIndex: index))
        }
    }

    @Test func testIsAnalysisForCurrentPlayer() async throws {
        let config = Config()

        // Default: analysisForWhom = 0 ("Both")
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black) == true)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white) == true)

        // analysisForWhom = 1 ("Black")
        config.analysisForWhom = 1
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black) == true)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white) == false)

        // analysisForWhom = 2 ("White")
        config.analysisForWhom = 2
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black) == false)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white) == true)

        // analysisForWhom = nil (default)
        config.optionalAnalysisForWhom = nil
        #expect(config.analysisForWhom == Config.defaultAnalysisForWhom)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black) == true)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white) == true)
    }

    @Test func testIsAnalysisForCurrentPlayerUnknownColor() async throws {
        let config = Config()

        // Assuming .unknown is a valid PlayerColor case
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .unknown) == false)
    }

    @Test func testIsAnalysisForCurrentPlayerEdgeCases() async throws {
        let config = Config()

        // Set analysisForWhom to an invalid index
        config.analysisForWhom = 5 // Out of bounds
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black) == true)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white) == true)
    }

    @Test func testSoundEffect() async throws {
        let config = Config()
        config.optionalSoundEffect = nil
        #expect(config.soundEffect == Config.defaultSoundEffect)
    }

    @Test func testShowComments() async throws {
        let config = Config()
        config.optionalShowComments = nil
        #expect(config.showComments == Config.defaultShowComments)
    }

    // 5. Extension Properties Tests
    @Test func testHumanProfileForWhiteAndRatio() async throws {
        let config = Config()

        // Default values
        #expect(config.humanProfileForWhite == Config.defaultHumanSLProfile)
        #expect(config.humanRatioForWhite == Config.defaultHumanRatio)

        // Set custom values
        config.humanProfileForWhite = "new_white_profile"
        config.humanRatioForWhite = 0.3
        #expect(config.humanProfileForWhite == "new_white_profile")
        #expect(config.humanRatioForWhite == 0.3)

        // Set to nil and check defaults
        config.optionalHumanProfileForWhite = nil
        config.optionalHumanRatioForWhite = nil
        #expect(config.humanProfileForWhite == Config.defaultHumanSLProfile)
        #expect(config.humanRatioForWhite == Config.defaultHumanRatio)
    }

    // 6. Edge Cases and Error Handling
    @Test func testInvalidStoneStyleIndex() async throws {
        let config = Config(stoneStyle: -1)
        // Depending on implementation, this might crash or handle gracefully
        // Here, assuming it sets to an invalid state
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == false)
    }

    @Test func testAllStoneStyles() async throws {
        for (index, style) in Config.stoneStyles.enumerated() {
            let config = Config(stoneStyle: index)
            if style == Config.fastStoneStyle {
                #expect(config.isFastStoneStyle == true)
                #expect(config.isClassicStoneStyle == false)
            } else if style == Config.classicStoneStyle {
                #expect(config.isFastStoneStyle == false)
                #expect(config.isClassicStoneStyle == true)
            }
        }
    }

    // 7. Clone Initialization Test
    @Test func testCloneWithCustomValues() async throws {
        let originalConfig = Config(
            boardWidth: 13,
            boardHeight: 13,
            rule: 1,
            komi: 6.5,
            playoutDoublingAdvantage: 1.0,
            analysisWideRootNoise: 0.05,
            maxAnalysisMoves: 100,
            analysisInterval: 20,
            analysisInformation: 2,
            hiddenAnalysisVisitRatio: 0.05,
            stoneStyle: 1,
            showCoordinate: true,
            humanSLRootExploreProbWeightful: 0.1,
            humanSLProfile: "custom_profile",
            optionalAnalysisForWhom: 2,
            optionalShowOwnership: false,
            optionalHumanRatioForWhite: 0.2,
            optionalHumanProfileForWhite: "custom_white_profile",
            optionalSoundEffect: false,
            optionalShowComments: true
        )

        let cloneConfig = Config(config: originalConfig)

        #expect(cloneConfig.boardWidth == originalConfig.boardWidth)
        #expect(cloneConfig.boardHeight == originalConfig.boardHeight)
        #expect(cloneConfig.rule == originalConfig.rule)
        #expect(cloneConfig.komi == originalConfig.komi)
        #expect(cloneConfig.playoutDoublingAdvantage == originalConfig.playoutDoublingAdvantage)
        #expect(cloneConfig.analysisWideRootNoise == originalConfig.analysisWideRootNoise)
        #expect(cloneConfig.maxAnalysisMoves == originalConfig.maxAnalysisMoves)
        #expect(cloneConfig.analysisInterval == originalConfig.analysisInterval)
        #expect(cloneConfig.analysisInformation == originalConfig.analysisInformation)
        #expect(cloneConfig.hiddenAnalysisVisitRatio == originalConfig.hiddenAnalysisVisitRatio)
        #expect(cloneConfig.stoneStyle == originalConfig.stoneStyle)
        #expect(cloneConfig.showCoordinate == originalConfig.showCoordinate)
        #expect(cloneConfig.humanRatioForBlack == originalConfig.humanRatioForBlack)
        #expect(cloneConfig.humanSLProfile == originalConfig.humanSLProfile)
        #expect(cloneConfig.optionalAnalysisForWhom == originalConfig.optionalAnalysisForWhom)
        #expect(cloneConfig.optionalShowOwnership == originalConfig.optionalShowOwnership)
        #expect(cloneConfig.optionalHumanRatioForWhite == originalConfig.optionalHumanRatioForWhite)
        #expect(cloneConfig.optionalHumanProfileForWhite == originalConfig.optionalHumanProfileForWhite)
        #expect(cloneConfig.optionalSoundEffect == originalConfig.optionalSoundEffect)
        #expect(cloneConfig.optionalShowComments == originalConfig.optionalShowComments)
    }

    /// The rest of the copied fields, all set away from their defaults so an
    /// omission in `Config(config:)` shows up as a value change rather than as
    /// a coincidental match. The six rule fields were dropped for exactly that
    /// reason: the copy took the initializer's defaults, so
    /// `GameRecord.clone()` turned a Japanese-rules game into a Chinese-rules
    /// one — invisible in the app only because loading a game overwrites those
    /// six from the SGF's `RU[]` (`GobanState.switchGame`), which masks the
    /// loss whenever the SGF happens to carry a ruleset. The load also
    /// reconciles the `rule` label index to those components (the tvOS
    /// info-row fix), so a stale preset label is healed the same way.
    @Test func testCloneCarriesEveryRemainingField() async throws {
        let original = Config()
        original.optionalShowPass = false
        original.optionalVerticalFlip = true
        original.optionalBlackMaxTime = 1.25
        original.optionalWhiteMaxTime = 2.5
        original.koRule = .situational
        original.scoringRule = .territory
        original.taxRule = .all
        original.multiStoneSuicideLegal = true
        original.hasButton = true
        original.whiteHandicapBonusRule = .n_minus_one
        original.optionalShowWinrateBar = false
        original.optionalAnalysisStyle = 1
        original.optionalShowCharts = false
        original.optionalUseLLM = true
        original.optionalTemperature = 0.9
        original.tone = .poetic

        let clone = Config(config: original)

        #expect(clone.optionalShowPass == original.optionalShowPass)
        #expect(clone.optionalVerticalFlip == original.optionalVerticalFlip)
        #expect(clone.optionalBlackMaxTime == original.optionalBlackMaxTime)
        #expect(clone.optionalWhiteMaxTime == original.optionalWhiteMaxTime)
        #expect(clone.optionalKoRule == original.optionalKoRule)
        #expect(clone.optionalScoringRule == original.optionalScoringRule)
        #expect(clone.optionalTaxRule == original.optionalTaxRule)
        #expect(clone.optionalMultiStoneSuicideLegal == original.optionalMultiStoneSuicideLegal)
        #expect(clone.optionalHasButton == original.optionalHasButton)
        #expect(clone.optionalWhiteHandicapBonusRule == original.optionalWhiteHandicapBonusRule)
        #expect(clone.optionalShowWinrateBar == original.optionalShowWinrateBar)
        #expect(clone.optionalAnalysisStyle == original.optionalAnalysisStyle)
        #expect(clone.optionalShowCharts == original.optionalShowCharts)
        #expect(clone.optionalUseLLM == original.optionalUseLLM)
        #expect(clone.optionalTemperature == original.optionalTemperature)
        #expect(clone.optionalTone == original.optionalTone)
    }

    /// Drift alarm for `Config(config:)`.
    ///
    /// The two tests above only prove the fields they name are copied; they
    /// stay green forever after someone adds a 38th property and forgets the
    /// copy initializer, which is precisely the failure that lost the rule
    /// fields. Every parameter of the designated initializer carries a
    /// default, so an omission is not a compile error — nothing but this list
    /// notices. Pin the schema instead: adding or removing a persisted
    /// property fails here, and the fix is to update `Config(config:)`, the
    /// round-trip tests, and this set together.
    ///
    /// `gameRecord` is the one property `Config(config:)` deliberately does
    /// NOT copy — a detached copy has no owner until the caller assigns one.
    @Test func configPersistedPropertiesAreAllCopied() async throws {
        // Split across several arrays: one 37-element set literal type-checks
        // too slowly for the compiler's budget.
        let copiedNames: [String] = [
            "boardWidth", "boardHeight", "rule", "komi",
            "playoutDoublingAdvantage", "analysisWideRootNoise",
            "maxAnalysisMoves", "analysisInterval", "analysisInformation",
            "hiddenAnalysisVisitRatio", "stoneStyle", "showCoordinate",
            "humanSLRootExploreProbWeightful", "humanSLProfile"
        ]
        let copiedOptionalNames: [String] = [
            "optionalAnalysisForWhom", "optionalShowOwnership",
            "optionalHumanRatioForWhite", "optionalHumanProfileForWhite",
            "optionalSoundEffect", "optionalShowComments", "optionalShowPass",
            "optionalVerticalFlip", "optionalBlackMaxTime", "optionalWhiteMaxTime"
        ]
        let copiedRuleNames: [String] = [
            "optionalKoRule", "optionalScoringRule", "optionalTaxRule",
            "optionalMultiStoneSuicideLegal", "optionalHasButton",
            "optionalWhiteHandicapBonusRule"
        ]
        let copiedDisplayNames: [String] = [
            "optionalShowWinrateBar", "optionalAnalysisStyle",
            "optionalShowCharts", "optionalUseLLM", "optionalTemperature",
            "optionalTone"
        ]
        // `gameRecord` is the one property `Config(config:)` deliberately does
        // NOT copy: a detached copy has no owner until the caller assigns one.
        var expected = Set(copiedNames)
        expected.formUnion(copiedOptionalNames)
        expected.formUnion(copiedRuleNames)
        expected.formUnion(copiedDisplayNames)
        expected.insert("gameRecord")

        let schema = Schema([Config.self])
        let entity = try #require(schema.entities.first { $0.name == "Config" })
        let persisted = Set(entity.properties.map(\.name))

        let unlisted = persisted.subtracting(expected).sorted()
        let vanished = expected.subtracting(persisted).sorted()
        let hint = "Config's persisted properties changed (new: \(unlisted), gone: \(vanished)). Every field must also be forwarded in `Config(config:)` — omitting one still compiles and silently resets that field to its default in every GameRecord.clone(). Update the copy initializer, the round-trip tests above, and this list together."

        #expect(persisted == expected, "\(hint)")
    }

    // 8. Existing Tests with Enhancements
    @Test func initializeConfig() async throws {
        let config = Config()
        let clone = Config(config: config)
        #expect(config.boardWidth == clone.boardWidth)
        #expect(config.boardHeight == clone.boardHeight)
        #expect(config.rule == clone.rule)
        #expect(config.komi == clone.komi)
        #expect(config.playoutDoublingAdvantage == clone.playoutDoublingAdvantage)
        #expect(config.analysisWideRootNoise == clone.analysisWideRootNoise)
        #expect(config.maxAnalysisMoves == clone.maxAnalysisMoves)
        #expect(config.analysisInterval == clone.analysisInterval)
        #expect(config.analysisInformation == clone.analysisInformation)
        #expect(config.hiddenAnalysisVisitRatio == clone.hiddenAnalysisVisitRatio)
        #expect(config.stoneStyle == clone.stoneStyle)
        #expect(config.showCoordinate == clone.showCoordinate)
        #expect(config.humanRatioForBlack == clone.humanRatioForBlack)
        #expect(config.humanSLProfile == clone.humanSLProfile)
        #expect(config.optionalAnalysisForWhom == clone.optionalAnalysisForWhom)
        #expect(config.optionalShowOwnership == clone.optionalShowOwnership)
        #expect(config.optionalHumanRatioForWhite == clone.optionalHumanRatioForWhite)
        #expect(config.optionalHumanProfileForWhite == clone.optionalHumanProfileForWhite)
        #expect(config.optionalSoundEffect == clone.optionalSoundEffect)
        #expect(config.optionalShowComments == clone.optionalShowComments)
    }

    @Test func analysisInformation() async throws {
        let config = Config()
        #expect(config.isAnalysisInformationWinrate == false)
        #expect(config.isAnalysisInformationScore == false)
        config.analysisInformation = 0
        #expect(config.isAnalysisInformationWinrate == true)
        #expect(config.isAnalysisInformationScore == false)
    }

    @Test func stoneStyle() async throws {
        let config = Config()
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == true)
        config.stoneStyle = 0
        #expect(config.isFastStoneStyle == true)
        #expect(config.isClassicStoneStyle == false)
    }

    @Test func analysisForWhom() async throws {
        let config = Config()
        #expect(config.analysisForWhom == 0)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black) == true)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white) == true)

        config.analysisForWhom = 1
        #expect(config.analysisForWhom == 1)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black) == true)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white) == false)

        config.analysisForWhom = 2
        #expect(config.analysisForWhom == 2)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .black) == false)
        #expect(config.isAnalysisForCurrentPlayer(nextColorForPlayCommand: .white) == true)

        config.optionalAnalysisForWhom = nil
        #expect(config.analysisForWhom == Config.defaultAnalysisForWhom)
    }

    @Test func showOwnership() async throws {
        let config = Config()
        config.optionalShowOwnership = nil
        #expect(config.showOwnership == Config.defaultShowOwnership)
        config.showOwnership = false
        #expect(config.showOwnership == false)
    }
}
