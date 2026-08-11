import Testing
@testable import KataGoUICore
import KataGoGameStore

struct TVNewGameFormTests {
    @Test("init clamps the starting size to the launched buffer")
    func initClampsToBuffer() {
        #expect(TVNewGameForm(maxBoardLength: 37).boardWidth == 19)
        #expect(TVNewGameForm(maxBoardLength: 9).boardWidth == 9)
        #expect(TVNewGameForm(maxBoardLength: 9).boardHeight == 9)
    }

    @Test("quick sizes disable above the cap")
    func quickSizesRespectCap() {
        let form = TVNewGameForm(maxBoardLength: 13)
        #expect(form.quickSizeEnabled(9))
        #expect(form.quickSizeEnabled(13))
        #expect(!form.quickSizeEnabled(19))
    }

    @Test("setSize clamps to 2...cap")
    func setSizeClamps() {
        var form = TVNewGameForm(maxBoardLength: 19)
        form.setSize(width: 1, height: 40)
        #expect(form.boardWidth == 2)
        #expect(form.boardHeight == 19)
    }

    @Test("handicap availability follows the placement domain")
    func handicapAvailability() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setSize(width: 19, height: 19)
        #expect(form.availableHandicaps == [0, 2, 3, 4, 5, 6, 7, 8, 9])
        form.setSize(width: 13, height: 13)
        #expect(form.availableHandicaps == [0, 2, 3, 4, 5])
        form.setSize(width: 8, height: 8)
        #expect(form.availableHandicaps == [0])
        #expect(!form.handicapPickerEnabled)
    }

    @Test("shrinking the board clears a now-impossible handicap, keeps a valid one")
    func handicapClearsWhenSizeLosesLayout() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setSize(width: 19, height: 19)
        form.setHandicap(9)
        form.setSize(width: 9, height: 9)
        #expect(form.handicap == 0)
        form.setHandicap(5)
        form.setSize(width: 13, height: 13)
        #expect(form.handicap == 5)
    }

    @Test("komi follows the preset until handicap forces 0.5")
    func komiFollowsPresetAndHandicap() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.ruleset = .japanese
        #expect(form.komi == 6.5)
        form.ruleset = .chinese
        #expect(form.komi == 7.5)
        form.ruleset = .agaButton
        #expect(form.komi == 7.0)
        form.setHandicap(2)
        #expect(form.komi == 0.5)
    }

    @Test("the SGF carries size, handicap, PL, komi, and the preset token")
    func sgfCarriesEverything() throws {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.ruleset = .japanese
        form.setHandicap(3)
        let sgf = try #require(form.sgf)
        #expect(sgf.contains("HA[3]"))
        #expect(sgf.contains("PL[W]"))
        #expect(sgf.contains("KM[0.5]"))
        #expect(sgf.contains("RU[japanese]"))
    }

    @Test("ruleset choices are the 11 named presets")
    func rulesetChoices() {
        #expect(TVNewGameForm.rulesetChoices.count == 11)
        #expect(!TVNewGameForm.rulesetChoices.contains(.custom))
    }

    @MainActor
    @Test("apply assigns the engine side, both directions")
    func applySetsTheEngineSide() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.rankProfile = "3k"
        form.ruleset = .japanese
        let config = Config()
        form.apply(to: config)
        #expect(config.blackMaxTime == 0)
        #expect(config.whiteMaxTime == Config.toggleAIThinkingTime)
        #expect(config.humanProfileForWhite == "3k")
        #expect(config.rule == NewGameRuleset.japanese.configRuleIndex)

        form.humanPlaysBlack = false
        let flipped = Config()
        form.apply(to: flipped)
        #expect(flipped.whiteMaxTime == 0)
        #expect(flipped.blackMaxTime == Config.toggleAIThinkingTime)
        #expect(flipped.humanProfileForBlack == "3k")
    }

    @Test("suggested name carries the rank")
    func suggestedName() {
        var form = TVNewGameForm(maxBoardLength: 37)
        #expect(form.suggestedName == "vs KataGo")
        form.rankProfile = "3k"
        #expect(form.suggestedName == "vs KataGo 3k")
    }
}
