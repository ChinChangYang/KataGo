# CONTEXT

Ubiquitous language for KataGo Anytime. Glossary only — no implementation details.

## Deep Analysis Report

- **Deep Analysis Report** — the on-demand, per-position study sheet (iOS/visionOS ⋯ menu, macOS Game menu). Distinct from *live analysis*, the continuous overlay on the board.
- **Best Move** — the report's top candidate: the move the engine's open search ranked first for the side to move.
- **Alternative** — the report's second candidate slot. Exactly one Alternative is shown; it can originate from the engine's rank #2, from the game's next recorded move (the *smart default*), or from a *user pick*.
- **Smart default** — the Alternative chosen automatically when the report opens: the game's next recorded move when reviewing mid-game (if legal and not the Best Move), else engine rank #2.
- **User pick** — an Alternative the user nominated from the in-report board picker.
- **Variation** — a hypothetical continuation played out on the position under study: the engine's principal variation, or the stones a *beat* acts out. Force-played one move at a time, with every liberty-less group lifted — so a variation board is always a position the rules could produce, never the current stones with extra ones laid on top.
- **Snapshot probe** — the unconstrained analysis pass over the report's position; its ranked candidate list is the report's baseline.
- **Forced-candidate probe** — an analysis pass constrained so that all root search effort goes to one nominated vertex, used to evaluate a move the open search would starve.
- **Tenuki follow-up** — the probe answering "what happens next if this candidate is played": play the candidate, analyze the reply position, undo.
- **Refine** — re-running the report's probes at a doubled budget (capped), preserving the user's pick.
- **Visits** — the number of search playouts backing a candidate's evaluation; the report's proxy for how trustworthy a candidate's numbers are.
- **Visit parity** — the report's contract that the Alternative is always evaluated by its own forced-candidate probe, regardless of origin (engine rank, smart default, or user pick), so its visits are in the same ballpark as the Best Move's and its numbers are equally trustworthy.
- **Evidence** — what a probe is waiting for: a reply in which the engine actually *searched* something. A reply carrying only the engine's prior guesses is not evidence; it reports the position's own numbers under another move's name.
- **Patience pool** — the extra time one report may spend, in total, waiting for evidence past its stages' fixed budgets. A property of the occasion, not of the position: an unattended TV slideshow has patience, a report sheet a person is watching has none.

## Live analysis

- **Live analysis** — the engine's continuous read of the position on screen, drawn over the board and refined for as long as the search runs. Distinct from the *Deep Analysis Report*, which studies one position once and then stops.
- **Ownership overlay** — the shaded square on every intersection, saying which side the engine expects to end up owning it and how settled that expectation is. A whole-board picture, never a selection: every intersection carries one, so there are no interesting points and boring gaps.
- **Candidate overlay** — the circles marking the moves the engine is weighing, carrying their win rate, score and visit count. Drawn for one specific side to move, which is what makes it worthless the instant the position changes.
- **Ownership hold** — the previous position's *ownership overlay* stays on the board across a played move, an undo or a scrub, and each square moves to its new shade when the engine's first answer for the new position lands. The *candidate overlay* is never held: a territory map one stone out of date is approximately right, a ranking made for the other side to move is simply wrong.
- **Hold expiry** — what ends an *ownership hold* outright instead of replacing it: the board ceasing to be the same game (a switch, a new game, a size change), *engine availability* leaving a working state, and the board moving while the engine is not being talked to. Shading that outlived its engine would claim an analysis the *analysis control* is at that moment badged to say the app does not have.

## Broadcast

