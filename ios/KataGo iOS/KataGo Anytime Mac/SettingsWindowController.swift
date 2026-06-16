//
//  SettingsWindowController.swift
//  KataGo Anytime Mac
//
//  P5-T11: the native macOS Settings (⌘,) window. A small, prefs-style
//  `NSWindow` (titled + closable, NOT resizable — the standard macOS
//  preferences shape) hosting `SettingsViewController` (a `.toolbar`-style
//  `NSTabViewController`). It is the AppKit analogue of the iOS
//  `GlobalSettingsView`.
//
//  Created lazily and retained by `MainWindowController.showSettings(_:)`
//  (reached through the responder chain from the app menu's "Settings…" item,
//  which targets `Selector(("showSettings:"))`). The window controller hands
//  the `SettingsViewController` the `GameSession` so its controls can read/WRITE
//  the shared `session.gobanState` (single writer — `MacGlobalPreferenceSync`
//  persists those changes to `GlobalSettings.*` UserDefaults).
//
//  The tab view sizes the window to each tab's content automatically (the
//  `.toolbar` tab style resizes the window to fit on tab switch), giving the
//  familiar System Settings feel without a fixed-content height.
//

import AppKit
import KataGoUICore

@MainActor
final class SettingsWindowController: NSWindowController {

    private let settingsViewController: SettingsViewController

    /// Builds the Settings window around a `SettingsViewController` bound to the
    /// shared `GameSession` (for its `gobanState`).
    init(session: GameSession) {
        settingsViewController = SettingsViewController(session: session)

        // Non-resizable, prefs-style: titled + closable + miniaturizable but no
        // `.resizable` — the `.toolbar` tab controller resizes the window to fit
        // the selected tab, the standard macOS preferences behaviour.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = settingsViewController
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
