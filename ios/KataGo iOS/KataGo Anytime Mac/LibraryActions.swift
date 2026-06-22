import AppKit
import SwiftData
import UniformTypeIdentifiers
import KataGoUICore
import WidgetKit

/// Library CRUD actions (New / Clone / Clone Current Position / Rename / Delete).
///
/// These live in an `extension MainWindowController` rather than the sidebar VC
/// so they're reachable through the responder chain: the toolbar `New` item and
/// the File/Edit menu items use `target = nil`, so AppKit walks the responder
/// chain (window → window controller) to find these `@objc` actions. The
/// context-menu entries call the explicit-`GameRecord` methods directly through
/// a weak back-reference held by the sidebar VC.
///
/// Every mutating op finishes with `libraryStore.refetch()` so the sidebar table
/// reflects the change immediately (`LibraryStore`'s store-change observers —
/// `.NSPersistentStoreRemoteChange` for CloudKit arrivals from other devices and
/// `ModelContext.didSave` for local autosaves — are the secondary net). All work
/// runs on the main thread, so — unlike the iOS `safelyDelete` async wrap — a
/// direct `modelContext.delete` is correct here (no SwiftData background-context
/// race to dodge).
extension MainWindowController: LibraryActionsDelegate {
    /// The shared `ModelContext` for inserts/deletes (the container's main context).
    private var modelContext: ModelContext { modelContainer.mainContext }

    // MARK: - New

