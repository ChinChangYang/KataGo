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
17. **37×37 on iPad**, both orientations, and in Split View at the narrowest
    width — labels intact. *(Container never measured; this row is the check.)*
18. **37×37 on macOS**, window shrunk to its minimum — labels intact.
    *(Container never measured.)*
19. **37×37 on tvOS** review board — labels intact. *(Container never
    measured.)*

---

## What the Simulator could and could not prove

* It **could** prove items 1–13: the widget was placed on a simulator Home
  Screen and screenshotted per family, and the GIF frames were rendered at the
  real export sizes.
* It **could not** rotate. `XCUIDevice.shared.orientation = .landscapeLeft`,
  Device ▸ Rotate Left, and Device ▸ Orientation ▸ Landscape Left all no-oped
  (`.portrait` worked). **Item 16 has never been observed** — it is derived from
  the 402 pt app height, which was measured. If item 16 does *not* reproduce on
  device, say so: the reasoning is wrong somewhere.
* Items 17–19 were never measured on any platform.
