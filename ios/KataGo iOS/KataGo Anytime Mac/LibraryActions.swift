import AppKit
import SwiftData
import UniformTypeIdentifiers
import KataGoUICore

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
/// reflects the change immediately (the `ModelContext.didSave` observer is only a
/// secondary net for CloudKit-synced arrivals). All work runs on the main thread,
/// so — unlike the iOS `safelyDelete` async wrap — a direct `modelContext.delete`
/// is correct here (no SwiftData background-context race to dodge).
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
}
