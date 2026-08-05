//
//  WatchLibraryStore.swift
//  KataGoGameStore
//
//  The watch's read-only view of the game library. Read-only is structural,
//  not a convention: nothing here inserts, deletes, or saves, so the watch can
//  never conflict with the phone through CloudKit.
//
//  Lives here rather than in the watch target because the watch has no test
//  bundle. Never imports CloudKit — the account signal is passed in by the
//  view layer so this module stays appex-safe.
//

import Foundation
import SwiftData
import CoreData
import Observation
import KataGoAnalysisKit

/// One game as the watch library lists it.
public struct WatchLibraryRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let boardWidth: Int
    public let boardHeight: Int
    /// The game record, the only source the watch replays positions from.
    public let sgf: String
    public let lastModified: Date?

    public init(id: String, name: String, boardWidth: Int, boardHeight: Int,
                sgf: String, lastModified: Date?) {
        self.id = id
        self.name = name
        self.boardWidth = boardWidth
        self.boardHeight = boardHeight
        self.sgf = sgf
        self.lastModified = lastModified
    }

    /// "19x9". ASCII only — the multiplication sign is not worth the encoding
    /// risk in a string this small.
    public var sizeText: String { "\(boardWidth)x\(boardHeight)" }
}

@Observable
@MainActor
public final class WatchLibraryStore {
    /// Newest-first cap. A wrist-sized process has no business materializing
    /// an unbounded library, and nobody scrolls past a hundred games on a watch.
    public static let fetchLimit = 100
    /// How long after opening the store an empty library still reads as
    /// "syncing" rather than "no games".
    public static let launchGrace: TimeInterval = 10
    /// How long a remote-change burst keeps the library reading as "syncing".
    public static let remoteActivityWindow: TimeInterval = 5

    public private(set) var rows: [WatchLibraryRow] = []
    /// Set by the view layer, which owns the CloudKit account check.
    public var accountState: ICloudAccountState = .unknown

    /// Invoked after every `refresh()`, once `rows` is current.
    ///
    /// The store itself stays read-only and side-effect-free: it must not
    /// import WidgetKit (it compiles for tvOS, which has no WidgetKit) and it
    /// must not write UserDefaults (WatchLibraryStoreTests calls `refresh()`
    /// in-process, which would scribble the real App Group on every test run).
    /// This callback is how the complication mirror learns the library changed
    /// without either.
    @ObservationIgnored public var onRefresh: (() -> Void)?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let storeMode: LibraryStoreMode
    @ObservationIgnored private let openedAt: Date
    @ObservationIgnored private var lastRemoteChange: Date?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    /// Coalesces remote-change-driven refetches (the pattern already running
    /// the Mac's iCloud list, `LibraryStore.remoteRefetchTrigger`). CloudKit
    /// can post a burst of `.NSPersistentStoreRemoteChange` notifications
    /// during initial sync — each one here is a 100-row sorted fetch
    /// materializing 100 SGF strings on the weakest main thread in the
    /// family, so a refetch per event would be costly; the trailing window
    /// also lets SwiftData's main-context auto-merge settle before the
    /// refetch reads, which a same-tick refetch on the LAST event of a burst
    /// could otherwise race and miss.
    @ObservationIgnored private let remoteRefetchTrigger = CoalescedTrigger()
    /// Memoized move counts, keyed by uuid *and* `lastModificationDate` so a
    /// remote edit (same uuid, new content) invalidates the memo instead of
    /// returning the pre-edit count forever. Observation-ignored on purpose:
    /// the library rows read this during body evaluation, and mutating
    /// observed state there would re-invalidate the view forever.
    @ObservationIgnored private var moveCounts: [MoveCountKey: Int] = [:]

    /// Identifies a game's content for memoization purposes: the uuid alone
    /// is not enough, because a game edited on another device keeps its
    /// uuid but arrives with a different `sgf`.
    private struct MoveCountKey: Hashable {
        let id: String
        let lastModified: Date?
    }

    public init(container: ModelContainer,
                storeMode: LibraryStoreMode,
                openedAt: Date = Date()) {
        self.container = container
        self.storeMode = storeMode
        self.openedAt = openedAt
    }

    // No deinit: the store is owned by the App scene and lives as long as the
    // process, and a nonisolated deinit cannot touch this @MainActor state in
    // Swift 6 anyway.

