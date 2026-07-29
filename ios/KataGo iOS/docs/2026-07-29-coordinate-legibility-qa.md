# Coordinate-label legibility QA — widget, GIF export, live board

Feature branch: `ios-dev` (coordinate-truncation sweep, commits `8e7a381d`,
`cb5d624f`, `580768c7`). Written 2026-07-29.

## Why this checklist exists

A device QA pass on 2026-07-27 recorded **"coordinate legibility per family —
PASSED"** for the Saved Game widget. It cannot have covered the case that was
actually broken: a **19×19 in the small family**, which was drawing a bare `…`
in place of every row number 10–19 — two columns of dots down the sides of the
board. The same defect was then found in GIF export, and the same floor was
shown to constrain the live board.

The lesson is that "coordinate legibility" is not one check. It is a check **per
surface × per board size × per size-of-thing-rendering-it**, and the failures
all live at the small end, which is exactly where a casual pass doesn't look.
Every row below names a concrete combination. Do not tick a row you did not
look at directly.

## The rule being tested

All three surfaces share `BoardLineView`'s label idiom: text clipped to a
cell-sized frame with a font floor of 5 pt. Below a certain cell pitch the label
**truncates to `…`** — it does not shrink, and it does not keep a leading digit.
The pitch each board needs (`WidgetCoordinateMetrics.requiredCell`):

| board | needs | what drives it |
|---|---|---|
| height ≤ 9, width ≤ 25 | 5.97 pt | label line height |
| height ≥ 10, width ≤ 25 | 7.34 pt | two-digit row numbers |
| width > 25 | 9.11 pt | `"A"`+letter column labels |

---

## A. Saved Game widget (iOS, macOS, visionOS)

Add the widget in each family and read the board edges. Expected behaviour is
all-or-nothing: labels are either fully present or fully absent — **a partial
or clipped label is a failure**, and so is a `…`.

1. **19×19, small** — no labels at all; board fills the card. *(This is the
   originally reported bug. Look for dots down the left and right edges.)*
   — **CONFIRMED FIXED 2026-07-30** by the reporter, on the TestFlight build
   from `2ef3010c` (Xcode Cloud archive green on all four platforms). Reported
   as "small-family widgets look good now". Note the scope of that observation:
   it covers the small family at whatever board sizes were in the library, so
   it settles row 1 and **not** rows 4–5, which assert the opposite behaviour
   (small-family 9×9 and 13×13 must KEEP their labels). Those still need a
   direct look, and they are the rows that would catch over-hiding.
2. **19×19, medium** — no labels. *(Was also broken; never reported.)*
3. **19×19, large** — all labels present: `A`–`T` and `1`–`19`, none clipped.
4. **9×9, small** — labels **present** and intact. *(Guards over-hiding: this
   one must not lose its coordinates.)*
5. **13×13, small** — labels present and intact, including `10`–`13`. *(Tightest
   surviving case; clears the floor by ~0.04 pt.)*
6. **37×37, large** — no labels. **37×37, extra-large** (iPad/macOS/visionOS) —
   labels present including the `AA`–`AM` columns.
7. Repeat 1 and 3 with the widget **tinted** (accented rendering mode).
8. visionOS only: step back until the widget enters its **distance** level of
   detail — coordinates drop regardless of board size.

## B. GIF export

Export ▸ Share GIF, coordinates **on**, and open the resulting GIF.

9. **37×37 at Low quality** — every column label present through `AM`; none
   clipped to `…`. *(Was broken; the raster now auto-raises 320 → 356 px.)*
10. **37×37 at High quality** — unchanged from before, all labels clean.
11. **19×19 at Low quality** — unchanged; confirm the file is still 320 px.
12. In the export sheet, compare the **preview** against the finished GIF for
    the 37×37 Low case — they must agree. *(The preview had the same bug
    independently.)*
13. Coordinates **off**, 37×37 Low — raster stays 320 px, no labels.

## C. Live in-app board

14. **19×19, iPhone portrait** — labels intact. *(Measured pitch 18.37 pt.)*
15. **37×37, iPhone portrait** — labels intact including `AA`–`AM`.
16. **37×37, iPhone landscape** — **known accepted limitation**: the column
    labels truncate. The app is 402 pt tall in landscape and the board needs
    ~390 pt of container. Confirm it is *only* this combination, and that the
    board is still fully playable. Do not file this as a new bug.