- **Broadcast** — the commentated slide show that narrates one position on Apple TV: deterministic fact sentences typed out in lockstep with an acted-out board, and spoken aloud when narration is on. Distinct from the *Deep Analysis Report*, which is the same underlying study data presented as a static sheet.
- **Live mode** — the broadcast driving a game forward; each cycle ends by asking the engine for a move.
- **Replay mode** — the broadcast walking a recorded game; each cycle ends by playing the game's next recorded move instead of asking for one.
- **Cycle** — one move's worth of broadcast: generate the study data for the current position, present its slides, then advance the game by one move.
- **Slide** — one titled unit of a cycle, carrying an ordered list of fact sentences. Six kinds: *Best Move*, *Alternative*, *Playing vs Passing*, *Comment*, *Played pass*, *Game over*.
- **Commentator register** — the single spoken-first wording of every fact sentence, shared verbatim by the slides, Copy to Comment, the narration prompt, and the report sheet's sentences. Sentences are shaped for the ear — no parentheses, no bare signs — with exact figures kept and visit counts left to the sheet's stat rows; "ahead", "behind", and their qualifiers are judged by score lead, never win rate.
- **Slide cursor** — how a cycle decides which slide comes next: by *kind*, in reading order, never by position in a list that is still being built. A slide whose turn has come but whose data has not yet landed is waited for; one whose data is settled and absent is skipped.
- **Playing vs Passing slide** — the slide contrasting playing the best move with passing: what passing costs, where the opponent would punish, and which areas change hands. Present whenever the position has a pass comparison to make — an absent one means the engine could not evaluate the position, never that the broadcast ran out of time. It weighs a *hypothetical* pass — the side to move has not passed.
- **Comment slide** — a slide whose facts are the human-written note attached to that move, rather than engine-derived sentences.
- **Played-pass slide** — the slide reporting that the move the cycle just made *was* a pass. Reports what happened; the Playing vs Passing slide weighs what would happen.
- **Game-over slide** — the terminal caption: both players have passed, so the game is over. At most one per game, and earnable again if the game returns to a live position.
- **Beat** — one acted-out moment of a slide's board choreography, paired with the sentence it illustrates. Its board is a *variation*: the stones it acts out are force-played onto the position, captures and all, never laid on top of it.
- **Pass beat** — the beat in which the side to move *passes*. Distinct from a tenuki beat: passing forfeits the move, it does not relocate it.
- **Tenuki beat** — the beat in which a player ignores the move under discussion and *plays elsewhere*.
- **Dwell** — the pause after a slide's text has finished, giving the viewer time to absorb the board the slide acted out.
- **Caption hold** — how long a standalone caption stays up once its text is done. Once the game-over card is up there is no board left to absorb, so a caption holds only as long as it is still being spoken, rather than taking a slide's dwell.
- **Auto-Play Speed** — the viewer's pacing choice for a replay broadcast (Slow / Normal / Fast). A pacing profile — how fast sentences reveal and how long a slide dwells — not a per-move delay, and not a choice about which analysis is shown.

## Downloads

- **Catalog asset** — an item the app's built-in catalog knows how to fetch: a downloadable neural network or an opening book. Distinct from a *user-imported asset* — a network or opening book that arrives from the file system and is never downloaded.
- **Imported book** — an opening book the user brought in from the file system. Exists only on the device that imported it; never synced.
- **Active book** — the book a board size actually uses: the explicit per-size choice when one has been made; otherwise the catalog book for that size, else the newest imported book of that size. Deleting the active book falls back down that chain.
- **Download** — the whole user-visible operation of bringing one catalog asset onto the device. Survives leaving the screen, leaving the app, and quitting.
- **Transfer** — one attempt at fetching the bytes a download is still missing. A download completes through as many transfers as it takes.
- **Partial** — the bytes of an incomplete download.
- **Staging** — where a partial lives while it is incomplete. Never a destination: a file at its destination is, by definition, complete.
- **Waiting** — asked for, not yet started, because another download is transferring. Distinct from *paused*: nobody stopped it.
- **Paused** — stopped by the user. Keeps its partial and never resumes itself.
- **Interrupted** — stopped by anything other than the user. Keeps its partial and is eligible to resume itself.
- **Verified** — the assembled bytes matched the total size the server declared for the asset. The gate a download passes before its file may reach its destination.
- **Downloaded** — a complete, verified asset at its destination. The only one of these states the rest of the app can observe.

