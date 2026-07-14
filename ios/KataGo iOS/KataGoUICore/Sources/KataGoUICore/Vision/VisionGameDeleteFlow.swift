//
//  VisionGameDeleteFlow.swift
//  KataGoUICore
//
//  Pure logic behind the visionOS Games-list delete flow. The confirmation
//  renders as an in-card content swap (VisionBranchConfirmCard pattern),
//  NEVER a .confirmationDialog: deleting the open game re-renders the board
//  and other ornaments, and an ornament-hosted dialog whose action does that
//  permanently blanks the volume (verified live on visionOS 26). Prompts are
//  iOS-verbatim (GameSplitView's delete dialogs); the select-mode chrome
//  mirrors iOS GameListView's Select/Done + "(N)" trash design.
//

import Foundation

public enum VisionGameDeleteFlow {
    /// What becomes the open game after a deletion, decided BEFORE anything
    /// is deleted (the doomed record must stay alive until the replacement
    /// mounts — loadGame reads it as `previous`).
    public enum Fallout<ID: Hashable & Sendable>: Equatable, Sendable {
        /// The open game survives the deletion — nothing to remount.
        case keepCurrent
        /// Mount this record (the newest not being deleted).
        case switchTo(ID)
        /// Every game is going away — create and mount a fresh one.
        case createFresh
    }

    /// `orderedNewestFirst` is the root @Query's order (reverse
    /// lastModificationDate — the same "newest" boot's fetch resolves).
    public static func fallout<ID: Hashable & Sendable>(
        orderedNewestFirst: [ID],
        deleting: Set<ID>,
        currentID: ID?) -> Fallout<ID> {
        guard let currentID, deleting.contains(currentID) else {
            return .keepCurrent
        }
        if let replacement = orderedNewestFirst.first(where: { !deleting.contains($0) }) {
            return .switchTo(replacement)
        }
        return .createFresh
    }

    /// iOS GameSplitView's single-delete dialog title, verbatim.
    public static let singleDeletePrompt =
        "Are you sure you want to delete this game? THIS ACTION IS IRREVERSIBLE!"

    /// iOS GameSplitView's bulk-delete dialog title, verbatim, with the
    /// same count pluralization.
    public static func bulkDeletePrompt(count: Int) -> String {
        "Are you sure you want to delete \(count) game\(count == 1 ? "" : "s")? THIS ACTION IS IRREVERSIBLE!"
    }

    /// iOS select-mode row leading image (GameListView.selectableRow).
    public static func selectionImage(isSelected: Bool) -> String {
        isSelected ? "checkmark.circle.fill" : "circle"
    }

    /// The header button that enters/exits select mode.
    public static func selectToggleTitle(isSelecting: Bool) -> String {
        isSelecting ? "Done" : "Select"
    }

    /// iOS bottom-bar trash label ("(N)" beside the trash symbol).
    public static func trashCountLabel(count: Int) -> String {
        "(\(count))"
    }

    public static func bulkTrashDisabled(count: Int) -> Bool {
        count == 0
    }
}
