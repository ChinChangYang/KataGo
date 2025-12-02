//
//  GameRecord.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/7.
//

import SwiftUI
import SwiftData
import KataGoInterface

@Model
final class GameRecord {
    static let defaultSgf = "(;FF[4]GM[1]SZ[19]PB[]PW[]HA[0]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN])"
    static let defaultName = "New Game"
    var sgf: String = defaultSgf
    var currentIndex: Int = 0
    // The iCloud servers don’t guarantee atomic processing of relationship changes,
    // so CloudKit requires all relationships to be optional.
    @Relationship(deleteRule: .cascade) var config: Config?
    var name: String = defaultName
    var lastModificationDate: Date?
    var comments: [Int: String]?
    var uuid: UUID? = UUID()
    var thumbnail: Data?
    var scoreLeads: [Int: Float]?
    var bestMoves: [Int: String]?
    var winRates: [Int: Float]?

    // These variables are not used. Leave these here for compatibility.
    private var deadBlackStones: [Int: String]?
    private var deadWhiteStones: [Int: String]?
    private var blackSchrodingerStones: [Int: String]?
    private var whiteSchrodingerStones: [Int: String]?

    var moves: [Int: String]?
    var blackStones: [Int: String]?
    var whiteStones: [Int: String]?
    var ownershipWhiteness: [Int: [Float]]?
    var ownershipScales: [Int: [Float]]?
    var width: Int?
    var height: Int?

    func getDeadBlackStones(_ index: Int) -> String? {
        getStones(
            from: blackStones,
            index: index
        ) { $0 > 0.9 }
    }

    func getDeadWhiteStones(_ index: Int) -> String? {
        getStones(
            from: whiteStones,
            index: index
        ) { $0 < 0.1 }
    }

    private func getStones(
        from stones: [Int: String]?,
        index: Int,
        condition: (Float) -> Bool
    ) -> String? {
        guard let stones = stones?[index],
              let whiteness = ownershipWhiteness?[index],
              let width, let height else {
            return nil
        }

        let stoneSet = Set(stones.split(separator: " ").map(String.init))

        let deadStoneSet = stoneSet.filter { stone in
            guard let coordinate = Coordinate(
                move: stone,
                width: width,
                height: height
            ) else {
                return false
            }

            return condition(whiteness[coordinate.index])
        }

        if deadStoneSet.isEmpty {
            return "None"
        } else {
            return deadStoneSet.joined(separator: " ")
        }
    }

    func getBlackSchrodingerStones(_ index: Int) -> String? {
        return getSchrodingerStones(from: blackStones, index: index)
    }

    func getWhiteSchrodingerStones(_ index: Int) -> String? {
        return getSchrodingerStones(from: whiteStones, index: index)
    }

    private func getSchrodingerStones(
        from stones: [Int: String]?,
        index: Int
    ) -> String? {
        guard let stones = stones?[index],
              let whitenesses = ownershipWhiteness?[index],
              let scales = ownershipScales?[index],
              let width, let height else {
            return nil
        }

        let stoneSet = Set(stones.split(separator: " ").map(String.init))

        let deadStoneSet = stoneSet.filter { stone in
            guard let coordinate = Coordinate(
                move: stone, width: width, height: height
            ) else {
                return false
            }

            let whiteness = whitenesses[coordinate.index]
            let scale = scales[coordinate.index]

            return (abs(whiteness - 0.5) < 0.2) && scale > 0.4
        }

        if deadStoneSet.isEmpty {
            return "None"
        } else {
            return deadStoneSet.joined(separator: " ")
        }
    }

    func getBlackSacrificeableStones(_ index: Int) -> String? {
        return getStones(
            from: blackStones,
            index: index
        ) { ($0 <= 0.9) && ($0 > 0.7) }
    }

    func getWhiteSacrificeableStones(_ index: Int) -> String? {
        return getStones(
            from: whiteStones,
            index: index
        ) { ($0 >= 0.1) && ($0 < 0.3) }
    }

    var concreteConfig: Config {
        // A config must not be nil in any case.
        // If it is not the case, there is a bug in the GameRecord initialization function.
        // Anyway, it will create a default config for this case, but the config is probably wrong.
        assert(self.config != nil)
        if let config {
            return config
        } else {
            let newConfig = Config(gameRecord: self)
            self.config = newConfig
            return newConfig
        }
    }