## Rules & presets

- **Ruleset preset** — a named ruleset (Chinese, Japanese, Korean, AGA, BGA, AGA Button, New Zealand, Tromp-Taylor, Stone Scoring, Ancient Territory, Chinese OGS/KGS) defined *entirely* by its six rule components. Komi is **not** part of a preset's identity.
- **Rule components** — the six knobs that define a ruleset: ko rule, scoring rule, tax rule, multi-stone-suicide legality, button, white handicap bonus.
- **Preset match** — the mapping from current rule components to the preset label the picker displays. Komi-blind by design: only the six components participate.
- **Custom** — the picker state shown when the current components match no preset. Not a preset itself.
- **Suggested komi** — the komi conventionally paired with a preset's components (6.5 for territory scoring, 7.0 with a button, 7.5 otherwise). Applying a preset applies its suggested komi.
- **Default game** — the game a platform creates without the user choosing anything (first launch, quick New Game, fallback after deleting the last game). An even default game uses the Tromp-Taylor preset with its suggested komi 7.5, identically on every platform and peripheral surface (photo import, Messages).
- **Handicap default** — the ruleset a new game with handicap stones receives when the user has not chosen one: the Chinese preset, whose white handicap bonus compensates White one point per free stone (Tromp-Taylor compensates nothing). The default follows the handicap only while *untouched*; an explicit ruleset choice always wins and never flips back.
- **Untouched rules** — rules the user has neither picked from the preset list nor edited knob-by-knob. Only untouched rules retarget themselves when the handicap changes. Rules identical to the default count as untouched: indistinguishable states are treated the same.

## Game library

- **Game library** — the saved games, listed newest first, that every platform browses. One game is *open* at a time; the rest are rows.
- **Thumbnail** — the small board on a game's row: that game's position at the move it is parked on, with its last move marked. Derived from the record — its own moves replayed — and never a picture of the screen, so it can only ever depict the game it belongs to. It shows stones, grid and the last move alone: no analysis, no move numbers, no coordinates, and never a *branch*, because none of those belong to the game. They belong to whoever is looking at it. Optional, at one of two sizes or not at all — and turning it off costs the row its replay as well as its picture, so a hidden thumbnail is genuinely no work rather than invisible work.
- **Row note** — the line a game's row carries under its title: the *comment* on the move that game is parked on, which is the move its *thumbnail* draws, so a row describes one moment rather than two. A game whose current move carries no note simply has no such line. Distinct from the subtitle the Shortcuts and widget pickers show, which names a game's earliest note because those rows identify a game rather than describe a position.
- **Unreadable record** — a saved game whose moves cannot be replayed at all. Not an empty game and not a game still loading: there is nothing to draw and nothing to analyse, and every surface that draws a board says so rather than showing a blank one. A row with its *thumbnail* off draws no board and so makes no such claim: the signal belongs to the picture, and a list that has given up pictures has given up this one too.

## Engine

