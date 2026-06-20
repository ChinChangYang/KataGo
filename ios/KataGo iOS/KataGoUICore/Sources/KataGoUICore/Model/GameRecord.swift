//
//  GameRecord.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/7.
//

import SwiftUI
import SwiftData

@Model
public final class GameRecord {
    public static let defaultSgf = "(;FF[4]GM[1]SZ[19]PB[]PW[]HA[0]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN])"
    public static let defaultName = "New Game"

    public static func makeDefaultSgf(boardSize: Int) -> String {
        "(;FF[4]GM[1]SZ[\(boardSize)]PB[]PW[]HA[0]KM[7]RU[koSIMPLEscoreAREAtaxNONEsui0whbN])"
    }

    public var sgf: String = defaultSgf
    public var currentIndex: Int = 0
    // The iCloud servers don’t guarantee atomic processing of relationship changes,
    // so CloudKit requires all relationships to be optional.
    @Relationship(deleteRule: .cascade) public var config: Config?
    public var name: String = defaultName
    public var lastModificationDate: Date?
    public var comments: [Int: String]?
    public var uuid: UUID? = UUID()
    public var thumbnail: Data?
    public var scoreLeads: [Int: Float]?
    public var bestMoves: [Int: String]?
    public var winRates: [Int: Float]?

    // These variables are not used. Leave these here for compatibility.
    private var deadBlackStones: [Int: String]?
    private var deadWhiteStones: [Int: String]?
    private var blackSchrodingerStones: [Int: String]?
    private var whiteSchrodingerStones: [Int: String]?

    public var moves: [Int: String]?
    public var blackStones: [Int: String]?
    public var whiteStones: [Int: String]?
    public var ownershipWhiteness: [Int: [Float]]?
    public var ownershipScales: [Int: [Float]]?
    public var width: Int?
    public var height: Int?

    public func getCapturedBlackStones(_ index: Int) -> String? {
        getCapturedStones(from: blackStones, index: index)
    }

    public func getCapturedWhiteStones(_ index: Int) -> String? {
        getCapturedStones(from: whiteStones, index: index)
    }

    private func getCapturedStones(
        from stones: [Int: String]?,
        index: Int
    ) -> String? {
        guard index >= 1,
              let previousStones = stones?[index - 1],
              let currentStones = stones?[index]
        else {
            return nil
        }

        let previousSet = Set(
            previousStones.split(separator: " ").map(String.init)
        )

        let currentSet = Set(
            currentStones.split(separator: " ").map(String.init)
        )

        let capturedSet = previousSet.subtracting(currentSet).sorted()

        let capturedStones = (
            capturedSet.isEmpty ? "None" :
                capturedSet.joined(separator: " ")
        )

        return capturedStones
    }

    public func getDeadBlackStones(_ index: Int) -> String? {
        getStones(
            from: blackStones,
            index: index
        ) { $0 > 0.9 }
    }

    public func getDeadWhiteStones(_ index: Int) -> String? {
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
              let width, let height
        else {
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
            return deadStoneSet.sorted().joined(separator: " ")
        }
    }

    public func getBlackSchrodingerStones(_ index: Int) -> String? {
        return getSchrodingerStones(from: blackStones, index: index)
    }

    public func getWhiteSchrodingerStones(_ index: Int) -> String? {
        return getSchrodingerStones(from: whiteStones, index: index)
    }

    private func getSchrodingerStones(
        from stones: [Int: String]?,
        index: Int
    ) -> String? {
        guard let stones = stones?[index],
              let whitenesses = ownershipWhiteness?[index],
              let scales = ownershipScales?[index],
              let width, let height
        else {
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
            return deadStoneSet.sorted().joined(separator: " ")
        }
    }

    public func getBlackSacrificeableStones(_ index: Int) -> String? {
        return getStones(
            from: blackStones,
            index: index
        ) { ($0 <= 0.9) && ($0 > 0.7) }
    }

    public func getWhiteSacrificeableStones(_ index: Int) -> String? {
        return getStones(
            from: whiteStones,
            index: index
        ) { ($0 >= 0.1) && ($0 < 0.3) }
    }

