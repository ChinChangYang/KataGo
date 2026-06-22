import WidgetKit
import AppIntents
import KataGoGameStore

struct SelectGameIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Game"
    static let description = IntentDescription("Choose which saved game the widget shows.")

    @Parameter(title: "Game")
    var game: GameEntity?
}
