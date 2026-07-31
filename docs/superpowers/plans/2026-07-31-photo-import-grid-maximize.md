# Photo Import Grid — Maximize the Photo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In `PhotoImportSheet`'s `adjustingGrid` phase, make the photo the dominant element — full container width, all leftover height — so dragging the four board-grid corners stops being fiddly.

**Architecture:** `BoardQuadView` becomes the flexible child of the phase's `VStack` at the lowest layout priority, and the sheet drops its horizontal padding in this phase so the photo bleeds to the sheet's edges (the chrome re-adds its own margins). Because that makes the photo's frame variable for the first time, three things that were only safe under a fixed size get guarded first: the loupe's placement math, the dimming/loupe use of `geo.size` instead of the fitted image rect, and the degenerate-frame path in `normalizedQuad` that silently replaces the user's corners with the whole unit square. iPad and macOS additionally need bigger *containers*, not bigger layouts.

**Tech Stack:** SwiftUI (iOS 26 / macOS 26), Swift Testing (`@Test`/`#expect`), XCUITest, SwiftPM package `GobanRecogKit` inside `KataGoUICore`, Xcode project `ios/KataGo iOS/KataGo Anytime.xcodeproj`.

**Design spec:** `docs/superpowers/specs/2026-07-31-photo-import-grid-maximize-design.md` (commit `220dabb3`).

## Global Constraints

- **English only in every committed file** — source, comments, docs, copy. No CJK anywhere in the diff.
- **No new `.swift` files.** Every change lands in a file that already exists, so no `project.pbxproj` registration is needed. If a task seems to want a new file, add to `BoardQuadEditorTests.swift` (tests) or the existing source file instead.
- **Do not touch the recognition pipeline, the C++ port, `BoardRecognizer`, or the quad→lattice seam.** `QuadGeometry` normalizes against the fitted image frame, so the quad is scale-invariant — resizing the photo cannot change what the recognizer receives. The 600-image `eval_cpp` gate is not in scope and must not be re-run.
- **The "outermost line crossing" wording is load-bearing** and must survive in every headline variant: placing corners on the wooden edge is the single easiest way to get a grid that is subtly wrong everywhere.
- **`BoardQuadView` must keep `.aspectRatio(...contentMode: .fit)` with the three accessibility modifiers attached to that same inner view.** `PhotoImportGridUITests` drags at normalized 0.10/0.90 and only works because the `BoardQuadView.gridArea` element frame ≡ the displayed image. Any new `.frame` wraps *outside* those modifiers.
- **Unit-test target is `KataGo AnytimeTests`** (directory `KataGo iOSTests`); **UI-test target is `KataGo AnytimeUITests`** (directory `KataGo iOSUITests`). UI tests are in `FullTestPlan` only — a UI invocation MUST pass `-testPlan FullTestPlan` and `-only-testing` must use the *target* name.
- **`xcodebuild` exit codes lie when piped.** Always grep for `** BUILD SUCCEEDED **` / `** BUILD FAILED **` / `** TEST SUCCEEDED **` / `** TEST FAILED **` rather than trusting `$?` after a pipe.
- **Commit after every task.** Do not push — pushing `ios-dev` triggers an Xcode Cloud archive and those are spaced ~1 day apart.
- All build/test commands run from `/Users/chinchangyang/Code/KataGo-ios-dev` unless a step says otherwise.

---

## File Structure

| File | Responsibility after this change |
|---|---|
| `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadEditor.swift` | Pure, UI-independent geometry for the grid editor. **Gains `LoupePlacement`** — where to draw the magnifier, clamped to the photo on both axes. |
| `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadView.swift` | The gesture/rendering shell. Switches `dimming` and the loupe from `geo.size` to the fitted image `frame`, delegates loupe placement to `LoupePlacement`, and refuses to write a quad derived from an empty frame. |
| `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/PhotoImportSheet.swift` | Phase chrome. Gains an `isGridPhase` gate driving phase-aware padding/spacing/title, a wider sheet lane with the non-grid phases re-capped, the flexible photo frame, and shorter copy. |
| `ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift` | iOS presentation. Gains `.presentationSizing(.page)` so iPad stops using a form sheet. |
| `ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift` | macOS host frame, `420×600` → `560×700`. |
| `ios/KataGo iOS/KataGo iOSTests/BoardQuadEditorTests.swift` | Gains `CropGeometry.fittedFrame` coverage (currently zero) and `LoupePlacement` coverage. |
| `ios/KataGo iOS/KataGo iOSUITests/PhotoImportGridUITests.swift` | Gains the regression pin that the photo bleeds past the chrome margins. |

---

### Task 1: Regression pin — the photo bleeds past the chrome

The one automatable proof that the photo got bigger. It compares the grid area's width against the board-size picker's width: the picker sits in the chrome lane (24 pt margins each side) while the photo bleeds to the sheet edges, so after the change the photo must be ~48 pt wider. Resolution- and device-independent, unlike comparing against the window.

This is the red half of the TDD cycle and it must be run *before* any source change.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOSUITests/PhotoImportGridUITests.swift:66-72`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks consume. It is a gate.

- [ ] **Step 1: Write the failing assertion**

In `testGridRecoveryImportsBoardAfterCornerDrags`, replace the block that currently reads:

```swift
        // The size picker is part of the phase — the overlay needs a concrete
        // board size to draw, so there is no "Auto".
        XCTAssertTrue(app.segmentedControls["PhotoImportSheet.boardSizePicker"].exists,
                      "Board size picker not found in the grid phase")

        // Bring the quad in to ~[0.22,0.78]² around the central board. The quad
        // starts inset at 0.1/0.9, so the drags begin there.
        let gridArea = app.descendants(matching: .any)["BoardQuadView.gridArea"].firstMatch
        XCTAssertTrue(gridArea.waitForExistence(timeout: 10), "Grid area not found")
