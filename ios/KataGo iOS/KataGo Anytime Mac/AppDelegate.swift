import AppKit
import AppIntents
import SwiftData
import KataGoUICore

/// Explicit entry point. A bare `@main` on an `NSApplicationDelegate` class does
/// NOT install that instance as `NSApp.delegate` (unlike SwiftUI's `App`), so
/// `applicationDidFinishLaunching(_:)` would never fire and the app would launch
/// to an empty process with no window or engine. Wiring the delegate explicitly
/// before `NSApplicationMain` fixes that.
@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        // If the File-menu "Re-sync from iCloud…" command requested a reset, delete
        // the local SwiftData/CloudKit store HERE — after the app object exists (so
        // the reset can wait for the previous instance to exit) but BEFORE
        // `AppDelegate()` constructs its eager `modelContainer` — so the fresh
        // container re-imports the whole zone from CloudKit. No-op (returns early)
        // unless the flag is set, so it is safe to call on every launch.
        CloudKitStoreReset.performIfRequested()
        let delegate = AppDelegate()
        app.delegate = delegate
        // Keep the delegate alive for the lifetime of the run loop.
        withExtendedLifetime(delegate) {
            _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?
    let modelContainer = SharedModelContainer.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerCoreMLBridge()  // from the copied CoreMLComputeHandleLoader.swift
        registerDownloadedHasher(BinFileHasher.shared.identityForDownloadedFile)

        // Register the App Shortcuts provider (P6-T9). Mirrors the iOS
        // `KataGo_iOSApp.init`: `updateAppShortcutParameters()` refreshes the
        // system's snapshot of the shortcut phrases/parameters so the Shortcuts
        // app and Spotlight pick them up. `KataGoShortcuts` is shared with the
        // iOS target (same files, two targets).
        KataGoShortcuts.updateAppShortcutParameters()

        // Wire the engine-launch status updater seam so the board pane (P5-T9)
        // can show a secondary caption during cache-miss CoreML compiles. Created
        // BEFORE the window controller and passed in, exactly as the iOS
        // `KataGo_iOSApp.init` does (the local `status` is captured in the
        // updater closure; the same closure-capture pattern, since at this point
        // the controller does not yet exist). `registerEngineLaunchStatusUpdater`
        // is the Mac target's own `CoreMLComputeHandleLoader` seam — the same
        // file that already vends `registerCoreMLBridge`/`registerDownloadedHasher`.
        let engineLaunchStatus = EngineLaunchStatus()
        registerEngineLaunchStatusUpdater { phase in
            await MainActor.run { engineLaunchStatus.phase = phase }
        }

        NSApp.mainMenu = buildMainMenu()
        let wc = MainWindowController(modelContainer: modelContainer,
                                      engineLaunchStatus: engineLaunchStatus)
        wc.showWindow(nil)
        windowController = wc
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        wc.restoreWindowStateOnLaunch()
        // Ensure keyboard focus lands on the board, not the sidebar search field,
        // so the LizzieYzy shortcuts (Space / `,` / `P`) work from launch. The
        // window's `initialFirstResponder` (set in the controller's `init`)
        // normally handles this; this is the guarded fallback for the case where
        // the search field still grabbed focus when the window became key.
        wc.focusBoardOnLaunch()

        // Proactive identity hygiene (Issue 2): assign stable, unique, non-nil
        // uuids to CloudKit-synced records so the widget's AppIntents round-trip
        // can resolve a configured game by id. The in-app game list uses a plain
        // @Query and never repairs, so without this nil/duplicate uuids stay
        // unselectable in the widget. Main-app only + idempotent; deferred so it
        // never blocks launch.
        Task { @MainActor in
            do {
                try GameEntityQuery.repairStoredIdentities(container: modelContainer)
            } catch {
                NSLog("repairStoredIdentities failed: \(error)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Backstop: kill the engine child on app quit even if `windowWillClose`
    /// didn't fire (it may not on ⌘Q). The child also self-exits when the app's
    /// pipe fds close (stdin EOF / SIGPIPE), but this terminates it immediately
    /// and deterministically. `terminate()` is bounded, so quit never hangs.
    func applicationWillTerminate(_ notification: Notification) {
        windowController?.shutdownEngineForAppTermination()
    }

    /// Finder / system URL open: handles both `.sgf` file imports and
    /// `katago-anytime://open-game?id=<uuid>` deep links from the widget.
    /// Deep-link URLs are routed to `selectGame(byID:)` on the window controller;
    /// everything else falls through to the same `importAndSelect(from:)` path as
    /// the open panel and drag-drop.
    /// `open(urls:)` arrives after `applicationDidFinishLaunching`, so the window
    /// controller is created by the time we're called — but we guard anyway.
    func application(_ application: NSApplication, open urls: [URL]) {
        var remaining: [URL] = []
        for url in urls {
            if let id = GameDeepLink.gameID(from: url) {
                windowController?.selectGame(byID: id)
            } else {
                remaining.append(url)
            }
        }
        if !remaining.isEmpty {
            windowController?.importAndSelect(from: remaining)
        }
    }

    // MARK: - Main Menu

    @MainActor
    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeSubmenu(appMenu()))
        mainMenu.addItem(makeSubmenu(fileMenu()))
        mainMenu.addItem(makeSubmenu(editMenu()))
        mainMenu.addItem(makeSubmenu(gameMenu()))
        mainMenu.addItem(makeSubmenu(viewMenu()))
        mainMenu.addItem(makeSubmenu(navigateMenu()))
        mainMenu.addItem(makeSubmenu(analysisMenu()))

        let windowMenu = windowMenu()
        mainMenu.addItem(makeSubmenu(windowMenu))
        NSApp.windowsMenu = windowMenu

        mainMenu.addItem(makeSubmenu(helpMenu()))
        return mainMenu
    }

    /// Wraps a populated menu in the top-level container item the menu bar expects.
    private func makeSubmenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    @MainActor
    private func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(withTitle: "About \(name)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…",
                     action: Selector(("showSettings:")),
                     keyEquivalent: ",")
        menu.addItem(.separator())

        let hide = menu.addItem(withTitle: "Hide \(name)",
                                action: #selector(NSApplication.hide(_:)),
                                keyEquivalent: "h")
        hide.target = NSApp
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        let showAll = menu.addItem(withTitle: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: "")
        showAll.target = NSApp
        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "Quit \(name)",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "New Game",
                     action: #selector(MainWindowController.newGame(_:)),
                     keyEquivalent: "n")
        menu.addItem(withTitle: "Import…",
                     action: #selector(MainWindowController.importSGF(_:)),
                     keyEquivalent: "o")
        menu.addItem(.separator())
        // Shares the currently-selected game's SGF via the system share sheet
        // (gated on a selection by `validateMenuItem`). Routed through the
        // responder chain to `MainWindowController`.
        menu.addItem(withTitle: "Share…",
                     action: #selector(MainWindowController.shareSelectedGame(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        // Discards the local SwiftData store and re-imports the whole zone from
        // CloudKit on the next launch (`CloudKitStoreReset`). Available in DEBUG
        // *and* RELEASE: DEBUG and TestFlight/App-Store builds share the same
        // CloudKit data, so a wedged/diverged local store can strike either, and
        // both need the recovery path. No key equivalent — it's an infrequent,
        // destructive action and an accidental keystroke must never wipe the store.
        // Routed (target = nil) through the responder chain to `MainWindowController`,
        // which presents the confirmation and relaunch.
        menu.addItem(withTitle: "Re-sync from iCloud…",
                     action: #selector(MainWindowController.resyncLibraryFromICloud(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo",
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo",
                                action: Selector(("redo:")),
                                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut",
                     action: #selector(NSText.cut(_:)),
                     keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")
        menu.addItem(withTitle: "Paste",
                     action: #selector(NSText.paste(_:)),
                     keyEquivalent: "v")
        menu.addItem(withTitle: "Select All",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        menu.addItem(.separator())

        // Library record actions, routed through the responder chain to
        // `MainWindowController` (enabled only when a game is selected, via
        // `validateMenuItem`). Bare ⏎ / ⌫ are NOT used as global menu key
        // equivalents — with an empty modifier mask they would intercept Return
        // and Delete everywhere (e.g. editing the search field), so Return-to-
        // rename and Delete-to-remove are handled contextually by the sidebar
        // table only when it is first responder (see `LibraryTableView`). Here
        // Rename carries no shortcut and Delete uses the standard ⌘⌫.
        menu.addItem(withTitle: "Rename",
                     action: #selector(MainWindowController.renameSelectedGame(_:)),
                     keyEquivalent: "")
        let delete = menu.addItem(withTitle: "Delete",
                                  action: #selector(MainWindowController.deleteSelectedGame(_:)),
                                  keyEquivalent: "\u{8}")
        delete.keyEquivalentModifierMask = [.command]
        return menu
    }

    /// Game menu (iOS spec order: File / Edit / Game / …). Hosts branch-exit and
    /// edit-mode actions. All items carry `target = nil`, so AppKit routes them
    /// through the responder chain to `MainWindowController`; `validateMenuItem`
    /// owns their enable state (and the Lock-Editing checkmark) from the LIVE
    /// `gobanState`.
    private func gameMenu() -> NSMenu {
        let menu = NSMenu(title: "Game")

        // Toggles edit mode (`gobanState.isEditing`) — the same flag the iOS Chart
        // wand / edit affordances drive. `validateMenuItem` sets the checkmark from
        // the live state. ⌘E (E for Edit) — not used by any other global item.
        let lockEditing = menu.addItem(withTitle: "Lock Editing",
                                       action: #selector(MainWindowController.toggleEditing(_:)),
                                       keyEquivalent: "e")
        lockEditing.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())

        // Board-move shortcuts mirroring LizzieYzy: `,` plays the engine's current
        // best move (the top analysis candidate) and `P` passes. Both are BARE keys
        // (no modifier), matching LizzieYzy; they route through the responder chain
        // to `MainWindowController`, which plays them via the same human-move entry
        // the board tap uses. `validateMenuItem` returns false for them while a text
        // control is first responder so the key types instead of playing (the same
        // reason bare ⏎/⌫ are NOT used as global equivalents — see the Edit menu).
        let playBest = menu.addItem(withTitle: "Play Best Move",
                                    action: #selector(MainWindowController.playBestMove(_:)),
                                    keyEquivalent: ",")
        playBest.keyEquivalentModifierMask = []
        let pass = menu.addItem(withTitle: "Pass",
                                action: #selector(MainWindowController.passMove(_:)),
                                keyEquivalent: "p")
        pass.keyEquivalentModifierMask = []
        menu.addItem(.separator())

        // Exits an active branch (the implicit variation entered by playing an
        // off-mainline move). Sets `confirmingBranchDeactivation`, which the
        // window controller's confirmation observer turns into the Replace /
        // Discard chooser sheet. No key equivalent (an infrequent action).
        menu.addItem(withTitle: "Deactivate Branch",
                     action: #selector(MainWindowController.deactivateBranchAction(_:)),
                     keyEquivalent: "")
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let toggleSidebar = menu.addItem(withTitle: "Toggle Sidebar",
                                         action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                         keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]

        let toggleInspector = menu.addItem(withTitle: "Toggle Inspector",
                                           action: #selector(NSSplitViewController.toggleInspector(_:)),
                                           keyEquivalent: "i")
        toggleInspector.keyEquivalentModifierMask = [.command, .control]

        // Inspector tab shortcuts: ⌘1 Chart (chart + moves) · ⌘2 Comments ·
        // ⌘3 Info. The item `tag` (0–2) is the tab index; `selectInspectorTab`
        // routes to the split VC, which expands the Inspector pane first if
        // collapsed. (A bare digit keyEquivalent defaults to the ⌘ modifier.)
        for (index, title) in ["Chart", "Comments", "Info"].enumerated() {
            let item = menu.addItem(withTitle: title,
                                    action: #selector(MainWindowController.selectInspectorTab(_:)),
                                    keyEquivalent: "\(index + 1)")
            item.tag = index
        }
        menu.addItem(.separator())

        // Display toggles routed through the responder chain to
        // `MainWindowController`. No key equivalents — these are infrequent
        // display preferences and bare letters/symbols would risk collisions.
        // Checkmarks (reflecting the live `gobanState` flags) and enable state
        // are set in `MainWindowController.validateMenuItem`. Ownership is NOT
        // here: it lives only in the Analysis menu to avoid duplication.
        menu.addItem(withTitle: "Show Coordinates",
                     action: #selector(MainWindowController.toggleCoordinates(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Show Pass",
                     action: #selector(MainWindowController.togglePass(_:)),
                     keyEquivalent: "")
        // Cycles the board↔book↔hidden visibility (the iOS eye button). A 3-state
        // cycle, so no checkmark — `validateMenuItem` only owns its enable state.
        // No key equivalent (infrequent; bare letters/symbols risk collisions).
        menu.addItem(withTitle: "Toggle Board/Book View",
                     action: #selector(MainWindowController.toggleEyeStatus(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Show Win-Rate Bar",
                     action: #selector(MainWindowController.toggleWinrateBar(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Show Visits per Second",
                     action: #selector(MainWindowController.toggleVisitsPerSecond(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let fullScreen = menu.addItem(withTitle: "Enter Full Screen",
                                      action: #selector(NSWindow.toggleFullScreen(_:)),
                                      keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private func navigateMenu() -> NSMenu {
        let menu = NSMenu(title: "Navigate")

        let back = menu.addItem(withTitle: "Back",
                                action: #selector(MainWindowController.goBackward(_:)),
                                keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        back.keyEquivalentModifierMask = []

        let forward = menu.addItem(withTitle: "Forward",
                                   action: #selector(MainWindowController.goForward(_:)),
                                   keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        forward.keyEquivalentModifierMask = []
        menu.addItem(.separator())

        let first = menu.addItem(withTitle: "First",
                                 action: #selector(MainWindowController.goToStart(_:)),
                                 keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        first.keyEquivalentModifierMask = [.command, .option]

        let last = menu.addItem(withTitle: "Last",
                                action: #selector(MainWindowController.goToEnd(_:)),
                                keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        last.keyEquivalentModifierMask = [.command, .option]
        return menu
    }

    /// Analysis menu. All items carry `target = nil`, so AppKit routes them
    /// through the responder chain to `MainWindowController` (the window controller
    /// sits in the window's responder chain). `MainWindowController.validateMenuItem`
    /// sets each item's checkmark from the LIVE `gobanState.analysisStatus` /
    /// `showOwnership` (re-read every time the menu opens) and its enable state, so
    /// the menu always mirrors the current engine/analysis state. "Show Ownership"
    /// is intentionally placed ONLY here (not in the View menu) to avoid
    /// duplicating the same toggle in two places.
    private func analysisMenu() -> NSMenu {
        let menu = NSMenu(title: "Analysis")

        // Space cycles run → pause → clear (same 3-way machine as the toolbar
        // Analyze button), mirroring LizzieYzy's Space = toggle analysis. BARE key
        // (no modifier); `MainWindowController.validateMenuItem` disables it while a
        // text control is first responder so Space still types normally there (the
        // same reason bare ⏎/⌫ are avoided as global equivalents — see the Edit menu).
        let toggle = menu.addItem(withTitle: "Toggle Analysis",
                                  action: #selector(MainWindowController.toggleAnalysis(_:)),
                                  keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = []
        menu.addItem(.separator())

        menu.addItem(withTitle: "Pause",
                     action: #selector(MainWindowController.pauseAnalysis(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Clear",
                     action: #selector(MainWindowController.clearAnalysis(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Show Ownership",
                     action: #selector(MainWindowController.toggleOwnership(_:)),
                     keyEquivalent: "")
        return menu
    }

    @MainActor
    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        // Opens the native Models window (P5-T7). `target = nil` routes through
        // the responder chain to `MainWindowController.showModelsWindow(_:)`.
        // (P5-T6 adds the toolbar active-model dropdown that opens the same window.)
        menu.addItem(withTitle: "Manage Models…",
                     action: #selector(MainWindowController.showModelsWindow(_:)),
                     keyEquivalent: "")
        // Opens the native Opening Books window. `target = nil` routes through the
        // responder chain to `MainWindowController.showOpeningBooksWindow(_:)`.
        menu.addItem(withTitle: "Manage Opening Books…",
                     action: #selector(MainWindowController.showOpeningBooksWindow(_:)),
                     keyEquivalent: "")
        return menu
    }

    private func helpMenu() -> NSMenu {
        NSMenu(title: "Help")
    }
}

/// Backs the File-menu "Re-sync from iCloud…" command (available in DEBUG *and*
/// RELEASE). The command sets `flagKey` and relaunches; `performIfRequested()`
/// runs at the very top of `AppMain.main()` (before the `ModelContainer` is
/// created) and, if the flag is set, removes the local SwiftData store so the new
/// container re-imports the whole zone from CloudKit.
///
/// It deletes the STORE FILES, not the records, on purpose: deleting records would
/// propagate cloud deletions and wipe the games on every device. The files go to
/// the Trash (recoverable); engine/model data is left untouched.
enum CloudKitStoreReset {
    static let flagKey = "ResyncCloudKitStoreOnLaunch"

    static func performIfRequested() {
        guard UserDefaults.standard.bool(forKey: flagKey) else { return }
        // Clear the flag FIRST so a partial failure can't trap the app in a reset loop,
        // and flush it to disk immediately: the CloudKit re-import that follows can run
        // for minutes, and if the app crashes before this clear is persisted the stale
        // on-disk flag would re-trigger the wipe on the next launch. `synchronize()`
        // makes the clear durable now (symmetric with the set side, which flushes too).
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.synchronize()

        // Clear the App-Group store-ready flag BEFORE wiping the store files: while
        // the store is gone and the app is re-importing from CloudKit, a widget
        // extension that wakes must take the in-memory placeholder, not recreate an
        // empty App-Group store (which would reopen the F11 race). The app re-sets
        // the flag once `SharedModelContainer.shared` has rebuilt the real store.
        SharedModelContainer.clearAppGroupStoreReady()

        // Wait until this is the ONLY running instance before touching the store, so
        // the delete never overlaps a previous instance that still has it open — this
        // restores the verified-good "quit first, then delete" ordering. Bounded so a
        // declined/stuck relaunch can't hang startup (the overlap is benign anyway:
        // unlink detaches the inode and we create a fresh store).
        if let bundleID = Bundle.main.bundleIdentifier {
            var waited = 0.0
            while waited < 5.0,
                  NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
                Thread.sleep(forTimeInterval: 0.1)
                waited += 0.1
            }
        }

        // Wipe the store family from EVERY location it can live (F16): the
        // App-Group container holds the live store post-migration, and the app's
        // own sandbox container holds the pre-App-Group / migration-source copy —
        // both must go or re-sync either no-ops (live store survived) or the stale
        // copy gets re-migrated back next launch. `SharedModelContainer` owns the
        // directory + artifact-name layout so it stays in sync with the store URLs.
        let fileManager = FileManager.default
        let directories = SharedModelContainer.storeResetDirectories()
        var trashedTotal = 0
        for dir in directories {
            // Match the whole SQLite family (default.store, -shm, -wal, -journal, …)
            // by prefix, plus the named sidecars, so a stray sidecar can't survive.
            let entries = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            let targets = SharedModelContainer.storeArtifactNames(in: entries)
            guard !targets.isEmpty else { continue }
            for name in targets {
                let url = dir.appendingPathComponent(name)
                do {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)  // recoverable
                } catch {
                    try? fileManager.removeItem(at: url)  // fall back to permanent removal
                }
            }
            trashedTotal += targets.count
            NSLog("[CloudKitStoreReset] reset store at \(dir.path) — trashed \(targets.count) artifact(s): \(targets)")
        }
        NSLog("[CloudKitStoreReset] re-importing from iCloud — trashed \(trashedTotal) artifact(s) across \(directories.count) location(s)")
    }
}
