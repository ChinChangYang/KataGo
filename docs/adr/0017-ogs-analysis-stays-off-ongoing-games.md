# 0017 — OGS analysis stays off ongoing games

Date: 2026-08-31
Status: Accepted

Builds on ADR 0016 (site adapters). OGS is the third adapter; this is the rule
it enforces, and the two mechanisms the extension needed to enforce it honestly.

## Context

online-go.com is the largest place people watch Go on the web, and it is
technically the easiest site the extension has met: every game, review and demo
route renders the same `<Game/>` component, which publishes its live board as
`window.global_goban`; that object emits `cur_move`, `move-made`, `gamedata`
and `phase`; and it exposes `setColoredCircles` as public, ephemeral display
state — the same primitive OGS's own AI review draws with.

It is also the first site with terms that bear on what we do. From
<https://online-go.com/docs/terms-of-service>, under "No Cheating or Computer
Help":

> You can NEVER use Go programs (Leela, Zen, etc.) or neural networks to
> analyze current ongoing games unless specifically permitted (e.g., a computer
> tournament). The only type of computer assistance allowed is games databases
> for opening lines and joseki databases for corner patterns in correspondence
> Go. You cannot receive ANY outside assistance on live or blitz Go games.

The sentence is unscoped. It does not say "games you are playing".

OGS's own code points the other way for its OWN analysis board: a per-game
`disable_analysis` flag "applies only to participants, spectators may always
analyze" (`src/lib/configure-goban.tsx:99-100`), and analysis is never
disabled once `phase === "finished"`. But that is OGS deciding what its own
feature may do, not a statement about a third-party neural network, and no
staff statement resolves the two. An extension that visibly reads a live OGS
game into KataGo is the exact shape OGS's anti-cheat language describes, and a
bad first impression with OGS staff is hard to undo.

## Decision

1. **A game is analysed only once it is finished.** The rule is one pure
   function in `page-hook.js`:

   ```
   ogsAccess({ hasSourceGame, phase, isPlayer, analysisDisabled,
               signedIn, liveSpectatingEnabled }) -> { allowed, reason }
   ```

   v1 allows exactly `!hasSourceGame || phase === "finished"`. A **demo board**
   has no source game and is always allowed. A **review of a finished game**
   carries that game's gamedata, so it reads as finished and is allowed. A
   **review of a live game** is a live game and is refused. `hasSourceGame` is
   read from `engine.config.game_id` / `goban.game_id`, never from the URL.

2. **The refusal is a sentence, not silence.** The panel mounts and shows one
   line — "KataGo stays off ongoing games — OGS's terms forbid engine analysis
   of a game in progress." — with Analyze disabled. A reader who came looking
   for the feature learns why it is not there.

3. **The verdict is live.** It is re-evaluated on `phase` and on
   `engine.updated`, because `goban.load()` REPLACES `goban.engine` on every
   gamedata and every reconnect. A game that finishes while the reader watches
   becomes analysable under them, and the panel says so by clearing its line.

4. **The future spectator rule ships implemented and off.**
   `ogsLiveSpectatingEnabled()` returns `false`. Behind it,
   `signedIn && !isPlayer && !analysisDisabled` is written and tested. Turning
   it on is a conversation with OGS staff, not a code change. Note what the
   gate would say if it ever opened: "we refuse unless OGS itself tells us you
   are a signed-in non-player" is a sentence a moderator can check;
   "we could not tell who you were, so we allowed it" is not — which is why an
   anonymous viewer would stay refused even then.

5. **We honour `disable_analysis` in its strictest reading.**
   `goban.isAnalysisDisabled(true)` — the same argument OGS passes when it
   turns off the SGF download for non-participants and logged-out viewers
   (`src/views/Game/GameDock.tsx:139-141`). That flag is the single
   machine-readable signal OGS gives about one specific game's wishes, and
   ignoring it while claiming to respect OGS's rules is the inconsistency a
   moderator would find first.

6. **We never write into the move tree.** Candidates go through
   `setColoredCircles`, which is ephemeral display state. `setMarks` /
   `setColoredMarks` write into the review's tree and are BROADCAST to every
   other participant over the socket; analysis nobody asked for must not appear
   on a stranger's board. Ownership squares and the candidate text have no
   ephemeral primitive — `setHeatmap` is a single-colour intensity map that
   cannot express Black-versus-White — so they go on an overlay canvas
   positioned from `computeMetrics()` and `square_size`.

7. **The extension opens no socket of its own.** The page's goban already has
   one and re-broadcasts everything as events. A second `game/connect` would
   double OGS's connection load per viewer for information the page already
   holds, and is the one approach that looks like an unsanctioned client rather
   than a reader's own browser.

## Two mechanisms this needed

**A session key separate from the content hash.** Native game identity was
`sha256(sgf)` everywhere. An OGS demo's SGF grows every time its author plays a
stone, so every move would have looked like a brand-new game: on macOS a fresh
whole-game sweep each time (and a stream of different games thrashing the
single-sweep `busy` guard), on iOS a cache file orphaned under the previous
hash. So `AnalysisRequest.start` gained a defaulted `gameId`, and the native
side keys its SESSION on `gameId ?? sgfHash` while the CONTENT hash keeps
naming the staged SGF and the cache files. A `start` with the same session key
and a new hash re-stages, rescans and rebuilds the planner in place, keeping the
worker running. The OGS adapter's key is `ogs:game:<id>` / `ogs:review:<id>` /
`ogs:demo:<id>` — a review of game 42 is not game 42.

On the two hash lengths: the persistent App-Group cache is named by the FULL
64-hex-character hash on both platforms already (macOS's `prefix(64)` of a
SHA-256 hex string is the whole string). Only macOS's staged temp file uses a
24-character prefix, and it stays: that file lives in the appex's own temporary
directory, a 96-bit prefix cannot realistically collide there, and lengthening
it would change nothing anyone can observe.

**A teardown message.** Sessions used to die only on `pagehide`, which a
single-page app never fires. Route changes on OGS null `window.global_goban`,
so the hook now posts `playerRemoved`, and both content scripts tear the
session down and forget the player. Without it a reader moving from one game to
the next left a dead shadow-DOM panel behind and, on macOS, a poll that kept the
`busy` guard armed against the game they had just opened.

## Consequences

- Finished games, reviews of finished games and demo boards work on day one.
  That is most of the value and none of the risk, and nothing built for it is
  thrown away if live watching is ever permitted.
- Someone who opens a live game gets a panel that explains itself and does
  nothing.
- macOS is where this is developed and QA'd. The shared `page-hook.js` means
  iOS Safari attaches too; its per-message appex lifecycle against a board that
  can move under it deserves its own pass.
- `gameId` is omitted from the wire when absent, so a WGo page's `start`
  message still encodes byte-for-byte as it always did.
