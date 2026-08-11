import Foundation
import KataGoGameStore

/// Pure state + validation for the tvOS "Play KataGo" New Game form. Lives
/// in the shared package so the iOS-simulator unit target covers it; the
/// tvOS screen is a thin SwiftUI shell over this.
public struct TVNewGameForm: Equatable {
    public static let quickSizes = [9, 13, 19]
    /// The 11 named presets; the granular Custom editor stays iOS/macOS.
    public static let rulesetChoices: [NewGameRuleset] =
        NewGameRuleset.pickerCases.filter { $0 != .custom }
    public static let rankChoices = HumanSLModel.allProfiles
    /// Classic handicap compensation: stones instead of points.
    public static let handicapKomi: Float = 0.5

    public private(set) var boardWidth: Int
    public private(set) var boardHeight: Int
    public var ruleset: NewGameRuleset = .trompTaylor
    public var rankProfile: String = "AI"
    public private(set) var handicap: Int = 0
    public var humanPlaysBlack: Bool = true
    /// The LAUNCHED NN buffer (engine.maxBoardLength) — never live settings.
    public let maxBoardLength: Int

    public init(maxBoardLength: Int) {
        self.maxBoardLength = maxBoardLength
        let initial = max(2, min(19, maxBoardLength))
        boardWidth = initial
        boardHeight = initial
    }

    public var sizeCap: Int { max(2, min(37, maxBoardLength)) }
    public func quickSizeEnabled(_ size: Int) -> Bool { size <= sizeCap }

    public mutating func setSize(width: Int, height: Int) {
        boardWidth = min(max(2, width), sizeCap)
        boardHeight = min(max(2, height), sizeCap)
        if handicap != 0, !availableHandicaps.contains(handicap) { handicap = 0 }
    }

    public mutating func setHandicap(_ n: Int) {
        handicap = availableHandicaps.contains(n) ? n : 0
    }

    /// 0 plus every n in 2...9 the board has a conventional layout for.
    public var availableHandicaps: [Int] {
        [0] + (2...9).filter {
            BoardHandicapPoints.points(width: boardWidth, height: boardHeight, count: $0).count == $0
        }
    }

    public var handicapPickerEnabled: Bool { availableHandicaps.count > 1 }

    /// Handicap forces komi 0.5; otherwise KataGo's own default for the preset.
    public var komi: Float {
        if handicap > 0 { return Self.handicapKomi }
        guard let components = NewGameRules.expand(ruleset) else { return Config.defaultKomi }
        return NewGameRules.suggestedKomi(components)
    }

    public var ruleString: String { ruleset.sgfToken ?? GameRecord.defaultRuleString }

    public var sgf: String? {
        GameRecord.makeSgf(width: boardWidth, height: boardHeight, komi: komi,
                           ruleString: ruleString, handicap: handicap)
    }

    public var suggestedName: String {
        rankProfile == "AI" ? "vs KataGo" : "vs KataGo \(rankProfile)"
    }

    /// KataGo's side gets the chosen rank + the standard 0.5 s thinking
    /// time; the human side gets maxTime 0 (the maxTime == 0 marker is what
    /// TVPlayability and the shared gen-move loop key off). Handicap stones
    /// are always Black's, so White + handicap is give-handicap play. The
    /// rule index must be set here: createGameRecord does not derive
    /// `Config.rule` from the SGF (the SelfPlaySeed factory documents that).
    @MainActor
    public func apply(to config: Config) {
        config.rule = ruleset.configRuleIndex
        if humanPlaysBlack {
            config.blackMaxTime = 0
            config.whiteMaxTime = Config.toggleAIThinkingTime
            config.humanProfileForWhite = rankProfile
        } else {
            config.whiteMaxTime = 0
            config.blackMaxTime = Config.toggleAIThinkingTime
            config.humanProfileForBlack = rankProfile
        }
    }
}
