# Photo Import: Crop-to-Board Recovery — Design

**Date:** 2026-07-12
**Status:** Approved (brainstorming session)
**Feature:** When board recognition fails on an imported photo (camera, Photos
library, or file), show a crop UI so the user can frame just the board and
retry — instead of the dead-end "Couldn't find a Go board" error. The success
preview also gains an "Adjust Crop" affordance.

## Problem

`PhotoImportSheet` runs the GobanRecog pipeline on the full frame. When
detection fails (board not found, low confidence, ambiguous size) the user gets
a terminal error with only Cancel (and, for camera captures, Retake Photo).
The documented detection-gap class — e.g. IMG_0820, a board on same-tone wood
flooring where every quad proposer grabs the whole frame — is unfixable in the
pipeline but trivially fixable by a human pointing at the board region:
cropping so the board fills the frame turns the "grab the whole frame" failure
mode into the success mode. Cropping also happens before the ≤1280 ingestion
downscale, so a tight crop feeds the recognizer *more* board resolution than
the failed full-frame attempt.

## Decisions (from brainstorming)

1. **Trigger:** crop UI on recognition failure (replacing the dead end), plus
   an **Adjust Crop** button on the success preview. `invalidImage`
   (undecodable data) keeps today's failure screen — nothing to crop.
2. **Crop shape:** axis-aligned rectangle (Photos-style). The pipeline handles
   perspective internally; the user only isolates the board. No 4-corner quad,
   no new C++ entry point — the C++ port's bit-exact lockstep with the Python
   reference and the 600-image eval are untouched.
3. **Scope:** all image-import sources (camera, Photos library, file) on iOS,
   visionOS, and macOS. Camera keeps its Retake Photo button alongside.
4. **Placement:** a new phase inside `PhotoImportSheet` (approach A). No new
   presentation contexts — avoids the codebase's documented cover⇄sheet
   presentation races. Rejected: separate full-screen crop editor (race
   surface, per-platform presentation work); JPEG re-encode crop (lossy —
   near-threshold recognition values are known to shift under re-encode).

## UX flow / states

`PhotoImportSheet.Phase` grows a `cropping` case:

```
recognizing ──ok──────────────► preview ──"Adjust Crop"──► cropping
     │                             ▲                          │
     │ recognitionFailed           │ ok                       │ "Recognize"
     └────────────────────────► cropping ◄──failed────── recognizing(crop)
                                (inline "still couldn't…")
invalidImage ────────────────► failure (unchanged dead end)
```

- **First failure → crop phase.** Photo shown fit-to-view with a draggable
  crop rectangle (initially full frame): 4 corner handles, edge drags,
  interior drag-to-move, dimmed mask outside. Headline: coaching copy along
  the lines of "Couldn't find the board — drag to frame just the board."
  Buttons: **Recognize** (primary), **Cancel**, and **Retake Photo** for
  camera source (same onRetry wiring as today).
- **Cropped attempt fails again:** stay in the crop phase, handles where the
  user left them, inline message along the lines of "Still couldn't read it.
  Tighten the crop to just the board, or retake with less shadow." Loop is
  unbounded; Cancel/Retake always available.
- **Success preview** gains a small **Adjust Crop** button (near the
  confidence/Reset row) that enters the crop phase prefilled with the
  last-used rect (full frame if none) — covers wrong-region / wrong-size
  recognitions without retaking.
- **Crop-from-preview gets a "Back" button** returning to the prior preview
  with the recognized board and any stone-tap edits intact (no re-run).
  Crop-from-failure has no Back — only Cancel/Retake.
- **Re-recognition replaces the board:** stone edits reset and `nextToPlay`
  is re-derived, exactly as for a first recognition.
- Deliberate simplification: fit-to-view image with a draggable rect — no
  pinch-zoom/pan of the image itself (the task is rough isolation, not
  pixel-accurate framing). Revisit only if real usage demands it.

## Architecture / components

All new code in **GobanRecogKit** (shared package; iOS + visionOS + macOS).
The C++ pipeline (`CGobanRecog`) is untouched.

### 1. `BoardImageIngestion` — crop-aware ingestion (correctness core)

New `bgrImage(from: Data, cropNormalized: CGRect?, maxPixelSize:)`.

- **Coordinate convention:** `cropNormalized` is [0,1], top-left origin, in
  the **EXIF-oriented (upright) image space** — the space the user sees and
  the space today's orientation-baked decode
  (`kCGImageSourceCreateThumbnailWithTransform: true`) produces, so SwiftUI
  view coordinates map 1:1 (both y-down).