```

with:

```swift
        // The size picker is part of the phase — the overlay needs a concrete
        // board size to draw, so there is no "Auto".
        let sizePicker = app.segmentedControls["PhotoImportSheet.boardSizePicker"]
        XCTAssertTrue(sizePicker.exists,
                      "Board size picker not found in the grid phase")

        // Bring the quad in to ~[0.22,0.78]² around the central board. The quad
        // starts inset at 0.1/0.9, so the drags begin there.
        let gridArea = app.descendants(matching: .any)["BoardQuadView.gridArea"].firstMatch
        XCTAssertTrue(gridArea.waitForExistence(timeout: 10), "Grid area not found")

        // The photo must bleed past the chrome's margins: the picker sits in
        // the padded lane, the photo reaches the sheet's edges, so the photo is
        // ~48 pt (2 × 24) wider. Comparing the two elements rather than the
        // window keeps this device- and orientation-independent.
        //
        // This holds only because the composed test image is 4:3 landscape, so
        // WIDTH is what binds the aspect fit. A portrait fixture would be
        // height-bound and this assertion would not apply.
        XCTAssertGreaterThan(gridArea.frame.width, sizePicker.frame.width + 40,
                             "The grid photo is not using the full sheet width — a maxWidth/maxHeight cap on BoardQuadView has come back")
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan "FullTestPlan" \
  -only-testing:"KataGo AnytimeUITests/PhotoImportGridUITests/testGridRecoveryImportsBoardAfterCornerDrags" \
  2>&1 | tee /tmp/grid-red.log | grep -E "TEST (SUCCEEDED|FAILED)|XCTAssertGreaterThan|not using the full sheet width"
```

Expected: `** TEST FAILED **`, with the failure being the new `XCTAssertGreaterThan` — today the photo lane is 354 pt and the picker is also 354 pt, so `354 > 394` is false.

**This run takes 6-10 minutes** (the test waits up to 300 s for full-frame recognition to abstain under the Debug-built recognizer). That is expected, not a hang.

If it instead fails at `"Grid area not found"` or `"Preview never appeared after Recognize"`, the baseline is broken before your change — stop and report, do not proceed.

- [ ] **Step 3: Commit the red test**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && \
git add "ios/KataGo iOS/KataGo iOSUITests/PhotoImportGridUITests.swift" && \
git commit -m "test(photo-import): pin that the grid photo bleeds past the chrome margins

Currently red: BoardQuadView is capped at 400x400 inside the sheet's padded
lane, so the photo is exactly as wide as the board-size picker instead of
~48 pt wider."
```

---

### Task 2: Cover `CropGeometry.fittedFrame`

`fittedFrame` is a no-op today — `BoardQuadView`'s `.aspectRatio` already makes `geo.size` match the image ratio, so it always returns the identity rect. Task 5 makes the outer frame greedy, at which point it starts returning a real letterboxed rect with a non-zero origin. It has **zero tests**. Cover it before relying on it.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOSTests/BoardQuadEditorTests.swift` (append)

**Interfaces:**
- Consumes: `CropGeometry.fittedFrame(imageSize:in:) -> CGRect` (already exists, `CropGeometry.swift:22`).
- Produces: nothing.

- [ ] **Step 1: Write the failing tests**

Append to `ios/KataGo iOS/KataGo iOSTests/BoardQuadEditorTests.swift`:

```swift
// MARK: - Fitted frame

/// `CropGeometry.fittedFrame` decides where the photo actually lands inside
/// `BoardQuadView`. It was an identity function while the view's own
/// `.aspectRatio` guaranteed a container of the image's ratio; once the view
/// is allowed to fill a greedy frame it does real letterboxing, and every
/// coordinate the grid editor speaks is measured from the rect it returns.
@Suite("Fitted frame")
struct FittedFrameTests {

    @Test func fillsAContainerOfTheSameRatio() {
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 1200, height: 1600),
                                             in: CGSize(width: 300, height: 400))
        expectClose(frame.origin, CGPoint(x: 0, y: 0))
        #expect(abs(frame.width - 300) <= epsilon)
        #expect(abs(frame.height - 400) <= epsilon)
    }

    @Test func letterboxesAWideContainerWithHorizontalBars() {
        // A 3:4 photo in a 4:3 container: height binds, bars left and right.
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 300, height: 400),
                                             in: CGSize(width: 400, height: 300))
        #expect(abs(frame.height - 300) <= epsilon)
        #expect(abs(frame.width - 225) <= epsilon)
        #expect(abs(frame.minX - 87.5) <= epsilon)
        #expect(abs(frame.minY - 0) <= epsilon)
    }

    @Test func letterboxesATallContainerWithVerticalBars() {
        // A 4:3 photo in a 3:4 container: width binds, bars top and bottom.
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 400, height: 300),
                                             in: CGSize(width: 300, height: 400))
        #expect(abs(frame.width - 300) <= epsilon)
        #expect(abs(frame.height - 225) <= epsilon)
        #expect(abs(frame.minX - 0) <= epsilon)
        #expect(abs(frame.minY - 87.5) <= epsilon)
    }

    /// The guard the grid editor's degenerate-frame protection keys on: a
    /// zero-sized container must produce an empty rect, never a rect that
    /// coordinates could be divided by.
    @Test(arguments: [
        CGSize(width: 0, height: 400),
        CGSize(width: 300, height: 0),
        CGSize(width: 0, height: 0),
    ])
    func degenerateContainerIsEmpty(container: CGSize) {
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 1200, height: 1600),
                                             in: container)
        #expect(frame.isEmpty)
    }

    @Test func degenerateImageIsEmpty() {
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 0, height: 0),
                                             in: CGSize(width: 300, height: 400))
        #expect(frame.isEmpty)
    }
}
```

