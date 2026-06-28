//
//  OpeningBooksWindowController.swift
//  KataGo Anytime Mac
//
//  The native "Opening Books" window: a resizable NSWindow hosting
//  `OpeningBooksViewController` — a table of the opening-book catalog (6x6...9x9)
//  with per-row download / delete. The AppKit analogue of the iOS
//  `OpeningBookPickerView` + `OpeningBookDetailView`.
//
//  Created lazily and retained by `MainWindowController.showOpeningBooksWindow(_:)`
//  (reached through the responder chain from the Window-menu "Manage Opening
//  Books…" item). It hands the view controller an `onBooksChanged` closure routed
//  to `MainWindowController` so a freshly downloaded/deleted book re-evaluates the
//  active game's book load + eye state.
//
//  On close it cancels every in-flight download (see
//  `OpeningBooksViewController.cancelAllDownloads`), so a dismissed window never
//  leaves a background download running.
//

import AppKit
import KataGoUICore

@MainActor
final class OpeningBooksWindowController: NSWindowController, NSWindowDelegate {

    private let booksViewController: OpeningBooksViewController

    init(onBooksChanged: @escaping () -> Void) {
        booksViewController = OpeningBooksViewController(onBooksChanged: onBooksChanged)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Opening Books"
        window.contentViewController = booksViewController
        window.setContentSize(NSSize(width: 720, height: 460))
        window.minSize = NSSize(width: 600, height: 340)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        booksViewController.cancelAllDownloads()
    }
}
