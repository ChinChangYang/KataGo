# Photo Import: Maximize the Photo in the Grid Phase — Design

**Date:** 2026-07-31
**Status:** Shipped 2026-08-01 (`2f75bef2..bf0148f3`) — see the corrections below
**Feature:** In `PhotoImportSheet`'s `adjustingGrid` phase, the photo becomes
the dominant element — full container width, all leftover height — on iOS,
iPadOS, and macOS, so placing the four corners on the board's outer line
crossings stops being fiddly.

> **Correction (2026-08-01).** This line originally also claimed "the four
> draggable corners get proportionally bigger". **They do not, and never did in
> any version of this plan.** `handles` draws fixed 18 pt / 5 pt circles
> (`BoardQuadView.swift`) and `BoardQuadEditor.grabRadius` is a fixed 32 pt;
> neither the design body nor the implementation plan ever scheduled a change.
> Because the photo grew, that fixed 32 pt radius now covers a *smaller*
> fraction of the image than before. That is defensible — a fixed target is
> correct touch ergonomics, and 32 pt exceeds the usual guidance — but it is
> not what this sentence promised, and anyone reading the spec to learn what
> shipped should not inherit the error.
>
> **Correction 2 (2026-08-01).** Risk #3 below ("`CropGeometry.fittedFrame`
> stops being a no-op") rests on a false premise. `.aspectRatio` sits *inside*
> `BoardQuadView` while the greedy frame is applied *outside* it, so `geo.size`
> always carries the image ratio and `fittedFrame` still returns a zero origin.
> Measurements confirm it: the identified element measured 402x301 and 402x536,
> i.e. it *is* the aspect-fitted photo. The letterboxing handling that risk
> motivated is therefore defensive, never exercised in production.
>
> **Correction 3 (2026-08-01).** The design's `.layoutPriority(-1)` on the photo
> shipped and was then **removed** (`be327748`) after measurement showed it
> crushed the photo to 54.67x41 pt at Accessibility XXXL (vs 288x216 without
> it), making the editor unusable, with no benefit at default text size and no
> chrome clipping in any measured condition. Guarded since by
> `testGridPhotoStaysReadableAtAccessibilityXXXL`.

## Problem

Tester feedback:

> When controllable quadrilateral grids appear for board photo recognition, the
> photo should be maximized for good UX. The current photo is too small to let
> the user easily drag and align with the grid.

Measured, not estimated. The constraint chain, outermost to innermost:

| # | Site | Code | Effect |
|---|---|---|---|
| C0 | `GameSplitView.swift:122` | `.sheet(item:)`, no detents, bare `NavigationStack` | iPhone: full-height sheet. iPad: ~540×620 form sheet. No `ScrollView` anywhere in the sheet |
| C1 | `PhotoImportSheet.swift:137` | `.frame(maxWidth: 480)` | Inert on iPhone (402 < 480); binds on iPad/macOS |
| C2 | `PhotoImportSheet.swift:136` | `.padding(24)` | −48 pt width, −48 pt height |
| C3 | `PhotoImportSheet.swift:121` | outer `VStack(spacing: 20)`, content-sized | Leftover height becomes symmetric dead space, not photo |
| C4 | `PhotoImportSheet.swift:297` | inner `VStack(spacing: 16)`, 4 children | 3 gaps = 48 pt |
| C5 | `PhotoImportSheet.swift:306` | `.frame(maxWidth: 400, maxHeight: 400)` | **The binding constraint on iPhone** |
| C6 | `BoardQuadView.swift:75` | `.aspectRatio(image, contentMode: .fit)` | Fits the photo ratio inside C5's box — so the *height* cap steals *width* |
| C8 | `BoardQuadView.swift:52` | `CropGeometry.fittedFrame(imageSize:in:)` | A no-op today: C6 already made `geo.size` the image ratio, so letterbox is always zero |

On an iPhone 17 (402×874) with a 3:4 photo:

```
width:   402 −48 (padding)              = 354 lane
height:  781 −48 −22 −20 −48 −66 −54 −34 = 489 available
C5 caps the proposal at (354 × 400)
C6 fit:  scale = min(354/3, 400/4) = 100  →  300 × 400
```

**300 × 400 pt**, inside a sheet with ~89 pt of unused vertical slack and 54 pt
of unused width. macOS is worse: the `minHeight: 600` host frame
(`LibraryActions.swift:234`) leaves the photo at **~233 × 310**.

