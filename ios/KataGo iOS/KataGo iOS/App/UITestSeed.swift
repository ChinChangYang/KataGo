//
//  UITestSeed.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2026/7/8.
//
//  DEBUG-only test-support: seeds one short, committed multi-move game into the
//  shared store so a UI test can open it and exercise the Export GIF preview
//  (which only animates when the game has moves). Runs ONLY when the launch
//  argument is passed and is idempotent (find-or-create on a fixed uuid), so it
//  never inserts duplicates across the simulator's persisted store. The whole
//  file is compiled out of Release.
//

#if DEBUG
import Foundation
import SwiftData
import KataGoUICore

enum UITestSeed {
    /// Pass in `XCUIApplication.launchArguments` to seed the GIF export game.
    static let gifGameLaunchArg = "--uitest-seed-gif-game"

    /// Fixed identity so re-running the test on a persisted simulator finds the
    /// same record instead of inserting duplicates.
    static let gifGameUUID = UUID(uuidString: "0000A11F-0000-0000-0000-00000000C1F0")!
    static let gifGameName = "UITest GIF Game"

    /// Short 6-move 19x19 main line. `RU[...]` is REQUIRED: the engine-side
    /// `loadsgf` reads rules via `Sgf::getRulesOrFail`, which aborts (uncatchable)
    /// on an SGF without one (see `SampleGames`). `KM[7]` matches the komi
    /// `createGameRecord` derives.
    static let gifGameSgf =
        "(;FF[4]GM[1]SZ[19]RU[chinese]KM[7];B[pd];W[dp];B[qp];W[dc];B[fq];W[cn])"

    /// Seeds a rectangular game (13 wide x 9 high, `SZ[13:9]`, four stones):
    /// the 2D board renders any width x height that fits the NN buffer, and
    /// this exercises that path (visionOS creates such games since the 2..37
    /// support landed).
    static let rectGameLaunchArg = "--uitest-seed-rect-game"
    static let rectGameUUID = UUID(uuidString: "0000A11F-0000-0000-0000-0000000013B9")!
    static let rectGameName = "UITest Rect Game"
    static let rectGameSgf =
        "(;FF[4]GM[1]SZ[13:9]RU[chinese]KM[7];B[cc];W[kc];B[cg];W[kg])"

    /// Idempotent. Safe to call on every launch; a no-op once the records exist.
    @MainActor
    static func seedIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(gifGameLaunchArg) {
            seed(uuid: gifGameUUID, name: gifGameName, sgf: gifGameSgf)
        }
        if arguments.contains(rectGameLaunchArg) {
            seed(uuid: rectGameUUID, name: rectGameName, sgf: rectGameSgf)
        }
    }

    @MainActor
    private static func seed(uuid: UUID, name: String, sgf: String) {
        let context = SharedModelContainer.shared.mainContext

        // Find-or-create by the fixed uuid.
        let target: UUID? = uuid
        var descriptor = FetchDescriptor<GameRecord>(predicate: #Predicate { $0.uuid == target })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            // Already seeded on a persisted store: refresh the timestamp so the
            // seed is the newest game again. The app auto-selects the most
            // recent game at launch and `GameListView.onAppear` pre-fills the
            // list's search filter with the SELECTED game's name — a stale seed
            // loses the recency race to games left behind by other suites, gets
            // filtered OUT of the list, and the test can never find it.
            existing.lastModificationDate = Date.now
            try? context.save()
            return
        }

        // Same construction the New Game path uses: createGameRecord builds the
        // record + its Config (board size / komi from the SGF) but does NOT insert.
        let record = GameRecord.createGameRecord(
            sgf: sgf,
            currentIndex: 0,
            name: name
        )
        record.uuid = uuid
        record.lastModificationDate = Date.now  // newest-first → top of the list

        context.insert(record)
        try? context.save()
    }
}
#endif
