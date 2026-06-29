import WidgetKit
import SwiftUI
import KataGoGameStore

struct SavedGameEntry: TimelineEntry {
    let date: Date
    let snapshot: SavedGameSnapshot
}

struct SavedGameProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SavedGameEntry {
        SavedGameEntry(date: .now, snapshot: .placeholder)
    }

    func snapshot(for configuration: SelectGameIntent, in context: Context) async -> SavedGameEntry {
        // In the widget gallery (context.isPreview) WidgetKit only needs a
        // representative sample, so return the store-free placeholder instead of
        // opening the App-Group SwiftData store from this memory-constrained
        // extension just to render a preview.
        if context.isPreview {
            return SavedGameEntry(date: .now, snapshot: .placeholder)
        }
        return await entry(for: configuration)
    }

    func timeline(for configuration: SelectGameIntent, in context: Context) async -> Timeline<SavedGameEntry> {
        // F7: a widget extension can't observe cross-device CloudKit edits, so
        // schedule a periodic reload to re-resolve the snapshot rather than
        // `.never` (which would leave a stale game shown indefinitely).
        let entry = await entry(for: configuration)
        return Timeline(entries: [entry],
                        policy: .after(WidgetReloadPolicy.nextReloadDate(after: entry.date)))
    }

    private func entry(for configuration: SelectGameIntent) async -> SavedGameEntry {
        // The configured game id is a plain String on the intent (`SelectGameIntent`),
        // so it survives every timeline pass — unlike a `GameEntity?` parameter, which
        // AppIntents re-materializes via `entities(for:)` and resolves to nil when
        // linkd rejects the widget bundle (Simulator) or under memory pressure
        // (device). Resolving the snapshot from this stable id keeps the widget pinned
        // to the user's exact configured game even when it isn't the most-recent.
        let configuredID = configuration.gameID.flatMap { UUID(uuidString: $0) }
        let snapshot = await MainActor.run {
            SavedGameSnapshot.resolveSnapshot(configuredID: configuredID,
                                              container: SharedModelContainer.shared)
        }
        return SavedGameEntry(date: .now, snapshot: snapshot)
    }
}
