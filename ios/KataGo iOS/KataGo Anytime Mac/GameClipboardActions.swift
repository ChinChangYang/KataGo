//
//  GameClipboardActions.swift
//  KataGo Anytime Mac
//
//  Edit ▸ Copy (⌘C) and Edit ▸ Paste (⌘V) for whole games, as SGF text.
//
//  These live in an `extension MainWindowController` for the same reason the
//  library CRUD actions do (see `LibraryActions.swift`): the Edit-menu items
//  carry `target = nil`, so AppKit walks the responder chain — window → window
//  controller — to find them.
//
//  WHY THE STANDARD `copy:` / `paste:` SELECTORS, not new ones: the Edit menu
//  already binds ⌘C/⌘V to them (`AppDelegate.editMenu()`), and the responder
//  chain then gives us the behavior we want for free. A focused text control's
//  field editor is EARLIER in the chain and implements both, so the search
//  field, the rename sheet, the comment editor and the config editor keep
//  ordinary text copy/paste; the window controller is only reached when nothing
//  text-like has focus, i.e. when the board or the game list is where the user
//  is working. Adding separate items with their own ⌘C/⌘V would instead create
//  duplicate key equivalents that AppKit resolves by menu order — which would
//  break text copy/paste outright.
//
//  Corollary worth knowing before someone files it as a bug: when a text view
//  IS first responder with NOTHING selected, it validates `copy:` as false and
//  AppKit disables the item rather than continuing down the chain. So ⌘C is
//  inert while a text field is focused, even with no selection. That is
//  standard macOS, not a gap here.
//

import AppKit
import KataGoAnalysisKit
import KataGoUICore

extension MainWindowController {

    // MARK: - Copy

    /// Edit ▸ Copy (⌘C): put the game currently ON THE BOARD on the clipboard
    /// as SGF text.
    ///
    /// `getSgf`, not `gameRecord.sgf`, deliberately. While a branch is active it
    /// returns `branchSgf`, so ⌘C captures the variation on screen and ⌘V can
    /// then promote it to a real library game; and while a draft is open
    /// `selectedGameRecord` IS the detached draft, so unsaved edits are copied
    /// too. (File ▸ Share… intentionally differs — it sends the SAVED game.)
    ///
    /// `@objc(copy:)` rather than naming the method `copy`: the selector has to
    /// be `copy:` to match the menu item, but `NSObject` already vends `copy()`,
    /// and overloading that inherited name by arity inside a 4000-line type
    /// invites confusion. The explicit selector keeps the Swift name greppable
    /// while `#selector(copyGameSgf(_:)) == Selector("copy:")`.
    ///
    /// Plain `.string` only — that is what every other Go program (CGoban,
    /// Sabaki, OGS) reads, and it matches the "Copy coordinate" item in
    /// `MacBoardInteractionLayer`. Copy touches no engine, no draft and no
    /// store, so it cannot fail.
    @objc(copy:) func copyGameSgf(_ sender: Any?) {
        guard let sgf = session.gobanState.getSgf(
            gameRecord: navigationContext.selectedGameRecord) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sgf, forType: .string)
    }

    // MARK: - Paste

    /// Edit ▸ Paste (⌘V): create a game from the clipboard's SGF.
    ///
    /// ALWAYS creates one, even when an identical SGF is already in the library
    /// — see `createAndSelect`. Every way this can end is visible: a new game
    /// appears and opens, or an alert says why not. Nothing silently does
    /// nothing.
    ///
    /// This is where the clipboard is READ, and that is not an accident.
    /// macOS 26 alerts the user when an app reads the general pasteboard
    /// outside "user input on a paste-related UI element", so the enablement
    /// check in `validateMenuItem` only asks whether the pasteboard OFFERS text
    /// (a type query) and every content check happens here, inside the paste
    /// action itself, which is exempt. Never move this read into validation.
    @objc(paste:) func pasteGameSgf(_ sender: Any?) {
        guard let pasted = PastedSgf.scan(clipboardText()) else {
            presentPasteFailureAlert(
                "The clipboard doesn’t contain a game record (SGF).")
            return
        }
        guard pasted.fits(maxBoardLength: launchedMaxBoardLength) else {
            presentPasteFailureAlert(
                "This game is \(pasted.boardWidth)×\(pasted.boardHeight), "
                + "which is larger than the \(launchedMaxBoardLength)×\(launchedMaxBoardLength) "
                + "board the running engine was started for.\n\n"
                + "Raise Max Board Size in Manage Models, then paste again.")
            return
        }

        // The draft prompt runs BEFORE anything is inserted, so Cancel leaves
        // the library byte-for-byte as it was — no orphan row, no selection
        // change. (Going the other way round, as ⌘O does, would strand an
        // inserted record when the user cancels.) `resolveDraft` closes the
        // draft on both Save and Discard, so the `selectGame` inside
        // `importAndSelect` finds `.proceed` and cannot prompt a second time.
        // Same shape as `LibraryActions.newGame`.
        resolveDraft(for: .switchGame) { [weak self] in
            guard let self else { return }
            // A pasted SGF has no filename to fall back on, so the game's own
            // identity properties are the only name source — the same
            // derivation the Safari hand-off drain uses.
            //
            // The fallback is "Pasted Game", not `GameRecord.defaultName`
            // ("New Game"), and it is not rare: this app's own `printsgf`
            // emits `PB[]PW[]` with no `GN`, so copying a game here and
            // pasting it back always lands on it. "New Game" would label a
            // 43-move paste exactly like an empty board from ⌘N. Follows the
            // per-source literals the other import drains use ("Web Game",
            // "iMessage Game").
            let name = SgfGameName.derive(fromSgf: pasted.sgf) ?? "Pasted Game"
            if !self.createAndSelect(sgf: pasted.sgf, name: name) {
                // Either the C++ parser rejected an SGF the cheap scan
                // accepted, or the parsed board turned out to be over the
                // engine's cap (a multi-game collection can read differently
                // to the two scanners). Nothing was inserted either way.
                self.presentPasteFailureAlert(
                    "The clipboard doesn’t contain a game this app can open.")
            }
        }
    }

    /// The clipboard's text, or nil.
    ///
    /// `data(forType:)` first so an oversized payload is rejected on a byte
    /// count before a `String` is ever materialized; `string(forType:)` is the
    /// fallback for a pasteboard that only offers a type convertible to text.
    private func clipboardText() -> String? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .string) {
            guard data.count <= PastedSgf.maxByteLength else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return pasteboard.string(forType: .string)
    }

    /// Explains why a ⌘V did nothing. A sheet, never `runModal` — a modal run
    /// loop here would block the `@MainActor` GTP loop.
    private func presentPasteFailureAlert(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Could not paste a game."
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }
}
