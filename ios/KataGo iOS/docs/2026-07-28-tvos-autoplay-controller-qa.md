# Apple TV device QA — Auto-Play and game-controller support

Feature branch: `ios-dev` (tvOS Auto-Play for all games + game-controller support).
Written 2026-07-28, after the whole-branch verification sweep.

Everything below needs a **real Apple TV**. The tvOS Simulator accepts the
Simulator's own Apple TV Remote window and host keyboard arrows, but it cannot
produce a **gamepad button press** at all (see "What the Simulator could and
could not prove" at the end), so the entire controller layer reaches the device
untested by anything but the compiler.

Work through sections A → B → C in order; each one leaves the app in the state
the next one needs. Tick items as you go and note the build number you tested.

---

## Read this first — the two items that matter most

* **Item 16** is a data-loss regression check. It guards the build-291 class of
  bug where a live continuation writes into the *recorded* game. If it fails,
  a user's iCloud-synced game is silently corrupted — stop testing and report.
* **Item 31** is a question nothing in the code answers yet: does an extended
  gamepad's **X** also arrive as a `UIPress.PressType.playPause`? If it does,
  `.onPlayPauseCommand` and the X binding both fire — the two toggles cancel out
  on the review screen and double-toggle pause on the live screen. There is no
  guard against this today, so item 31 decides whether one is needed.

---

## Setup

1. Install the branch build on a real Apple TV (4K preferred; test the oldest
   model you have if you want the thermal signal).
2. Sign in to iCloud so the library populates, and have all three of these ready:
   * **Game U** — an **unfinished** game, ≥ 30 recorded moves, *not* ending in
     two passes.
   * **Game F** — a **finished** game that ends in two passes.
   * A copy of Game U reachable from the **Search** tab.
3. Pair an extended gamepad (Settings ▸ Remotes and Devices ▸ Bluetooth):
   DualSense, DualShock 4, Xbox Wireless, or an MFi pad. Keep the Siri Remote
   in reach — sections A and B are remote-only.
4. Sit ~10 feet from the TV for the legibility items (9 and 47).
5. Note the room/device temperature. Auto-Play stops itself when the device
   reports a serious thermal state; that is by design, not a bug.

---

## A. Auto-Play with the Siri Remote

1. **Start/stop.** Open Game U. Press **Play/Pause**: stones start appearing
   about **1.5 s** apart, the move counter climbs, and the small transport pill
   next to "Analysis On" shows the **pause** glyph. Press **Play/Pause** again:
   the counter freezes on the move it reached and the pill returns to the
   **play** glyph. *(Verified in Simulator — confirm on the real remote.)*
   Then repeat the press with focus in each place it can be: the timeline, the
   Analysis button, the Auto-Play pill, and a Top Moves row. Play/Pause must
   start and stop the replay from **every** one of them (the only deliberate
   exception is the board in aiming mode, item 35). This is a responder-chain
   assumption that has never been checked from more than one focus location.
2. **Settings section order.** Open Settings on the Apple TV. Top to bottom the
   sections read Recovery, Board Size, **Playback**, Sound, Game Controller
   (only while a pad is paired), About, Diagnostics; inside Playback, the
   Auto-Play Speed control shows **Slow / Normal / Fast** left-to-right with
   **Normal** selected by default; and moving focus straight down from the top
   reaches every section in turn — a tvOS `ScrollView` scrolls by focus, so a
   card that focus cannot reach is a real failure, not just a layout curiosity.
   *(Card ordering was seen in the Simulator, but only at desk distance — this
   is the real-TV, real-distance confirmation.)*
3. **Speed.** Settings ▸ Playback ▸ Auto-Play Speed ▸ **Fast**, go back into
   Game U, press Play/Pause: the cadence is visibly quicker (**0.7 s**, vs
   3.0 s for Slow). The engine must **not** restart — no loading screen, no
   re-analysis pause, Top Moves keep updating throughout.
4. **Timeline click stops it.** While replaying, click the timeline left or
   right: Auto-Play stops on the **first** click (pill back to play glyph), and
   that click also steps exactly one move. *(Verified in Simulator.)*
5. **Board focus stops it.** While replaying, move focus left onto the board:
   Auto-Play stops and the ghost cursor appears on the board.
6. **Top Moves stops it.** While replaying, pick a Top Move: Auto-Play stops
   **and** the variation is played. In particular a Top Move pressed within a
   second of an auto-advanced move must not be swallowed — a press that does
   nothing while stones keep appearing is the exact bug fixed in this branch.
7. **Analysis is never touched.** Replay with Analysis **On**, then with
   Analysis **Off**: Auto-Play never flips the toggle in either direction, and
   with Analysis off each replayed move still shows its persisted per-move
   numbers.
8. **No screensaver.** Replay a long game to the end without touching the
   remote: the tvOS screensaver never covers the board mid-replay.
9. **Layout at 10 feet.** Both controls in the bottom row (the icon-only
   Auto-Play pill and "Analysis On"/"Analysis Off") are fully legible, neither
   label is truncated, and nothing is clipped by the bottom screen edge — check
   in all three states: Auto-Play off, Auto-Play running, and with a variation
   active. This is the layout gate the panel failed once during implementation.
10. **No dead press.** With Auto-Play running, and again with a variation active,
    press **down** from the timeline: focus always lands on something legal —
    never a press that does nothing.
11. **Focus between the two pills.** Move focus left and right between the
    Auto-Play pill and the Analysis button. Both directions work and focus never
    escapes the row unexpectedly (the row has no `.focusSection()`).
12. **Disabled pill must not strand focus.** Put focus **on the Auto-Play pill**,
    then activate a variation (play a Top Move from the board cursor) so the
    pill becomes disabled. Focus must move somewhere legal, and Menu must still
    work. Believed unreachable in practice — prove it.
13. **Leaving the screen stops it.** With Auto-Play running, press Menu (or
    switch to another tab): the replay stops, and returning to the game does not
    resume it by itself.

## B. Handoff to a live continuation

14. **The handoff.** Replay Game U to its **last** recorded move:
    "Continuing live…" appears for about 2 s, then the broadcast screen opens,
    titled with the game's name plus "(Live)", showing the recorded position,
    and the engine eventually lands a stone of its own.
15. **The return.** When that continuation ends, the result card reads
    "Returning to review…" and the app pops back to the review screen — not to
    the library.
16. **⚠️ THE REGRESSION CHECK.** After that pop: play a **Top Moves** move on
    the review screen, press Menu to exit, then reopen the same game from the
    library. **The recorded game must be unchanged** — same move count, same
    final position, no extra stones from the live continuation and none from the
    variation you just played. Check it on a second device (iPhone/iPad) too if
    iCloud has had a moment to sync. **If this fails, stop and report it.**
17. **Analysis state survives the round trip.** Note whether Analysis was on or
    off before the handoff; after the pop back to review it must be in the
    **same** state, with the eye icon and the panel agreeing.
18. **No flash on the pop.** Watch the moment of the pop: the review screen must
    come back showing the recorded position it left from — no empty board, no
    board that briefly shows the continuation's stones.
19. **A finished game never hands off.** Replay Game F to its last move: it
    stops on the final position with **no** "Continuing live…" overlay and no
    push.
20. **The two-pass seed gate.** Replay Game F (it already ends in two passes)
    all the way to its last move: Auto-Play stops there with no "Continuing
    live…" overlay and no push — the same outcome item 19 checks, but for a
    sharper reason here. That refusal is the only thing standing between a live
    continuation and a pass counter seeded already at 2 (the broadcast's
    `startIfNeeded()` seeds `gobanState.passCount` from the recorded position's
    trailing passes, inside `onAppear`), and nothing proves whether SwiftUI's
    `onChange(of: passCount)` even fires for a 0→2 write made inside `onAppear`.
    Believed unreachable in practice — prove it: if a live continuation ever
    does open on an already-finished position, the symptom to report is a
    result card that appears immediately and never pops back to review.
21. **Manual stepping never hands off.** With the D-pad, step Game U manually to
    its last recorded move: nothing is pushed, no overlay.
22. **Parked at the end.** Park on Game U's last move and press Play/Pause: the
    handoff starts immediately (overlay, then push).
23. **From Search.** Repeat item 14 for Game U opened from the **Search** tab.
24. **Cancel the beat.** Start the handoff and press **Menu** during the
    "Continuing live…" beat: it cancels cleanly, you land back in the library,
    and **no** live screen appears afterwards (not even seconds later).
25. **Hammer the beat.** Start the handoff and, during the 2 s beat, press
    Play/Pause repeatedly and also try to pick a Top Move. Exactly **one** live
    screen may be pushed, no variation may be recorded, and after it ends,
    re-run item 16's check on the recorded game.
26. **Menu-exit mid-continuation.** Run item 14's handoff again, then — a stone
    or two into the live continuation — press **Menu** instead of letting the
    game end. Three things must hold back on the review screen: Analysis is in
    the **same** state it was in before the handoff (item 17, but for a Menu
    exit rather than the natural return), the recorded game is unchanged
    (re-run item 16's check), and **X** on the gamepad still toggles Auto-Play
    (the handler stack has to pop on a non-natural exit too — item 41 exercises
    only the natural one). Items 15-18 and 24 cover the natural return and the
    cancelled beat; nothing covered this exit.
27. **Tab switch during the beat.** Start the handoff and, while "Continuing
    live…" is on screen, switch to the **Search** or **Settings** tab. No live
    screen may appear afterwards, on any tab, not even seconds later.
28. **Backgrounding during the beat.** Start the handoff and press the **TV**
    button mid-beat, then reopen the app. At most **one** live screen may be
    pushed, and only onto the review screen — never on top of the library,
    another tab, or a second copy of itself.
29. **Parked at the end on a hot device.** With the device already reporting a
    serious thermal state (Setup step 5; a long replay at Fast on the oldest
    model you have is the easiest way there), park on Game U's last recorded
    move and press **Play/Pause**. The handoff must **refuse**: the pill returns
    to the play glyph, there is no "Continuing live…" overlay and no push. Item
    22 is the same press on a cool device, where it does hand off.

## C. Game controller

30. **Detection.** With the pad paired, Settings shows a **Game Controller**
    section naming your pad, with all six rows (X, Y, L1, R1, L2, R2) and the
    "The D-pad, A and B navigate the interface as usual." footnote. Unpair or
    power off the pad: the section disappears. *(Section rendering was seen in
    Simulator; the disappear half was not.)*
31. **⚠️ Does X double-fire?** On the review screen, with Auto-Play **stopped**,
    press **X** once. Expected: Auto-Play starts (one toggle). If instead
    nothing happens, X is also arriving as a Play/Pause press and the two
    handlers are cancelling out. Then check the live screen: press **X** once
    while running — it must end up **paused**, not paused-and-resumed. Report
    either symptom; the fix would be to suppress one of the two paths.
32. **Navigation parity.** The D-pad moves focus, **A** selects, **B** goes
    back — exactly as the Siri Remote does, on the library, the review screen
    and Settings.
33. **Review bindings.** On the review screen: **X** toggles Auto-Play (pill
    glyph flips), **Y** toggles Analysis (label flips between "Analysis On" and
    "Analysis Off"), **L1**/**R1** step exactly one move back/forward, and
    **holding** L1 or R1 auto-repeats (first repeat after ~0.4 s, then ~8 per
    second). **L2** jumps to the start (move 0), **R2** jumps to the end.
34. **L1 at move 0.** Press and hold **L1** while already at move 0: nothing
    happens at all — no flicker, no re-analysis.
35. **Aiming makes them inert.** Focus the board (aiming/ghost-cursor mode):
    X, Y, L1, R1, L2 and R2 all do **nothing**, and the D-pad steps the ghost
    cursor one intersection per press. The thumbstick does **not** aim — that is
    deliberate, the D-pad is the only aiming input. Press Menu to leave aiming;
    the six buttons work again.
36. **Live-screen bindings.** On the live broadcast: **X** pauses and resumes,
    **R1** skips the current slide, **L1** undoes **while paused**.
37. **L1 held on the live screen.** Hold **L1** on the paused live screen. The
    binding auto-repeats there too, though the Settings legend describes L1 as
    "Undo (while paused)" with no "(hold to repeat)". Confirm the undo does not
    run away, and note which should change — the legend text or the binding.
38. **Attract mode ignores the mapping.** Leave the app idle until the
    screensaver self-play demo starts, then press **X** (and each of Y, L1, R1,
    L2, R2). Every one of them must **exit** the demo, exactly as the remote
    does. None may pause it or leave a "Paused" badge with no way out.
39. **Mid-hold disconnect.** While **holding L1** on the review screen, power
    the controller off. The auto-repeat stops immediately; the timeline does not
    keep running backwards.
40. **Reconnect re-arms.** Turn the pad back on (or unpair and re-pair) while
    sitting on the review screen: the six buttons work again without leaving the
    screen, and Settings shows the section again.
41. **⚠️ The handler stack (LIFO).** Review → let the handoff push the live
    screen → confirm **X** there pauses/resumes (the review action must **not**
    fire) → let it end and pop back → press **X** on the review screen: it still
    toggles Auto-Play. This whole push/pop contract has never been exercised.
42. **No stray handler.** Press X, Y, L1, R1, L2 and R2 on the **library** and
    **Settings** screens: nothing happens (no hidden Auto-Play on a screen you
    left). Then push a review screen, switch tabs away, press X on the other
    tab: still nothing.
43. **Two pads.** Pair a second controller. Settings must name the pad you are
    actually pressing, and pressing X on either pad must drive the screen you
    are on.
44. **Siri Remote after the pad.** Use the Siri Remote for a few presses (this
    makes it the "current" controller), then press **X** on the gamepad without
    touching anything else: the binding must still fire — this is the fallback
    that keeps the pad bound after the remote is used.
45. **System button remapping.** In tvOS Settings ▸ Remotes and Devices ▸ your
    controller, swap two of the mapped buttons (X and Y are the easiest to see),
    then return to the review screen: the app must follow the system remapping —
    the button now reported as X toggles Auto-Play. This is the only in-app
    effect of the `GCSupportsControllerUserInteraction` declaration added on this
    branch. Undo the remapping afterwards.

## D. Accessibility

46. **VoiceOver.** Turn VoiceOver on and focus the icon-only Auto-Play pill: it
    must be announced with a meaningful name (it has no visible text, so the
    announcement comes entirely from its accessibility label), and its
    play-versus-pause state must be distinguishable by ear.
47. **Legibility of the Settings legend.** At 10 feet, the Game Controller
    legend's three columns (button, Reviewing, Live) are readable and nothing is
    truncated.

## E. Watch list (observe, do not gate the release on these)

* **Thermals at Fast.** Auto-Play at Fast asks the engine to re-analyze on every
  step, and each step currently issues the analysis request twice (a known,
  pre-existing duplication that manual stepping shares). Replay a long game at
  Fast and watch for the device getting hot, the frame rate dropping, or
  Auto-Play stopping itself on the thermal guard. If that happens, the fix is to
  drop the extra re-analysis from the auto-advance path only.
* **CloudKit chatter.** Every auto-advanced move writes the game's current move
  index, i.e. roughly 1.4 writes/second at Fast. The library's ordering field is
  deliberately untouched, so the list must **not** reshuffle while replaying —
  check that, and watch a second signed-in device for sync churn or battery
  drain during a long replay.
* **Board too large.** If the Board Size setting is below the game's size, the
  review screen shows the board-too-large state and Auto-Play must be
  unavailable rather than silently doing nothing.

---

## What the Simulator could and could not prove (2026-07-28)

Verified live on the tvOS 26.5 Simulator against this build, using the
Simulator's own Apple TV Remote window (a real remote press path) and host
arrow keys:

* Play/Pause **starts** Auto-Play from the review screen's default focus, the
  pill flips to the pause glyph, and moves advance (item 1, first half).
* Play/Pause **stops** it: the counter froze at the same move across two
  screenshots 4 s apart and the pill returned to the play glyph (item 1, second
  half).
* A timeline step during replay stops Auto-Play on the first press and advances
  exactly one move (item 4).
* The Settings **Game Controller** section renders with the connected pad's name
  and all six legend rows (item 30, first half).

Not provable here, and therefore untested until this checklist is run:

* **Any gamepad button press.** A real DualSense is paired to the Mac and the
  Simulator forwards it — the app sees an `extendedGamepad` and renders the
  Settings section — but nothing on the machine can *press* it. The Simulator's
  I/O ▸ Input menu offers only "Send Keyboard Input to Device"; there is no API
  to set a `GCController` element's value from outside the device; and building
  a synthetic HID gamepad on the host is refused without root (the virtual-HID
  create call returns NULL, and this machine has no passwordless sudo). So
  items 31-45 are entirely unexercised — button bindings, the LIFO handler
  stack, the hold-repeat loop, the disconnect path, the current-controller
  fallback and the remapping declaration are all code-reading only.
* Everything in section B beyond what an earlier end-to-end Simulator run
  covered (the overlay, the push and the seeded position were seen there; the
  return, the recorded-game integrity check and the mid-beat cases were not).
* All of section D, and items 9, 11, 12 (layout, focus and VoiceOver on a real
  TV at a real viewing distance). The Settings card ordering was seen in the
  Simulator, but only at desk distance.
