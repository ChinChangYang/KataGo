//
//  GameRecord+SGF.swift
//  KataGo iOS
//
//  Bridge-using extension on GameRecord. These methods depend on
//  SgfOperations / SgfTruncation (C++ bridge) or Coordinate (KataGoModel).
//  The @Model class itself lives in KataGoGameStore/GameRecord.swift.
//

import SwiftUI
import SwiftData

extension GameRecord {

    // MARK: - Coordinate-based stone-status helpers

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

    // MARK: - SgfTruncation-based clone

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

    // MARK: - SgfOperations-based factory + import

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

        // Record the final board position (setup stones + captures, via the C++
        // engine rules) at the last move index so the Saved Game widget can draw
        // an imported game before it is ever opened — opening it later just
        // refills these per-index dicts from the live engine. Both keys are set
        // (even when empty) so GameEntity's lastIndex resolves to moveSize.
        let finalStones = sgfHelper.finalStones()
        let blackStones: [Int: String] = [moveSize: finalStones.black.joined(separator: " ")]
        let whiteStones: [Int: String] = [moveSize: finalStones.white.joined(separator: " ")]

        let newRecord = GameRecord.createGameRecord(sgf: sgf,
                                                    currentIndex: moveSize,
                                                    name: name,
                                                    comments: comments,
                                                    blackStones: blackStones,
                                                    whiteStones: whiteStones)
        return (gameRecord: newRecord, isNew: true)
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
