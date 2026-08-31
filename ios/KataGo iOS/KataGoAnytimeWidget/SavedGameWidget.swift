import WidgetKit
import SwiftUI
import KataGoGameStore

struct SavedGameWidget: Widget {
    let kind = "SavedGameWidget"

    private var base: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind,
                               intent: SelectGameIntent.self,
                               provider: SavedGameProvider()) { entry in
            SavedGameWidgetView(entry: entry)
        }
        .configurationDisplayName("Saved Game")
        .description("Shows a saved game's name and board, with the comment at the displayed move when Show Comment is on.")
        // `.systemExtraLarge` is available on iPadOS, macOS, and visionOS 26 (the
        // platforms this widget ships to); iPhone simply never offers it. No `#if`
        // guard is needed — the enum case compiles on every slice.
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }

    var body: some WidgetConfiguration {
        // The spatial modifiers exist only on the xros slice (mounting styles
        // and textures are also macOS-unavailable), so the split must be
        // compile-time: each slice returns one concrete opaque type.
        #if os(visionOS)
        base
            // Elevated (desk/wall frame) AND recessed (wall cutout) — the
            // full placement choice; the glass layout works in both.
            .supportedMountingStyles([.elevated, .recessed])
            // Glass, not paper: this is an information widget — the name and
            // comment stay bright and legible over the glass backdrop instead
            // of dimming with the room like a print.
            .widgetTexture(.glass)
        #elseif os(iOS)
        // A glanceable goban on the CarPlay Dashboard is a distraction
        // magnet; Apple's guidance is to disfavor game widgets there. The
        // Listening Live Activity is the app's one CarPlay surface.
        base
            .disfavoredLocations([.carPlay], for: [.systemSmall])
        #else
        base
        #endif
    }
}

#Preview("Extra Large", as: .systemExtraLarge) {
    SavedGameWidget()
} timeline: {
    SavedGameEntry(date: .now,
                   snapshot: SavedGameSnapshot(
                    gameID: nil,
                    name: "Sample Game",
                    comment: "A quiet opening. Black takes the empty corners; White builds toward the center and the fight is still to come.",
                    boardWidth: 19, boardHeight: 19,
                    lastBlackStones: ["Q16", "D4", "C16"],
                    lastWhiteStones: ["Q4", "D16", "R14"],
                    moveCount: 6))
}

/// The same game with the Edit Widget "Show Comment" switch OFF: the comment
/// and the "Move N" line drop out and the board claims the row, with the name
/// centred beside it.
#Preview("Medium, comment off", as: .systemMedium) {
    SavedGameWidget()
} timeline: {
    SavedGameEntry(date: .now,
                   snapshot: SavedGameSnapshot(
                    gameID: nil,
                    name: "Sample Game",
                    comment: "A quiet opening. Black takes the empty corners; White builds toward the center and the fight is still to come.",
                    boardWidth: 19, boardHeight: 19,
                    lastBlackStones: ["Q16", "D4", "C16"],
                    lastWhiteStones: ["Q4", "D16", "R14"],
                    moveCount: 6),
                   showsComment: false)
}

/// Accented rendering — what the tinted and Clear Home Screens show. The
/// `#Preview(as:)` macro takes a `Widget`, and `Widget` has no environment
/// modifier, so the override goes on the CONTENT of a preview-only widget.
/// This exercises the accented layout — the neutral backplate, no wood, the
/// two-tone stones with white a solid disc and black a ring — but not the
/// system's white flattening; the Simulator's Home Screen shows that.
private struct AccentedPreviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "SavedGameWidget.accentedPreview",
                               intent: SelectGameIntent.self,
                               provider: SavedGameProvider()) { entry in
            SavedGameWidgetView(entry: entry)
                .environment(\.widgetRenderingMode, .accented)
        }
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

#Preview("Small, accented", as: .systemSmall) {
    AccentedPreviewWidget()
} timeline: {
    SavedGameEntry(date: .now,
                   snapshot: SavedGameSnapshot(
                    gameID: nil,
                    name: "Sample Game",
                    comment: "A quiet opening. Black takes the empty corners; White builds toward the center and the fight is still to come.",
                    boardWidth: 19, boardHeight: 19,
                    lastBlackStones: ["Q16", "D4", "C16"],
                    lastWhiteStones: ["Q4", "D16", "R14"],
                    moveCount: 6))
}
