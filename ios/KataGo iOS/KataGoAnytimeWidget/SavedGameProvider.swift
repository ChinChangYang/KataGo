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
        let snapshot = await MainActor.run {
            // `configuration.game` is re-materialized by WidgetKit/AppIntents on each
            // timeline pass and resolves INTERMITTENTLY to nil in the memory-constrained
            // widget process. Persist the id whenever it DOES resolve, and reuse the
            // last-known configured id when it doesn't, so a configured widget stays
            // pinned to its game instead of falling back to (and deep-linking) the
            // most-recently-modified game. See `WidgetConfiguredGameStore`.
            let store = WidgetConfiguredGameStore()
            if let liveID = configuration.game?.id { store.save(liveID) }
            let configuredID = configuration.game?.id ?? store.load()
            return SavedGameSnapshot.resolveSnapshot(configuredID: configuredID,
                                                     container: SharedModelContainer.shared)
        }
        return SavedGameEntry(date: .now, snapshot: snapshot)
    }
}