- [ ] **Step 2: Run them — they should PASS immediately**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/FittedFrameTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|Test Case.*Fitted"
```

Expected: `** TEST SUCCEEDED **`.

These are characterization tests over existing correct behavior, so passing on the first run is the correct outcome — there is no red step here. If any fails, `fittedFrame` does not do what the rest of this plan assumes; stop and report.

- [ ] **Step 3: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && \
git add "ios/KataGo iOS/KataGo iOSTests/BoardQuadEditorTests.swift" && \
git commit -m "test(photo-import): cover CropGeometry.fittedFrame

It had no tests and was an identity function in practice, because
BoardQuadView's own .aspectRatio guaranteed a container of the image's ratio.
Letting the photo fill a greedy frame makes it do real letterboxing, so pin
the bar placement and the degenerate cases first."
```

---

### Task 3: Extract loupe placement into tested geometry

Today the loupe's centre is computed inline in the view: it prefers a position above the dragged corner, flips below near the top edge, and clamps x with `min(max(point.x, radius), size.width - radius)`. That expression **inverts** when the photo is narrower than the loupe (108 pt), and nothing clamps y at all — with no `.clipped()` on the view, the loupe can draw over the board-size picker and the button row. Both regimes become easier to hit once the photo's size varies.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadEditor.swift` (append, after `QuadGeometry`)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadView.swift:41-42, 58-70, 122-130, 188-218`
- Test: `ios/KataGo iOS/KataGo iOSTests/BoardQuadEditorTests.swift` (append)

**Interfaces:**
- Consumes: `BoardQuad`, `CGRect` (existing).
- Produces:
  - `public enum LoupePlacement`
  - `public static let LoupePlacement.gapFraction: CGFloat` (= `0.85`)
  - `public static func LoupePlacement.center(for point: CGPoint, diameter: CGFloat, in bounds: CGRect) -> CGPoint`
  - `BoardQuadView.dimming(outside:in:)` changes its second parameter from `CGSize` to `CGRect`.
  - `BoardQuadView.loupe(at:frame:)` loses its `in size: CGSize` parameter.

- [ ] **Step 1: Write the failing tests**

Append to `ios/KataGo iOS/KataGo iOSTests/BoardQuadEditorTests.swift`:

```swift
// MARK: - Loupe placement

/// The magnifier follows the dragged corner, which sits under the fingertip,
/// so it has to sit clear of the hand — above by preference, below near the
/// top edge — and it must never leave the photo: `BoardQuadView` does not
/// clip, so an unclamped loupe draws over the board-size picker and the
/// buttons underneath.
@Suite("Loupe placement")
struct LoupePlacementTests {

    private let diameter: CGFloat = 108
    private let photo = CGRect(x: 0, y: 0, width: 400, height: 500)

    private var gap: CGFloat { diameter * LoupePlacement.gapFraction }

    @Test func sitsAboveACornerWithRoomAbove() {
        let center = LoupePlacement.center(for: CGPoint(x: 200, y: 300),
                                           diameter: diameter, in: photo)
        expectClose(center, CGPoint(x: 200, y: 300 - gap))
    }

    @Test func flipsBelowACornerNearTheTopEdge() {
        let center = LoupePlacement.center(for: CGPoint(x: 200, y: 10),
                                           diameter: diameter, in: photo)
        expectClose(center, CGPoint(x: 200, y: 10 + gap))
    }

    @Test func clampsHorizontallyAtTheLeftEdge() {
        let center = LoupePlacement.center(for: CGPoint(x: 4, y: 300),
                                           diameter: diameter, in: photo)
        #expect(abs(center.x - diameter / 2) <= epsilon)
    }

    @Test func clampsHorizontallyAtTheRightEdge() {
        let center = LoupePlacement.center(for: CGPoint(x: 398, y: 300),
                                           diameter: diameter, in: photo)
        #expect(abs(center.x - (photo.maxX - diameter / 2)) <= epsilon)
    }

    /// A corner at the very bottom flips the loupe above, but when the photo
    /// is too short for either side the y-clamp is what keeps the circle off
    /// the picker below.
    @Test func neverLetsTheCircleLeaveTheBottomEdge() {
        let center = LoupePlacement.center(for: CGPoint(x: 200, y: photo.maxY),
                                           diameter: diameter, in: photo)
        #expect(center.y + diameter / 2 <= photo.maxY + epsilon)
    }

    @Test func neverLetsTheCircleLeaveTheTopEdge() {
        let center = LoupePlacement.center(for: CGPoint(x: 200, y: photo.minY),
                                           diameter: diameter, in: photo)
        #expect(center.y - diameter / 2 >= photo.minY - epsilon)
    }

    /// The regression that motivated extracting this: `min(max(x, r), w - r)`
    /// inverts when the photo is narrower than the loupe and returns `w - r`,
    /// which is off the left of the view. The midpoint is the only sane answer.
    @Test func returnsTheMidpointWhenThePhotoIsNarrowerThanTheLoupe() {
        let narrow = CGRect(x: 0, y: 0, width: 90, height: 500)
        let center = LoupePlacement.center(for: CGPoint(x: 80, y: 300),
                                           diameter: diameter, in: narrow)
        #expect(abs(center.x - narrow.midX) <= epsilon)
    }

    @Test func returnsTheMidpointWhenThePhotoIsShorterThanTheLoupe() {
        let short = CGRect(x: 0, y: 0, width: 400, height: 90)
        let center = LoupePlacement.center(for: CGPoint(x: 200, y: 40),
                                           diameter: diameter, in: short)
        #expect(abs(center.y - short.midY) <= epsilon)
    }

    /// The photo is centred in a larger container once the frame is greedy, so
    /// the rect the loupe is clamped into no longer starts at the origin.
    @Test func respectsANonZeroOrigin() {
        let offset = CGRect(x: 50, y: 120, width: 400, height: 500)
        let center = LoupePlacement.center(for: CGPoint(x: 52, y: 420),
                                           diameter: diameter, in: offset)
        #expect(abs(center.x - (offset.minX + diameter / 2)) <= epsilon)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/LoupePlacementTests" \
  2>&1 | grep -E "BUILD FAILED|cannot find 'LoupePlacement'|TEST (SUCCEEDED|FAILED)"
```

