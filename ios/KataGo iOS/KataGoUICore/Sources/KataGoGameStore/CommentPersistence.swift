//
//  CommentPersistence.swift
//  KataGoGameStore
//
//  The single place a comment pane's text becomes part of the record.
//
//  CommentView holds its text in @State and used to flush it only when the
//  pane disappeared or the move index changed, so a freshly generated comment
//  was invisible to every other reader — the watch widget, the iOS widget,
//  Shortcuts — until the user navigated away. Routing all four write sites
//  through one function makes "when is a comment real?" a single, testable
//  question rather than four inline assignments in a view.
//

import Foundation

public enum CommentPersistence {
    /// Write `text` as the record's comment at `index`, creating the
    /// dictionary if the record arrived without one. The text is stored
    /// verbatim: it is user content, which may be in any script, and callers
    /// that care about blank comments (`WatchStoredAnalysis.at`) already trim.
    ///
    /// Blank text does NOT create an entry that did not exist. The typing
    /// debounce fires on the pane's first appearance too, and an empty string
    /// stored at move 0 would be returned verbatim by
    /// `GameEntity.firstComment` (which reads `comments?[0]` before its
    /// fallback), making the iOS widget picker's subtitle blank instead of the
    /// game's earliest real comment. Clearing an EXISTING comment still
    /// persists — otherwise the pane could not delete text.
    public static func store(_ text: String, at index: Int, in record: GameRecord) {
        let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBlank, record.comments?[index] == nil { return }
        if record.comments == nil { record.comments = [:] }
        record.comments?[index] = text
    }
}
