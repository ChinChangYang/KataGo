import WidgetKit
import SwiftUI

@main
struct KataGoAnytimeWidgetBundle: WidgetBundle {
    var body: some Widget {
        SavedGameWidget()
        #if os(iOS)
        ListeningActivityWidget()
        #endif
    }
}
