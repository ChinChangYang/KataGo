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

import Foundation
import SwiftData

@Model
public final class GameRecord {
    // Non-unique local SQLite indexes (NOT mirrored to CloudKit, so they don't
    // touch the synced record schema): collapse the widget picker / list fetches
    // from a full-table scan to an index walk. `lastModificationDate` backs every
    // newest-first sort (the picker `suggestedEntities`, name search, deep-link
    // resolution); `uuid` backs the per-render `fetchGameRecord(uuid:)` equality
    // lookup. Both grew O(N) with library size before, stalling the throttled
    // widget extension. (`#Unique` is intentionally NOT used — CloudKit forbids it,
    // which is also why the duplicate-UUID repair machinery exists.)
    #Index<GameRecord>([\.lastModificationDate], [\.uuid])

    /// The default game's ruleset token: Tromp-Taylor, KataGo's canonical
    /// rules (ADR 0001). Every fresh-game surface composes its SGF from this
    /// and `Config.defaultKomi` so the default cannot drift per-platform.
    public static let defaultRuleString = "tromp-taylor"
    public static let defaultSgf = makeDefaultSgf(boardSize: 19)
    public static let defaultName = "New Game"

    /// Whether a game whose SGF is `sgf` should come up UNLOCKED (editable).
    ///
    /// A game nobody has played a move in yet is editable, so a brand-new game
    /// is ready to take its first stone; anything with a history is locked
    /// until the user says otherwise. `unlockRequested` is the one-shot intent
    /// `GobanState.commitBranch` sets so the line just committed stays open.
    ///
    /// It lives here, in the bridge-free store beside `defaultSgf`, rather than
    /// on `GobanState`, because two very different things depend on it: the
    /// board's lock state, and — on macOS — whether a DRAFT is opened over the
    /// record (`DraftEditingSync`, whose test target cannot link the engine).
    /// One rule, one place, so those two can never disagree about what a load
    /// leaves behind.
    public static func editingAfterLoad(sgf: String, unlockRequested: Bool) -> Bool {
        sgf == defaultSgf || unlockRequested
    }

    public static func makeDefaultSgf(boardSize: Int) -> String {
        "(;FF[4]GM[1]SZ[\(boardSize)]PB[]PW[]HA[0]KM[\(Config.komiText(Config.defaultKomi))]RU[\(defaultRuleString)])"
    }

    /// Builds a fresh-game SGF that encodes board size, komi, and rules directly
    /// in the `SZ`/`KM`/`RU` fields. This is the single source of truth the
    /// `createGameRecord` factory and `GobanState.loadGame` re-derive board size,
    /// komi, and rules from — `loadGame` OVERWRITES the `Config` rule/komi fields
    /// from the SGF on every load — so a new game's settings must be carried here,
    /// not merely assigned on `Config`.
    ///
    /// `ruleString` is any spelling KataGo's SGF parser accepts: a named ruleset
    /// (`chinese`, `japanese`, …) or the compact `koSIMPLEscoreAREA…` form. Square
    /// boards use `SZ[n]`; rectangular boards use `SZ[w:h]`.
    public static func makeSgf(width: Int, height: Int, komi: Float, ruleString: String) -> String {
        let sizeField = width == height ? "\(width)" : "\(width):\(height)"
        return "(;FF[4]GM[1]SZ[\(sizeField)]PB[]PW[]HA[0]KM[\(komiSgfField(komi))]RU[\(ruleString)])"
    }

    /// SGF for a fresh classic-handicap game: `HA[n]` + `AB[...]` on the
    /// conventional star points (stones always Black's) and White to move
    /// (`PL[W]` — belt-and-suspenders: the engine's parser also infers White
    /// from all-black placements). Returns `nil` when the board has no
    /// star-point layout for `handicap` (see `BoardHandicapPoints`) — callers
    /// disable those choices up front. `handicap == 0` delegates to the plain
    /// builder. Komi is the caller's; the New Game flow passes 0.5 for
    /// handicap games.
    public static func makeSgf(width: Int, height: Int, komi: Float,
                               ruleString: String, handicap: Int) -> String? {
        guard handicap != 0 else {
            return makeSgf(width: width, height: height, komi: komi, ruleString: ruleString)
        }
        let points = BoardHandicapPoints.points(width: width, height: height, count: handicap)
        guard points.count == handicap else { return nil }
        var setup = ""
        for point in points {
            guard let coordinate = BoardHandicapPoints.sgfCoordinate(x: point.x, y: point.y) else {
                return nil
            }
            setup += "[\(coordinate)]"
        }
        let sizeField = width == height ? "\(width)" : "\(width):\(height)"
        return "(;FF[4]GM[1]SZ[\(sizeField)]PB[]PW[]HA[\(handicap)]AB\(setup)PL[W]KM[\(komiSgfField(komi))]RU[\(ruleString)])"
    }

