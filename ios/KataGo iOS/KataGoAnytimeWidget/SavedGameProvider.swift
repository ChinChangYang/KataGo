import WidgetKit
import SwiftUI
import GoRulesKit
import KataGoGameStore

struct SavedGameEntry: TimelineEntry {
    let date: Date
    let snapshot: SavedGameSnapshot
    /// The user's Edit Widget backplate choice, resolved from the intent by
    /// the provider (the view never sees the intent). Presentation config,
    /// not game data — deliberately NOT part of SavedGameSnapshot.
    var background: SavedGameBackground = .default
    /// The user's Edit Widget "Show Comment" choice, resolved from the intent by
    /// the provider (the view never sees the intent) — presentation config, not
    /// game data, exactly like `background`. The `= true` member default is what
    /// keeps the configuration-free construction sites compiling and showing
    /// today's full layout: `placeholder(in:)` below, and the `#Preview`
    /// timelines in `SavedGameWidget.swift`.
    var showsComment: Bool = true
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
            return SavedGameEntry(date: .now, snapshot: .placeholder,
                                  background: SavedGameBackground.resolve(
                                      rawValue: configuration.background),
                                  showsComment: configuration.showsComment)
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
            // The board comes from the game's own SGF, replayed to its own
            // cursor — the projection every other library surface draws (ADR
            // 0014). `GoRulesKit` is the bridge-free replay an appex can link;
            // the C++ parser the app uses is not reachable from here.
            SavedGameSnapshot.resolveSnapshot(configuredID: configuredID,
                                              container: SharedModelContainer.shared,
                                              position: SgfDisplayPosition.resolve)
        }
        return SavedGameEntry(date: .now, snapshot: snapshot,
                              background: SavedGameBackground.resolve(
                                  rawValue: configuration.background),
                              showsComment: configuration.showsComment)
    }
}
