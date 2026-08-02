//
//  DraftSnapshot.swift
//  KataGo Anytime Mac
//

import Foundation
import KataGoGameStore

/// A versioned, `Codable` capture of every field a draft owns.
///
/// This is the SINGLE place the drafted field list is written down. It serves
/// three jobs, and a field missing here is silently lost by all three:
///   * the baseline a draft is compared against (dirty / conflict),
///   * the field copy applied to the origin at Save,
///   * the crash-mirror payload on disk.
///
/// It deliberately does NOT carry `uuid`: applying a snapshot must never
/// change the identity of the record it is applied to. The origin's UUID
/// travels separately in `originUUID`, purely so a restored mirror can find
/// its origin again.
struct DraftSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    /// The saved record this draft came from, or nil while untitled.
    var originUUID: UUID?
    var game: GameFields
    var config: ConfigFields

    struct GameFields: Codable, Equatable {
        var sgf: String
        var currentIndex: Int
        var name: String
        var lastModificationDate: Date?
        var comments: [Int: String]?
        var thumbnail: Data?
        var scoreLeads: [Int: Float]?
        var bestMoves: [Int: String]?
        var winRates: [Int: Float]?
        var deadBlackStones: [Int: String]?
        var deadWhiteStones: [Int: String]?
        var blackSchrodingerStones: [Int: String]?
        var whiteSchrodingerStones: [Int: String]?
        var moves: [Int: String]?
        var blackStones: [Int: String]?
        var whiteStones: [Int: String]?
        var ownershipWhiteness: [Int: [Float]]?
        var ownershipScales: [Int: [Float]]?
        var width: Int?
        var height: Int?
    }

    struct ConfigFields: Codable, Equatable {
        var boardWidth: Int
        var boardHeight: Int
        var rule: Int
        var komi: Float
        var playoutDoublingAdvantage: Float
        var analysisWideRootNoise: Float
        var maxAnalysisMoves: Int
        var analysisInterval: Int
        var analysisInformation: Int
        var hiddenAnalysisVisitRatio: Float
        var stoneStyle: Int
        var showCoordinate: Bool
        var humanSLRootExploreProbWeightful: Float
        var humanSLProfile: String
        var optionalAnalysisForWhom: Int?
        var optionalShowOwnership: Bool?
        var optionalHumanRatioForWhite: Float?
        var optionalHumanProfileForWhite: String?
        var optionalSoundEffect: Bool?
        var optionalShowComments: Bool?
        var optionalShowPass: Bool?
        var optionalVerticalFlip: Bool?
        var optionalBlackMaxTime: Float?
        var optionalWhiteMaxTime: Float?
        var optionalKoRule: Int?
        var optionalScoringRule: Int?
        var optionalTaxRule: Int?
        var optionalMultiStoneSuicideLegal: Bool?
        var optionalHasButton: Bool?
        var optionalWhiteHandicapBonusRule: Int?
        var optionalShowWinrateBar: Bool?
        var optionalAnalysisStyle: Int?
        var optionalShowCharts: Bool?
        var optionalUseLLM: Bool?
        var optionalTemperature: Float?
        var optionalTone: Int?

        /// Reads the whole config in one place, so anything that has to know
        /// which config fields are drafted — the snapshot below, and the
        /// observation tracking in `DraftComparator` — reaches them through
        /// this and cannot drift from the list above.
        @MainActor
        init(config c: Config) {
            self.boardWidth = c.boardWidth
            self.boardHeight = c.boardHeight
            self.rule = c.rule
            self.komi = c.komi
            self.playoutDoublingAdvantage = c.playoutDoublingAdvantage
            self.analysisWideRootNoise = c.analysisWideRootNoise
            self.maxAnalysisMoves = c.maxAnalysisMoves
            self.analysisInterval = c.analysisInterval
            self.analysisInformation = c.analysisInformation
            self.hiddenAnalysisVisitRatio = c.hiddenAnalysisVisitRatio
            self.stoneStyle = c.stoneStyle
            self.showCoordinate = c.showCoordinate
            self.humanSLRootExploreProbWeightful = c.humanSLRootExploreProbWeightful
            self.humanSLProfile = c.humanSLProfile
            self.optionalAnalysisForWhom = c.optionalAnalysisForWhom
            self.optionalShowOwnership = c.optionalShowOwnership
            self.optionalHumanRatioForWhite = c.optionalHumanRatioForWhite
            self.optionalHumanProfileForWhite = c.optionalHumanProfileForWhite
            self.optionalSoundEffect = c.optionalSoundEffect
            self.optionalShowComments = c.optionalShowComments
            self.optionalShowPass = c.optionalShowPass
            self.optionalVerticalFlip = c.optionalVerticalFlip
            self.optionalBlackMaxTime = c.optionalBlackMaxTime
            self.optionalWhiteMaxTime = c.optionalWhiteMaxTime
            self.optionalKoRule = c.optionalKoRule
            self.optionalScoringRule = c.optionalScoringRule
            self.optionalTaxRule = c.optionalTaxRule
            self.optionalMultiStoneSuicideLegal = c.optionalMultiStoneSuicideLegal
            self.optionalHasButton = c.optionalHasButton
            self.optionalWhiteHandicapBonusRule = c.optionalWhiteHandicapBonusRule
            self.optionalShowWinrateBar = c.optionalShowWinrateBar
            self.optionalAnalysisStyle = c.optionalAnalysisStyle
            self.optionalShowCharts = c.optionalShowCharts
            self.optionalUseLLM = c.optionalUseLLM
            self.optionalTemperature = c.optionalTemperature
            self.optionalTone = c.optionalTone
        }
    }

    @MainActor
    init(record: GameRecord, originUUID: UUID?) {
        self.version = Self.currentVersion
        self.originUUID = originUUID

        self.game = GameFields(
            sgf: record.sgf,
            currentIndex: record.currentIndex,
            name: record.name,
            lastModificationDate: record.lastModificationDate,
            comments: record.comments,
            thumbnail: record.thumbnail,
            scoreLeads: record.scoreLeads,
            bestMoves: record.bestMoves,
            winRates: record.winRates,
            deadBlackStones: record.deadBlackStones,
            deadWhiteStones: record.deadWhiteStones,
            blackSchrodingerStones: record.blackSchrodingerStones,
            whiteSchrodingerStones: record.whiteSchrodingerStones,
            moves: record.moves,
            blackStones: record.blackStones,
            whiteStones: record.whiteStones,
            ownershipWhiteness: record.ownershipWhiteness,
            ownershipScales: record.ownershipScales,
            width: record.width,
            height: record.height
        )

        self.config = ConfigFields(config: record.concreteConfig)
    }

    /// Copies every drafted field onto `record`. Never touches `uuid` or the
    /// record's `config` relationship — only the config's field values.
    @MainActor
    func apply(to record: GameRecord) {
        record.sgf = game.sgf
        record.currentIndex = game.currentIndex
        record.name = game.name
        record.lastModificationDate = game.lastModificationDate
        record.comments = game.comments
        record.thumbnail = game.thumbnail
        record.scoreLeads = game.scoreLeads
        record.bestMoves = game.bestMoves
        record.winRates = game.winRates
        record.deadBlackStones = game.deadBlackStones
        record.deadWhiteStones = game.deadWhiteStones
        record.blackSchrodingerStones = game.blackSchrodingerStones
        record.whiteSchrodingerStones = game.whiteSchrodingerStones
        record.moves = game.moves
        record.blackStones = game.blackStones
        record.whiteStones = game.whiteStones
        record.ownershipWhiteness = game.ownershipWhiteness
        record.ownershipScales = game.ownershipScales
        record.width = game.width
        record.height = game.height

        let c = record.concreteConfig
        c.boardWidth = config.boardWidth
        c.boardHeight = config.boardHeight
        c.rule = config.rule
        c.komi = config.komi
        c.playoutDoublingAdvantage = config.playoutDoublingAdvantage
        c.analysisWideRootNoise = config.analysisWideRootNoise
        c.maxAnalysisMoves = config.maxAnalysisMoves
        c.analysisInterval = config.analysisInterval
        c.analysisInformation = config.analysisInformation
        c.hiddenAnalysisVisitRatio = config.hiddenAnalysisVisitRatio
        c.stoneStyle = config.stoneStyle
        c.showCoordinate = config.showCoordinate
        c.humanSLRootExploreProbWeightful = config.humanSLRootExploreProbWeightful
        c.humanSLProfile = config.humanSLProfile
        c.optionalAnalysisForWhom = config.optionalAnalysisForWhom
        c.optionalShowOwnership = config.optionalShowOwnership
        c.optionalHumanRatioForWhite = config.optionalHumanRatioForWhite
        c.optionalHumanProfileForWhite = config.optionalHumanProfileForWhite
        c.optionalSoundEffect = config.optionalSoundEffect
        c.optionalShowComments = config.optionalShowComments
        c.optionalShowPass = config.optionalShowPass
        c.optionalVerticalFlip = config.optionalVerticalFlip
        c.optionalBlackMaxTime = config.optionalBlackMaxTime
        c.optionalWhiteMaxTime = config.optionalWhiteMaxTime
        c.optionalKoRule = config.optionalKoRule
        c.optionalScoringRule = config.optionalScoringRule
        c.optionalTaxRule = config.optionalTaxRule
        c.optionalMultiStoneSuicideLegal = config.optionalMultiStoneSuicideLegal
        c.optionalHasButton = config.optionalHasButton
        c.optionalWhiteHandicapBonusRule = config.optionalWhiteHandicapBonusRule
        c.optionalShowWinrateBar = config.optionalShowWinrateBar
        c.optionalAnalysisStyle = config.optionalAnalysisStyle
        c.optionalShowCharts = config.optionalShowCharts
        c.optionalUseLLM = config.optionalUseLLM
        c.optionalTemperature = config.optionalTemperature
        c.optionalTone = config.optionalTone
    }
}
