//
//  GamePickerPerformanceTests.swift
//  KataGo iOSTests
//
//  Scaling investigation + regression guard for the widget game-list picker.
//
//  The widget configuration picker (AppIntents `GameEntityQuery.pickerOptions`,
//  formerly `suggestedEntities` / `entities(matching:)`) fetches via a
//  `FetchDescriptor` sorted by `lastModificationDate`. If that column is UNINDEXED,
//  SQLite must scan + sort the whole `GameRecord` table to return the newest N — O(N)
//  in the total number of games, on every picker open, inside the throttled widget
//  `.appex`. With many heavy games this is the reported "tap the menu → long wait" bug.
//
//  These tests:
//   1. `pickerFetchScalingBenchmark` (OPT-IN: set KATAGO_RUN_PERF=1) seeds thousands
//      of heavy rows and prints, across N, the time to (i) open the container,
//      (ii) run the real `fetchGameRecords(fetchLimit: 20)`, and the same fetch
//      against an UNINDEXED vs INDEXED probe model. Before the fix the real fetch
//      tracks the unindexed probe (scales); after adding `#Index` to `GameRecord`
//      it tracks the indexed probe (flat). It is opt-in because seeding is far too
//      slow for CI.
//   2. `indexedModel_topN_isNewestFirst` (always on) is a cheap, deterministic
//      regression guard that the picker fetch still returns the correct newest-first
//      top-N after the index is added.
//

import Testing
import SwiftData
import Foundation
import KataGoUICore

struct GamePickerPerformanceTests {

    // MARK: - Probe models (reference points that do NOT change when GameRecord is edited)

    /// Same heavy shape as the picker fetch needs, WITHOUT an index on the sort key.
    @Model final class UnindexedProbe {
        var lastModificationDate: Date?
        var blob: Data?
        var payload: String = ""
        init(date: Date, blob: Data, payload: String) {
            self.lastModificationDate = date; self.blob = blob; self.payload = payload
        }
    }

    /// Identical, but WITH a non-unique index on the sort key — the fix under test.
    @Model final class IndexedProbe {
        #Index<IndexedProbe>([\.lastModificationDate])
        var lastModificationDate: Date?
        var blob: Data?
        var payload: String = ""
        init(date: Date, blob: Data, payload: String) {
            self.lastModificationDate = date; self.blob = blob; self.payload = payload
        }
    }

    // MARK: - Helpers

    private func freshStoreURL(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(tag).store")
    }

    /// ~25 KB of realistic per-row weight: an 8 KB thumbnail-sized blob, a few-KB
    /// sgf-sized string, and ~150-entry stone/comment dictionaries.
    private func heavyBlob() -> Data { Data((0..<8_192).map { UInt8($0 & 0xFF) }) }
    private func heavySgf() -> String { String(repeating: "(;B[qd];W[dd];B[oc];W[qo])", count: 80) }
    private func heavyStones() -> [Int: String] {
        var d: [Int: String] = [:]
        for i in 0..<150 { d[i] = "Q16 D4 Q4 D16 R14 C6 F3 O17" }
        return d
    }

    private func seconds(_ block: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let elapsed = try clock.measure { try block() }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Seeds N heavy GameRecords into a fresh on-disk store; returns the URL.
    @MainActor private func seedGameRecords(_ n: Int) throws -> URL {
        let url = try freshStoreURL("gr-\(n)")
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: ModelConfiguration(url: url))
        let ctx = container.mainContext
        let blob = heavyBlob(); let sgf = heavySgf(); let stones = heavyStones()
        for i in 0..<n {
            let r = GameRecord(config: Config())
            r.name = "Game \(i)"
            r.lastModificationDate = Date(timeIntervalSince1970: Double(n - i))   // distinct, descending
            r.sgf = sgf
            r.thumbnail = blob
            r.comments = stones
            r.blackStones = stones
            r.whiteStones = stones
            ctx.insert(r)
            if i % 250 == 249 { try ctx.save() }
        }
        try ctx.save()
        return url
    }

    @MainActor private func seedProbes<T: PersistentModel>(_ type: T.Type, _ n: Int,
                                                           make: (Date, Data, String) -> T) throws -> URL {
        let url = try freshStoreURL("probe-\(n)")
        let container = try ModelContainer(for: type, configurations: ModelConfiguration(url: url))
        let ctx = container.mainContext
        let blob = heavyBlob(); let sgf = heavySgf()
        for i in 0..<n {
            ctx.insert(make(Date(timeIntervalSince1970: Double(n - i)), blob, sgf))
            if i % 250 == 249 { try ctx.save() }
        }
        try ctx.save()
        return url
    }

    // MARK: - Opt-in scaling benchmark

