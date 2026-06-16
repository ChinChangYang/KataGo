//
//  ModelsWindowController.swift
//  KataGo Anytime Mac
//
//  P5-T7: the native "Models" window. A resizable `NSWindow` hosting
//  `ModelsViewController` — a view-based `NSTableView` of the neural-net catalog
//  with per-row download / delete / set-active and a backend-config detail pane
//  (P5-T8). It is the AppKit analogue of the iOS `ModelPickerView` +
//  `ModelDetailView` + `BackendConfigSheet`.
//
//  The window controller is created lazily and retained by
//  `MainWindowController.showModelsWindow(_:)` (reached through the responder
//  chain from the Window-menu "Manage Models…" item). It hands the
//  `ModelsViewController` two things from the main window controller:
//    • `currentModelTitle` — to draw the "Active" badge on the matching row;
//    • `onSetActive` — a closure routed to `MainWindowController.relaunch(model:)`
//      so selecting a downloaded model switches the active net + relaunches the
//      in-process engine (P5-S0).
//
//  On close, the view controller cancels every in-flight `Downloader` (see
//  `ModelsViewController.windowWillClose`), so a dismissed window never leaves a
//  background download running.
//

import AppKit
import KataGoUICore

@MainActor
final class ModelsWindowController: NSWindowController, NSWindowDelegate {

    private let modelsViewController: ModelsViewController

    /// Builds the Models window around a `ModelsViewController`.
    ///
    /// - Parameters:
    ///   - currentModelTitle: title of the currently-active model (drives the
    ///     "Active" badge). A closure so the badge re-reads the live selection
    ///     each time the table reloads (e.g. after a set-active relaunch).
    ///   - onSetActive: invoked when the user chooses a downloaded model as the
    ///     active net; the caller routes it to `relaunch(model:)`.
    init(currentModelTitle: @escaping () -> String,
         onSetActive: @escaping (NeuralNetworkModel) -> Void) {
        modelsViewController = ModelsViewController(
            currentModelTitle: currentModelTitle,
            onSetActive: onSetActive
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Models"
        window.contentViewController = modelsViewController
        window.setContentSize(NSSize(width: 720, height: 460))
        window.minSize = NSSize(width: 620, height: 360)
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - NSWindowDelegate

    /// Cancels any in-flight downloads before the window goes away so a dismissed
    /// Models window never leaves a background download running.
    func windowWillClose(_ notification: Notification) {
        modelsViewController.cancelAllDownloads()
    }
}