    init(sgf: String = defaultSgf,
         currentIndex: Int = 0,
         config: Config,
         name: String = defaultName,
         lastModificationDate: Date? = Date.now,
         comments: [Int: String]? = [:],
         thumbnail: Data? = nil,
         scoreLeads: [Int: Float]? = [:],
         bestMoves: [Int: String]? = [:],
         winRates: [Int: Float]? = [:],
         deadBlackStones: [Int: String]? = [:],
         deadWhiteStones: [Int: String]? = [:],
         blackSchrodingerStones: [Int: String]? = [:],
         whiteSchrodingerStones: [Int: String]? = [:],
         moves: [Int: String]? = [:],
         endangeredBlackStones: [Int: String]? = [:],
         endangeredWhiteStones: [Int: String]? = [:],
         blackStones: [Int: String]? = [:],
         whiteStones: [Int: String]? = [:],
         ownershipWhiteness: [Int: [Float]]? = [:],
         ownershipScales: [Int: [Float]]? = [:],
         width: Int? = nil,
         height: Int? = nil
    ) {
        self.sgf = sgf
        self.currentIndex = currentIndex
        self.config = config
        self.name = name
        self.lastModificationDate = lastModificationDate
        self.comments = comments
        self.thumbnail = thumbnail
        self.scoreLeads = scoreLeads
        self.bestMoves = bestMoves
        self.winRates = winRates
        self.deadBlackStones = deadBlackStones
        self.deadWhiteStones = deadWhiteStones
        self.blackSchrodingerStones = blackSchrodingerStones
        self.whiteSchrodingerStones = whiteSchrodingerStones
        self.moves = moves
        self.blackStones = blackStones
        self.whiteStones = whiteStones
        self.ownershipWhiteness = ownershipWhiteness
        self.ownershipScales = ownershipScales
        self.width = width
        self.height = height
    }

    func clone() -> GameRecord {
        let newConfig = Config(config: self.config)

        let newGameRecord = GameRecord(
            sgf: self.sgf,
            currentIndex: self.currentIndex,
            config: newConfig,
            name: self.name + " (copy)",
            lastModificationDate: Date.now,
            comments: self.comments,
            thumbnail: self.thumbnail,
            scoreLeads: self.scoreLeads,
            bestMoves: self.bestMoves,
            winRates: self.winRates,
            deadBlackStones: self.deadBlackStones,
            deadWhiteStones: self.deadWhiteStones,
            blackSchrodingerStones: self.blackSchrodingerStones,
            whiteSchrodingerStones: self.whiteSchrodingerStones,
            moves: self.moves,
            blackStones: self.blackStones,
            whiteStones: self.whiteStones,
            ownershipWhiteness: self.ownershipWhiteness,
            ownershipScales: self.ownershipScales,
            width: self.width,
            height: self.height
        )

        newConfig.gameRecord = newGameRecord
        return newGameRecord
    }

    func undo() {
        if (currentIndex > 0) {
            currentIndex = currentIndex - 1
        }
    }

    func clearData(after index: Int) {
        comments = comments?.filter { $0.key <= index }
        scoreLeads = scoreLeads?.filter { $0.key <= index }
        bestMoves = bestMoves?.filter { $0.key <= index }
        winRates = winRates?.filter { $0.key <= index }
        deadBlackStones = deadBlackStones?.filter { $0.key <= index }
        deadWhiteStones = deadWhiteStones?.filter { $0.key <= index }
        blackSchrodingerStones = blackSchrodingerStones?.filter { $0.key <= index }
        whiteSchrodingerStones = whiteSchrodingerStones?.filter { $0.key <= index }
        moves = moves?.filter { $0.key <= index }
        blackStones = blackStones?.filter { $0.key <= index }
        whiteStones = whiteStones?.filter { $0.key <= index }
        ownershipWhiteness = ownershipWhiteness?.filter { $0.key <= index }
        ownershipScales = ownershipScales?.filter { $0.key <= index }
    }

    class func createFetchDescriptor(fetchLimit: Int? = nil) -> FetchDescriptor<GameRecord> {
        var descriptor = FetchDescriptor<GameRecord>(
            sortBy: [.init(\.lastModificationDate, order: .reverse)]
        )
        descriptor.fetchLimit = fetchLimit
        return descriptor
    }

    @MainActor
    class func fetchGameRecords(container: ModelContainer, fetchLimit: Int? = nil) throws -> [GameRecord] {
        let context = container.mainContext
        let descriptor = createFetchDescriptor(fetchLimit: fetchLimit)
        return try context.fetch(descriptor)
    }

