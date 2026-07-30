# Voice Control QA — help screen, board commands, chrome

Feature branch: `ios-dev`. Written 2026-07-30, when the Voice Control help
screen shipped. Rows 4–12 are **carried forward** from a verification plan
drafted on 2026-07-26 that was never committed and never run; they are folded in
here so there is one list instead of a plan in a chat log.

## Why this checklist exists

Voice Control support shipped on 2026-07-19 (`c0d58974`..`fb9c81b2`) and has
never been exercised by voice on a device. Nothing in this area can be proven by
the Simulator: XCUITest reads the same accessibility tree Voice Control does, so
it can prove an element **exists and is named**, but it cannot prove the name is
**speakable** — that a person saying "Tap K ten" is matched to the element
labelled `"K 10"`. Only a device with Voice Control switched on can.

Then on 2026-07-30 a tester reported the thing that prompted the help screen:
*"it is not clear what commands are available"*. That is a discoverability
failure, not a missing feature — every command below already worked.

## The rule being tested

The app names its targets; **Voice Control owns the command list**. The app
cannot enumerate commands and must not pretend to. What the help screen claims:

| claim | where it comes from |
|---|---|
| iOS: say **"Show me what to say"** | Apple, support.apple.com/en-us/111778 |
| macOS: say **"Show commands"** | Apple, support.apple.com/guide/mac-help/mh40719 |
| overlays **"Show names" / "Show numbers" / "Show grid"** | both platforms |
| activation verb **"Tap"** (iOS) / **"Click"** (macOS) | both pages above |
| board names like **"K 10"**, **"Pass"** | `BoardAccessibilityElement.elements(...)` |

Every board name the screen prints is generated from that builder, not typed as
a string, so the doc cannot drift from the overlay. Pinned in
`BoardAccessibilityElementsTests` → `VoiceControlHelpTests` (5 tests; the
parameterized one covers 19×19, 9×9, 37×37, 13×9, 2×2). The two platforms'
wording is data, not `#if`, so the **macOS** strings are asserted by a test that
runs on the iOS Simulator.

---

## A. The help screen (new, 2026-07-30)

Needs a device with Voice Control **on** (Settings ▸ Accessibility ▸ Voice
Control). Rows 1–3 are the ones that decide whether the feedback is actually
addressed.

1. **Reachable by voice.** On the board, say "Show names", then say
   "Tap More" ▸ "Tap Settings" ▸ "Tap Voice Control". The help screen opens.
   *(Also try "Tap Voice Commands" and "Tap Voice Control Help" — all three are
   registered as input labels for that row.)*
2. **The phrase it names actually works.** With the screen open, say
   "Show me what to say" and confirm Voice Control shows a command list. This is
   the whole point of the change: if the phrase is wrong or has been renamed by
   the OS, the screen is worse than nothing.
3. **The board examples match the board.** Open a 19×19 and confirm the screen
   says "Tap K 10". Then switch to a 9×9 (examples become "A 1"/"J 9"/"E 5") and,
   if Max Board Size allows, a 37×37 (a two-letter example "Tap AA 1" appears).
   The examples are generated, so a mismatch means the generator regressed.

## B. Playing by voice (carried from 2026-07-26, never run)

4. **"Tap K ten"** on an empty 19×19 plays a stone at K10. Try a corner
   ("Tap A one") and an edge.
5. **"Tap Pass"** passes — with Show pass **on**. Turn Show pass **off** and
   confirm the pass target is gone rather than silently playing a pass.
6. **Refusals are quiet and correct.** Say a point that is already occupied, and
   say a point when it is the AI's turn. Nothing should happen, and nothing
   should break. *(The help screen tells users this is a refusal, not a
   mis-hear — confirm that is what it looks like.)*
7. **Overwrite dialog by voice.** Step back into the game, say a point, and the
   overwrite confirmation appears; say "Tap Overwrite" to replace and
   "Tap Cancel" on a second attempt to keep the game.
8. **37×37 two-letter columns.** Raise Max Board Size, open a 37×37, and say a
   two-letter column ("Tap AA one"). This is the path most likely to mis-hear.
9. **"Show names" clutter check.** Say "Show names" on a 19×19 board screen and
   look at it. 361 intersection labels are expected to be unreadable — that is
   why the help screen says to name the point instead. Confirm it is *ugly, not
   broken* (no hang, no crash, and "Hide names" recovers).

## C. Chrome controls (carried from 2026-07-26, never run)

10. Board screen: "Tap Chart", "Tap Comments", "Tap More", "Tap Forward to End".
11. Toolbar title: "Tap Rename Game" opens the rename field; the game's own name
    also matches.
12. Global Settings ▸ Engine: "Tap Quit Engine" raises the quit confirmation.
    Model picker: "Tap Play", "Tap Download", "Tap Remove Model",
    "Tap Stop Download". Player chips: "Tap Black Player" / "Tap White Player"
    flip Human⇄AI. Console: "Tap Send".

## D. macOS (new surface, same day)

13. Settings (⌘,) has a **Voice Control** tab between Sound & Feedback and
    Licenses, and its wording is the Mac wording: **"Show commands"**,
    **"Click K 10"**, "System Settings ▸ … ▸ Commands". An iOS phrase here is a
    bug — it would tell a Mac user to say something that does nothing.
14. With Voice Control on, say "Show commands", then "Click K 10" on the board.
    macOS mounts the same `BoardAccessibilityOverlay` and routes through the same
    `attemptHumanMove` gate, so rows 4–7 should behave identically.
15. Switch games while the Settings window is open and confirm the examples
    follow the new board size (the pane observes `BoardSize`).

---

## Known gaps — stated, not bugs

* **visionOS has Voice Control but no voice-addressable board.** Vision input is
  game-controller-only; there is no `BoardView` and no
  `BoardAccessibilityOverlay` under `KataGo Anytime Vision/`, so no intersection
  can be named or spoken. The ornament controls carry labels, but the board
  cannot be played by voice at all. The help screen is deliberately **not**
  mounted there — it would document an absence. Do not file this as a
  regression; it is a scope decision, and reopening it means designing voice
  input for the volumetric board.
* **tvOS and watchOS have no Voice Control.** tvOS additionally excludes the
  overlay (`#if !os(tvOS)`). Nothing to test.
* **361 names on a 19×19 make "Show names" unusable**, by design. Naming a point
  directly is the supported path and the help screen says so. Reducing the count
  (e.g. exposing only legal moves) would break VoiceOver inspection of the
  board, which is the other user of these elements.
* **macOS keeps a second, click-only board layer.** `MacBoardInteractionLayer`
  Z-stacks a landmark element ("Go board", no `.isButton`, no
  `.accessibilityAction`) with its own copy of the play guards. Voice **cannot**
  activate it, so it does not affect anything above — but mouse clicks on macOS
  go through that duplicate rather than the shared gate. Unreconciled; flag it
  only if Mac click and Mac voice ever disagree about legality or overwrite.

## What the Simulator proved on 2026-07-30

* `VoiceControlHelpTests` — every printed board name is a real overlay label at
  19×19, 9×9, 37×37, 13×9 and 2×2; degenerate sizes (0, 99) clamp instead of
  printing empty examples; iOS and macOS wording differ on all three strings and
  the macOS copy never says "Tap".
* `GlobalSettingsMenuUITests` — More ▸ Settings ▸ Accessibility ▸ Voice Control
  opens, and the screen shows "Show me what to say" and "Tap K 10" with iOS
  wording. 1288 unit tests in 152 suites pass; iOS and macOS both build.
* It proved **nothing** about whether any phrase is heard. Rows 1–15 are all
  device rows.
