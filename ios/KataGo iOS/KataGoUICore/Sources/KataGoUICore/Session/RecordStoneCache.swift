//
//  RecordStoneCache.swift
//  KataGoUICore
//
//  The per-index stone cache a `GameRecord` carries (`blackStones` /
//  `whiteStones` / `moves`). It exists for readers that cannot replay an SGF:
//  the Saved Game widget renders `blackStones[currentIndex]`, and the
//  Commentator reads `moves`. Three hosts used to keep byte-identical copies
//  of this write (iOS `GameSplitView`, macOS `MainWindowController`, visionOS
//  `VisionRootView`); it lives here once, driven by the record position rather
//  than by the engine's `showboard` reply.
//

import Foundation

public enum RecordStoneCache {
    /// Caches `position` into `record` at the key's index.
    ///
    /// Returns whether anything was actually written — for tests, and to make
    /// the assign-only-on-change discipline visible. That discipline is not
    /// cosmetic: SwiftData dirties a record when a property is SET, even to the
    /// value it already holds, and a dirtied record is saved and exported to
    /// CloudKit. Re-projecting the same position (a board reload, a re-entry)
    /// must therefore cost nothing.
    ///
    /// Skips entirely while a branch is active: a branch is a scratch line that
    /// is never saved, and its indices are numbered from the divergence point,
    /// so writing them would corrupt the mainline's cache.
    ///
    /// Skips too when the key describes a DIFFERENT record than the one handed
    /// in. Every caller reads the record and the key from two places (a host's
    /// selection and the projector's `currentKey`), and a game switch moves
    /// them one at a time — so the pairing is an assumption, not a guarantee.
    /// Writing under it would stamp the outgoing game's position into the
    /// incoming game's cache at the outgoing game's index, which the widget
    /// then renders as that game's board. Refused rather than corrected: this
    /// is a caller bug, and a silent repair would hide it. A nil id on either
    /// side is not a mismatch — an unsaved record has no persistent identity
    /// yet, and the nil-key path publishes an empty board on purpose.
    @discardableResult
    public static func write(position: RecordPosition,
                             key: RecordPositionKey,
                             into record: GameRecord) -> Bool {
        guard !key.isBranchActive else { return false }
        if let keyID = key.recordID, keyID != record.persistentModelID { return false }
        let index = key.index
        var wrote = false

        // `refillString` (not `toString`) so an empty side stays
        // present-but-empty ("") rather than dropping the key — `dict[i] = nil`
        // REMOVES the entry, which diverges from the SGF-import path and breaks
        // the widget's `lastIndex` / `getCapturedStones` logic, both of which
        // distinguish "no entry" from "empty entry". See `GameEntity.init`.
        let black = BoardPoint.refillString(position.blackPoints,
                                            width: position.width,
                                            height: position.height)
        if let current = record.blackStones, current[index] != black {
            record.blackStones?[index] = black
            wrote = true
        }

        let white = BoardPoint.refillString(position.whitePoints,
                                            width: position.width,
                                            height: position.height)
        if let current = record.whiteStones, current[index] != white {
            record.whiteStones?[index] = white
            wrote = true
        }

        if writeMoves(position: position, into: record) {
            wrote = true
        }

        return wrote
    }

    /// The move-vertex cache the Commentator reads: the recorded move at the
    /// displayed index and the one before it — the same pair
    /// `GobanState.maybeUpdateMoves` fills from a `printsgf` reply. Navigation
    /// sends no `printsgf`, so without this an index reached by stepping would
    /// have no entry.
    ///
    /// No SGF parsing happens here. `RecordPosition.recordedMoveVertices` is
    /// filled by the projector, which had the record parsed anyway; doing it
    /// here meant a full C++ `CompactSgf` parse on every projection — and at
    /// the tip (where the index has no move yet) that parse was thrown away
    /// unused on every single played move.
    private static func writeMoves(position: RecordPosition,
                                   into record: GameRecord) -> Bool {
        let pending = position.recordedMoveVertices.filter { record.moves?[$0.key] != $0.value }
        guard !pending.isEmpty else { return false }

        // Only materialize the dictionary once there is something to put in it:
        // assigning `[:]` to a nil field would dirty the record (and re-export
        // it to CloudKit) for nothing.
        if record.moves == nil { record.moves = [:] }
        for (index, vertex) in pending {
            record.moves?[index] = vertex
        }
        return true
    }
}
