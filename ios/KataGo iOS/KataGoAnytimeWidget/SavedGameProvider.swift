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
        await entry(for: configuration)
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
            SavedGameSnapshot.resolveSnapshot(for: configuration.game, container: SharedModelContainer.shared)
        }
        return SavedGameEntry(date: .now, snapshot: snapshot)
    }
}
