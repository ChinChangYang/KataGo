import WidgetKit
import SwiftUI
import KataGoGameStore

struct SavedGameWidget: Widget {
    let kind = "SavedGameWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectGameIntent.self,
                               provider: SavedGameProvider()) { entry in
            SavedGameWidgetView(entry: entry)
        }
        .configurationDisplayName("Saved Game")
        .description("Shows a saved game's name, first comment, and board.")
        // `.systemExtraLarge` is available on iPadOS, macOS, and visionOS 26 (the
        // platforms this widget ships to); iPhone simply never offers it. No `#if`
        // guard is needed — the enum case compiles on every slice.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

#Preview("Extra Large", as: .systemExtraLarge) {
    SavedGameWidget()
} timeline: {
    SavedGameEntry(date: .now,
                   snapshot: SavedGameSnapshot(
                    gameID: nil,
                    name: "Sample Game",
                    firstComment: "A quiet opening. Black takes the empty corners; White builds toward the center and the fight is still to come.",
                    boardWidth: 19, boardHeight: 19,
                    lastBlackStones: ["Q16", "D4", "C16"],
                    lastWhiteStones: ["Q4", "D16", "R14"],
                    moveCount: 6))
}
