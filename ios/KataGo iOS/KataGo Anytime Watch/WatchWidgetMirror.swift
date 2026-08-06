import Foundation
import SwiftData
import WidgetKit
import KataGoGameStore

/// Owns every App-Group write the complication reads, and every timeline
/// reload it gets.
///
/// All three writers live in the watch app process because App Group
/// containers are PER-DEVICE: `group.chinchangyang.KataGo-iOS.tw` is entitled
/// on the iPhone too, but nothing the phone writes there is visible here. That
/// is a platform constraint, not a style choice.
///
/// `WidgetCenter` is confined to this type (and the widget target) on purpose:
/// KataGoGameStore compiles for tvOS, which has no WidgetKit.
///
/// Deliberately holds no `ModelContainer`. `mirrorLive` — the only path a
/// background wake ever exercises — never touches SwiftData; only
/// `mirrorLibrary` does, and it now takes the container as a parameter from
/// its caller instead. That makes this type constructible from
/// `UserDefaults` alone, which is what lets `KataGoAnytimeWatchApp.init()`
/// build it (and wire it into `WatchLiveModel.widgetMirror`) before
/// `activateForLaunch()` runs — without paying for
/// `SharedModelContainer.shared`'s CloudKit-mirrored stack on a background
/// launch that only needs to write one record and ask for a reload.
@MainActor
final class WatchWidgetMirror {
    private let defaults: UserDefaults?

    /// The content key and time of the last reload actually requested, keyed
    /// on the RESOLVED record — what the tile renders — rather than on either
    /// mirror alone.
    private var lastReloadKey: String?
    private var lastReloadAt: Date?

    init(defaults: UserDefaults? = WatchWidgetDefaults.sharedDefaults()) {
        self.defaults = defaults
        // Retire the previous complication's scalars, once. UserDefaults-only,
        // so this is safe to run this early — it cannot be why the mirror
        // used to require deferring construction to first UI appearance.
        WatchWidgetDefaults.cleanLegacyKeysOnce(in: defaults)
    }

    /// Refresh the `.library` record, and evict a `.live` record whose game is
    /// gone. This is the only writer that sees both worlds, so eviction is its
    /// job: deleting the mirrored game from the Mac while the iPhone app is
    /// closed pushes no further frames, and without this the tile would keep a
    /// dead game — with a newer clock — forever.
    ///
    /// The extras fetch below runs on every call that has a newest row —
    /// there is deliberately no memo keyed on `(id, lastModified)` to skip it
    /// when the row "hasn't moved". Such a memo was tried and removed: a
    /// `GameRecord`'s `lastModificationDate` does NOT advance when only its
    /// comment changes (`CommentPersistence.store` and Deep Report's
    /// copy-to-comment both mutate `comments` without touching it — see the
    /// note on `WatchWidgetSnapshot.capturedAt`), so an id/lastModified memo
    /// would silently swallow every comment-only edit until the watch app
    /// next relaunched — defeating this feature's headline behavior. Re-doing
    /// the fetch every time is safe and cheap instead: it is one row with
    /// four properties (`fetchLimit = 1`, narrow `propertiesToFetch`), the
    /// resulting write is already content-gated by
    /// `WatchWidgetRecords.acceptingLibrary` (an unchanged `contentKey`
    /// produces no `UserDefaults` write and no timeline reload), and the
    /// burst this would otherwise guard against — CloudKit's initial-sync
    /// storm — is already damped upstream by `WatchLibraryStore`'s
    /// `CoalescedTrigger`.
    func mirrorLibrary(rows: [WatchLibraryRow],
                       moveCount: (WatchLibraryRow) -> Int,
                       libraryIsAuthoritative: Bool,
                       container: ModelContainer,
                       now: Date = Date()) {
        var records = WatchWidgetDefaults.read(from: defaults)
        var changed = false

        let swept = records.evictingStaleLive(libraryIDs: Set(rows.map(\.id)),
                                              libraryIsAuthoritative: libraryIsAuthoritative)
        if swept != records {
            records = swept
            changed = true
        }

        // A row with no lastModified has no honest ordering, so it is not
        // mirrored at all (the repo contains an 1846-dated sample record
        // shaped exactly like one).
        if let row = rows.first, row.lastModified != nil {
            if let extras = WatchWidgetLibrarySource.extras(gameID: row.id,
                                                            container: container) {
                let candidate = WatchWidgetLibrarySource.snapshot(
                    row: row, moveCount: moveCount(row), extras: extras, capturedAt: now)
                if let updated = records.acceptingLibrary(candidate) {
                    records = updated
                    changed = true
                }
            }
        }

        guard changed, WatchWidgetDefaults.write(records, to: defaults) else { return }
        reloadIfNeeded(records, now: now, immediate: false)
    }

    /// Store a live candidate, if it says anything new. `immediate` bypasses
    /// the reload floor for a background wake, where refreshing the tile is
    /// the entire point of having been woken.
    func mirrorLive(_ candidate: WatchWidgetSnapshot,
                    now: Date = Date(),
                    immediate: Bool = false) {
        let records = WatchWidgetDefaults.read(from: defaults)
        guard let updated = records.acceptingLive(candidate),
              WatchWidgetDefaults.write(updated, to: defaults) else { return }
        reloadIfNeeded(updated, now: now, immediate: immediate)
    }

    private func reloadIfNeeded(_ records: WatchWidgetRecords, now: Date, immediate: Bool) {
        let key = records.resolved(now: now)?.contentKey ?? ""
        let elapsed = now.timeIntervalSince(lastReloadAt ?? .distantPast)
        guard immediate || WatchWidgetRefreshPolicy.shouldReload(previousKey: lastReloadKey,
                                                                 nextKey: key,
                                                                 elapsed: elapsed) else { return }
        lastReloadKey = key
        lastReloadAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetDefaults.widgetKind)
    }
}