    /// Renders komi for an SGF `KM[]` field: a bare integer when whole (matching
    /// the default SGF's `KM[7]`), else a trimmed decimal (`6.5`). Delegates to the
    /// shared, SGF-canonical `Config.komiText` (same module) so the SGF field and
    /// the macOS komi labels stay in lock-step.
    static func komiSgfField(_ komi: Float) -> String {
        Config.komiText(komi)
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
    /// RETIRED (ADR 0014). A library picture is derived from the record now, so
    /// nothing writes this and nothing reads it. The column stays because the
    /// schema is frozen for CloudKit, and the bytes already in it stay because
    /// no healing pass runs — once nothing reads the column they are simply
    /// invisible.
    ///
    /// There is deliberately no way to SET it at construction any more: the
    /// init and `createGameRecord` dropped their `thumbnail:` parameters, so a
    /// new record cannot be born carrying one. The two remaining writers touch
    /// it directly and both mean it — `DraftSnapshot` round-trips whatever a
    /// legacy record already holds (dropping it would make a macOS draft Save
    /// *erase* those bytes), and a perf test sets a blob to weigh a realistic
    /// legacy row.
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

    /// Fetches the single game with `uuid`, or nil. A bounded predicate fetch so a
    /// memory-constrained process (the widget extension) never materializes the
    /// whole library just to resolve one configured game.
    @MainActor
    public class func fetchGameRecord(uuid: UUID, container: ModelContainer) throws -> GameRecord? {
        let target: UUID? = uuid
        // Sort newest-first so that, should the (read-only, not-yet-repaired) store
        // hold duplicate UUIDs, this returns the same most-recently-modified match
        // the previous whole-library `first(where:)` did.
        var descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate { $0.uuid == target },
            sortBy: [.init(\.lastModificationDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        // Memory-pressure mitigation for the widget extension: this fetch only ever
        // feeds `GameEntity.init` / `SavedGameSnapshot`, which read a small set of
        // display fields. Restrict the materialized properties to those so the
        // resolution never pulls a game's heavy per-move analysis dictionaries
        // (ownership, win rates, best moves, dead stones, …) into the constrained
        // appex — a smaller footprint makes the AppIntents `entities(for:)` round-trip
        // less likely to be jettisoned (which is what makes a configured widget fall
        // back to most-recent). SwiftData faults any unlisted property in on demand,
        // so this is purely a footprint bound, never a correctness change.
        descriptor.propertiesToFetch = [
            \.uuid, \.name, \.comments, \.width, \.height,
            \.blackStones, \.whiteStones, \.currentIndex, \.lastModificationDate
        ]
        return try container.mainContext.fetch(descriptor).first
    }

    /// Bounded, newest-first name search for the widget configuration picker, so a
    /// memory-constrained extension never materializes the whole library to filter
    /// by name in Swift. `localizedStandardContains` gives a case/diacritic-
    /// insensitive match. The `query.isEmpty ||` short-circuit makes an empty query
    /// return the newest `limit` games (mirroring `GameListView`'s @Query predicate):
    /// `localizedStandardContains("")` is `false` in both the in-memory and the
    /// SQLite-backed store, so without the guard an empty search would return NONE.
    /// A non-positive `limit` returns [] (a `fetchLimit` of 0 means "no limit" in
    /// Core Data, which would silently defeat the bound in the extension).
    @MainActor
    public class func fetchGameRecords(nameContains query: String, limit: Int, container: ModelContainer) throws -> [GameRecord] {
        guard limit > 0 else { return [] }
        var descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate { query.isEmpty || $0.name.localizedStandardContains(query) },
            sortBy: [.init(\.lastModificationDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return try container.mainContext.fetch(descriptor)
    }

    /// Newest-first, footprint-bounded fetch for the widget configuration picker. The
    /// picker renders only each game's NAME and FIRST COMMENT, so restrict the
    /// materialized properties to uuid/name/comments (plus the sort key). This keeps
    /// the memory-constrained widget extension from faulting in every game's heavy
    /// per-move board/analysis dictionaries (blackStones/whiteStones/ownership/…) just
    /// to list names — that footprint blew the hard 30 MB widget memory limit and got
    /// the appex jettisoned (JETSAM_REASON_MEMORY_PERPROCESSLIMIT), leaving the picker
    /// empty. `propertiesToFetch` is a footprint hint only; SwiftData faults any
    /// unlisted property in on demand, so this is never a correctness change. A
    /// non-positive `limit` returns [] (a `fetchLimit` of 0 means "no limit" in Core
    /// Data, which would silently defeat the bound in the extension).
    @MainActor
    public class func fetchGameRecordsForPicker(container: ModelContainer, fetchLimit: Int) throws -> [GameRecord] {
        guard fetchLimit > 0 else { return [] }
        var descriptor = createFetchDescriptor(fetchLimit: fetchLimit)
        descriptor.propertiesToFetch = [\.uuid, \.name, \.comments, \.lastModificationDate]
        return try container.mainContext.fetch(descriptor)
    }

    /// Drain-time resolution for a deferred deep-link selection (macOS cold-launch
    /// F14 gate). When the stashed target was deleted during the pre-ready window,
    /// fall back to the most-recently-modified game (mirroring
    /// `resolveDeepLinkTarget`) instead of loading nothing. `fetched` must be sorted
    /// newest-first (as `fetchGameRecords` returns), so `.first` is the most recent.
    public class func resolveDrainTarget(stashed: GameRecord?,
                                         stashedIsDeleted: Bool,
                                         fetched: [GameRecord]) -> GameRecord? {
        if let stashed, !stashedIsDeleted { return stashed }
        return fetched.first   // most-recent fallback (newest-first list)
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

    /// Cold-launch initial selection. When a widget deep link is captured at launch
    /// (`pendingGameID`), open that game (exact match, else the most-recent fallback
    /// via `resolveDeepLinkTarget`); otherwise open the most-recently-modified game.
    /// `ContentView.initializationTask` uses this so a widget tap that *cold*-launches
    /// the app opens the configured game instead of the default most-recent.
    @MainActor
    public class func resolveInitialSelection(pendingGameID: UUID?, container: ModelContainer) -> GameRecord? {
        if let id = pendingGameID {
            return resolveDeepLinkTarget(id: id, container: container)
        }
        // `fetchGameRecords` is sorted by `lastModificationDate` descending, so
        // `first` is the most-recently-modified game (the default selection).
        return (try? fetchGameRecords(container: container))?.first
    }

}
