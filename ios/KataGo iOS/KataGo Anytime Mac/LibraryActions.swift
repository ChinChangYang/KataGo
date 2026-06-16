import AppKit
import SwiftData
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
}
