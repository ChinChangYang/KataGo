import WidgetKit
import SwiftUI

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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
