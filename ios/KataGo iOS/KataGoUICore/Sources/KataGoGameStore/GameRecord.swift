//
//  GameRecord.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/7.
//
//  Bridge-free core: @Model class body + pure helpers.
//  Bridge-using methods (createGameRecord, importGameRecord, updateToLatestVersion,
//  clone(upToMove:), Coordinate-based dead-stone helpers) live in
//  KataGoUICore/Model/GameRecord+SGF.swift.
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
    // The iCloud servers don't guarantee atomic processing of relationship changes,
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
    // Widened from private to public so the bridge extension in KataGoUICore can access them.
    public var deadBlackStones: [Int: String]?
    public var deadWhiteStones: [Int: String]?
    public var blackSchrodingerStones: [Int: String]?
    public var whiteSchrodingerStones: [Int: String]?

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

    /// Resolve the game a `katago-anytime://open-game` deep link should open: the
    /// game with `id` if it still exists, else the most-recently-modified game,
    /// else nil. Mirrors `SavedGameSnapshot.resolveSnapshot`'s display fallback so
    /// a tap on a widget that is still showing a since-deleted game (the widget
    /// can lag the store) opens the most-recent game instead of doing nothing.
    @MainActor
    public class func resolveDeepLinkTarget(id: UUID, container: ModelContainer) -> GameRecord? {
        // `fetchGameRecords` is sorted by `lastModificationDate` descending, so
        // `first` is the most-recently-modified game.
        let all = (try? fetchGameRecords(container: container)) ?? []
        return all.first(where: { $0.uuid == id }) ?? all.first
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
}
