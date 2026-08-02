//
//  DraftController.swift
//  KataGo Anytime Mac
//

import Foundation
import SwiftData
import KataGoGameStore

/// Owns the single open draft and everything around it: the detached record
/// the session points at, the debounced crash mirror, and the exit rule.
///
/// The AppKit wiring (menus, sheets, window chrome) lives in
/// `MainWindowController`; this type holds no UI so the parts worth testing
/// stay in `GameDraft` / `DraftComparator` / `DraftExitDecision`, which are
/// unit-tested.
@MainActor
final class DraftController {
    private(set) var draft: GameDraft?
    let mirrorStore: DraftMirrorStore

    /// Fired whenever the dirty or conflict state may have changed, so the
    /// window controller can refresh the title, the dirty dot, and the
    /// "Changed on another device" subtitle.
    var onStateChanged: (() -> Void)?

    private var mirrorWriteTask: Task<Void, Never>?
    private static let mirrorDebounce = Duration.seconds(1)

    init(mirrorStore: DraftMirrorStore = DraftMirrorStore()) {
        self.mirrorStore = mirrorStore
    }

    var isDirty: Bool { draft?.isDirty ?? false }
    var hasConflict: Bool { draft?.hasConflict ?? false }
    var isUntitled: Bool { draft != nil && draft?.origin == nil }

    /// The name to put in the window title.
    var displayName: String? { draft?.record.name }

    // MARK: - Opening and closing

    /// Opens a draft over `origin` and returns the DETACHED record the session
    /// should select. No `loadGame` is needed at the call site: the content is
    /// identical, so the engine and board must not move — only object identity
    /// changes.
    @discardableResult
    func open(origin: GameRecord) -> GameRecord {
        let draft = GameDraft(origin: origin)
        self.draft = draft
        onStateChanged?()
        return draft.record
    }

    /// Opens a draft over a brand-new detached record that is not in the
    /// library. Unlike `open(origin:)` the caller DOES need to load the board,
    /// because the game really is different.
    @discardableResult
    func openUntitled(_ record: GameRecord) -> GameRecord {
        let draft = GameDraft(untitled: record)
        self.draft = draft
        onStateChanged?()
        return draft.record
    }

    /// Restores a draft recovered from the mirror after a crash.
    @discardableResult
    func restore(from mirror: DraftMirror, origin: GameRecord?) -> GameRecord {
        let record: GameRecord
        if let origin {
            record = origin.detachedDraftCopy()
        } else {
            record = GameRecord(config: Config())
        }
        mirror.draft.apply(to: record)

        let draft = GameDraft(record: record, origin: origin, baseline: mirror.baseline)
        self.draft = draft
        onStateChanged?()
        return record
    }

    /// Drops the draft without saving, and removes the mirror.
    func close() {
        mirrorWriteTask?.cancel()
        mirrorWriteTask = nil
        draft = nil
        mirrorStore.clear()
        onStateChanged?()
    }

    // MARK: - Identity

    /// Maps a record back to the saved object it stands for.
    ///
    /// The sidebar highlights rows by object identity, and library actions
    /// (delete, rename, share) must act on the real record. While a draft is
    /// open the selected record is the detached clone, so every such site has
    /// to resolve through here. Returns nil for an untitled draft, which has
    /// no saved counterpart and therefore no row.
    func resolvedRecord(_ record: GameRecord?) -> GameRecord? {
        guard let record, let draft, record === draft.record else { return record }
        return draft.origin
    }

    /// True when `record` is the live draft rather than a stored game.
    func isDraftRecord(_ record: GameRecord?) -> Bool {
        guard let record, let draft else { return false }
        return record === draft.record
    }

    // MARK: - Change notification

    /// Called after any mutation that could have changed the draft. Recomputes
    /// state for the window chrome and schedules a debounced mirror write.
    func noteChanged() {
        onStateChanged?()
        scheduleMirrorWrite()
    }

    private func scheduleMirrorWrite() {
        mirrorWriteTask?.cancel()
        guard let draft, draft.isDirty else {
            mirrorStore.clear()
            return
        }
        mirrorWriteTask = Task { [weak self] in
            try? await Task.sleep(for: Self.mirrorDebounce)
            guard !Task.isCancelled, let self, let draft = self.draft, draft.isDirty
            else { return }
            self.mirrorStore.write(
                DraftMirror(draft: draft.snapshot(), baseline: draft.baseline))
        }
    }

    // MARK: - Saving

    @discardableResult
    func save(into context: ModelContext) throws -> GameDraft.SaveOutcome? {
        guard let draft else { return nil }
        let outcome = try draft.save(into: context)
        mirrorWriteTask?.cancel()
        mirrorStore.clear()
        onStateChanged?()
        return outcome
    }

    @discardableResult
    func saveAsNewGame(into context: ModelContext) throws -> GameRecord? {
        guard let draft else { return nil }
        let inserted = try draft.saveAsNewGame(into: context)
        draft.rebaseline()
        mirrorWriteTask?.cancel()
        mirrorStore.clear()
        onStateChanged?()
        return inserted
    }

    // MARK: - Exits

    func decision(for trigger: DraftExitTrigger) -> DraftExitDecision {
        DraftExitDecision.decide(hasDraft: draft != nil,
                                 isDirty: isDirty,
                                 trigger: trigger)
    }
}
