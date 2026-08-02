import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import KataGoUICore
import GobanRecogKit
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

    /// File ▸ New Game (⌘N) and the toolbar `New` item: present the New Game
    /// setup sheet (Name / Board size / Komi / Rules). On Create it builds the
    /// chosen settings into an SGF and runs the same insert → select → refetch →
    /// reload tail as before; on Cancel nothing changes. The automatic,
    /// non-interactive `createGameRecord()` paths (first-launch empty store,
    /// last-game delete fallback) intentionally stay dialog-free.
    @objc func newGame(_ sender: Any?) {
        let dialog = NewGameViewController(maxBoardLength: launchedMaxBoardLength) { [weak self] sgf, name in
            guard let self else { return }
            let new = GameRecord.createGameRecord(sgf: sgf, name: name)
            self.modelContext.insert(new)
            self.selectGame(new)
            self.libraryStore.refetch()
            WidgetCenter.shared.reloadAllTimelines()
        }
        contentViewController?.presentAsSheet(dialog)
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

    /// Public entry for every delete path that can target ANY row — the
    /// sidebar's right-click context menu and its bare-⌫ key
    /// (`LibrarySidebarViewController`) — not just the Edit-menu action
    /// (`deleteSelectedGame`, which already resolves its own draft before
    /// calling `performDeleteGame` directly). Deleting some other row than
    /// the one being edited is not an exit and proceeds untouched; deleting
    /// the row a draft stands for resolves it first, same as
    /// `deleteSelectedGame` — otherwise a right-click Delete on the game
    /// you're actively editing would strand the draft on a tombstone with no
    /// chance to save.
    func deleteGame(_ game: GameRecord) {
        guard draftController.resolvedRecord(navigationContext.selectedGameRecord) === game
        else {
            performDeleteGame(game)
            return
        }
        resolveDraft(for: .deleteOrigin) { [weak self] in
            self?.performDeleteGame(game)
        }
    }

    /// Confirms (destructive) then deletes `game`. If it's the currently-loaded
    /// game, the board is switched to a replacement *before* the delete — while
    /// `game` is still a live object — so `selectGame` → `GobanState.loadGame`
    /// never reads a deleted record's `concreteConfig` as its `previous`. (iOS
    /// sidesteps this by routing the deleted selection through `nil`.) The
    /// replacement is the first other record in the *unfiltered* store, or a
    /// freshly-created default when no other game exists, so the board never
    /// lingers on a deleted game and an active search filter can't make us
    /// fabricate a phantom default. Deleting a non-loaded game leaves the
    /// selection/board untouched. Only reached through the `deleteGame(_:)`
    /// chokepoint above (or `deleteSelectedGame`'s own resolve), which
    /// resolves an open draft on `game` first.
    private func performDeleteGame(_ game: GameRecord) {
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

    /// Imports one or more SGF files (and/or board images) and switches the board
    /// to the last SGF one.
    ///
    /// Shared by every import entry point (open panel, drag-and-drop, Finder
    /// deep-link / "Open With") so they behave identically. Each URL is branched
    /// by content type BEFORE the SGF path's UTF-8 read: image bytes are binary
    /// and would fail silently when decoded as UTF-8 by `readSgfContent`, so an
    /// image routes to the photo-import preview sheet (recognition + confirm)
    /// instead. For SGF/text URLs we reuse the package's `importGameRecord(from:in:)`
    /// — which de-duplicates against the store, so a re-imported game returns
    /// `isNew == false` and is *selected without being re-inserted*. URLs that
    /// fail to parse (nil result) are skipped, not fatal, so one bad file can't
    /// abort a multi-file drop. We select the LAST imported SGF record (matching
    /// iOS, where each import overwrites the selection) and refetch once after the
    /// batch so the sidebar reflects every new row.
    ///
    /// A board image opens the recognition sheet, which is modal — only one board
    /// can be confirmed at a time — so if several images are selected we present
    /// the first that decodes and ignore the rest. Any SGF/text files in the same
    /// batch are still imported normally before the sheet appears.
    func importAndSelect(from urls: [URL]) {
        var lastImported: GameRecord?
        var pendingImage: (data: Data, name: String)?
        for url in urls {
            if let imageData = imageDataIfImage(at: url) {
                if pendingImage == nil {
                    pendingImage = (imageData, url.deletingPathExtension().lastPathComponent)
                }
                continue
            }
            guard let result = GameRecord.importGameRecord(from: url, in: modelContext) else { continue }
            if result.isNew {
                modelContext.insert(result.gameRecord)
            }
            lastImported = result.gameRecord
        }
        if let lastImported {
            selectGame(lastImported)
            libraryStore.refetch()
            WidgetCenter.shared.reloadAllTimelines()
        }
        if let pendingImage {
            presentPhotoImport(imageData: pendingImage.data, name: pendingImage.name)
        }
    }

    /// If `file` is an image, reads and returns its bytes inside a
    /// security-scoped access (mirroring the SGF read); otherwise nil. macOS
    /// open-panel / Finder-open URLs are Powerbox-scoped, so the read must run
    /// inside `startAccessingSecurityScopedResource()`.
    private func imageDataIfImage(at file: URL) -> Data? {
        let contentType = (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: file.pathExtension)
        guard let contentType, contentType.conforms(to: .image) else { return nil }

        let hasSecurityAccess = file.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityAccess {
                file.stopAccessingSecurityScopedResource()
            }
        }
        return try? Data(contentsOf: file)
    }

    /// Hosts the shared `PhotoImportSheet` (GobanRecogKit) in an
    /// `NSHostingController` and presents it as a sheet on the board pane.
    /// Recognition runs IN-PROCESS inside the sheet (a GobanRecogKit call, not a
    /// GTP command to the engine subprocess). On confirm the synthesized SGF flows
    /// through the SAME `importGameRecord(sgf:name:in:)` seam the SGF path uses.
    ///
    /// SwiftUI's `\.dismiss` can't reach an `NSHostingController` presented via
    /// `presentAsSheet`, so the in-body Cancel/Import buttons drive AppKit
    /// dismissal through the `dismissSheet` closure (the `exportGameGif` /
    /// `showDeepReport` idiom). `navigationTitle` likewise never reaches the
    /// sheet window, so the title is set on the window directly (async — the
    /// sheet window may not exist until `presentAsSheet` finishes).
    private func presentPhotoImport(imageData: Data, name: String) {
        var dismissSheet: () -> Void = {}
        let root = PhotoImportSheet(
            imageData: imageData,
            suggestedName: name,
            onImport: { [weak self] sgf, importName in
                self?.importAndSelect(sgf: sgf, name: importName)
                dismissSheet()
            },
            onCancel: { dismissSheet() }
        )
        // Sized for the grid phase, where the photo is the content: at the old
        // 420x600 it rendered about 233x310. 700 rather than more keeps the
        // sheet inside the 1100x720 default main window. The preview phase
        // caps its own width, so it is unaffected.
        .frame(minWidth: 560, minHeight: 700)
        let hosting = NSHostingController(rootView: root)
        dismissSheet = { [weak hosting] in
            guard let hosting else { return }
            if let presenting = hosting.presentingViewController {
                presenting.dismiss(hosting)
            } else {
                hosting.dismiss(nil)
            }
        }
        contentViewController?.presentAsSheet(hosting)
        DispatchQueue.main.async { [weak hosting] in
            hosting?.view.window?.title = "Import from Photo"
        }
    }

    /// Safari-extension hand-off consumer: import every SGF spooled into the
    /// App Group (oldest first), select the one the `import-sgf` deep link
    /// names (or the last imported), then delete the spool files. Mirrors the
    /// iOS drain in GameSplitView; on macOS the only spool writer is the
    /// Safari web extension's "Open in KataGo Anytime".
    func drainHandoffSpool(preferring fileName: String?) {
        guard let directory = GameDeepLink.messagesHandoffDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let spooled = files
            .filter { $0.pathExtension == "sgf" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return dateA < dateB
            }
        var selected: GameRecord?
        for file in spooled {
            // Prefer the game's own identity — the Safari extension writes the
            // page title into GN before spooling, so a hand-off arrives named
            // rather than as another indistinguishable "Web Game" row.
            if let sgf = try? String(contentsOf: file, encoding: .utf8),
               let result = GameRecord.importGameRecord(
                   sgf: sgf,
                   name: SgfGameName.derive(fromSgf: sgf) ?? "Web Game",
                   in: modelContext) {
                if result.isNew {
                    modelContext.insert(result.gameRecord)
                }
                if selected == nil || fileName == nil || file.lastPathComponent == fileName {
                    selected = result.gameRecord
                }
            }
            try? FileManager.default.removeItem(at: file)
        }
        if let selected {
            selectGame(selected)
            libraryStore.refetch()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Confirm seam for the photo-import sheet: creates (or de-dups to) a game
    /// from the recognized SGF and selects it, reusing the exact same
    /// insert/refetch/select/widget-reload sequence as the file path.
    private func importAndSelect(sgf: String, name: String) {
        guard let result = GameRecord.importGameRecord(sgf: sgf, name: name, in: modelContext) else { return }
        if result.isNew {
            modelContext.insert(result.gameRecord)
        }
        selectGame(result.gameRecord)
        libraryStore.refetch()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// File ▸ Import… (⌘O) and the toolbar `Import` item: present an open panel
    /// for `.sgf`/`.text` files and board images (multi-select) and import the
    /// chosen files. The panel is shown as a sheet anchored to the window so it
    /// reads as belonging to this document. App-Sandbox file access is granted
    /// through Powerbox by the user's selection — the existing
    /// `files.user-selected.read-write` entitlement covers the subsequent read in
    /// `readSgfContent` (SGF) and `imageDataIfImage` (board photos); no new
    /// entitlement is required.
    @objc func importSGF(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "sgf"), .text, .image].compactMap { $0 }

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

    /// Edit ▸ Delete (⌫): delete the currently-selected library game. Resolves
    /// an unsaved draft first — deleting the record a draft is editing would
    /// otherwise strand the draft on a tombstone. Resolves straight to
    /// `performDeleteGame` rather than through `deleteGame(_:)`'s own gate:
    /// `navigationContext.selectedGameRecord` here is always the game on
    /// screen, so the draft check would just repeat this same resolution.
    @objc func deleteSelectedGame(_ sender: Any?) {
        guard let game = draftController.resolvedRecord(
            navigationContext.selectedGameRecord) else { return }
        resolveDraft(for: .deleteOrigin) { [weak self] in
            self?.performDeleteGame(game)
        }
    }

    /// File ▸ Share…: share the currently-selected library game, anchored to the
    /// window's content view (no specific row to point at from the menu bar).
    @objc func shareSelectedGame(_ sender: Any?) {
        guard let game = navigationContext.selectedGameRecord else { return }
        shareGame(game, from: nil, rect: .zero)
    }

    // MARK: - Draft identity

    func resolvedStoredRecord(_ record: GameRecord?) -> GameRecord? {
        draftController.resolvedRecord(record)
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
