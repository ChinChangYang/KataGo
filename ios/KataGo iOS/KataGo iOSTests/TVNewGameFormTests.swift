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

    @Test("the form defaults to the app default ruleset (ADR 0001)")
    func defaultsToTrompTaylor() throws {
        let form = TVNewGameForm(maxBoardLength: 37)
        #expect(form.ruleset == .trompTaylor)
        #expect(form.komi == 7.5)
        let sgf = try #require(form.sgf)
        #expect(sgf.contains("RU[tromp-taylor]"))
        #expect(sgf.contains("KM[7.5]"))
    }

    @Test("komi follows the preset until handicap forces 0.5")
    func komiFollowsPresetAndHandicap() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setRuleset(.japanese)
        #expect(form.komi == 6.5)
        form.setRuleset(.chinese)
        #expect(form.komi == 7.5)
        form.setRuleset(.agaButton)
        #expect(form.komi == 7.0)
        form.setHandicap(2)
        #expect(form.komi == 0.5)
    }

    @Test("the SGF carries size, handicap, PL, komi, and the preset token")
    func sgfCarriesEverything() throws {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setRuleset(.japanese)
        form.setHandicap(3)
        let sgf = try #require(form.sgf)
        #expect(sgf.contains("HA[3]"))
        #expect(sgf.contains("PL[W]"))
        #expect(sgf.contains("KM[0.5]"))
        #expect(sgf.contains("RU[japanese]"))
    }

    @Test("handicap flips an untouched default to Chinese and back (ADR 0002)")
    func handicapDefaultsToChinese() throws {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setHandicap(2)
        #expect(form.ruleset == .chinese)
        #expect(form.komi == 0.5)
        let sgf = try #require(form.sgf)
        #expect(sgf.contains("RU[chinese]"))
        #expect(sgf.contains("HA[2]"))
        form.setHandicap(0)
        #expect(form.ruleset == .trompTaylor)
        #expect(form.komi == 7.5)
    }

    @Test("an explicit ruleset pick survives handicap changes")
    func explicitPickSurvivesHandicap() throws {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setRuleset(.trompTaylor)
        form.setHandicap(2)
        #expect(form.ruleset == .trompTaylor)
        let sgf = try #require(form.sgf)
        #expect(sgf.contains("RU[tromp-taylor]"))
        form.setHandicap(0)
        #expect(form.ruleset == .trompTaylor)
    }

    @Test("a pick made after the auto-flip also survives handicap changes")
    func pickAfterAutoFlipSurvivesHandicap() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setHandicap(2)
        #expect(form.ruleset == .chinese)
        form.setRuleset(.japanese)
        form.setHandicap(0)
        #expect(form.ruleset == .japanese)
        form.setHandicap(3)
        #expect(form.ruleset == .japanese)
    }

    @Test("a size change that clears the handicap also reverts the auto ruleset")
    func sizeClearingHandicapRevertsAutoRuleset() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setSize(width: 19, height: 19)
        form.setHandicap(9)
        #expect(form.ruleset == .chinese)
        form.setSize(width: 9, height: 9)
        #expect(form.handicap == 0)
        #expect(form.ruleset == .trompTaylor)
    }

    @MainActor
    @Test("apply carries the auto-Chinese label index for a handicap game")
    func applyCarriesAutoChineseRuleIndex() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setHandicap(2)
        let config = Config()
        form.apply(to: config)
        #expect(config.rule == NewGameRuleset.chinese.configRuleIndex)
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
        form.setRuleset(.japanese)
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

    /// Creating the record and opening its board is ENGINE-FREE: the form
    /// writes an SGF and inserts a `GameRecord`, and the board draws it from
    /// the record. The Start button therefore gates on the form alone —
    /// nothing about the engine — so a game can be started while the net is
    /// still loading, and while the engine is *Held* on a board too large for
    /// it (starting a smaller one is the way out of that hold).
    @Test("Start Game gates on the form alone, never on the engine")
    func startGameIsEngineFree() {
        // Every form the screen can produce — including the ones a small NN
        // buffer or an odd size yields — is startable, because nothing about
        // the engine takes part in the decision. The form's only input that
        // could ever refuse is its own SGF factory.
        for cap in [2, 9, 13, 19, 37] {
            var form = TVNewGameForm(maxBoardLength: cap)
            #expect(form.canStart, "a \(cap)-capped form must be startable")
            form.setSize(width: 2, height: 37)     // clamps to the cap
            #expect(form.canStart)
            form.setHandicap(9)                    // ignored where unavailable
            #expect(form.canStart)
        }
    }

    @Test("suggested name carries the rank")
    func suggestedName() {
        var form = TVNewGameForm(maxBoardLength: 37)
        #expect(form.suggestedName == "vs KataGo")
        form.rankProfile = "3k"
        #expect(form.suggestedName == "vs KataGo 3k")
    }
}