- **Record position** — the board at the game's current index, replayed from the game record. The only thing the board ever shows.
- **Engine position** — the position the engine has been fed. Never displayed; it exists so analysis has something to analyse.
- **Feed** — telling the engine the record's moves one at a time. A move the engine would refuse is skipped, exactly as the replay skipped it.
- **In sync** — the engine has acknowledged the record position. Analysis is collected, and stones may be played, only while in sync.
- **Engine availability** — *Absent* (no model chosen), *Launching* (model loading, possibly compiling), *Ready*, *Failed* (with a reason and an action), *Held* (the engine cannot take this board's size, so it is told nothing about it and analysis is off). A state; never a screen that replaces the board. Only the transient *Launching* overlays the board; the resting states surface through the *analysis control*.
- **Launch pill** — the only chrome that ever overlays the board: the *Launching* status and its compile caption, drawn over the top of the goban until the engine is ready. Never a control, never a resting state's home.
- **Keep-awake window** — from the moment the engine owes the person a move until a few seconds after its stone lands, and the whole of an auto-play; the only time the app holds the screen on.
- **Analysis preference** — the user's run / pause / off choice for *live analysis*. Owned by the user: engine transitions never write it, which is why analysis resumes by itself when a down engine comes back.
- **Analysis activity** — whether analysis is actually streaming: the preference says run *and* the engine is ready. What the analysis control's appearance reports.
- **Analysis control** — the sparkle. With a usable engine its tap cycles the preference; with a resting-down engine it wears a warning badge and its tap opens the *remedy surface*. A bare red slash means the user turned analysis off; a badged one means the engine cannot analyse.
- **Remedy surface** — the model-selection surface (model picker sheet, Manage Models window, Models ornament), carrying an engine-status header: the state, the failure reason, Retry when offered, and the way out of *Held*.

## Core ML compilation

- **Compile** — turning a neural network into a model the Neural Engine or GPU can actually run. Minutes of work on a phone, and the only reason the engine status has anything to say beyond "Loading".
- **Compile key** — everything that identifies one compiled model: which network, the *NN buffer size*, the numeric precision, the identity-mask optimisation, the batch-size bounds, the converter's own version, and the operating system's major version. Two loads share a compiled model only when every one of these agrees — so a new app build and a new OS release each invalidate every compiled model, exactly as a different network does.
- **Cache miss** — no compiled model exists for the current compile key. The only condition under which the app may say it is compiling.
- **Recompile** — a compile that happens because the compile key changed, because the compiled model was evicted to stay within the cache's bounds, or because the user cleared the cache. Ordinary, not exceptional: the app never describes compiling as a one-time event.
- **NN buffer size** — the largest board the running engine can evaluate, fixed when the engine launches (the *Max Board Size* setting). Distinct from the board size of any particular game, which may be smaller — a 9×9 game on a 19×19 engine compiles nothing new.
- **Heavy Core ML work** — clearing the compiled cache, or checking where Core ML routes a network: work that must never run beside a running engine, because it deletes or contends for what that engine is using. A running engine does not block it — the engine is unloaded around the work and relaunched after. Only a mid-launch engine defers it.

## Listen

- **Listen** — the audio-first feature that narrates a saved game aloud, move by move, for ears-only settings such as driving. Distinct from *Broadcast*: a broadcast is slide-paced and screen-bound, while Listen is utterance-paced — the next move begins when the current sentence has been spoken — and needs no screen at all.
- **Listening Session** — one game being narrated: a read-only projection of the record as it was when the session began. Edits made to the record while a session plays never reach it, and playback never writes the record.
- **Listening Cursor** — the per-game resume point, local to the device it was made on. Finishing a game clears it; stopping mid-game keeps it; a cursor pointing past the end of a game that has since shrunk snaps back to the last position the game still has.
- **Listening Cue** — one move's worth of a session: the stone sound, then that move's sentence — a saved comment spoken verbatim, a *commentator register* sentence when the move has analysis, or a *bare move call* when it has nothing.
- **Bare move call** — the minimal cue text for a move without analysis: the color and the vertex, nothing else. What an unprepared game sounds like.
- **Prepare for Listening** — the optional pass that analyzes every move of a game and writes commentary for the moves that have none, so a session speaks full sentences throughout. An upgrade, never a gate: every game is listenable unprepared, and saved comments are never overwritten.
- **Ready to listen** — the derived marker that a game is fully prepared: every move carries analysis. Read off the record's data, never stored.

## Siri

- **Siri Phrasebook** — the app's own, per-platform catalog of the spoken phrases its App Shortcuts answer to (the Mac has no Listen shortcuts). What Siri accepts is registered at build time and cannot be read back at runtime, so the phrasebook mirrors the registration by hand, and the two are kept in step deliberately.