    /// Newest-first, property-bounded fetch. `propertiesToFetch` keeps a
    /// game's heavy per-move dictionaries (ownership, win rates, best moves,
    /// board snapshots) out of the watch's memory; SwiftData faults anything
    /// unlisted in on demand, so this is a footprint bound, never a
    /// correctness change.
    public func refresh() {
        var descriptor = FetchDescriptor<GameRecord>(
            sortBy: [.init(\.lastModificationDate, order: .reverse)])
        descriptor.fetchLimit = Self.fetchLimit
        descriptor.propertiesToFetch = [
            \.uuid, \.name, \.width, \.height, \.sgf, \.lastModificationDate
        ]
        let fetched = (try? container.mainContext.fetch(descriptor)) ?? []
        rows = fetched.compactMap { record in
            guard let uuid = record.uuid else { return nil }
            return WatchLibraryRow(id: uuid.uuidString,
                                   name: record.name,
                                   boardWidth: record.width ?? 19,
                                   boardHeight: record.height ?? 19,
                                   sgf: record.sgf,
                                   lastModified: record.lastModificationDate)
        }
        // A game may have been edited on another device: its uuid survives
        // but its lastModificationDate moves, so the composite key below
        // already misses the memo and recomputes. This filter only drops
        // entries for games that vanished from the fetch entirely, so the
        // memo cannot grow without bound.
        let liveKeys = Set(rows.map { MoveCountKey(id: $0.id, lastModified: $0.lastModified) })
        moveCounts = moveCounts.filter { key, _ in liveKeys.contains(key) }
        onRefresh?()
    }

    /// Refetch whenever CloudKit lands an import, so games appear without a
    /// relaunch. Same pattern as the Mac's iCloud list: `lastRemoteChange` is
    /// stamped on EVERY notification (so `emptyState` keeps reading as
    /// "syncing" through a burst), but the actual refetch is coalesced —
    /// otherwise the LAST notification of a burst could be serviced before
    /// SwiftData's auto-merge lands, and nothing fires afterwards, leaving
    /// those games invisible until relaunch.
    public func startObservingRemoteChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastRemoteChange = Date()
                self.remoteRefetchTrigger.schedule { [weak self] in self?.refresh() }
            }
        }
    }

    /// The game's mainline length, scanned on demand and memoized so opening
    /// the library never scans a hundred SGFs up front.
    public func moveCount(for row: WatchLibraryRow) -> Int {
        let key = MoveCountKey(id: row.id, lastModified: row.lastModified)
        if let cached = moveCounts[key] { return cached }
        let count = SgfHeaderScan(sgf: row.sgf)?.moveCount ?? 0
        moveCounts[key] = count
        return count
    }

    public func row(id: String) -> WatchLibraryRow? {
        rows.first { $0.id == id }
    }

    /// What to show while `rows` is empty. Delegates to the same policy the
    /// Apple TV library uses.
    public func emptyState(now: Date) -> EmptyLibraryState {
        return LibrarySyncPolicy.emptyLibraryState(
            storeMode: storeMode,
            accountState: accountState,
            importInFlight: false,
            recentRemoteActivity: Self.isRecentRemoteChange(lastRemoteChange, now: now),
            graceExpired: now.timeIntervalSince(openedAt) >= Self.launchGrace)
    }

    /// Whether a remote-change timestamp still counts as "recent" as of
    /// `now`. `now.timeIntervalSince(changedAt)` can be NEGATIVE if `now` was
    /// sampled before the change landed (a stale `now`, e.g. this view hasn't
    /// re-rendered since); an unclamped negative interval is less than
    /// `remoteActivityWindow` forever, which is the same "empty state never
    /// settles" failure the launch-grace timing exists to avoid elsewhere.
    /// `max(0, …)` would NOT fix this — it collapses to `0 < window`, still
    /// true — so this checks non-negativity explicitly instead. `internal`
    /// rather than `private` so the test target (`@testable import`, no
    /// access to the private `lastRemoteChange` storage or to CloudKit
    /// notifications on a deterministic clock) can pin the future-timestamp
    /// case directly.
    static func isRecentRemoteChange(_ changedAt: Date?, now: Date) -> Bool {
        guard let changedAt else { return false }
        let elapsed = now.timeIntervalSince(changedAt)
        return elapsed >= 0 && elapsed < remoteActivityWindow
    }
}
