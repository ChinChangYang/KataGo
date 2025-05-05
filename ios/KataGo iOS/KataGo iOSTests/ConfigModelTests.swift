//
//  ConfigModelTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/18.
//

import Testing
@testable import KataGo_Anytime

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

    // 3. Command Methods Tests
    @Test func testKataAnalyzeCommand() async throws {
        let config = Config()
        #expect(config.getKataAnalyzeCommand() == "kata-analyze interval \(Config.defaultAnalysisInterval) maxmoves \(Config.defaultMaxAnalysisMoves) ownership true ownershipStdev true")
    }

    @Test func testGetKataAnalyzeCommandWithCustomInterval() async throws {
        let config = Config()
        config.analysisInterval = 30
        config.maxAnalysisMoves = 60
        let command = config.getKataAnalyzeCommand(analysisInterval: 30)
        #expect(command == "kata-analyze interval 30 maxmoves 60 ownership true ownershipStdev true")
    }

    @Test func testGetKataFastAnalyzeCommand() async throws {
        let config = Config()
        config.maxAnalysisMoves = 70
        let command = config.getKataFastAnalyzeCommand()
        #expect(command == "kata-analyze interval 10 maxmoves 70 ownership true ownershipStdev true")
    }

    @Test func testGetKataBoardSizeCommand() async throws {
        let config = Config(boardWidth: 13, boardHeight: 13)
        let command = config.getKataBoardSizeCommand()
        #expect(command == "rectangular_boardsize 13 13")
    }

    @Test func testGetKataKomiCommand() async throws {
        let config = Config(komi: 6.5)
        let command = config.getKataKomiCommand()
        #expect(command == "komi 6.5")
    }

    @Test func testGetKataPlayoutDoublingAdvantageCommand() async throws {
        let config = Config(playoutDoublingAdvantage: 1.5)
        let command = config.getKataPlayoutDoublingAdvantageCommand()
        #expect(command == "kata-set-param playoutDoublingAdvantage 1.5")
    }

    @Test func testGetKataAnalysisWideRootNoiseCommand() async throws {
        let config = Config(analysisWideRootNoise: 0.05)
        let command = config.getKataAnalysisWideRootNoiseCommand()
        #expect(command == "kata-set-param analysisWideRootNoise 0.05")
    }

    @Test func testGetKataRuleCommand() async throws {
        let config = Config(rule: 2) // Assuming rule index 2 corresponds to "korean"
        var command = config.getKataRuleCommand()
        #expect(command == "kata-set-rules korean")

        config.rule = 4 // Assuming rule index 4 corresponds to "bga"
        command = config.getKataRuleCommand()
        #expect(command == "kata-set-rules bga")
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

        // Default is "Fast" (index 0)
        #expect(config.isFastStoneStyle == true)
        #expect(config.isClassicStoneStyle == false)

        // Set to "Classic" (index 1)
        config.stoneStyle = 1
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == true)

        // Set to an invalid index (e.g., 2) to ensure no false positives
        config.stoneStyle = 2
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == false)
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
    @Test func testInvalidRuleIndex() async throws {
        let config = Config(rule: -1)
        #expect(config.getKataRuleCommand() == "kata-set-rules \(Config.rules[Config.defaultRule])")
    }

    @Test func testInvalidStoneStyleIndex() async throws {
        let config = Config(stoneStyle: -1)
        // Depending on implementation, this might crash or handle gracefully
        // Here, assuming it sets to an invalid state
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == false)
    }

    @Test func testAllKataRuleCommands() async throws {
        for (index, rule) in Config.rules.enumerated() {
            let config = Config(rule: index)
            let command = config.getKataRuleCommand()
            #expect(command == "kata-set-rules \(rule)")
        }
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

    @Test func kataAnalyzeCommand() async throws {
        let config = Config()
        let defaultCommand = "kata-analyze interval \(Config.defaultAnalysisInterval) maxmoves \(Config.defaultMaxAnalysisMoves) ownership true ownershipStdev true"
        #expect(config.getKataAnalyzeCommand() == config.getKataAnalyzeCommand(analysisInterval: Config.defaultAnalysisInterval))
        #expect(config.getKataAnalyzeCommand() == defaultCommand)
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
        #expect(config.isFastStoneStyle == true)
        #expect(config.isClassicStoneStyle == false)
        config.stoneStyle = 1
        #expect(config.isFastStoneStyle == false)
        #expect(config.isClassicStoneStyle == true)
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
