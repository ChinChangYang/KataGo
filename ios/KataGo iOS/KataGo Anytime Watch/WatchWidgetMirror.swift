import Foundation
import SwiftData
import WidgetKit
import KataGoGameStore

/// Owns every App-Group write the complication reads, and every timeline
/// reload it gets.
///
/// The mirror lives in the watch app process because App Group containers are
/// PER-DEVICE: `group.chinchangyang.KataGo-iOS.tw` is entitled on the iPhone
/// too, but nothing the iPhone writes there is visible here. That was already
/// a platform constraint rather than a style choice; now that the phone has no
/// WatchConnectivity channel either, this process is the only writer there can
/// possibly be.
///
/// `WidgetCenter` is confined to this type (and the widget target) on purpose:
/// KataGoGameStore compiles for tvOS, which has no WidgetKit.
///
/// Deliberately holds no `ModelContainer` — `mirrorLibrary` takes one as a
/// parameter from its caller instead.
@MainActor
final class WatchWidgetMirror {
    private let defaults: UserDefaults?

    /// The content key and time of the last reload actually requested.
    private var lastReloadKey: String?
    private var lastReloadAt: Date?

    init(defaults: UserDefaults? = WatchWidgetDefaults.sharedDefaults()) {
        self.defaults = defaults
        // Retire the previous complication's scalars, once. UserDefaults-only,
        // so this is safe to run this early — it cannot be why the mirror
        // used to require deferring construction to first UI appearance.
        WatchWidgetDefaults.cleanLegacyKeysOnce(in: defaults)
    }

    /// Refresh the stored record from the newest row of the library.
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
    /// resulting write is already content-gated by `WatchWidgetRecord.accepting`
    /// (an unchanged `contentKey` produces no `UserDefaults` write and no
    /// timeline reload), and the burst this would otherwise guard against —
    /// CloudKit's initial-sync storm — is already damped upstream by
    /// `WatchLibraryStore`'s `CoalescedTrigger`.
    func mirrorLibrary(rows: [WatchLibraryRow],
                       moveCount: (WatchLibraryRow) -> Int,
                       container: ModelContainer,
                       now: Date = Date()) {
        // A row with no lastModified has no honest ordering, so it is not
        // mirrored at all (the repo contains an 1846-dated sample record
        // shaped exactly like one).
        guard let row = rows.first, row.lastModified != nil,
              let extras = WatchWidgetLibrarySource.extras(gameID: row.id,
                                                           container: container) else { return }
        let candidate = WatchWidgetLibrarySource.snapshot(
            row: row, moveCount: moveCount(row), extras: extras, capturedAt: now)
        let stored = WatchWidgetDefaults.read(from: defaults)
        guard let updated = stored.accepting(candidate),
              WatchWidgetDefaults.write(updated, to: defaults) else { return }
        reloadIfNeeded(updated, now: now)
    }

    private func reloadIfNeeded(_ record: WatchWidgetRecord, now: Date) {
        let key = record.library?.contentKey ?? ""
        let elapsed = now.timeIntervalSince(lastReloadAt ?? .distantPast)
        guard WatchWidgetRefreshPolicy.shouldReload(previousKey: lastReloadKey,
                                                    nextKey: key,
                                                    elapsed: elapsed) else { return }
        lastReloadKey = key
        lastReloadAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: WatchWidgetDefaults.widgetKind)
    }
}