    @Test(.enabled(if: ProcessInfo.processInfo.environment["KATAGO_RUN_PERF"] != nil),
          .timeLimit(.minutes(10)))
    @MainActor func pickerFetchScalingBenchmark() throws {
        let sizes = [500, 1500, 3000]
        var open: [Double] = [], real: [Double] = [], unindexed: [Double] = [], indexed: [Double] = []

        for n in sizes {
            // Real GameRecord store. Reopen fresh from disk so neither the OS page
            // cache nor the seeding context's row cache hides the cost.
            let grURL = try seedGameRecords(n)
            var grContainer: ModelContainer!
            let openT = try seconds { grContainer = try ModelContainer(for: SharedModelContainer.schema,
                                                                       configurations: ModelConfiguration(url: grURL)) }
            var fetchSamples: [Double] = []                                    // median; first warms caches
            for _ in 0..<4 {
                fetchSamples.append(try seconds { _ = try GameRecord.fetchGameRecords(container: grContainer, fetchLimit: 20) })
            }

            // Probe stores: fixed reference points unaffected by edits to GameRecord.
            let unidxURL = try seedProbes(UnindexedProbe.self, n) { UnindexedProbe(date: $0, blob: $1, payload: $2) }
            let idxURL = try seedProbes(IndexedProbe.self, n) { IndexedProbe(date: $0, blob: $1, payload: $2) }
            let unidxC = try ModelContainer(for: UnindexedProbe.self, configurations: ModelConfiguration(url: unidxURL))
            let idxC = try ModelContainer(for: IndexedProbe.self, configurations: ModelConfiguration(url: idxURL))

            open.append(openT)
            real.append(fetchSamples.sorted()[fetchSamples.count / 2])
            unindexed.append(try probeFetch(unidxC, sortBy: [SortDescriptor(\UnindexedProbe.lastModificationDate, order: .reverse)]))
            indexed.append(try probeFetch(idxC, sortBy: [SortDescriptor(\IndexedProbe.lastModificationDate, order: .reverse)]))
        }

        print("\n=== Widget picker fetch scaling (ms) ===")
        print("N    | open(real) | fetch(real) | fetch(unindexed) | fetch(indexed)")
        for (i, n) in sizes.enumerated() {
            print(String(format: "%-5d| %9.1f | %10.1f | %15.1f | %14.1f",
                         n, open[i] * 1000, real[i] * 1000, unindexed[i] * 1000, indexed[i] * 1000))
        }
        func growth(_ a: [Double]) -> Double { a.first! > 0 ? a.last! / a.first! : 0 }
        print(String(format: "growth N=%d→%d:  open %.2fx | real %.2fx | unindexed %.2fx | indexed %.2fx",
                     sizes.first!, sizes.last!, growth(open), growth(real), growth(unindexed), growth(indexed)))

        // Soft scaling assertion (generous; opt-in only): the indexed probe must not
        // blow up with N the way the unindexed probe does.
        #expect(indexed.last! < unindexed.last!, "indexed fetch should be faster than unindexed at large N")
    }

    @MainActor private func probeFetch<T: PersistentModel>(_ c: ModelContainer, sortBy: [SortDescriptor<T>]) throws -> Double {
        var samples: [Double] = []
        for _ in 0..<4 {
            samples.append(try seconds {
                var d = FetchDescriptor<T>(sortBy: sortBy)
                d.fetchLimit = 20
                _ = try c.mainContext.fetch(d)
            })
        }
        return samples.sorted()[samples.count / 2]
    }

    // MARK: - Always-on correctness guard

    /// Adding `#Index([\.lastModificationDate])` to GameRecord must not change the
    /// picker fetch result: still the newest-first top-N.
    @Test @MainActor func indexedModel_topN_isNewestFirst() throws {
        let url = try freshStoreURL("order")
        let container = try ModelContainer(for: SharedModelContainer.schema,
                                           configurations: ModelConfiguration(url: url))
        for i in 0..<100 {
            let r = GameRecord(config: Config())
            r.name = "Game \(i)"
            r.lastModificationDate = Date(timeIntervalSince1970: Double(i))   // i=99 newest
            container.mainContext.insert(r)
        }
        try container.mainContext.save()

        let top = try GameRecord.fetchGameRecords(container: container, fetchLimit: 20)
        #expect(top.count == 20)
        #expect(top.first?.name == "Game 99")                                 // newest first
        #expect(top.last?.name == "Game 80")
        let dates = top.compactMap(\.lastModificationDate)
        #expect(dates == dates.sorted(by: >))                                 // strictly descending
    }

    // MARK: - Footprint-bounded picker options (jetsam regression: 30 MB widget limit)

    //  The Saved Game widget's config picker (`GameOptionsProvider.results`) used to
    //  fetch 50 records with NO `propertiesToFetch` bound and build 50 full
    //  `GameEntity` objects, faulting in each game's heavy `blackStones`/`whiteStones`
    //  per-move board dictionaries. On a real device that exceeded the widget
    //  extension's hard 30 MB memory limit, so jetsam killed `KataGoAnytimeWidget`
    //  (JETSAM_REASON_MEMORY_PERPROCESSLIMIT) before the options returned — the picker
    //  showed "Loading…" then closed empty. (No appex memory cap exists in the
    //  Simulator or this test host, so these tests guard the two things the fix makes
    //  true — a property-bounded fetch and a `GameEntity`-free map — not the kill
    //  itself, which only the on-device run can prove.) The fix: a property-bounded
    //  `fetchGameRecordsForPicker` + `GameEntityQuery.pickerOptions`, which read only
    //  name + first comment and never touch the board dictionaries.