- **Adaptive decode:** orientation-baked decode with long side
  ≈ `1280 / max(cropW, cropH)`, capped at **4096** (bounds the BGRA transient
  to ~50 MB). Thumbnail decode never upscales, so small originals pass
  through at native size.
- **Crop:** map the normalized rect to an integral pixel rect (clamped to
  bounds), `CGImage.cropping(to:)` — lossless, then the existing
  own-color-space BGRA draw + BGR compaction (Display-P3 discipline and BGR
  channel order unchanged).
- **Post-clamp:** if rounding leaves the long side > 1280, draw-downscale to
  1280 (the pipeline's validated envelope).
- **`cropNormalized == nil` ≡ today's path byte-for-byte.** Full-frame rect
  (0,0,1,1) must also be byte-identical (max(w,h)=1 → 1280 decode → same
  path).
- New display helper: orientation-baked CGImage for the crop view
  (~1600 long side, normal color handling — it's for the screen, not the
  recognizer).

Known trade-off: with the 4096 cap, crops tighter than ~31% of the frame
yield < 1280px of board (15% minimum crop → ~610px), below the tuned
800–1280 envelope but within what the pipeline already accepts for small
inputs. Realistic board crops are 30–80% of frame.

### 2. `BoardRecognizer`

`recognize(imageData:cropNormalized:) async throws -> RecognizedBoard`, same
detached-task pattern; the existing `recognize(imageData:)` forwards with
`nil`. Serialization guarantee unchanged (one sheet, one recognition at a
time — `recognizeGoban` stays non-concurrent).

### 3. New `BoardCropView` (SwiftUI)

Fit-to-view image + crop-rect overlay: 4 corner handles, edge drags, interior
move; dimmed mask outside; minimum crop ~15% per dimension enforced at the
gesture layer; binds a normalized `CGRect`. Pure SwiftUI gestures (touch and
mouse). Accessibility identifiers on the rect and each handle for UI tests.

### 4. `PhotoImportSheet`

- `Phase.cropping(context)` where context distinguishes first-failure /
  cropped-retry-failure / from-preview (drives the message variants and the
  Back button).
- `@State cropRect: CGRect?` remembered for the sheet's lifetime (prefills
  Adjust Crop and re-failures; passed to `recognize`).
- Recognition runs driven by an attempt-keyed `.task(id:)` (attempt counter +
  rect), preserving today's "sheet re-appearance never re-runs a finished
  recognition" behavior; the transition to `.recognizing` debounces
  double-taps on Recognize.

## Error handling / edge cases

- `invalidImage` → unchanged dead-end failure. `recognitionFailed` implies a
  successful decode, so the crop view's display decode is safe; if it fails
  anyway, fall back to the plain failure state.
- Gesture layer clamps rect to bounds + min size; ingestion re-clamps
  defensively and returns nil on a degenerate pixel rect (surfaces as
  `invalidImage`; unreachable in practice).
- Retake-from-crop reuses the existing race-hardened onRetry wiring (flag +
  dismiss + present camera cover from sheet `onDismiss`).
- Cancel available in every phase (dismisses the sheet).
- English-only copy (project discipline).

## Testing

- **Unit (package tests):**
  - Normalized→pixel crop mapping, including EXIF-oriented inputs
    (synthesize a JPEG with orientation 6, crop a known quadrant, assert BGR
    content) — pins the oriented-space convention.
  - `cropNormalized: nil` and full-frame rect byte-identical to the existing
    path on the img0811 fixture.
  - Clamp/degenerate rects; adaptive-decode sizing.
  - **E2E success-after-crop fixture generated in code:** embed the
    known-recognizable img_00009 board into a larger distractor canvas so
    full-frame recognition fails but the center crop succeeds; assert both
    directions. No new binary fixtures.
- **UI tests (KataGo AnytimeUITests):**
  - `--uitest-camera-import-failing` now lands in the crop phase (headline +
    Recognize button asserted).
  - New DEBUG seam with the composed canvas image: fail → drag corner
    handles → Recognize → preview → Import → game exists. Fallback if
    handle-drags are flaky under XCUITest: DEBUG launch-arg pre-setting the
    rect (documented fallback, not primary).
  - Adjust Crop → Back preserves preview and stone edits.
  - Retake from crop phase reopens the camera cover (camera seam).
- **Manual QA:** real IMG_0820 (wood-floor empty board — the documented
  detection-gap case): crop to the board, expect a correct import. This is
  the acceptance case the feature exists for.
- **Builds:** all five schemes still build; GobanRecogKit remains linked only
  to the iOS and Mac app targets (tvOS/watch/widgets stay OpenCV-free).