    class func createGameRecord(
        sgf: String = defaultSgf,
        currentIndex: Int = 0,
        name: String = defaultName,
        comments: [Int: String]? = [:],
        thumbnail: Data? = nil,
        scoreLeads: [Int: Float]? = [:],
        bestMoves: [Int: String]? = [:],
        winRates: [Int: Float]? = [:],
        deadBlackStones: [Int: String]? = [:],
        deadWhiteStones: [Int: String]? = [:],
        blackSchrodingerStones: [Int: String]? = [:],
        whiteSchrodingerStones: [Int: String]? = [:],
        moves: [Int: String]? = [:],
        endangeredBlackStones: [Int: String]? = [:],
        endangeredWhiteStones: [Int: String]? = [:],
        blackStones: [Int: String]? = [:],
        whiteStones: [Int: String]? = [:],
        ownershipWhiteness: [Int: [Float]]? = [:],
        ownershipScales: [Int: [Float]]? = [:],
        width: Int? = nil,
        height: Int? = nil
    ) -> GameRecord {

        let config = Config()
        let sgfHelper = SgfHelper(sgf: sgf)
        config.boardWidth = sgfHelper.xSize
        config.boardHeight = sgfHelper.ySize
        config.komi = sgfHelper.rules.komi

        let gameRecord = GameRecord(
            sgf: sgf,
            currentIndex: currentIndex,
            config: config,
            name: name,
            comments: comments,
            thumbnail: thumbnail,
            scoreLeads: scoreLeads,
            bestMoves: bestMoves,
            winRates: winRates,
            deadBlackStones: deadBlackStones,
            deadWhiteStones: deadWhiteStones,
            blackSchrodingerStones: blackSchrodingerStones,
            whiteSchrodingerStones: whiteSchrodingerStones,
            moves: moves,
            endangeredBlackStones: endangeredBlackStones,
            endangeredWhiteStones: endangeredWhiteStones,
            blackStones: blackStones,
            whiteStones: whiteStones,
            ownershipWhiteness: ownershipWhiteness,
            ownershipScales: ownershipScales,
            width: sgfHelper.xSize,
            height: sgfHelper.ySize
        )

        config.gameRecord = gameRecord

        return gameRecord
    }

    class func createGameRecord(from file: URL) -> GameRecord? {
        guard file.startAccessingSecurityScopedResource() else { return nil }

        // Get the name
        let name = file.deletingPathExtension().lastPathComponent

        // Attempt to read the contents of the file into a string; exit if reading fails
        guard let fileContents = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        // Release access
        file.stopAccessingSecurityScopedResource()

        // Initialize the SGF helper with the file contents
        let sgfHelper = SgfHelper(sgf: fileContents)

        // Get the index of the last move in the SGF file; exit if the SGF is invalid
        guard let moveSize = sgfHelper.moveSize else { return nil }

        // Create a dictionary of comments for each move by filtering and mapping non-empty comments
        let comments = (0...moveSize)
            .compactMap { index in sgfHelper.getComment(at: index).flatMap { !$0.isEmpty ? (index, $0) : nil } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }

        // Create a new game record with the SGF content, the current move index, the name, and the comments
        return GameRecord.createGameRecord(sgf: fileContents,
                                           currentIndex: moveSize,
                                           name: name,
                                           comments: comments)
    }

    var image: Image? {
#if os(macOS)
        if let thumbnail,
           let uiImage = NSImage(data: thumbnail) {
            return Image(nsImage: uiImage)
        } else {
            return nil
        }
#else
        if let thumbnail,
           let uiImage = UIImage(data: thumbnail) {
            return Image(uiImage: uiImage)
        } else {
            return nil
        }
#endif
    }

    func updateToLatestVersion() {
        if lastModificationDate == nil {
            lastModificationDate = Date.now
        }

        if comments == nil {
            comments = [:]
        }

        if scoreLeads == nil {
            scoreLeads = [:]
        }

        if bestMoves == nil {
            bestMoves = [:]
        }

        if winRates == nil {
            winRates = [:]
        }

        if deadBlackStones == nil {
            deadBlackStones = [:]
        }

        if deadWhiteStones == nil {
            deadWhiteStones = [:]
        }

        if blackSchrodingerStones == nil {
            blackSchrodingerStones = [:]
        }

        if whiteSchrodingerStones == nil {
            whiteSchrodingerStones = [:]
        }

        if moves == nil {
            moves = [:]
        }

        if blackStones == nil {
            blackStones = [:]
        }

        if whiteStones == nil {
            whiteStones = [:]
        }

        if ownershipWhiteness == nil {
            ownershipWhiteness = [:]
        }

        if ownershipScales == nil {
            ownershipScales = [:]
        }

        let sgfHelper = SgfHelper(sgf: sgf)

        width = sgfHelper.xSize
        height = sgfHelper.ySize
    }
}