Precision is the entire job of this control. 1 view pt ≈ 10 source px for a
3024-wide original, and the 19×19 lattice pitch is ~17.8 pt at 400 pt tall.
Every point of render size is corner-placement accuracy.

## Decisions (from brainstorming)

1. **Maximize in place** — no new presentation context. The grid phase gets its
   own layout inside the existing sheet. Rejected: a dedicated full-screen
   editor. On iPhone it yields *exactly the same* photo size, because width
   binds for any photo that is not extremely tall; it buys only iPad, at the
   cost of a restructure plus this codebase's documented cover⇄sheet
   presentation races. Rejected: pinch-to-zoom/pan — orthogonal to the ask, and
   it re-bases the normalized-quad math on a zoom transform whose
   degenerate-frame path already has a silent-data-loss hazard (see below).
2. **Moderate chrome trimming.** Drop the outer "Import from Photo" title in
   the grid phase only; shorten the instruction to two lines and the picker
   caption to one. The "outermost line crossing — not the wooden edge" wording
   is load-bearing (placing corners on the wood is the single easiest way to
   get a grid that is subtly wrong everywhere) and survives verbatim.
3. **iPad needs a bigger container, not a bigger layout.** Its ~540×620 form
   sheet is the limiter, so `.presentationSizing(.page)`.
4. **macOS gets a bigger host frame**, the same way `showDeepReport`
   (`560×640`) and `exportGameGif` (`420×640`) size theirs.
5. **The photo is the flexible child, at the lowest layout priority.** Chrome
   gets its ideal size first and can never be clipped — which matters because
   there is no `ScrollView` in this sheet and adding one would defeat the whole
   greedy-photo model.

## Layout changes

All in the `adjustingGrid` phase; `recognizing`, `preview`, and `failure` are
visually unchanged.

### `KataGoUICore/Sources/GobanRecogKit/PhotoImportSheet.swift`

A single derived gate drives the phase-aware chrome:

```swift
private var isGridPhase: Bool {
    if case .adjustingGrid = phase { return true }
    return false
}
```

| Change | Was | Becomes |
|---|---|---|
| Outer title | always shown | suppressed when `isGridPhase` (the phase carries its own headline; macOS additionally shows it in the sheet window title) |
| Outer `VStack` spacing | `20` | `isGridPhase ? 0 : 20` |
| Root padding | `.padding(24)` | `.padding(.vertical, 24)` + `.padding(.horizontal, isGridPhase ? 0 : 24)`; the grid phase re-adds `.padding(.horizontal, 24)` to its **own** headline, picker block, and button row |
| Sheet lane | `.frame(maxWidth: 480)` | `.frame(maxWidth: 560)`, with `.frame(maxWidth: 480)` applied inside `recognizing`, `preview(_:)`, and `failure(_:)` |
| `BoardQuadView` | `.frame(maxWidth: 400, maxHeight: 400)` | `.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(-1)` |

The photo bleeds to the sheet edges because the *root* drops horizontal padding
in this phase and the chrome re-adds its own — not via negative padding on the
photo. Keeping the sheet lane at a constant 560 for every phase (rather than
widening only for the grid phase) is deliberate: on macOS an
`NSHostingController` sheet resizes its window to the SwiftUI root's fitting
width, so a phase-dependent `maxWidth` would make the sheet window jump on
"Adjust Grid".

Copy:

| Context | Was | Becomes |
|---|---|---|
| `.firstFailure` | "Couldn't find the board. Drag each corner onto the outermost line crossing of the board, then tap Recognize." (3 lines) | "Couldn't find the board. Drag each corner onto the outermost line crossing." (2 lines) |
| `.fromPreview` | "Drag each corner onto the outermost line crossing of the board, then tap Recognize." (2 lines) | "Drag each corner onto the outermost line crossing." (2 lines) |
| `.retryFailure` | "Still couldn't read the board. Check that each corner sits on the outermost line crossing — not on the wooden edge — and that the board size is right." (4 lines) | "Still no luck. Corners go on the outermost line crossing, not the wooden edge — and check the size." (3 lines) |
| Picker caption | "The overlaid lines should sit on the board's lines." | "The grid should land on the board's lines." (1 line) |

"then tap Recognize" goes because the button is a `borderedProminent` default
action two rows below the text. The caption stays — shortened to one line it
costs 16 pt, which for a 3:4 photo is *free* (width binds, see below), and it
is the only place that explains what the overlay is for.

### `KataGo iOS/Game/GameSplitView.swift`

