import AppKit
import SwiftData

final class MainWindowController: NSWindowController {
    init(modelContainer: ModelContainer) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "KataGo Anytime"
        super.init(window: w)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
