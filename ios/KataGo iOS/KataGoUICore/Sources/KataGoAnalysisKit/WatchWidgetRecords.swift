//
//  WatchWidgetRecords.swift
//  KataGoAnalysisKit
//
//  Both mirrors, in one value, behind one App-Group key.
//
//  One key rather than two on purpose: the merge below is per-FIELD, so two
//  independently-written keys could be read across a torn cross-process
//  boundary and yield one game's parked index beside another game's comment —
//  wrong in a way no single record could ever be. Eviction also becomes one
//  atomic write instead of two.
//

import Foundation

public struct WatchWidgetRecords: Codable, Equatable, Sendable {
    /// From the phone's WatchConnectivity frame (or its complication push).
    public var live: WatchWidgetSnapshot?
    /// From the newest row of the watch's own CloudKit-synced library.
    public var library: WatchWidgetSnapshot?

    public init(live: WatchWidgetSnapshot? = nil, library: WatchWidgetSnapshot? = nil) {
        self.live = live
        self.library = library
    }

    /// How long a `.live` record stays eligible to outrank a `.library` one.
    /// Without a ceiling, a phone left idling on an old game would pin the
    /// tile indefinitely, because its heartbeat keeps a newer clock than any
    /// library edit made on another device.
    public static let liveExpiry: TimeInterval = 24 * 60 * 60

    /// What the tile should render.
    public func resolved(now: Date) -> WatchWidgetSnapshot? {
        switch (live, library) {
        case (nil, nil):
            return nil
        case (let live?, nil):
            return live
        case (nil, let library?):
            return library
        case (let live?, let library?):
            // Same game: MERGE. The two mirrors routinely park on different
            // indices (the phone at move 158, the CloudKit replica still where
            // the user typed), and picking one throws away a real comment.
            if live.gameID == library.gameID {
                return Self.merged(live: live, library: library)
            }
            if now.timeIntervalSince(live.capturedAt) >= Self.liveExpiry {
                return library
            }
            return live.capturedAt >= library.capturedAt ? live : library
        }
    }

    /// Per-field combination of two records describing the SAME game.
    /// Everything positional comes from the newer record; the older one may
    /// only contribute a comment, and only when it agrees on the index.
    static func merged(live: WatchWidgetSnapshot,
                       library: WatchWidgetSnapshot) -> WatchWidgetSnapshot {
        let liveIsNewer = live.capturedAt >= library.capturedAt
        let newer = liveIsNewer ? live : library
        let older = liveIsNewer ? library : live
        guard newer.comment == nil, newer.parkedIndex == older.parkedIndex else {
            return newer
        }
        var merged = newer
        merged.comment = older.comment
        return merged
    }

    /// The updated envelope if `candidate` is worth storing, else nil so the
    /// caller skips the encode and the `UserDefaults` write entirely.
    ///
    /// Two rules, both load-bearing. An unchanged `contentKey` means nothing
    /// the tile shows has moved, so the stored `capturedAt` must be preserved
    /// rather than refreshed — otherwise a cold replay of a days-old persisted
    /// application context would stamp itself as brand new. And for the same
    /// game the clock is MONOTONIC, which is what makes a late-delivered older
    /// complication payload harmless.
    public func acceptingLive(_ candidate: WatchWidgetSnapshot) -> WatchWidgetRecords? {
        if let stored = live {
            guard stored.contentKey != candidate.contentKey else { return nil }
            if stored.gameID == candidate.gameID, candidate.capturedAt < stored.capturedAt {
                return nil
            }
        }
        var updated = self
        updated.live = candidate
        return updated
    }

    /// The updated envelope if `candidate` is worth storing as the library
    /// record, else nil. Same content-key rule; no monotonicity guard is
    /// needed because there is exactly one library writer and it is serialized
    /// on the main actor.
    public func acceptingLibrary(_ candidate: WatchWidgetSnapshot) -> WatchWidgetRecords? {
        if let stored = library, stored.contentKey == candidate.contentKey { return nil }
        var updated = self
        updated.library = candidate
        return updated
    }

    /// Drop a `.live` record whose game no longer exists.
    ///
    /// The library mirror is the only writer that sees both worlds, so it owns
    /// this. Deleting the mirrored game from the Mac while the iPhone app is
    /// closed pushes no further frames, so without eviction the tile would
    /// keep a dead game — with a newer clock — forever, and the tap would
    /// dead-end on "Game not found".
    ///
    /// `libraryIsAuthoritative` must be false whenever the caller did not see
    /// the whole library (a degraded or in-memory store, or a fetch that hit
    /// its row cap), so a transient empty read cannot mass-evict.
    public func evictingStaleLive(libraryIDs: Set<String>,
                                  libraryIsAuthoritative: Bool) -> WatchWidgetRecords {
        guard libraryIsAuthoritative,
              let live,
              !libraryIDs.isEmpty,
              !libraryIDs.contains(live.gameID) else { return self }
        var updated = self
        updated.live = nil
        return updated
    }
}