Expected: `** BUILD FAILED **` with `cannot find 'LoupePlacement' in scope`.

- [ ] **Step 3: Add `LoupePlacement`**

Append to `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadEditor.swift`, after the closing brace of `QuadGeometry`:

```swift
/// Where to draw the magnifier for the corner being dragged.
///
/// The corner sits under the fingertip — exactly where the user needs to look
/// — so the loupe is offset clear of the hand: above by preference, flipping
/// below when the corner is near the top edge. Both axes are then clamped into
/// the photo, because `BoardQuadView` does not clip: an unclamped loupe draws
/// over the board-size picker and the button row beneath the photo.
///
/// Pure and separate from the view so the clamping rules are testable. They
/// are not obvious: the naive `min(max(x, r), width - r)` inverts when the
/// photo is narrower than the loupe and returns a point off the opposite edge.
public enum LoupePlacement {

    /// Distance between the corner and the loupe's centre, as a fraction of
    /// the diameter. Large enough that the circle clears a fingertip.
    public static let gapFraction: CGFloat = 0.85

    public static func center(for point: CGPoint,
                              diameter: CGFloat,
                              in bounds: CGRect) -> CGPoint {
        let radius = diameter / 2
        let gap = diameter * gapFraction
        let above = point.y - gap - radius >= bounds.minY
        return CGPoint(x: clamped(point.x, radius: radius,
                                  from: bounds.minX, to: bounds.maxX),
                       y: clamped(above ? point.y - gap : point.y + gap,
                                  radius: radius,
                                  from: bounds.minY, to: bounds.maxY))
    }

    /// Keeps a circle of `radius` centred at `value` inside `[from, to]`.
    /// When the span is narrower than the circle there is no such position, so
    /// the midpoint is the answer — clamping in that case would place the
    /// centre outside the span entirely.
    private static func clamped(_ value: CGFloat, radius: CGFloat,
                                from minimum: CGFloat, to maximum: CGFloat) -> CGFloat {
        guard maximum - minimum >= 2 * radius else { return (minimum + maximum) / 2 }
        return min(max(value, minimum + radius), maximum - radius)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/LoupePlacementTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Wire `BoardQuadView` to it, and move `dimming`/loupe off `geo.size`**

In `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadView.swift`:

(a) In `body`, replace the two call sites so both take the fitted image rect instead of the container size:

```swift
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                dimming(outside: viewQuad, in: frame)
                lattice(viewQuad)
                outline(viewQuad)
                handles(viewQuad)
                if let loupeTarget {
                    loupe(at: loupeTarget, frame: frame)
                }
            }
