//
//  StoneAnimationPlanner.swift
//  KataGoUICore
//
//  Decides which stone of a showboard diff animates on the 3D goban. A FIFO
//  intent queue: command sites enqueue what they are about to do (place at p,
//  remove the tip at p) and the scene model resolves each non-empty stone
//  diff against the queue. No intent ⇒ instant, so batch updates (jumps,
//  game switches, board reloads) can never animate by accident, and any race
//  degrades to a missed animation — never a wrong one.
//
//  Why intents instead of an index delta at diff time: on the editing path
//  (the default Vision flow) a human play or AI reply updates sgf/currentIndex
//  only at the printsgf reply — AFTER the showboard stone diff — so the index
//  is stale by one move exactly when the diff lands. And a play capturing one
//  stone is shape-identical to an undo restoring one (1 addition + 1 removal),
//  so no diff-time heuristic can classify all cases. Provenance can.
//

public struct StoneAnimationPlanner {
    /// What a command site is about to do to the board.
    public enum Intent: Equatable, Sendable {
        /// A stone is about to be played at the point.
        case place(BoardPoint)
        /// The tip stone at the point is about to be undone.
        case remove(BoardPoint)
    }

    /// What the scene should do with the current diff.
    public enum Effect: Equatable, Sendable {
        case none
        /// Animate the addition at the point flying onto the board.
        case flyIn(BoardPoint)
        /// Animate the removal at the point flying off the board.
        case flyAway(BoardPoint)
    }

    /// When the placement sound should play for one resolved stone diff.
    /// On the 3D goban the sound is scene-driven (it tracks what the eye
    /// sees), not commit-driven like GobanState's GTP-time sound.
    public enum SoundCue: Equatable, Sendable {
        case none
        /// Play now: a batch update's single click.
        case playImmediately
        /// Play when the flying stone lands (flyInDuration after the
        /// animation starts).
        case playAfterFlyIn
    }

    /// When the capture rattle should play for one resolved stone diff.
    /// Captures ride the placement click's clock rather than showboard's:
    /// the engine reports the new capture count in the same block as the
    /// stone lists, so a rattle fired the moment the counter moves is heard
    /// a whole flight before the capturing stone touches the board.
    ///
    /// There is deliberately no silent case, unlike `SoundCue`: the user
    /// decided (2026-07-22, reaffirmed 2026-07-27) that a boot/switch remount
    /// into a game whose capture count rises DOES rattle. Only the timing was
    /// ever wrong.
    public enum CaptureCue: Equatable, Sendable {
        /// Play now: this diff mounted instantly, so nothing is in the air.
        case immediately
        /// Play with the landing click of the stone flying in.
        case atLanding
    }

    /// Decides the sound cue for a resolved diff. A fly-in sounds at
    /// landing; a fly-away is silent — a stone leaving the board is not a
    /// stone hitting it; a non-empty diff with nothing animating is a batch
    /// update (L2/R2 jump) and clicks once — unless it is the first sync
    /// after boot, a board rebuild, or a game switch (`isInitialSync`),
    /// which must stay silent: loading a game is not a move.
    public static func soundCue(effect: Effect,
                                additions: Int,
                                removals: Int,
                                isInitialSync: Bool) -> SoundCue {
        switch effect {
        case .flyIn:
            return .playAfterFlyIn
        case .flyAway:
            return .none
        case .none:
            guard additions > 0 || removals > 0, !isInitialSync else { return .none }
            return .playImmediately
        }
    }

    /// Decides how a capture reported against this diff should sound, or nil
    /// when the diff is empty and the previous diff's cue still stands.
    ///
    /// The nil case is the whole reason this is separate from `soundCue`:
    /// showboard writes the stone lists (its "Next player" line) BEFORE its
    /// "B/W stones captured" lines, so the capture counter can be observed
    /// on a later, empty sync of the same block. That empty sync must not
    /// overwrite the cue the capturing move's diff just set.
    ///
    /// Only a fly-in has a landing to wait for. A batch diff (L2/R2 jump, a
    /// boot/switch remount) mounts instantly, so its rattle is already in
    /// step with what the eye sees. A fly-away can never raise a capture
    /// count — an undo restores stones, it does not take them — so its
    /// `.immediately` is only a floor.
    public static func captureCue(effect: Effect,
                                  additions: Int,
                                  removals: Int) -> CaptureCue? {
        guard additions > 0 || removals > 0 else { return nil }
        switch effect {
        case .flyIn:
            return .atLanding
        case .flyAway, .none:
            return .immediately
        }
    }

    /// Outstanding intents, oldest first. Exposed for tests.
    public private(set) var pending: [Intent] = []

    /// More outstanding intents than this means the diffs stopped arriving
    /// (engine restart, dropped replies) — cap the queue so it cannot grow
    /// stale forever.
    private static let capacity = 8

    public init() {}

    public mutating func expect(_ intent: Intent) {
        pending.append(intent)
        if pending.count > Self.capacity {
            pending.removeFirst(pending.count - Self.capacity)
        }
    }

    /// Drops every outstanding intent. Called around batch operations (jump
    /// to start/end, game switch) and on board reload.
    public mutating func clear() {
        pending.removeAll()
    }

    /// Withdraws the most recent matching intent: the command site learned
    /// its command failed (an illegal-move rejection), so the queued intent
    /// will never see its diff. Without this, a rejected ko attempt at a
    /// just-captured point leaves a `.place` that the NEXT undo's
    /// restored-capture addition would satisfy — animating a restore the
    /// contract says mounts instantly.
    public mutating func retract(_ intent: Intent) {
        if let index = pending.lastIndex(of: intent) {
            pending.remove(at: index)
        }
    }

    /// Resolves a stone diff against the queue. An empty diff (no board
    /// change — e.g. an illegal move's showboard echo) leaves the queue
    /// untouched. Among matching intents the NEWEST wins — when more than
    /// one matches the same diff, the older ones are by construction stale
    /// (commands resolve strictly in order, so a live older intent's diff
    /// would have arrived first) — and consumes itself plus everything
    /// queued before it. A non-empty diff matching nothing is a batch
    /// update, which invalidates the whole queue.
    public mutating func resolve(additions: Set<BoardPoint>,
                                 removals: Set<BoardPoint>) -> Effect {
        guard !additions.isEmpty || !removals.isEmpty else { return .none }

        for (index, intent) in pending.enumerated().reversed() {
            let effect: Effect?
            switch intent {
            case .place(let point):
                effect = additions.contains(point) ? .flyIn(point) : nil
            case .remove(let point):
                effect = removals.contains(point) ? .flyAway(point) : nil
            }
            if let effect {
                pending.removeFirst(index + 1)
                return effect
            }
        }

        pending.removeAll()
        return .none
    }
}
