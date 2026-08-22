//
//  RecordPositionSync.swift
//  KataGoUICore
//
//  One driver per SwiftUI host for "the record position changed": it projects
//  the new position into the session's display models and hands the host the
//  side effects that must run engine-free (the per-index stone cache the
//  widget reads, the widget reload, the opening-book walk, the macOS draft
//  notice). The macOS AppKit host has no SwiftUI body to attach this to and
//  mirrors it with `withObservationTracking` in `MainWindowController`.
//
//  The projector is passed in with the session rather than resolved from the
//  environment: visionOS holds its `GameSession` directly and injects none of
//  the display models, so an environment-reading modifier would silently do
//  nothing there.
//

import SwiftUI

extension View {
    /// Projects the displayed record position whenever it changes (and once on
    /// appear), then calls `onChanged` with what was published.
    ///
    /// A nil key — nothing selected — publishes an empty board, which is how a
    /// deselecting screen clears the goban without any engine round-trip.
    public func recordPositionSync(
        session: GameSession,
        gameRecord: GameRecord?,
        onChanged: @escaping (RecordPosition, RecordPositionKey?) -> Void = { _, _ in }
    ) -> some View {
        modifier(RecordPositionSync(session: session,
                                    gameRecord: gameRecord,
                                    onChanged: onChanged))
    }
}

struct RecordPositionSync: ViewModifier {
    let session: GameSession
    let gameRecord: GameRecord?
    let onChanged: (RecordPosition, RecordPositionKey?) -> Void

    func body(content: Content) -> some View {
        // The key is computed inside the body so SwiftUI tracks every
        // observable it reads — the record's `sgf`/`currentIndex` and the
        // branch line — and re-evaluates when any of them moves.
        content.onChange(of: session.gobanState.recordPositionKey(gameRecord: gameRecord),
                         initial: true) { _, key in
            onChanged(session.projectRecordPosition(key: key), key)
        }
    }
}