    public var concreteConfig: Config {
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

    public init(sgf: String = defaultSgf,
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

    public func clone() -> GameRecord {
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

    /// Like `clone()`, but the copy contains only the moves up to `index`:
    /// the SGF is truncated to `index` move nodes, `currentIndex` is set to
    /// `index`, and per-index data after `index` is dropped.
    ///
    /// Built on top of `clone()` so the full stored-field list is materialized
    /// in exactly one place: this method only overrides the sgf/currentIndex
    /// and trims the per-index data on the (not-yet-inserted) copy.
    public func clone(upToMove index: Int) -> GameRecord {
        clone(upToMove: index, fromSgf: self.sgf, dataValidUpTo: index)
    }

    /// Branch-aware variant of `clone(upToMove:)`. Truncates `sourceSgf`
    /// (which may be a live branch line, not `self.sgf`) to `index` move nodes
    /// and sets `currentIndex = index`. Per-index data is trimmed to keys
    /// `<= dataValidUpTo`: while a branch is active the stored dictionaries
    /// still describe the old mainline and are only valid up to the branch's
    /// divergence point, so callers pass the smaller of the divergence index
    /// and `index` there (mirroring `GobanState.commitBranch`).
    public func clone(upToMove index: Int, fromSgf sourceSgf: String, dataValidUpTo dataIndex: Int) -> GameRecord {
        let newGameRecord = clone()
        newGameRecord.sgf = SgfTruncation.truncate(sourceSgf, toMoveCount: index)
        newGameRecord.currentIndex = index
        newGameRecord.clearData(after: dataIndex)
        return newGameRecord
    }

    public func undo() {
        if (currentIndex > 0) {
            currentIndex = currentIndex - 1
        }
    }

    public func clearData(after index: Int) {
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

    public class func createFetchDescriptor(fetchLimit: Int? = nil) -> FetchDescriptor<GameRecord> {
        var descriptor = FetchDescriptor<GameRecord>(
            sortBy: [.init(\.lastModificationDate, order: .reverse)]
        )
        descriptor.fetchLimit = fetchLimit
        return descriptor
    }

    @MainActor
    public class func fetchGameRecords(container: ModelContainer, fetchLimit: Int? = nil) throws -> [GameRecord] {
        let context = container.mainContext
        let descriptor = createFetchDescriptor(fetchLimit: fetchLimit)
        return try context.fetch(descriptor)
    }

    public class func createGameRecord(
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
        blackStones: [Int: String]? = [:],
        whiteStones: [Int: String]? = [:],
        ownershipWhiteness: [Int: [Float]]? = [:],
        ownershipScales: [Int: [Float]]? = [:],
        width: Int? = nil,
        height: Int? = nil,
        maxBoardLength: Int? = nil
    ) -> GameRecord {

        let resolvedSgf: String = {
            if sgf == Self.defaultSgf, let cap = maxBoardLength, cap < 19 {
                return Self.makeDefaultSgf(boardSize: max(2, cap))
            }
            return sgf
        }()

        let config = Config()
        let sgfHelper = SgfOperations(sgf: resolvedSgf)
        config.boardWidth = sgfHelper.xSize
        config.boardHeight = sgfHelper.ySize
        config.komi = sgfHelper.rules.komi

        let gameRecord = GameRecord(
            sgf: resolvedSgf,
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

    /// Reads SGF string content and filename from a URL without creating a GameRecord.
    public class func readSgfContent(from file: URL) -> (sgf: String, name: String)? {
        let hasSecurityAccess = file.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                file.stopAccessingSecurityScopedResource()
            }
        }
        let name = file.deletingPathExtension().lastPathComponent
        guard let fileContents = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        return (sgf: fileContents, name: name)
    }

    /// Queries SwiftData for an existing GameRecord whose SGF matches exactly.
    public class func findExistingGameRecord(withSgf sgf: String, in modelContext: ModelContext) -> GameRecord? {
        let descriptor = FetchDescriptor<GameRecord>(predicate: #Predicate<GameRecord> { $0.sgf == sgf })
        return try? modelContext.fetch(descriptor).first
    }

    /// Reads an SGF file, checks for duplicates, and returns an existing or new GameRecord.
    /// The caller must insert the record into the model context when `isNew` is true.
    public class func importGameRecord(from file: URL, in modelContext: ModelContext) -> (gameRecord: GameRecord, isNew: Bool)? {
        guard let content = readSgfContent(from: file) else { return nil }
        return importGameRecord(sgf: content.sgf, name: content.name, in: modelContext)
    }

    /// Imports a game from pre-read SGF content, checking for duplicates.
    /// The caller must insert the record into the model context when `isNew` is true.
    public class func importGameRecord(sgf: String, name: String, in modelContext: ModelContext) -> (gameRecord: GameRecord, isNew: Bool)? {
        if let existing = findExistingGameRecord(withSgf: sgf, in: modelContext) {
            return (gameRecord: existing, isNew: false)
        }

        let sgfHelper = SgfOperations(sgf: sgf)
        guard let moveSize = sgfHelper.moveSize else { return nil }

        let comments = (0...moveSize)
            .compactMap { index in sgfHelper.getComment(at: index).flatMap { !$0.isEmpty ? (index, $0) : nil } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }

        let newRecord = GameRecord.createGameRecord(sgf: sgf,
                                                    currentIndex: moveSize,
                                                    name: name,
                                                    comments: comments)
        return (gameRecord: newRecord, isNew: true)
    }

    public var image: Image? {
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

    public func updateToLatestVersion() {
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

        let sgfHelper = SgfOperations(sgf: sgf)

        width = sgfHelper.xSize
        height = sgfHelper.ySize
    }
}

