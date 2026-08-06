//
//  WatchWidgetDefaults.swift
//  KataGoAnalysisKit
//
//  The watch-local IPC channel between the watch app and its complication.
//
//  App Group containers are PER-DEVICE. `group.chinchangyang.KataGo-iOS.tw` is
//  entitled on both the iPhone and the watch, which reads as one shared
//  container but is not: nothing the iPhone writes there is visible to the
//  watch widget. That is why both mirrors (live and library, fed from three
//  call sites) live in the watch app process and the phone reaches the tile
//  only through WatchConnectivity. It is a platform constraint, not a style
//  choice — "just have the relay write the record" looks plausible and
//  produces a permanently empty tile.
//
//  Note also that on watchOS the SwiftData store deliberately does NOT use
//  this group (see SharedModelContainer's CloudKit-only branch), so this is
//  the ONLY channel the complication has.
//

import Foundation

public enum WatchWidgetDefaults {
    public static let appGroupID = "group.chinchangyang.KataGo-iOS.tw"
    public static let recordsKey = "watchWidget.records"

    /// The widget's `kind`, and the argument to `reloadTimelines(ofKind:)`.
    ///
    /// Deliberately still the old identifier. Renaming it would drop every
    /// placement testers have already made — they would see an empty slot, not
    /// a renamed tile — and, because `WCSession.isComplicationEnabled` tracks
    /// an ACTIVE face placement, it would also flip the phone's push gate to
    /// false with no error anywhere. Hoisted here so the app-side and
    /// widget-side constants cannot drift apart.
    public static let widgetKind = "ScoreLeadWidget"

    /// Written by the complication this one replaces. Read for one release so
    /// a watch that has not been opened since the update still shows a score,
    /// then removed once.
    public static let legacyScoreKey = "watchScoreLeadBlack"
    public static let legacyUpdatedAtKey = "watchScoreUpdatedAt"
    public static let legacyCleanupFlagKey = "didCleanLegacyComplicationKeys"

    /// nil when the App Group is unavailable — a state the widget renders
    /// differently from "no data", now that the tile claims to show a name.
    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    public static func read(from defaults: UserDefaults?) -> WatchWidgetRecords {
        guard let data = defaults?.data(forKey: recordsKey),
              let records = try? decoder.decode(WatchWidgetRecords.self, from: data)
        else { return WatchWidgetRecords() }
        return records
    }

    /// Returns false when the write could not happen (no App Group, or an
    /// encode failure), so callers do not record a reload they never earned.
    @discardableResult
    public static func write(_ records: WatchWidgetRecords, to defaults: UserDefaults?) -> Bool {
        guard let defaults, let data = try? encoder.encode(records) else { return false }
        defaults.set(data, forKey: recordsKey)
        return true
    }

    public static func legacyScoreLeadBlack(from defaults: UserDefaults?) -> Double? {
        defaults?.object(forKey: legacyScoreKey) as? Double
    }

    /// Remove the retired scalars, once. Guarded by a flag so a later feature
    /// that legitimately reuses one of those names is not wiped on every
    /// launch.
    public static func cleanLegacyKeysOnce(in defaults: UserDefaults?) {
        guard let defaults, !defaults.bool(forKey: legacyCleanupFlagKey) else { return }
        defaults.removeObject(forKey: legacyScoreKey)
        defaults.removeObject(forKey: legacyUpdatedAtKey)
        defaults.set(true, forKey: legacyCleanupFlagKey)
    }

    // `secondsSince1970` on both sides, matching WatchSnapshot's coders: the
    // default strategy would encode a Double reference-date offset, which is
    // fine in isolation but diverges from the payload this shares a process
    // with, and `capturedAt` ordering is load-bearing.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
