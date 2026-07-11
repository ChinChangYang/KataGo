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

    /// Idempotent. Safe to call on every launch; a no-op once the record exists.
    @MainActor
    static func seedIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains(gifGameLaunchArg) else { return }

        let context = SharedModelContainer.shared.mainContext

        // Find-or-create by the fixed uuid.
        let target: UUID? = gifGameUUID
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
            sgf: gifGameSgf,
            currentIndex: 0,
            name: gifGameName
        )
        record.uuid = gifGameUUID
        record.lastModificationDate = Date.now  // newest-first → top of the list

        context.insert(record)
        try? context.save()
    }
}
#endif