```

(b) Replace `dimming` so it washes only the photo, not the letterbox:

```swift
    /// Dims everything outside the quad (even-odd fill punch-out), so the board
    /// the user is framing is the bright part.
    ///
    /// Scoped to the fitted image rect rather than the container: once the view
    /// is allowed to fill a greedy frame those differ, and washing the letterbox
    /// would draw dark bars around the photo instead of clear ones.
    private func dimming(outside quad: BoardQuad, in frame: CGRect) -> some View {
        Path { path in
            path.addRect(frame)
            path.addLines(quad.points)
            path.closeSubpath()
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }
```

(c) Replace the head of `loupe` — everything from the signature down to and including the `let center = …` binding:

```swift
    /// A magnified inset of the photo centred on the corner being dragged.
    ///
    /// Precision is the entire job of this control, and a dragged corner sits
    /// under the fingertip — exactly where the user needs to look. Placement
    /// (above the corner, flipping below near the top edge, clamped into the
    /// photo on both axes) lives in the unit-tested `LoupePlacement`.
    private func loupe(at point: CGPoint, frame: CGRect) -> some View {
        let diameter = Self.loupeDiameter
        let zoom = Self.loupeZoom
        let center = LoupePlacement.center(for: point, diameter: diameter, in: frame)
```

Leave the rest of the function (the `return Image(decorative:…)` chain through `.allowsHitTesting(false)`) exactly as it is.

- [ ] **Step 6: Build and run the whole unit suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && \
git add "ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadEditor.swift" \
        "ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadView.swift" \
        "ios/KataGo iOS/KataGo iOSTests/BoardQuadEditorTests.swift" && \
git commit -m "fix(photo-import): clamp the grid loupe into the photo on both axes

The inline placement clamped x with min(max(x, r), w - r), which inverts when
the photo is narrower than the 108 pt loupe, and never clamped y at all — with
no .clipped() on the view the magnifier could draw over the board-size picker
and the buttons. Extracted to a tested LoupePlacement, and pointed both it and
the dimming punch-out at the fitted image rect rather than the container, which
stop being the same rect once the photo fills a greedy frame."
```

---

### Task 4: Refuse to write a quad derived from an empty frame

`QuadGeometry.normalizedQuad(fromView:in:)` returns the **entire unit square** for a degenerate frame (`BoardQuadEditor.swift:341-344`), and `.onChanged` writes its result straight into `quad`. Today the frame is constant for the phase's lifetime, so the path is unreachable. A greedy layout makes a zero-height proposal reachable — during presentation, rotation, or an extreme Dynamic Type pass — and the user's carefully placed corners would vanish silently.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadView.swift:84-116`

**Interfaces:**
- Consumes: `CropGeometry.fittedFrame` returning an empty rect for a degenerate container (pinned in Task 2).
- Produces: nothing.

- [ ] **Step 1: Add the guard**

In `quadGesture(editor:frame:)`, insert as the first statement inside `.onChanged`:

```swift
            .onChanged { value in
                // An empty frame makes `normalizedQuad` fall back to the whole
                // unit square, which would silently replace the corners the
                // user just placed. Unreachable while the photo had a fixed
                // size; a greedy frame can be proposed zero height during
                // presentation, rotation, or an extreme Dynamic Type pass.
                guard !frame.isEmpty else { return }

                let active: (startLocation: CGPoint, start: BoardQuad, grab: BoardQuadEditor.Grab)
```

Leave the rest of `.onChanged` unchanged.

- [ ] **Step 2: Build**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `** BUILD SUCCEEDED **`.

There is no unit test for this step: the guard lives inside a SwiftUI gesture closure and the condition it guards (`fittedFrame` returning empty) is already pinned by `FittedFrameTests.degenerateContainerIsEmpty` from Task 2.

- [ ] **Step 3: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && \
git add "ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/BoardQuadView.swift" && \
git commit -m "fix(photo-import): do not overwrite the grid quad from an empty frame

normalizedQuad falls back to the whole unit square for a degenerate frame, and
onChanged wrote that straight into the binding — silently discarding the
corners the user placed. Unreachable while the photo was fixed-size; a greedy
frame can be proposed zero height."
```

---

### Task 5: The photo becomes the flexible, full-bleed child

The core change. `BoardQuadView` stops being capped at `400×400` and instead absorbs whatever the chrome does not need, and the sheet drops its horizontal padding in this phase so the photo reaches the sheet's edges.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/PhotoImportSheet.swift:76-77, 120-139, 143-155, 162-253, 271-293, 295-347`

**Interfaces:**
- Consumes: `BoardQuadView` (unchanged public init).
- Produces:
  - `PhotoImportSheet.isGridPhase: Bool` (private)
  - `PhotoImportSheet.contentPadding: CGFloat` = `24` (private static)
  - `PhotoImportSheet.contentMaxWidth: CGFloat` = `480` (private static)
  - `PhotoImportSheet.sheetMaxWidth: CGFloat` = `560` (private static)

- [ ] **Step 1: Add the constants and the phase gate**

In `PhotoImportSheet.swift`, immediately after the `supportedSizes` declaration (line 76-77), add:

```swift
    /// The sheet's own margin. The grid phase drops it horizontally so the
    /// photo can reach the sheet's edges, and re-adds it to that phase's text,
    /// picker, and buttons.
    private static let contentPadding: CGFloat = 24
    /// The lane the non-grid phases use — unchanged from before the grid phase
    /// widened the sheet.
    private static let contentMaxWidth: CGFloat = 480
    /// The sheet's lane. Wider than `contentMaxWidth` because the photo is the
    /// entire point of the grid phase. Applied for EVERY phase, not just that
    /// one: on macOS an NSHostingController sheet resizes its window to the
    /// SwiftUI root's fitting width, so a phase-dependent cap would make the
    /// sheet window jump on "Adjust Grid".
    private static let sheetMaxWidth: CGFloat = 560

    /// Whether the grid editor is showing. Drives the phase-aware chrome: this
    /// is the only phase whose content wants more room than words need.
    private var isGridPhase: Bool {
        if case .adjustingGrid = phase { return true }
        return false
    }
```

- [ ] **Step 2: Rework `body`**

Replace `body` (lines 120-139) with:

```swift
    public var body: some View {
        VStack(spacing: isGridPhase ? 0 : 20) {
            // The grid phase supplies its own headline and needs every point
            // it can get; on macOS the sheet window's title says this anyway.
            if !isGridPhase {
                Text("Import from Photo")
                    .font(.headline)
            }

            switch phase {
            case .recognizing:
                recognizing
            case .preview(let board):
                preview(board)
            case .adjustingGrid(let context):
                adjustingGrid(context)
            case .failure(let error):
                failure(error)
            }
        }
        .padding(.vertical, Self.contentPadding)
        .padding(.horizontal, isGridPhase ? 0 : Self.contentPadding)
        .frame(maxWidth: Self.sheetMaxWidth)
        .task(id: recognitionAttempt) { await recognize() }
    }
```

- [ ] **Step 3: Re-cap the three non-grid phases so they look unchanged**

The sheet lane grew from 480 to 560, so the phases that are not the grid editor pin themselves back to 480.

In `recognizing` (line 143-155), change the trailing modifier from:

```swift
        .frame(minHeight: 240)
```

to:

```swift
        .frame(maxWidth: Self.contentMaxWidth, minHeight: 240)
```

In `failure(_:)` (line 271-293), make the identical change to its trailing `.frame(minHeight: 240)`.

In `preview(_:)` (line 162-253), append to the outer `VStack(spacing: 16) { … }` — immediately after its closing brace, before the end of the function:

```swift
        .frame(maxWidth: Self.contentMaxWidth)
```

- [ ] **Step 4: Make the photo flexible and full-bleed**

Replace `adjustingGrid(_:)`'s body (lines 296-347) with:

```swift
        VStack(spacing: 16) {
            Text(gridHeadline(for: context))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.contentPadding)

            if let displayImage {
                BoardQuadView(image: displayImage,
                              quad: $editingQuad,
                              boardSize: editingBoardSize)
                    // The photo takes every point the chrome does not need,
                    // and bleeds past the sheet's margins — width is what
                    // binds the aspect fit on every device this ships to, so
                    // those 48 points are the single biggest win available.
                    //
                    // The negative layout priority is what makes it safe:
                    // headline, picker, and buttons get their ideal size
                    // first, so they can never be pushed off a sheet that has
                    // no ScrollView. The photo absorbs the shrinkage instead.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(-1)
            }

            VStack(spacing: 6) {
                Picker("Board size", selection: $editingBoardSize) {
                    ForEach(Self.supportedSizes, id: \.self) { size in
                        Text("\(size)×\(size)").tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("PhotoImportSheet.boardSizePicker")
                Text("The grid should land on the board's lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Self.contentPadding)

            HStack {
                if case .fromPreview(let board, let edited) = context {
                    Button("Back") {
                        editedBoard = edited
                        phase = .preview(board)
                    }
                    .accessibilityIdentifier("PhotoImportSheet.gridBack")
                }
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("PhotoImportSheet.cancel")
                if let onRetry {
                    Button(retryButtonTitle, action: onRetry)
                        .accessibilityIdentifier("PhotoImportSheet.retry")
                }
                Spacer()
                Button("Recognize") {
                    submittedQuad = editingQuad
                    recognitionAttempt += 1
                    phase = .recognizing
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("PhotoImportSheet.recognize")
            }
            .padding(.horizontal, Self.contentPadding)
        }
```

Note the only changes are: the three `.padding(.horizontal, Self.contentPadding)` additions, the `BoardQuadView` frame, and the caption's text. Every identifier and every button stays exactly where it was.

- [ ] **Step 5: Update the doc comment that describes the sheet's shape**

The file header (lines 26-30) explains the grid phase; it is still accurate. No change needed there. Instead, update the stale platform claim on line 6, which says the sheet is "Used by iOS/visionOS and macOS" — `GobanRecogKit` is linked only by the iOS and macOS targets:

```swift
//  Shared preview-and-confirm sheet for importing a game from a board photo.
//  Used by iOS and macOS — the two targets that link GobanRecogKit; there is
//  no photo import on visionOS, tvOS, or watchOS. Four states:
```

- [ ] **Step 6: Build and run the unit suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Turn Task 1's pin green**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan "FullTestPlan" \
  -only-testing:"KataGo AnytimeUITests/PhotoImportGridUITests/testGridRecoveryImportsBoardAfterCornerDrags" \
  2>&1 | tee /tmp/grid-green.log | grep -E "TEST (SUCCEEDED|FAILED)|not using the full sheet width|Preview never appeared"
```

Expected: `** TEST SUCCEEDED **`. Again 6-10 minutes.

If it fails at `"Preview never appeared after Recognize"`, the corner drags stopped landing — that means the `BoardQuadView.gridArea` element frame is no longer identical to the displayed image. Check that `.aspectRatio` and the accessibility modifiers are still attached to the *inner* view in `BoardQuadView.swift` and that the new `.frame` was added at the *call site*, outside them.

- [ ] **Step 8: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && \
git add "ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/PhotoImportSheet.swift" && \
git commit -m "feat(photo-import): let the grid photo fill the sheet

BoardQuadView was capped at 400x400 inside a 24 pt-padded lane, and because
the aspect fit takes the smaller scale the HEIGHT cap was stealing WIDTH: a 3:4
photo rendered 300x400 on an iPhone inside a sheet with ~89 pt of vertical
slack. It is now the flexible child at the lowest layout priority — chrome
keeps its ideal size and can never be clipped, the photo absorbs the rest —
and it bleeds past the sheet's horizontal margins. 300x400 -> 402x536."
```

---

### Task 6: Trim the chrome

Recovers 64 pt above and below the photo. The `.firstFailure` and `.fromPreview` headlines drop to two lines; the picker caption drops to one. "then tap Recognize" goes because the button is a prominent default action two rows below the text. The "outermost line crossing" wording — the guidance that stops users placing corners on the wooden edge — survives in all three variants.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/PhotoImportSheet.swift:349-362`

**Interfaces:**
- Consumes: `GridContext` (unchanged).
- Produces: nothing.

No test asserts any of this copy — verified by grepping the tree for `outermost line crossing`, `overlaid lines`, `Couldn't find the board`, and `Still couldn't read`; the only non-source hit is `BoardQuadView`'s VoiceOver hint, which is not space-constrained and stays as it is.

- [ ] **Step 1: Rewrite the headlines**

Replace `gridHeadline(for:)` (lines 349-362) with:

```swift
    private func gridHeadline(for context: GridContext) -> String {
        switch context {
        // "Line crossings", not "the board's corners": the fit wants the outer
        // GRID intersections, which on most boards sit well inside the wooden
        // edge. Placing them on the wood is the single easiest way to get a
        // grid that is subtly wrong everywhere.
        //
        // Two lines each at the sheet's width (three for the retry, where the
        // extra coaching earns its space). Every line here is a line the photo
        // does not get, and "then tap Recognize" says nothing the prominent
        // default-action button two rows below does not.
        case .firstFailure:
            return "Couldn't find the board. Drag each corner onto the outermost line crossing."
        case .retryFailure:
            return "Still no luck. Corners go on the outermost line crossing, not the wooden edge — and check the size."
        case .fromPreview:
            return "Drag each corner onto the outermost line crossing."
        }
    }
```

The caption under the picker was already shortened to `"The grid should land on the board's lines."` in Task 5, Step 4.

- [ ] **Step 2: Build**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm no CJK crept in**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && \
git diff --cached -U0; git diff -U0 | grep -nP '[\x{4e00}-\x{9fff}\x{3040}-\x{30ff}\x{ac00}-\x{d7af}]' && echo "CJK FOUND — fix before committing" || echo "clean"
```

Expected: `clean`.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && \
git add "ios/KataGo iOS/KataGoUICore/Sources/GobanRecogKit/PhotoImportSheet.swift" && \
git commit -m "feat(photo-import): trim the grid phase's chrome to two lines

Recovers 64 pt for the photo: the outer sheet title is redundant with the
phase's own headline (Task 5), the headlines lose 'then tap Recognize' when
that button is right there, and the picker caption fits one line. The
'outermost line crossing — not the wooden edge' guidance survives in every
variant; it is what stops corners landing on the wood."
```

---

### Task 7: Give iPad and macOS a bigger container

The layout inside the sheet is now maximal, but on iPad the sheet itself is a ~540×620 form sheet and on macOS it is a 420×600 hosting frame. Those containers are the remaining limit.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift:197-213`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift:232-234`

**Interfaces:**
- Consumes: `PhotoImportSheet` (unchanged public init).
- Produces: nothing.

- [ ] **Step 1: Enlarge the iPad sheet**

In `GameSplitView.swift`, in `photoImportSheet(for:)`, add a modifier to the returned `NavigationStack`. Replace:

```swift
        return NavigationStack {
            PhotoImportSheet(
                imageData: pending.imageData,
                suggestedName: pending.suggestedName,
                onImport: { sgf, name in
                    importAndSelect(sgf: sgf, name: name)
                    topUIState.pendingPhotoImport = nil
                },
                onCancel: {
                    topUIState.pendingPhotoImport = nil
                },
                onRetry: onRetry,
                retryButtonTitle: retryButtonTitle
            )
        }
    }
```

with:

```swift
        return NavigationStack {
            PhotoImportSheet(
                imageData: pending.imageData,
                suggestedName: pending.suggestedName,
                onImport: { sgf, name in
                    importAndSelect(sgf: sgf, name: name)
                    topUIState.pendingPhotoImport = nil
                },
                onCancel: {
                    topUIState.pendingPhotoImport = nil
                },
                onRetry: onRetry,
                retryButtonTitle: retryButtonTitle
            )
        }
        // The grid phase's photo is sized by its container, and on iPad the
        // default form sheet (~540x620) is that limit — the layout inside is
        // already maximal. No effect in compact width, where the sheet is
        // full height already.
        .presentationSizing(.page)
    }
```

- [ ] **Step 2: Enlarge the macOS sheet**

In `LibraryActions.swift`, replace:

```swift
        // 600, not 560: the tap-to-correct hint and Reset rows add ~40 pt and
        // must not compress the 320 pt board.
        .frame(minWidth: 420, minHeight: 600)
```

with:

```swift
        // Sized for the grid phase, where the photo is the content: at the old
        // 420x600 it rendered about 233x310. 700 rather than more keeps the
        // sheet inside the 1100x720 default main window. The preview phase
        // caps its own width, so it is unaffected.
        .frame(minWidth: 560, minHeight: 700)
```

- [ ] **Step 3: Build both platforms**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:" && \
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' -configuration Debug \
  2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:"
```

Expected: `** BUILD SUCCEEDED **` twice.

If `.presentationSizing(.page)` does not compile, the fallback named in the spec is `.presentationDetents([.large])` — use it and note the substitution in the commit message.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev" && \
git add "ios/KataGo iOS/KataGo iOS/Game/GameSplitView.swift" \
        "ios/KataGo iOS/KataGo Anytime Mac/LibraryActions.swift" && \
git commit -m "feat(photo-import): give the import sheet a bigger container on iPad and Mac

With the layout inside the sheet now maximal, the containers are the limit:
iPad presented a ~540x620 form sheet and macOS a 420x600 hosting frame, which
left the grid photo at ~233x310 on the Mac. Page-sized presentation on iPad,
560x700 on macOS."
```

---

### Task 8: Full verification

Nothing new is written here. This task proves the whole change across every scheme and suite, then records what only a human can check.

**Files:**
- Modify: none (unless a failure sends you back).

**Interfaces:** none.

- [ ] **Step 1: Build every scheme**

CLAUDE.md requires all five app targets to build. `GobanRecogKit` is linked only by the iOS and macOS targets, but the shared package is in every graph.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && for spec in \
  "KataGo Anytime|platform=iOS Simulator,name=iPhone 17" \
  "KataGo Anytime Mac|platform=macOS" \
  "KataGo Anytime Vision|platform=visionOS Simulator,name=Apple Vision Pro" \
  "KataGo Anytime TV|platform=tvOS Simulator,name=Apple TV" \
  "KataGo Anytime Watch|platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)" ; do
  scheme="${spec%%|*}"; dest="${spec##*|}"
  printf '\n=== %s ===\n' "$scheme"
  xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "$scheme" \
    -destination "$dest" -configuration Debug 2>&1 \
    | grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*|error:"
done
```

Expected: `** BUILD SUCCEEDED **` five times, no `error:` lines.

- [ ] **Step 2: Run the SwiftPM package tests**

These never run under `xcodebuild test`, so a green Xcode run says nothing about them.

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS/KataGoUICore" && \
swift test 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 3: Run the full unit suite**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|error:"
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Run every photo-import UI test**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS" && \
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan "FullTestPlan" \
  -only-testing:"KataGo AnytimeUITests/PhotoImportGridUITests" \
  -only-testing:"KataGo AnytimeUITests/PhotoImportUITests" \
  -only-testing:"KataGo AnytimeUITests/CameraImportUITests" \
  2>&1 | tee /tmp/photo-ui.log | grep -E "TEST (SUCCEEDED|FAILED)|Test Case .* failed"
```

Expected: `** TEST SUCCEEDED **`. Budget 25-40 minutes.

`PhotoImportUITests` matters here even though this change does not touch the preview phase: it carries a literal `board.frame.width == board.frame.height` assertion and a `tapIntersection` closed form, and the shared root padding and `maxWidth` did change.

A `CameraImportUITests` failure whose message is about a cover race is the known flake — rerun that class alone once before treating it as a regression.

- [ ] **Step 5: Manual smoke on iOS**

The layout is not unit-testable and the UI-test fixture is a 4:3 landscape image, so **the removal of the 400 pt height cap is only observable with a portrait photo.** This step is the only coverage it gets.

Launch the app on the iPhone 17 simulator, Import ▸ Photo Library, and for each case reach the grid phase (a failed recognition, or Adjust Grid from the preview):

1. Portrait 3:4 photo — the photo should reach both sheet edges and be visibly taller than wide; the Recognize row must remain fully visible.
2. Landscape 4:3 photo — reaches both sheet edges.
3. Square photo — reaches both sheet edges.
4. Drag a corner to each of the four edges and confirm the loupe never overlaps the board-size picker or the button row.
5. Rotate to landscape mid-phase and confirm the quad's corners stay where they were placed (this is the degenerate-frame guard from Task 4).

- [ ] **Step 6: Manual smoke on iPad and macOS**

1. iPad simulator: confirm `.presentationSizing(.page)` actually produces a bigger sheet than before. If it does not, switch to `.presentationDetents([.large])` per the spec and re-verify.
2. macOS: build a **signed** Debug build — an unsigned one (`CODE_SIGNING_ALLOWED=NO`) crashes at CloudKit setup — then File ▸ Import an image, reach the grid phase via Adjust Grid, and confirm the sheet is 560×700 and the photo fills it.
3. One Dynamic Type XXL pass on iPhone: the chrome must win and nothing may clip; the photo absorbs the shrinkage.

- [ ] **Step 7: Report**

Summarize for the user: measured before/after photo sizes on each platform actually checked, which suites ran green with their verdict lines, and — explicitly — anything from Steps 5-6 that was not exercised. Do not describe manual checks as done if they were not run.

- [ ] **Step 8: Update the project memory**

Append to `/Users/chinchangyang/.claude/projects/-Users-chinchangyang-Code-KataGo-ios-dev/memory/project_photo_import_grid_quad.md`: the commit range for this change, the before/after photo sizes, and the three invariants a future editor must not break — the `gridArea` element frame ≡ the displayed image (or the UI-test drags silently no-op and fail 100 s later with a misleading message), `.layoutPriority(-1)` on the photo being what keeps the buttons reachable in a sheet with no `ScrollView`, and `normalizedQuad`'s unit-square fallback being a live data-loss path now that the frame can be empty.

---

## Self-Review

**Spec coverage.** Every section of `2026-07-31-photo-import-grid-maximize-design.md` maps to a task: the layout table → Task 5; the copy table → Tasks 5 (caption) and 6 (headlines); `presentationSizing` → Task 7; the macOS host frame → Task 7; risk 1 (silent quad destruction) → Task 4; risk 2 (loupe) → Task 3; risk 3 (`geo.size` → `frame`) → Task 3, Step 5; risk 4 (UI-test invariant) → Tasks 1 and 5, Step 7; risk 5 (Dynamic Type) → Task 5's `.layoutPriority(-1)` plus Task 8, Step 6; the testing section → Tasks 1, 2, 3, 8; out-of-scope items are restated in Global Constraints.

**Known gap, stated rather than papered over.** The removal of `maxHeight: 400` has **no automated coverage**. The UI-test fixture (`CropImportUITestSupport.composedCanvasPNG`) is a 2560×1920 4:3 canvas, so width binds and the height cap is inert for it. Task 1's assertion pins the width bleed only; Task 8, Step 5.1 is the sole check on the height cap. Building a portrait fixture would mean a new `--uitest` seam and another 6-10 minute UI test, which is not worth it for a layout constant — but the gap is real and should be named in any review.

**Type consistency.** `LoupePlacement.center(for:diameter:in:)` and `LoupePlacement.gapFraction` are used identically in Task 3's tests, its implementation, and the `BoardQuadView` call site. `dimming(outside:in:)` takes `CGRect` in both its definition and its call site after Task 3, Step 5. `loupe(at:frame:)` loses `in size:` in both places. `Self.contentPadding` / `Self.contentMaxWidth` / `Self.sheetMaxWidth` are declared in Task 5, Step 1 and used in Steps 2, 3, and 4 of the same task. `isGridPhase` is declared in Step 1 and used in Step 2.
