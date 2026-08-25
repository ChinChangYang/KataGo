# 0013 — A Listening Session is a read-only projection of the record

Date: 2026-08-26
Status: Accepted

## Context

Listen narrates a saved game as background audio for ears-only settings —
principally a car, where iOS 26 also mirrors the session's Live Activity onto
the CarPlay Dashboard. Two pressures meet here:

1. **The record can change under a playing session.** A passenger can open the
   same game on the phone and play moves; Prepare for Listening can finish and
   rewrite analysis and comments mid-drive. Narration that re-plans against a
   mutating record can contradict itself between one sentence and the next.
2. **Resume needs persistence, but the schema is frozen.** Podcast-style
   resume wants a per-game position. The SwiftData models are CloudKit-frozen
   (ADR 0001's discipline: values may change, schema may not), so no new
   `GameRecord` field is available. Reusing the record's parked index would
   sync — and then a car ride would silently re-park the position that the
   phone, the watch, every widget and the Mac all display.

ADR 0008 made the board a projection of the record so the display never waits
on the engine. Listen faces the mirror image: the session must never *write*
the surface every other platform reads.

## Decision

**A Listening Session is a read-only projection of the record as it was when
the session began, and its only persistent trace is device-local.**

- At start, the session snapshots the SGF and every per-move narration input
  (comments, win rates, score leads, best moves, capture data) into an
  immutable value. Playback reads only the snapshot; concurrent record edits
  are invisible until the next session.
- Playback writes nothing to the record — not the parked index, not analysis,
  not comments, not modification dates.
- The Listening Cursor lives in local `UserDefaults`, keyed by the record's
  UUID. It never syncs. Finishing a game clears it; stopping mid-game keeps
  it; on the next start it clamps to the game's current length.

## Consequences

- A cursor is lost on reinstall and invisible to the user's other devices —
  accepted: a stale resume point costs one skip; a synced one that moves every
  surface's parked position costs trust.
- Prepare finishing mid-session does not upgrade the playing narration; the
  richer sentences arrive on the next session of that game.
- Listening causes zero CloudKit traffic and can never reorder the library
  (nothing bumps `lastModificationDate`).
- The snapshot is what makes the session safe to drive from remote commands
  and to mirror into a Live Activity: every surface reads one immutable value.