    /// File ▸ New Game (⌘N) and the toolbar `New` item: create a fresh default
    /// 19×19 game, insert it, switch the board to it, and refresh the sidebar.
    @objc func newGame(_ sender: Any?) {
        let new = GameRecord.createGameRecord()
        modelContext.insert(new)
        selectGame(new)
        libraryStore.refetch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Clone

    /// Deep-copies `game` (full move history) into a new record and selects it.
    /// Takes an explicit record because the context menu clones the right-clicked
    /// row, which isn't necessarily the currently-loaded game.
    func cloneGame(_ game: GameRecord) {
        let clone = game.clone()
        modelContext.insert(clone)
        selectGame(clone)
        libraryStore.refetch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Clones `game` truncated to the position currently on the board. Only
    /// meaningful for the currently-loaded game (it reads the live `GobanState`
    /// branch/index), which the context menu enforces by enabling this item only
    /// for the loaded row.
    func cloneCurrentPosition(of game: GameRecord) {
        let clone = session.gobanState.cloneCurrentPosition(gameRecord: game)
        modelContext.insert(clone)
        selectGame(clone)
        libraryStore.refetch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Rename

    /// Prompts for a new name via an `NSAlert` with a text-field accessory
    /// pre-filled with the current name. On OK with non-empty trimmed text the
    /// record's `name` is updated (assigning a stored property is fine — only
    /// the `@Model` schema is frozen) and the sidebar refreshes so the row label
    /// updates.
    func renameGame(_ game: GameRecord) {
        let alert = NSAlert()
        alert.messageText = "Rename Game"
        alert.informativeText = "Enter a new name for this game."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = game.name
        alert.accessoryView = textField
        // Focus the text field so the user can type/replace immediately.
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }

        game.name = newName
        libraryStore.refetch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Delete

    /// Confirms (destructive) then deletes `game`. If it's the currently-loaded
    /// game, the board is switched to a replacement *before* the delete — while
    /// `game` is still a live object — so `selectGame` → `GobanState.loadGame`
    /// never reads a deleted record's `concreteConfig` as its `previous`. (iOS
    /// sidesteps this by routing the deleted selection through `nil`.) The
    /// replacement is the first other record in the *unfiltered* store, or a
    /// freshly-created default when no other game exists, so the board never
    /// lingers on a deleted game and an active search filter can't make us
    /// fabricate a phantom default. Deleting a non-loaded game leaves the
    /// selection/board untouched.
    func deleteGame(_ game: GameRecord) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(game.name)”?"
        alert.informativeText = "This game will be permanently deleted. This cannot be undone."
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if game === navigationContext.selectedGameRecord {
            if let replacement = libraryStore.allGames.first(where: { $0 !== game }) {
                selectGame(replacement)
            } else {
                let fresh = GameRecord.createGameRecord()
                modelContext.insert(fresh)
                selectGame(fresh)
            }
        }

        modelContext.delete(game)
        libraryStore.refetch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Import

    /// Imports one or more SGF files and switches the board to the last one.
    ///
    /// Shared by every import entry point (open panel, drag-and-drop, Finder
    /// deep-link) so they behave identically. For each URL we reuse the package's
    /// `importGameRecord(from:in:)` — which de-duplicates against the store, so a
    /// re-imported game returns `isNew == false` and is *selected without being
    /// re-inserted*. URLs that fail to parse (nil result) are skipped, not fatal,
    /// so one bad file can't abort a multi-file drop. We select the LAST imported
    /// record (matching iOS, where each import overwrites the selection) and
    /// refetch once after the batch so the sidebar reflects every new row.
    func importAndSelect(from urls: [URL]) {
        var lastImported: GameRecord?
        for url in urls {
            guard let result = GameRecord.importGameRecord(from: url, in: modelContext) else { continue }
            if result.isNew {
                modelContext.insert(result.gameRecord)
            }
            lastImported = result.gameRecord
        }
        guard let lastImported else { return }
        selectGame(lastImported)
        libraryStore.refetch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// File ▸ Import… (⌘O) and the toolbar `Import` item: present an open panel
    /// for `.sgf`/`.text` files (multi-select) and import the chosen files. The
    /// panel is shown as a sheet anchored to the window so it reads as belonging
    /// to this document. App-Sandbox file access is granted through Powerbox by
    /// the user's selection — the existing `files.user-selected.read-write`
    /// entitlement covers the subsequent read in `readSgfContent`.
    @objc func importSGF(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "sgf"), .text].compactMap { $0 }

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.importAndSelect(from: panel.urls)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    // MARK: - Share

    /// Presents `NSSharingServicePicker` for `game`'s SGF. The shareable item is a
    /// temp `.sgf` file written from the persisted `game.sgf` string (the same
    /// payload iOS's `TransferableSgf` exports), named after the game so the
    /// receiver sees a meaningful filename. A write failure is non-fatal — we just
    /// don't show the picker. When `view` is nil (menu-bar path) we anchor to the
    /// window's content view so the popover still has something to attach to.
    func shareGame(_ game: GameRecord, from view: NSView?, rect: NSRect) {
        let sanitized = sanitizedFileName(game.name)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(sanitized)
            .appendingPathExtension("sgf")

        do {
            try game.sgf.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Share failed: could not write SGF to temp file: \(error)")
            return
        }

        let anchorView = view ?? window?.contentView
        guard let anchorView else { return }
        let anchorRect = view != nil ? rect : anchorView.bounds

        let picker = NSSharingServicePicker(items: [fileURL])
        picker.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
    }

    /// Strips path separators / control characters and collapses an empty result
    /// to a stable default so the temp filename is always valid.
    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "KataGoAnytime" : cleaned
    }

    // MARK: - Menu-bar wrappers (operate on the selected game)

    /// Edit ▸ Rename (⏎): rename the currently-selected library game.
    @objc func renameSelectedGame(_ sender: Any?) {
        guard let game = navigationContext.selectedGameRecord else { return }
        renameGame(game)
    }

    /// Edit ▸ Delete (⌫): delete the currently-selected library game.
    @objc func deleteSelectedGame(_ sender: Any?) {
        guard let game = navigationContext.selectedGameRecord else { return }
        deleteGame(game)
    }

    /// File ▸ Share…: share the currently-selected library game, anchored to the
    /// window's content view (no specific row to point at from the menu bar).
    @objc func shareSelectedGame(_ sender: Any?) {
        guard let game = navigationContext.selectedGameRecord else { return }
        shareGame(game, from: nil, rect: .zero)
    }

    // MARK: - Re-sync from iCloud

    /// File ▸ "Re-sync from iCloud…": discard the local SwiftData store and let
    /// `NSPersistentCloudKitContainer` re-import the whole zone from CloudKit on the
    /// next launch. Confirms first (it is destructive — local-only changes are lost),
    /// arms the `CloudKitStoreReset` flag, then relaunches; the new instance's
    /// `CloudKitStoreReset.performIfRequested()` (top of `AppMain.main`, before the
    /// `ModelContainer` is built) waits for this instance to exit, then trashes the
    /// store files. It deletes FILES, never records — record deletion would
    /// propagate cloud deletes and wipe every device.
    ///
    /// Available in DEBUG and RELEASE: both build configs share the same CloudKit
    /// data, so a wedged/diverged local store can strike either and both need the
    /// recovery path.
    @objc func resyncLibraryFromICloud(_ sender: Any?) {
        // Re-sync only restores what is actually in iCloud. With no iCloud account
        // there is nothing to re-import, so wiping the local store would be pure
        // data loss — make the safe choice (Cancel) the default and force an
        // explicit opt-in to proceed. `ubiquityIdentityToken` is a cheap, synchronous
        // proxy for "signed into iCloud" (non-nil iff an iCloud account is present).
        let signedIntoICloud = FileManager.default.ubiquityIdentityToken != nil

        let alert = NSAlert()
        alert.messageText = "Re-sync games from iCloud?"
        if signedIntoICloud {
            alert.informativeText = "This discards the local database — including any changes not yet uploaded to iCloud — and re-downloads everything from CloudKit. The app will relaunch."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Re-sync & Relaunch")   // first button == default (⏎)
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else {
            alert.informativeText = "You don’t appear to be signed into iCloud. Re-syncing now will erase the local database — including games not yet uploaded — and there may be nothing in iCloud to restore them from. Sign into iCloud first, or continue only if you’re sure."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Cancel")               // first button == default (⏎) → safe
            alert.addButton(withTitle: "Erase & Re-sync Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }

        UserDefaults.standard.set(true, forKey: CloudKitStoreReset.flagKey)
        // Force the flag to disk before spawning the new instance: it reads the flag
        // at startup, and `set` only schedules an async write — `synchronize()` makes
        // the cross-process handoff deterministic so the new process can't miss it.
        UserDefaults.standard.synchronize()

        // Spawn a genuinely new instance, then terminate this one; the new instance's
        // `CloudKitStoreReset.performIfRequested()` waits for this one to exit before
        // it deletes the store. `allowsRunningApplicationSubstitution = false` forces
        // a real new process — without it LaunchServices may just re-activate this
        // (dying) instance, so the relaunch would silently fail.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    // Launch declined: keep this instance alive (don't strand a quit
                    // app) and clear the flag so the next ordinary launch doesn't
                    // surprise-wipe the store. Surface the failure to the user.
                    UserDefaults.standard.removeObject(forKey: CloudKitStoreReset.flagKey)
                    NSLog("[CloudKitStoreReset] relaunch failed: \(error.localizedDescription) — reset cancelled")
                    let failure = NSAlert()
                    failure.messageText = "Couldn’t relaunch to re-sync"
                    failure.informativeText = "The app couldn’t start a new instance, so re-sync was cancelled and your local games are unchanged. Please quit and reopen the app, then try again."
                    failure.alertStyle = .warning
                    failure.addButton(withTitle: "OK")
                    failure.runModal()
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