`.presentationSizing(.page)` on the sheet content (`photoImportSheet(for:)`,
line 174). No-op in compact width; on iPad it replaces the form sheet with the
larger page sheet. **This is the one API here that must be confirmed
empirically** — if `.page` does not visibly enlarge the iPad sheet, fall back
to `.presentationDetents([.large])`. Note the repo has zero prior uses of
either modifier, so there is no house precedent to match.

### `KataGo Anytime Mac/LibraryActions.swift`

`.frame(minWidth: 420, minHeight: 600)` → `.frame(minWidth: 560, minHeight: 700)`,
with the stale comment ("600, not 560: the tap-to-correct hint and Reset rows
add ~40 pt and must not compress the 320 pt board") rewritten. 700 rather than
720 keeps the sheet inside the 1100×720 default main window.

## Expected outcome

Chrome in the grid phase: 292 pt → **228 pt** (`.firstFailure`, default
Dynamic Type) — the outer title and its spacing (−42) plus one line off the
headline and one off the caption (−22). iPhone 17, 3:4 photo:

```
height: 781 −48 (padding) −48 (spacings) −44 (headline) −54 (picker block) −34 (buttons) = 553
width:  402 (bleed)
fit:    scale = min(402/3, 553/4) = min(134, 138) = 134  →  402 × 536
```

| | today | after | area |
|---|---|---|---|
| iPhone 17, 3:4 portrait | 300 × 400 | **402 × 536** | 1.80× |
| iPhone 17, 1:1 | 354 × 354 | **402 × 402** | 1.29× |
| iPhone 17, 4:3 landscape | 354 × 266 | **402 × 302** | 1.29× |
| macOS (approx — AppKit metrics differ) | 233 × 310 | **354 × 472** | 2.31× |
| iPad | 300 × 400 | grows with the page sheet | — |

402 × 536 is the theoretical maximum on an iPhone: width binds, so a
full-screen presentation would produce the identical number. Landscape and
square photos gain from width alone, which is why they gain less — there is no
further headroom to take.

## Risks and guards

Three things in the current code are safe only *because* the photo has a fixed
size. Each gets an explicit guard in this change.

### 1. Silent quad destruction (the one that loses user work)

`QuadGeometry.normalizedQuad(fromView:in:)` (`BoardQuadEditor.swift:341`)
returns the **entire unit square** for a degenerate frame, and
`BoardQuadView.quadGesture`'s `.onChanged` (`BoardQuadView.swift:106`) writes
that straight into `quad`. Today `frame` is constant for the phase's lifetime
so the path is unreachable. A greedy layout makes a zero-height proposal
reachable (presentation animation, rotation, extreme Dynamic Type).

**Guard:** bail out of `.onChanged` when the fitted frame is empty. Two lines,
in the view.

Related, and worth stating even though this design does not introduce it: if
`frame` changed *during* a drag, `active.start` would have been captured in the
old frame's points while `updated` is normalized against the new one, and the
quad would jump. The chrome in this phase is fixed-height, so the photo's frame
does not change mid-gesture — but a future size-responsive headline would
introduce exactly this.

### 2. Loupe placement

`BoardQuadView.swift:188-218`. `above` requires `point.y ≥ gap + diameter/2 =
145.8`, and the x-clamp `min(max(point.x, 54), size.width − 54)` **inverts**
when the photo is narrower than 108 pt. Growing the photo fixes the common
case (a 536 pt-tall photo always has room above), but iPhone landscape stays
cramped.

**Guard:** clamp the loupe centre on both axes so it can never draw over the
picker or button row — there is no `.clipped()` on this view.

### 3. `CropGeometry.fittedFrame` stops being a no-op

With C5 gone, the outer `.frame(maxWidth: .infinity, maxHeight: .infinity)` is
greedy while the inner `.aspectRatio` is not, so `geo.size` may no longer match
the image ratio and `fittedFrame` starts returning a real letterboxed rect with
a non-zero origin. `viewQuad`, `lattice`, `outline`, `handles`, the gesture,
and the loupe's magnification offset are all expressed relative to `frame` and
survive this. Two lines do not:

- `dimming(outside:in: geo.size)` (`BoardQuadView.swift:64`, `122`) — fills
  `geo.size`, so the bars would get the 45% black wash.
- the loupe's x-clamp against `size.width` (`BoardQuadView.swift:193`) — the
  loupe could park over a bar.

**Guard:** both switch from `geo.size` to `frame`. These are the only two
places in the file that use `geo.size`.

### 4. The UI-test invariant (verify, do not assume)

`PhotoImportGridUITests.testGridRecoveryImportsBoardAfterCornerDrags` drags at
normalized 0.10/0.90 on `BoardQuadView.gridArea`, which works *only* because
that element's frame ≡ the displayed image. The invariant holds after the
change — `.aspectRatio` and the three accessibility modifiers stay attached to
the same inner view, and the new greedy `.frame` wraps outside them, so the
identified element is still the image box, merely centred in a larger
container. **This must be proved by running the test, not by reading.**

If it were broken, the failure would be misleading: the drags would silently
no-op (a start in the letterbox makes `BoardQuadEditor.grab` return `nil`),
`submittedQuad` would stay at `[0.1,0.9]²`, and the test would fail 100+
seconds later at "Preview never appeared after Recognize".

`BoardQuadEditorTests` is pure math over synthetic rects. It stays green
through any layout regression, so it offers no safety net here — the
FullTestPlan-only UI test is the entire gate.

### 5. Dynamic Type

`.layoutPriority(-1)` on the photo means the chrome always wins, so buttons
cannot be pushed off a sheet that has no `ScrollView`. The cost is that at
accessibility sizes the photo absorbs the shrinkage. No `minHeight` floor: a
floor would trade a small photo for clipped, unreachable buttons. Guard #1
covers the degenerate limit.

## Testing

**New regression pin.** In `PhotoImportGridUITests`, after the grid phase
appears:

```swift
// The photo must use the full sheet width — the composed test image is 4:3,
// so width binds and the grid area should span the window. This fails loudly
// if a maxWidth/maxHeight cap is ever reintroduced on BoardQuadView.
XCTAssertGreaterThan(gridArea.frame.width, window.frame.width * 0.95)
```

**Existing suites that must stay green:**

- `PhotoImportGridUITests` — both cases (the corner-drag flow and Adjust Grid →
  Back).
- `PhotoImportUITests` — carries a literal `board.frame.width == board.frame.height`
  assertion and a `tapIntersection` closed form over the *preview* board. This
  design does not touch the preview phase, but the shared root padding and
  `maxWidth` do, so it must be re-run.
- `CameraImportUITests` — presence/label only; known flake is a cover race,
  rerun on failure.
- `BoardQuadEditorTests` (`KataGo AnytimeTests`, both plans).
- `KataGoUICore` SwiftPM tests via `swift test` — these never run under
  `xcodebuild test`, so green there proves nothing about them.

UI tests need the `KataGo AnytimeUITests` target with `-testPlan FullTestPlan`.
Piped `xcodebuild` exit codes are unreliable — grep for `BUILD SUCCEEDED` /
`BUILD FAILED` or set `pipefail`.

**Build matrix:** all five schemes (`KataGo Anytime`, `KataGo Anytime Mac`,
`KataGo Anytime Vision`, `KataGo Anytime TV`, `KataGo Anytime Watch`).
`GobanRecogKit` is linked only by the iOS and macOS targets — the pbxproj is
authoritative, and `PhotoImportSheet.swift`'s header comment claiming
"iOS/visionOS and macOS" is stale — but the shared package is in every graph.

**Manual smoke** (the layout is not unit-testable):

- iPhone simulator: portrait 3:4, landscape 4:3, and square photos; confirm the
  photo reaches the sheet edges and the Recognize row is never clipped.
- iPhone landscape orientation.
- iPad simulator: confirm `.presentationSizing(.page)` actually enlarges the
  sheet; fall back to `.presentationDetents([.large])` if not.
- macOS: a **signed** Debug build (an unsigned one crashes at CloudKit setup),
  File ▸ Import ▸ an image, then Adjust Grid.
- One Dynamic Type XXL pass to confirm the chrome wins and nothing clips.

## Out of scope

- Pinch-to-zoom / pan in the grid editor (considered and rejected above).
- A dedicated full-screen grid editor.
- visionOS: `GobanRecogKit` is not linked into the Vision target, so there is
  no photo import there at all.
- Any change to the recognition pipeline, the C++ port, or the quad→lattice
  seam. `QuadGeometry` normalizes against the *fitted image frame*, so the quad
  is scale-invariant: resizing the photo cannot change what
  `BoardRecognizer.recognize(imageData:quadNormalized:)` receives. The 600-image
  `eval_cpp` gate is untouched and does not need re-running.