17. **37×37 on iPad** — **MEASURED 2026-07-29 on iPad mini (A17 Pro)**, the
    smallest iPad and therefore the worst case. Portrait passes outright;
    landscape carries a limitation of the same shape as item 16.

    | orientation | container | 19×19 pitch | largest board with intact labels |
    |---|---|---|---|
    | portrait | 436 × ≥488 pt (width-bound) | 20.78 pt | **37×37** — everything fits |
    | landscape | ≈806 × 354 pt (height-bound) | 14.86 pt | **≈32×32** |

    In landscape the chrome — 106 pt nav bar, the status toolbar, and the
    150 pt info pane (`InfoView.minHeight`) — takes ~390 pt of the 744 pt
    window, leaving 354 pt where a 37×37 needs 389 pt. So **34×34 through
    37×37 truncate their column labels on an iPad mini in landscape**; every
    board up to 33×33 is intact, and the default 19×19 clears the floor 2×.
    An 11-inch iPad (834 pt tall in landscape) and a 13-inch (1024 pt) both
    clear it, so the exposure is short windows only — under roughly **779 pt
    of window height**, which also covers Split View and Stage Manager
    windows on any iPad. Regression guard:
    `BoardAccessibilityUITests.testCoordinatePitchClearsTheWidestBoardsFloor`
    measures this on whatever destination it runs on.
18. **37×37 on macOS** — **width is structurally safe at every window size**;
    height is the user's own window. macOS transposes the demand (the pass
    tile sits to the *right* of the board, not below), so a 37×37 needs
    383 pt of width but only 376 pt of height — the mirror image of every
    other platform. `MainSplitViewController` floors the board pane at
    **480 pt** (`boardItem.minimumThickness`), which is 97 pt of headroom, so
    **macOS can never truncate on the axis that fails everywhere else**. The
    height side has no floor — the window sets no `minSize` — so a 37×37
    needs roughly 404 pt of board-pane height and shrinking the window past
    that will truncate. Self-inflicted and self-correcting (enlarge the
    window), and the default 1100×720 window clears it comfortably. Pinned in
    `BoardCoordinateFitTests.macOSTransposesTheDemandOntoWidth`. *(Still
    worth a human glance: drag the window short and confirm the failure is
    the ordinary one and nothing else breaks.)*
19. **37×37 on tvOS** — **CLOSED, no Apple TV needed.** tvOS is the one
    platform whose board container is fixed in source rather than negotiated
    with a window, so the check is exact and device-independent:
    `TVReviewScreen` and `TVSelfPlayScreen` pin `BoardView` to
    `.frame(width: 1080, height: 1080)` → a 37×37 renders at **26.17 pt**
    against a 9.115 pt floor (2.9× margin); `TVBroadcastSlideView` pins
    `ReportBoardView` to 900 × 900 → **23.08 pt**. tvOS has no
    coordinate-legibility exposure at any board size. Pinned in
    `BoardCoordinateFitTests.tvOSFixedBoardContainers_fitEveryBoardSize`.

---

## What the Simulator could and could not prove

* It **could** prove items 1–13: the widget was placed on a simulator Home
  Screen and screenshotted per family, and the GIF frames were rendered at the
  real export sizes.
* It **could not** rotate the **iPhone**. `XCUIDevice.shared.orientation =
  .landscapeLeft`, Device ▸ Rotate Left, and Device ▸ Orientation ▸ Landscape
  Left all no-oped (`.portrait` worked), and a retry on 2026-07-29 failed the
  same way. **Item 16 has never been observed** — it is derived from the 402 pt
  app height, which was measured. If item 16 does *not* reproduce on device, say
  so: the reasoning is wrong somewhere. (The app is *not* portrait-locked —
  `INFOPLIST_KEY_UISupportedInterfaceOrientations` lists all four for the iOS
  target — so iPhone landscape is genuinely reachable. It is the simulator that
  refuses.)
* It **could** rotate the **iPad**, which is how item 17 got both orientations.

## What changed on 2026-07-29 (items 17–19)

Items 17–19 previously read "container never measured on any platform". They
are now closed, two of them without any hardware:

* **tvOS (19)** needed no device at all — its container is a literal
  `.frame(width: 1080, height: 1080)` in source, so the check is exact and
  device-independent. Closed by `BoardCoordinateFitTests`.
* **macOS (18)** is closed on the axis that matters — the 480 pt board-pane
  floor makes width truncation impossible at any window size — and open on
  height, which is just "the user made their own window short". A live
  measurement of the window's minimum was attempted and abandoned: a second
  instance of the app (Debug build alongside the installed copy) ran 18 minutes
  at high CPU without holding a window open. **The minimum window height is
  still unmeasured**; the 404 pt figure is computed, not observed.
* **iPad (17)** was measured on an iPad mini, the smallest and therefore the
  worst case, in both orientations — and it found a real limitation in
  landscape (34×34 and up), which is why this row was worth doing rather than
  assuming.

The generalisable trick, now baked into
`BoardAccessibilityUITests.testCoordinatePitchClearsTheWidestBoardsFloor`:
**you never need a 37×37 on screen.** A 19×19 rendered at pitch `s` pins the
container from below, so every board's pitch follows — and a 19×19 at
**16.93 pt or better guarantees a 37×37 keeps its labels**. Measuring the
default board costs nothing; building a 37×37 means raising Max Board Size and
restarting the engine.