    @MainActor private func inMemoryStore() throws -> ModelContainer {
        try ModelContainer(for: SharedModelContainer.schema,
                           configurations: ModelConfiguration(schema: SharedModelContainer.schema,
                                                              isStoredInMemoryOnly: true))
    }

    /// Inserts `n` lightweight records with distinct, ascending modification dates
    /// (so `Game n-1` is newest) and a first comment.
    @MainActor private func seedLight(_ container: ModelContainer, count n: Int) throws {
        let ctx = container.mainContext
        for i in 0..<n {
            let r = GameRecord(config: Config())
            r.name = "Game \(i)"
            r.lastModificationDate = Date(timeIntervalSince1970: Double(i))   // i == n-1 is newest
            r.comments = [0: "comment \(i)"]
            ctx.insert(r)
        }
        try ctx.save()
    }

    @Test @MainActor func fetchGameRecordsForPicker_isBoundedAndNewestFirst() throws {
        let c = try inMemoryStore()
        try seedLight(c, count: 60)
        let rows = try GameRecord.fetchGameRecordsForPicker(container: c, fetchLimit: 50)
        #expect(rows.count == 50)
        #expect(rows.first?.name == "Game 59")                                // newest first
        #expect(rows.last?.name == "Game 10")                                 // 50th newest
        let dates = rows.compactMap(\.lastModificationDate)
        #expect(dates == dates.sorted(by: >))                                 // strictly descending
    }

    @Test @MainActor func fetchGameRecordsForPicker_nonPositiveLimit_isEmpty() throws {
        let c = try inMemoryStore()
        try seedLight(c, count: 5)
        // fetchLimit 0 means "no limit" in Core Data; the helper must refuse it so the
        // bound can't be silently defeated in the extension.
        #expect(try GameRecord.fetchGameRecordsForPicker(container: c, fetchLimit: 0).isEmpty)
    }

    @Test @MainActor func pickerOptions_mapsNameAndFirstComment() throws {
        let c = try inMemoryStore()
        let r = GameRecord(config: Config())
        r.name = "Opening Study"
        r.comments = [0: "Black takes 4-4", 1: "White approaches"]
        let id = try #require(r.uuid)
        c.mainContext.insert(r); try c.mainContext.save()

        let options = try GameEntityQuery.pickerOptions(container: c, limit: 50)
        let opt = try #require(options.first { $0.id == id.uuidString })
        #expect(opt.title == "Opening Study")
        #expect(opt.subtitle == "Black takes 4-4")                            // comments[0], not [1]
    }

    @Test @MainActor func pickerOptions_dropsRecordsWithNilUUID() throws {
        let c = try inMemoryStore()
        let normal = GameRecord(config: Config()); normal.name = "Normal"
        let nilGame = GameRecord(config: Config()); nilGame.name = "NilGame"; nilGame.uuid = nil
        c.mainContext.insert(normal); c.mainContext.insert(nilGame); try c.mainContext.save()

        let options = try GameEntityQuery.pickerOptions(container: c, limit: 50)
        #expect(options.contains { $0.title == "Normal" })
        #expect(!options.contains { $0.title == "NilGame" })                  // nil uuid → unselectable → hidden
    }

    @Test @MainActor func pickerOptions_nilComments_yieldsEmptySubtitle() throws {
        let c = try inMemoryStore()
        let r = GameRecord(config: Config()); r.name = "No Comments"; r.comments = nil
        let id = try #require(r.uuid)
        c.mainContext.insert(r); try c.mainContext.save()

        let options = try GameEntityQuery.pickerOptions(container: c, limit: 50)
        let opt = try #require(options.first { $0.id == id.uuidString })
        #expect(opt.subtitle == "")
    }

    /// An imported SGF whose FIRST comment isn't on move 0 (e.g. `comments = [3: …]`)
    /// must still show that comment in the picker — matching what the rendered widget
    /// displays (`GameEntity.firstComment`, which falls back to the earliest comment
    /// when key 0 is absent). A bare `comments?[0]` would leave the row blank and
    /// disagree with the widget the user is choosing.
    @Test @MainActor func pickerOptions_firstCommentNotAtZero_matchesRenderedWidget() throws {
        let c = try inMemoryStore()
        let r = GameRecord(config: Config())
        r.name = "Imported"
        r.comments = [3: "Comment on move 3"]                 // no key 0
        let id = try #require(r.uuid)
        c.mainContext.insert(r); try c.mainContext.save()

        let options = try GameEntityQuery.pickerOptions(container: c, limit: 50)
        let opt = try #require(options.first { $0.id == id.uuidString })
        #expect(opt.subtitle == "Comment on move 3")
        #expect(opt.subtitle == GameEntity(gameRecord: r).firstComment)   // parity with rendered widget
    }

    @Test @MainActor func pickerOptions_respectsLimit() throws {
        let c = try inMemoryStore()
        try seedLight(c, count: 60)
        #expect(try GameEntityQuery.pickerOptions(container: c, limit: 50).count == 50)
    }
}
