# Photo Import Crop-to-Board Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When board recognition fails on an imported photo, `PhotoImportSheet` shows an in-sheet crop UI (draggable rectangle) so the user can frame just the board and retry — instead of the dead-end "Couldn't find a Go board" error. The success preview gains an "Adjust Crop" button.

**Architecture:** All new code lives in the shared `GobanRecogKit` SwiftPM target (iOS + visionOS + macOS). The crop is applied losslessly at the ingestion layer (`BoardImageIngestion`) *before* the ≤1280 downscale, at an adaptively-chosen decode resolution. The C++ pipeline (`CGobanRecog`) is **never touched**. The sheet's phase machine grows a `cropping` case; crop-rect gesture math is a pure, unit-tested `CropRectEditor`.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing (unit), XCTest (UI), CGImageSource/CoreGraphics, existing GobanRecog recognition seam.

**Spec:** `docs/superpowers/specs/2026-07-12-photo-import-crop-design.md`

## Global Constraints

- **Never modify anything under `KataGoUICore/Sources/CGobanRecog/` or `ThirdParty/opencv/`** — the C++ port is kept in bit-exact lockstep with a Python reference; any change there requires a 600-image eval this feature must not trigger.
- **Never run the C++ recognizer in unit tests on new/marginal images** — the app test target builds Debug, where libc++ hardening can non-deterministically abort inside the recognizer. Unit tests are byte-level only (existing discipline, see the header comment of `PhotoImportRecognitionTests.swift`). End-to-end recognition is exercised ONLY via UI tests with wide-margin synthetic boards.
- **English-only source, comments, and UI copy.**
- **Working directory for all commands:** `/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS` (quote paths — it contains a space).
- **Piped `xcodebuild` exit codes lie** — always `set -o pipefail` or grep for `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **`.
- **New files in app/test targets must be registered in the pbxproj** via `ruby scripts_add_swift_files.rb "<target>" <file>` (SwiftPM package sources under `KataGoUICore/Sources` and `KataGoUICore/Tests` are auto-discovered — do NOT register those).
- **Commit locally after each task; do NOT `git push`** (pushes trigger Xcode Cloud builds and are spaced ≥ ~1 day apart by project policy).
- **Do not modify any SwiftData `@Model`** (CloudKit schema is frozen). This plan touches none.
- Deployment targets are iOS/macOS/visionOS 26 — no availability checks needed for current APIs.
- If a full-suite run shows a rare `PhotoImportUITests` red with an app crash whose stack ends in `np_percentile`'s internal sort: that is a known, pre-existing build-churn heap-corruption bug, not a regression from this work. Re-run; it goes green.

## Known UI-test flake policies (pre-existing)

- Cold-install first run of a UI test can flake on menu timing — re-run warm before diagnosing.
- UI tests run against target `KataGo AnytimeUITests` with `-testPlan FullTestPlan`.

---

### Task 1: Crop-aware ingestion + recognizer parameter

**Files:**
- Modify: `KataGoUICore/Sources/GobanRecogKit/BoardImageIngestion.swift`
- Modify: `KataGoUICore/Sources/GobanRecogKit/BoardRecognizer.swift` (the `recognize(imageData:)` entry point, currently lines 24–29)
- Test: `KataGo iOSTests/PhotoImportRecognitionTests.swift` (existing file — no pbxproj registration needed)

**Interfaces:**
- Consumes: existing `BoardImageIngestion.bgrImage(from:maxPixelSize:)`, `bgrBuffer(from:)`, `BGRImage`, `BoardRecognizer.recognize(image:)`, `BoardRecognitionError`.
- Produces (later tasks rely on these exact signatures):
  - `BoardImageIngestion.bgrImage(from data: Data, cropNormalized: CGRect?, maxPixelSize: Int = BoardImageIngestion.maxPixelSize) -> BGRImage?`
  - `BoardImageIngestion.displayImage(from data: Data, maxPixelSize: Int = BoardImageIngestion.displayMaxPixelSize) -> CGImage?`
  - `BoardImageIngestion.cropDecodeCapPixelSize == 4096`, `BoardImageIngestion.displayMaxPixelSize == 1600`
  - `BoardRecognizer.recognize(imageData: Data, cropNormalized: CGRect? = nil) async throws -> RecognizedBoard`

**Coordinate contract (used everywhere):** `cropNormalized` is a rect in [0,1]², **top-left origin**, in the **EXIF-oriented (upright) image space** — the space the user sees. Ingestion already bakes orientation (`kCGImageSourceCreateThumbnailWithTransform: true`), so this is also the space its output pixels live in.

- [ ] **Step 1: Write the failing tests**

Append to the `PhotoImportIngestionTests` struct in `KataGo iOSTests/PhotoImportRecognitionTests.swift` (inside the struct, after the existing tests; the `fixtureData`/`meanAbsDiff` helpers and the `upscaledPNG` private helper already exist in that file):

```swift
    // MARK: - Crop-aware ingestion
    //
    // The crop rect is normalized [0,1]², TOP-LEFT origin, in the
    // EXIF-oriented (upright) image space. All tests are byte-level — they
    // never run the C++ recognizer (Debug hardening discipline, see header).

    /// `cropNormalized: nil` must be byte-identical to the original entry
    /// point: the crop parameter is additive and the full-frame recognition
    /// path must not change by a single byte.
    @Test func nilCropIsByteIdenticalToOriginalPath() throws {
        let data = try fixtureData("img0811")
        let original = try #require(BoardImageIngestion.bgrImage(from: data))
        let nilCrop = try #require(BoardImageIngestion.bgrImage(from: data, cropNormalized: nil))
        #expect(nilCrop.width == original.width)
        #expect(nilCrop.height == original.height)
        #expect(nilCrop.bytes == original.bytes)
    }

    /// The exact full-frame rect short-circuits onto the nil path.
    @Test func fullFrameCropIsByteIdenticalToNilCrop() throws {
        let data = try fixtureData("img0811")
        let original = try #require(BoardImageIngestion.bgrImage(from: data))
        let fullFrame = try #require(BoardImageIngestion.bgrImage(
            from: data, cropNormalized: CGRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(fullFrame.bytes == original.bytes)
    }

    /// Center-crop of the golden photo matches the corresponding sub-rect of
    /// the cv2.imread reference — pins the normalized→pixel mapping (origin
    /// and scale) against external ground truth, not our own code. img0811 is
    /// 602×626 (≤1280, decoded at native size), so rect (.25,.25,.5,.5) is
    /// the integral of (150.5, 156.5, 301, 313).
    @Test func centerCropMatchesReferenceSubRect() throws {
        let data = try fixtureData("img0811")
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let image = try #require(BoardImageIngestion.bgrImage(from: data, cropNormalized: crop))

        let expected = CGRect(x: 150.5, y: 156.5, width: 301, height: 313).integral
        #expect(image.width == Int(expected.width))
        #expect(image.height == Int(expected.height))

        let reference = [UInt8](try fixtureData("img0811", "bgr.raw"))
        var sub = [UInt8]()
        sub.reserveCapacity(image.bytes.count)
        for row in Int(expected.minY)..<Int(expected.maxY) {
            let rowStart = (row * 602 + Int(expected.minX)) * 3
            sub.append(contentsOf: reference[rowStart..<(rowStart + Int(expected.width) * 3)])
        }
        #expect(meanAbsDiff(image.bytes, sub) < 1.0)
    }

    /// EXIF-oriented input: the crop rect addresses the same upright space the
    /// full (nil-crop) ingestion produces — crop (0,0,.5,.5) of an
    /// orientation-6 JPEG must equal the top-left quadrant of the full upright
    /// ingestion, byte for byte (same decode, same draw path).
    @Test func cropMatchesUprightFullIngestionOnOrientedJPEG() throws {
        let data = try orientedJPEG()
        let full = try #require(BoardImageIngestion.bgrImage(from: data))
        // Orientation 6 uprights the stored 400×200 landscape to 200×400.
        #expect(full.height > full.width)

        let crop = try #require(BoardImageIngestion.bgrImage(
            from: data, cropNormalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(crop.width == full.width / 2)
        #expect(crop.height == full.height / 2)

        var expected = [UInt8]()
        expected.reserveCapacity(crop.bytes.count)
        for row in 0..<crop.height {
            let start = (row * full.width) * 3
            expected.append(contentsOf: full.bytes[start..<(start + crop.width * 3)])
        }
        #expect(crop.bytes == expected)
    }

    /// Adaptive decode: a half-frame crop of a >1280 source decodes at double
    /// resolution first, so the crop keeps the full 1280 envelope rather than
    /// cropping an already-downscaled frame.
    @Test func cropOfLargeImageKeepsEnvelopeResolution() throws {
        // img_00009 is 1280×960; 2.5× → 3200×2400 PNG.
        let big = try upscaledPNG(fixtureData("img_00009"), scale: 2.5)
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let image = try #require(BoardImageIngestion.bgrImage(from: big, cropNormalized: crop))
        // needed decode = 1280/0.5 = 2560 (< 3200 source) → crop = 1280×960.
        #expect(image.width == 1280)
        #expect(image.height == 960)
    }

    /// The adaptive decode is capped (memory bound): a tiny crop cannot demand
    /// an unbounded decode, and an under-envelope result passes through
    /// un-upscaled.
    @Test func tinyCropIsBoundedByDecodeCapAndNeverUpscaled() throws {
        let big = try upscaledPNG(fixtureData("img_00009"), scale: 2.5) // 3200×2400
        let crop = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        // needed = 1280/0.2 = 6400 → capped at 4096; the 3200px source is
        // below the cap so it decodes at native size → crop = 640×480.
        let image = try #require(BoardImageIngestion.bgrImage(from: big, cropNormalized: crop))
        #expect(image.width == 640)
        #expect(image.height == 480)
    }

    @Test func degenerateCropRectYieldsNil() throws {
        let data = try fixtureData("img0811")
        // Fully outside the unit square.
        #expect(BoardImageIngestion.bgrImage(
            from: data, cropNormalized: CGRect(x: 2, y: 2, width: 0.5, height: 0.5)) == nil)
        // Zero-size.
        #expect(BoardImageIngestion.bgrImage(from: data, cropNormalized: .zero) == nil)
    }

    /// The recognizer surfaces a degenerate crop as `.invalidImage` without
    /// ever reaching the C++ pipeline (ingestion returns nil first).
    @Test func recognizeWithDegenerateCropThrowsInvalidImage() async throws {
        let data = try fixtureData("img0811")
        await #expect(throws: BoardRecognitionError.invalidImage) {
            _ = try await BoardRecognizer.recognize(imageData: data, cropNormalized: .zero)
        }
    }

    // MARK: - Display decode (crop-phase preview image)

    @Test func displayImageIsOrientationBakedCappedAndNilOnGarbage() throws {
        let oriented = try orientedJPEG()
        let display = try #require(BoardImageIngestion.displayImage(from: oriented))
        #expect(display.height > display.width) // upright portrait

        let big = try upscaledPNG(fixtureData("img_00009"), scale: 2.5)
        let capped = try #require(BoardImageIngestion.displayImage(from: big))
        #expect(max(capped.width, capped.height) == BoardImageIngestion.displayMaxPixelSize)

        #expect(BoardImageIngestion.displayImage(from: Data([0x00, 0x01])) == nil)
    }
```

Add this private helper below the existing `upscaledPNG` helper in the same struct:

```swift
    /// A stored-landscape JPEG (400×200: left half red, right half blue)
    /// tagged EXIF orientation 6, so it displays upright as 200×400 portrait.
    private func orientedJPEG() throws -> Data {
        let w = 400, h = 200
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: info))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        let cg = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil))
        let props: [CFString: Any] = [kCGImagePropertyOrientation: 6,
                                      kCGImageDestinationLossyCompressionQuality: 1.0]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/PhotoImportIngestionTests" 2>&1 | tail -30
```

Expected: **compile FAILURE** — `bgrImage(from:cropNormalized:)`, `displayImage(from:)`, `cropDecodeCapPixelSize` and the recognizer's `cropNormalized:` label don't exist yet.

- [ ] **Step 3: Implement ingestion**

In `BoardImageIngestion.swift`:

3a. Add two constants right after the existing `maxPixelSize` (line 54):

```swift
    /// Decode ceiling for crop-aware ingestion. A tight crop would otherwise
    /// demand an unbounded decode (maxPixelSize / cropFraction); 4096 bounds
    /// the transient BGRA buffer to ~50 MB while keeping the full 1280
    /// envelope for crops down to ~31% of the frame.
    public static let cropDecodeCapPixelSize = 4096

    /// Long-side cap for `displayImage(from:)` — a screen-resolution preview
    /// for the crop UI, never recognition input.
    public static let displayMaxPixelSize = 1600
```

3b. Add the crop-aware entry point and the display helper after the existing `bgrImage(fromFileURL:maxPixelSize:)`:

```swift
    /// Crop-aware variant of `bgrImage(from:maxPixelSize:)`.
    ///
    /// `cropNormalized` is a rect in [0,1]² with TOP-LEFT origin in the
    /// EXIF-oriented (upright) image space — the space the user sees, and the
    /// space this type's orientation-baked output lives in. The crop happens
    /// BEFORE the ≤`maxPixelSize` downscale, at an adaptively chosen decode
    /// resolution, so a tight crop keeps more board pixels than the full-frame
    /// path had. `nil` and the exact full-frame rect take the original path
    /// byte-for-byte. Returns nil for undecodable data or a degenerate rect.
    public static func bgrImage(from data: Data,
                                cropNormalized: CGRect?,
                                maxPixelSize: Int = BoardImageIngestion.maxPixelSize) -> BGRImage? {
        guard let cropNormalized else {
            return bgrImage(from: data, maxPixelSize: maxPixelSize)
        }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let crop = cropNormalized.standardized.intersection(unit)
        guard crop.width > 0, crop.height > 0 else { return nil }
        if crop == unit {
            return bgrImage(from: data, maxPixelSize: maxPixelSize)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        // Decode large enough that the cropped region's long side lands at
        // maxPixelSize, bounded by the cap. The thumbnail API never upscales
        // past the source's native size.
        let needed = (Double(maxPixelSize) / Double(max(crop.width, crop.height))).rounded(.up)
        let decodeSize = min(Int(needed), cropDecodeCapPixelSize)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSize,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let pixelRect = CGRect(x: crop.origin.x * CGFloat(decoded.width),
                               y: crop.origin.y * CGFloat(decoded.height),
                               width: crop.width * CGFloat(decoded.width),
                               height: crop.height * CGFloat(decoded.height))
            .integral
            .intersection(CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = decoded.cropping(to: pixelRect) else { return nil }

        // .integral rounding can leave the long side a few px over the
        // envelope; scale DOWN to it, never up.
        return bgrBuffer(from: cropped, longSideCappedTo: maxPixelSize)
    }

    /// Orientation-baked, screen-capped decode for DISPLAY in the crop UI.
    /// Unlike the BGR path this is ordinary color-managed rendering — it feeds
    /// the screen, never the recognizer.
    public static func displayImage(from data: Data,
                                    maxPixelSize: Int = BoardImageIngestion.displayMaxPixelSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
```

3c. Give `bgrBuffer` an optional downscale cap. Change its signature and size setup (the rest of the body — colorspace comment, context, compaction — is untouched; only `width`/`height` become `var` and the draw uses them, which it already does):

```swift
    /// Draws `cgImage` into a BGRA context in the image's own color space and
    /// returns the compacted tightly packed BGR buffer. When `cap` is given
    /// and the image's long side exceeds it, the draw downscales to the cap
    /// (aspect preserved) — used by the crop path, whose integral pixel rect
    /// can overshoot the envelope by a few pixels. Callers without a cap get
    /// the original native-size behavior, byte for byte.
    static func bgrBuffer(from cgImage: CGImage, longSideCappedTo cap: Int? = nil) -> BGRImage? {
        var width = cgImage.width
        var height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        if let cap, max(width, height) > cap {
            let scale = Double(cap) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
        }
```

3d. In `BoardRecognizer.swift`, replace the `recognize(imageData:)` function (lines 24–29) with:

```swift
    /// Recognizes the board in an encoded image (`Data` from a Photos pick, a
    /// Files URL, an NSOpenPanel selection, or a camera capture). Ingests to
    /// BGR — optionally cropped to `cropNormalized`, a [0,1]² top-left-origin
    /// rect in the upright image space (the crop-phase UI's output) — runs the
    /// CPU-heavy C++ pipeline on a background task, and maps the result:
    ///   - status `ok`     → a `RecognizedBoard`
    ///   - anything else   → `throw BoardRecognitionError.recognitionFailed(reason:)`
    ///     carrying the raw `failed:<reason>` tail.
    ///   - undecodable data or a degenerate crop → `throw BoardRecognitionError.invalidImage`
    public static func recognize(imageData: Data,
                                 cropNormalized: CGRect? = nil) async throws -> RecognizedBoard {
        guard let image = BoardImageIngestion.bgrImage(from: imageData,
                                                       cropNormalized: cropNormalized) else {
            throw BoardRecognitionError.invalidImage
        }
        return try await recognize(image: image)
    }
```

Add `import CoreGraphics` to `BoardRecognizer.swift`'s imports (it currently imports only `CGobanRecog` and `Foundation`).

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: `** TEST SUCCEEDED **`, all `PhotoImportIngestionTests` pass — including the four pre-existing ones (full-frame path unchanged). If `cropMatchesUprightFullIngestionOnOrientedJPEG`'s bit-equality fails on LSB noise (both sides go through the identical decode+draw, so it should not), relax that single assertion to `meanAbsDiff(crop.bytes, expected) < 0.5` with a comment.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git add "KataGoUICore/Sources/GobanRecogKit/BoardImageIngestion.swift" \
        "KataGoUICore/Sources/GobanRecogKit/BoardRecognizer.swift" \
        "KataGo iOSTests/PhotoImportRecognitionTests.swift"
git commit -m "feat(import): crop-aware BGR ingestion + recognizer crop parameter"
```

---

### Task 2: CropRectEditor — pure crop-geometry (fit, classify, apply)

**Files:**
- Create: `KataGoUICore/Sources/GobanRecogKit/CropRectEditor.swift` (SwiftPM — auto-discovered, no registration)
- Create: `KataGo iOSTests/CropRectEditorTests.swift` (**needs pbxproj registration**, target `KataGo AnytimeTests`)

**Interfaces:**
- Consumes: nothing project-specific (CoreGraphics only).
- Produces (Task 3 relies on these exact signatures):
  - `CropGeometry.fittedFrame(imageSize: CGSize, in container: CGSize) -> CGRect`
  - `CropGeometry.viewRect(fromNormalized: CGRect, in frame: CGRect) -> CGRect`
  - `CropGeometry.normalizedRect(fromView: CGRect, in frame: CGRect) -> CGRect`
  - `CropHandles: OptionSet` with `.minX .maxX .minY .maxY` and `.move == [all four]`
  - `CropRectEditor(bounds: CGRect, minFraction: CGFloat = 0.15, grabRadius: CGFloat = 24)`
  - `CropRectEditor.handles(at point: CGPoint, in rect: CGRect) -> CropHandles`
  - `CropRectEditor.apply(translation: CGSize, handles: CropHandles, to startRect: CGRect) -> CGRect`

- [ ] **Step 1: Write the failing tests**

Create `KataGo iOSTests/CropRectEditorTests.swift`:

```swift
//
//  CropRectEditorTests.swift
//  KataGo AnytimeTests
//
//  Pure-geometry tests for the crop UI's interaction model: aspect-fit
//  framing, normalized↔view mapping, drag classification (corner / edge /
//  interior / outside), and translation clamping (bounds + minimum size).
//

import CoreGraphics
import Testing
import GobanRecogKit

struct CropGeometryTests {

    @Test func fittedFrameLetterboxesLandscapeImageInSquare() {
        let frame = CropGeometry.fittedFrame(imageSize: CGSize(width: 200, height: 100),
                                             in: CGSize(width: 100, height: 100))
        #expect(frame == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func viewAndNormalizedRectsRoundTrip() {
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let normalized = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let view = CropGeometry.viewRect(fromNormalized: normalized, in: frame)
        #expect(view == CGRect(x: 60, y: 70, width: 100, height: 25))
        #expect(CropGeometry.normalizedRect(fromView: view, in: frame) == normalized)
    }

    @Test func degenerateInputsAreSafe() {
        #expect(CropGeometry.fittedFrame(imageSize: .zero, in: CGSize(width: 10, height: 10)) == .zero)
        // A zero frame maps back to the full-frame rect rather than dividing by zero.
        #expect(CropGeometry.normalizedRect(fromView: CGRect(x: 1, y: 1, width: 1, height: 1), in: .zero)
                == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

struct CropRectEditorTests {

    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    private var editor: CropRectEditor { CropRectEditor(bounds: bounds) }
    private let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func classifiesCornersEdgesInteriorAndOutside() {
        #expect(editor.handles(at: CGPoint(x: 102, y: 98), in: rect) == [.minX, .minY])
        #expect(editor.handles(at: CGPoint(x: 298, y: 202), in: rect) == [.maxX, .maxY])
        #expect(editor.handles(at: CGPoint(x: 200, y: 103), in: rect) == .minY) // top edge
        #expect(editor.handles(at: CGPoint(x: 98, y: 150), in: rect) == .minX)  // left edge
        #expect(editor.handles(at: CGPoint(x: 200, y: 150), in: rect) == .move) // interior
        #expect(editor.handles(at: CGPoint(x: 390, y: 20), in: rect) == [])     // far outside
    }

    @Test func cornerDragResizesAndClampsToBoundsAndMinSize() {
        // TL corner dragged up-left past the bounds: clamps to bounds origin.
        let grown = editor.apply(translation: CGSize(width: -500, height: -500),
                                 handles: [.minX, .minY], to: rect)
        #expect(grown == CGRect(x: 0, y: 0, width: 300, height: 200))

        // TL corner dragged down-right past the far side: the minimum size
        // (15% of each bounds dimension) holds against the fixed maxX/maxY.
        let shrunk = editor.apply(translation: CGSize(width: 500, height: 500),
                                  handles: [.minX, .minY], to: rect)
        #expect(shrunk.maxX == rect.maxX)
        #expect(shrunk.maxY == rect.maxY)
        #expect(shrunk.width == bounds.width * 0.15)
        #expect(shrunk.height == bounds.height * 0.15)
    }

    @Test func edgeDragMovesOneSideOnlyAndIgnoresCrossAxis() {
        let out = editor.apply(translation: CGSize(width: 40, height: 999),
                               handles: .maxX, to: rect)
        #expect(out == CGRect(x: 100, y: 100, width: 240, height: 100))
    }

    @Test func moveDragTranslatesWithoutResizingAndClampsInsideBounds() {
        let out = editor.apply(translation: CGSize(width: 500, height: -500),
                               handles: .move, to: rect)
        #expect(out.size == rect.size)
        #expect(out.maxX == bounds.maxX)
        #expect(out.minY == bounds.minY)
    }

    @Test func emptyHandlesLeaveTheRectUntouched() {
        #expect(editor.apply(translation: CGSize(width: 50, height: 50),
                             handles: [], to: rect) == rect)
    }
}
```

- [ ] **Step 2: Register the test file and verify the tests fail**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeTests" "KataGo iOSTests/CropRectEditorTests.swift"
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/CropRectEditorTests" 2>&1 | tail -20
```

Expected: **compile FAILURE** — `CropGeometry` / `CropRectEditor` / `CropHandles` don't exist.

- [ ] **Step 3: Implement**

Create `KataGoUICore/Sources/GobanRecogKit/CropRectEditor.swift`:

```swift
//
//  CropRectEditor.swift
//  GobanRecogKit
//
//  Pure geometry for the crop UI: aspect-fitting the photo into the
//  available container, mapping the crop rect between normalized image space
//  ([0,1]², top-left origin — the BoardImageIngestion crop contract) and view
//  points, classifying where a drag starts (corner / edge / interior), and
//  applying drag translations with bounds- and minimum-size clamping.
//  UI-independent so the whole interaction model is unit-testable;
//  `BoardCropView` is a thin gesture/rendering shell over this.
//

import CoreGraphics

public enum CropGeometry {

    /// The aspect-fit frame of `imageSize` centered in `container` (view
    /// points). Zero or negative inputs produce `.zero`.
    public static func fittedFrame(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width,
                        container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Normalized (top-left-origin, [0,1]²) → view points inside `frame`.
    public static func viewRect(fromNormalized rect: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX * frame.width,
               y: frame.minY + rect.minY * frame.height,
               width: rect.width * frame.width,
               height: rect.height * frame.height)
    }

    /// View points inside `frame` → normalized (top-left-origin, [0,1]²).
    /// A degenerate frame yields the full-frame rect (safe fallback while
    /// layout is settling).
    public static func normalizedRect(fromView rect: CGRect, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(x: (rect.minX - frame.minX) / frame.width,
                      y: (rect.minY - frame.minY) / frame.height,
                      width: rect.width / frame.width,
                      height: rect.height / frame.height)
    }
}

/// Which sides of the crop rect a drag moves: a corner is two sides, an edge
/// is one, and interior "move" is all four (pure translation).
public struct CropHandles: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let minX = CropHandles(rawValue: 1 << 0)
    public static let maxX = CropHandles(rawValue: 1 << 1)
    public static let minY = CropHandles(rawValue: 1 << 2)
    public static let maxY = CropHandles(rawValue: 1 << 3)
    public static let move: CropHandles = [.minX, .maxX, .minY, .maxY]
}

public struct CropRectEditor: Sendable {

    /// The fitted image frame the crop rect lives in (view points).
    public let bounds: CGRect
    /// Minimum crop size as a fraction of each bounds dimension.
    public let minFraction: CGFloat
    /// Grab radius for corners; edge strips use the same distance.
    public let grabRadius: CGFloat

    public init(bounds: CGRect, minFraction: CGFloat = 0.15, grabRadius: CGFloat = 24) {
        self.bounds = bounds
        self.minFraction = minFraction
        self.grabRadius = grabRadius
    }

    /// Classifies a drag that starts at `point` against `rect` (both in view
    /// points): the nearest corner within the grab radius wins, then the
    /// nearest edge strip, then interior move; a start outside every zone is
    /// ignored (empty set).
    public func handles(at point: CGPoint, in rect: CGRect) -> CropHandles {
        let corners: [(CGPoint, CropHandles)] = [
            (CGPoint(x: rect.minX, y: rect.minY), [.minX, .minY]),
            (CGPoint(x: rect.maxX, y: rect.minY), [.maxX, .minY]),
            (CGPoint(x: rect.minX, y: rect.maxY), [.minX, .maxY]),
            (CGPoint(x: rect.maxX, y: rect.maxY), [.maxX, .maxY]),
        ]
        var bestCorner: (distance: CGFloat, handles: CropHandles)?
        for (corner, handles) in corners {
            let d = hypot(point.x - corner.x, point.y - corner.y)
            if d <= grabRadius, d < (bestCorner?.distance ?? .infinity) {
                bestCorner = (d, handles)
            }
        }
        if let bestCorner { return bestCorner.handles }

        // Edge strips: within the grab radius of one side, inside that side's
        // span (extended by the radius so strips reach the corners).
        let withinX = point.x >= rect.minX - grabRadius && point.x <= rect.maxX + grabRadius
        let withinY = point.y >= rect.minY - grabRadius && point.y <= rect.maxY + grabRadius
        var edges: [(distance: CGFloat, handles: CropHandles)] = []
        if withinY {
            edges.append((abs(point.x - rect.minX), .minX))
            edges.append((abs(point.x - rect.maxX), .maxX))
        }
        if withinX {
            edges.append((abs(point.y - rect.minY), .minY))
            edges.append((abs(point.y - rect.maxY), .maxY))
        }
        if let nearest = edges.filter({ $0.distance <= grabRadius })
            .min(by: { $0.distance < $1.distance }) {
            return nearest.handles
        }

        return rect.contains(point) ? .move : []
    }

    /// Applies a drag `translation` to `startRect` for the given handles,
    /// clamping to `bounds` and the minimum size. `startRect` must be the
    /// rect at DRAG START (the same rect for every update of one gesture),
    /// so translations never compound.
    public func apply(translation: CGSize, handles: CropHandles, to startRect: CGRect) -> CGRect {
        guard !handles.isEmpty else { return startRect }
        let minW = bounds.width * minFraction
        let minH = bounds.height * minFraction

        if handles == .move {
            let x = min(max(startRect.minX + translation.width, bounds.minX),
                        bounds.maxX - startRect.width)
            let y = min(max(startRect.minY + translation.height, bounds.minY),
                        bounds.maxY - startRect.height)
            return CGRect(x: x, y: y, width: startRect.width, height: startRect.height)
        }

        var minXv = startRect.minX
        var maxXv = startRect.maxX
        var minYv = startRect.minY
        var maxYv = startRect.maxY
        if handles.contains(.minX) {
            minXv = min(max(minXv + translation.width, bounds.minX), maxXv - minW)
        }
        if handles.contains(.maxX) {
            maxXv = max(min(maxXv + translation.width, bounds.maxX), minXv + minW)
        }
        if handles.contains(.minY) {
            minYv = min(max(minYv + translation.height, bounds.minY), maxYv - minH)
        }
        if handles.contains(.maxY) {
            maxYv = max(min(maxYv + translation.height, bounds.maxY), minYv + minH)
        }
        return CGRect(x: minXv, y: minYv, width: maxXv - minXv, height: maxYv - minYv)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git add "KataGoUICore/Sources/GobanRecogKit/CropRectEditor.swift" \
        "KataGo iOSTests/CropRectEditorTests.swift" \
        "KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(import): pure crop-rect geometry (fit, classify, clamp) with tests"
```

---

### Task 3: BoardCropView — the SwiftUI crop control

**Files:**
- Create: `KataGoUICore/Sources/GobanRecogKit/BoardCropView.swift` (SwiftPM — auto-discovered)

**Interfaces:**
- Consumes: `CropGeometry`, `CropRectEditor`, `CropHandles` (Task 2).
- Produces (Task 4 relies on): `BoardCropView(image: CGImage, cropRect: Binding<CGRect>)` — `cropRect` is normalized top-left-origin, exactly the `bgrImage(from:cropNormalized:)` contract. Accessibility identifier `"BoardCropView.cropArea"` on the whole crop canvas (its frame ≡ the displayed image, because the view constrains itself to the image's aspect ratio — UI tests rely on this to address corners by normalized offset).

There is no unit test for a SwiftUI view; this task's gate is a clean iOS build (the crop-flow UI test in Task 6 exercises the behavior end-to-end).

- [ ] **Step 1: Implement**

Create `KataGoUICore/Sources/GobanRecogKit/BoardCropView.swift`:

```swift
//
//  BoardCropView.swift
//  GobanRecogKit
//
//  The crop control for the photo-import sheet: the photo aspect-fit in the
//  available space with a draggable crop rectangle over it — corner handles,
//  edge drags, and interior move, with classification and clamping in the
//  unit-tested CropRectEditor. Binds a normalized top-left-origin crop rect,
//  the exact convention BoardImageIngestion.bgrImage(from:cropNormalized:)
//  consumes. The view constrains itself to the image's aspect ratio so its
//  bounds ≡ the displayed image; UI tests address corners by normalized
//  offsets on the "BoardCropView.cropArea" element because of this.
//

import SwiftUI

public struct BoardCropView: View {
    private let image: CGImage
    @Binding private var cropRect: CGRect // normalized, top-left origin

    /// The crop rect and handle classification captured at drag start; nil
    /// between drags. Translations always apply to `start`, never to the
    /// live rect, so they cannot compound.
    @State private var drag: (start: CGRect, handles: CropHandles)?

    public init(image: CGImage, cropRect: Binding<CGRect>) {
        self.image = image
        self._cropRect = cropRect
    }

    public var body: some View {
        GeometryReader { geo in
            let frame = CropGeometry.fittedFrame(
                imageSize: CGSize(width: image.width, height: image.height),
                in: geo.size)
            let editor = CropRectEditor(bounds: frame)
            let rect = CropGeometry.viewRect(fromNormalized: cropRect, in: frame)

            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                dimming(around: rect, in: geo.size)
                cropBorder(rect)
            }
            .contentShape(Rectangle())
            .gesture(cropGesture(editor: editor, frame: frame))
        }
        .aspectRatio(CGSize(width: image.width, height: image.height), contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop area")
        .accessibilityHint("Drag the corners to frame the board")
        .accessibilityIdentifier("BoardCropView.cropArea")
    }

    private func cropGesture(editor: CropRectEditor, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = CropGeometry.viewRect(fromNormalized: cropRect, in: frame)
                let active = drag ?? (start: current,
                                      handles: editor.handles(at: value.startLocation, in: current))
                if drag == nil { drag = active }
                guard !active.handles.isEmpty else { return }
                let updated = editor.apply(translation: value.translation,
                                           handles: active.handles,
                                           to: active.start)
                cropRect = CropGeometry.normalizedRect(fromView: updated, in: frame)
            }
            .onEnded { _ in drag = nil }
    }

    /// Dims everything outside the crop rect (even-odd fill punch-out).
    private func dimming(around rect: CGRect, in size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(rect)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// White border + four corner dots. Purely decorative: hit-testing and
    /// grab zones belong to the editor's classification.
    private func cropBorder(_ rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .path(in: rect)
                .stroke(.white, lineWidth: 2)
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.gray.opacity(0.6), lineWidth: 1))
                    .frame(width: 16, height: 16)
                    .position(x: i % 2 == 0 ? rect.minX : rect.maxX,
                              y: i < 2 ? rect.minY : rect.maxY)
            }
        }
        .allowsHitTesting(false)
    }
}
```

- [ ] **Step 2: Verify it builds for iOS and macOS**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
set -o pipefail
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **` twice. (If the Swift 6 compiler rejects the labeled-tuple `@State`, split it into two `@State` optionals `dragStartRect: CGRect?` / `dragHandles: CropHandles?` set and cleared together.)

- [ ] **Step 3: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git add "KataGoUICore/Sources/GobanRecogKit/BoardCropView.swift"
git commit -m "feat(import): BoardCropView draggable crop control"
```

---

### Task 4: PhotoImportSheet crop phase

**Files:**
- Modify: `KataGoUICore/Sources/GobanRecogKit/PhotoImportSheet.swift`

**Interfaces:**
- Consumes: `BoardCropView` (Task 3), `BoardImageIngestion.displayImage(from:)` and `BoardRecognizer.recognize(imageData:cropNormalized:)` (Task 1).
- Produces (Task 6's UI tests rely on): accessibility identifiers `PhotoImportSheet.recognize` (crop-phase primary button), `PhotoImportSheet.cropBack` (Back from crop-from-preview), `PhotoImportSheet.adjustCrop` (preview button); the crop phase keeps `PhotoImportSheet.retry` with the host-provided title (camera: "Retake Photo") so the existing `CameraImportUITests` stays green. Public init is **unchanged**.

Behavior contract (from the spec):
- `recognitionFailed` → crop phase (headline varies: first failure vs cropped-retry failure). `invalidImage` → unchanged terminal failure state.
- Preview gains "Adjust Crop" → crop phase with a Back button restoring the exact preview (board + stone edits).
- "Recognize" stores the edited rect, bumps an attempt counter, and re-enters `.recognizing`; re-recognition resets stone edits and re-derives next-to-play.
- Sheet re-appearance never re-runs a finished recognition (attempt-keyed `.task(id:)` + the `phase == .recognizing` guard).

- [ ] **Step 1: Apply the changes**

1a. Replace the `Phase` enum (currently lines 43–47) with:

```swift
    private enum Phase: Equatable {
        case recognizing
        case preview(RecognizedBoard)
        case cropping(CropContext)
        case failure(BoardRecognitionError)
    }

    /// Why the crop phase is showing — drives the headline and the Back
    /// button. `fromPreview` carries the recognition (and any stone edits) so
    /// Back can restore the exact preview without re-running the pipeline.
    private enum CropContext: Equatable {
        case firstFailure
        case retryFailure
        case fromPreview(RecognizedBoard, edited: RecognizedBoard?)
    }
```

1b. Add the new state properties after `editedBoard` (line 41):

```swift
    /// The last crop submitted to the recognizer (normalized, top-left
    /// origin); nil = full frame. Prefills the crop phase and is reused by
    /// the next Recognize.
    @State private var cropRect: CGRect?
    /// The rect being edited in the crop phase.
    @State private var editingCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Orientation-baked screen-resolution decode shown by the crop phase;
    /// loaded once on first need.
    @State private var displayImage: CGImage?
    /// Bumped by Recognize so the attempt-keyed `.task` restarts recognition.
    @State private var recognitionAttempt = 0
```

1c. In `body`, add the new phase case to the `switch`:

```swift
            case .cropping(let context):
                cropping(context)
```

and change `.task { await recognize() }` to:

```swift
        .task(id: recognitionAttempt) { await recognize() }
```

1d. Replace `recognize()` (currently lines 230–244) with:

```swift
    private func recognize() async {
        // Only a fresh `.recognizing` transition runs the pipeline; the sheet
        // body re-appearing after a result must not re-run it.
        guard phase == .recognizing else { return }
        do {
            let board = try await BoardRecognizer.recognize(imageData: imageData,
                                                            cropNormalized: cropRect)
            // Each successful recognition replaces the position wholesale:
            // stone edits belong to the old board, and the picker default
            // re-derives (the user can still override it afterwards).
            editedBoard = nil
            nextToPlay = board.defaultNextToPlay
            phase = .preview(board)
        } catch let error as BoardRecognitionError {
            phase = phaseAfterFailure(error)
        } catch {
            phase = phaseAfterFailure(.recognitionFailed(reason: "\(error)"))
        }
    }

    /// A failed recognition opens the crop phase — the user can point at the
    /// board — unless the data is undecodable (nothing to crop) or, in a
    /// belt-and-suspenders corner, the display decode fails after ingestion
    /// succeeded; both fall back to the terminal failure state.
    private func phaseAfterFailure(_ error: BoardRecognitionError) -> Phase {
        guard case .recognitionFailed = error else { return .failure(error) }
        if displayImage == nil {
            displayImage = BoardImageIngestion.displayImage(from: imageData)
        }
        guard displayImage != nil else { return .failure(error) }
        editingCropRect = cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return .cropping(cropRect == nil ? .firstFailure : .retryFailure)
    }
```

1e. Add the crop-phase view + headline below the `failure(_:)` builder:

```swift
    @ViewBuilder
    private func cropping(_ context: CropContext) -> some View {
        VStack(spacing: 16) {
            Text(cropHeadline(for: context))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let displayImage {
                BoardCropView(image: displayImage, cropRect: $editingCropRect)
                    .frame(maxWidth: 400, maxHeight: 400)
            }

            HStack {
                if case .fromPreview(let board, let edited) = context {
                    Button("Back") {
                        editedBoard = edited
                        phase = .preview(board)
                    }
                    .accessibilityIdentifier("PhotoImportSheet.cropBack")
                }
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("PhotoImportSheet.cancel")
                if let onRetry {
                    Button(retryButtonTitle, action: onRetry)
                        .accessibilityIdentifier("PhotoImportSheet.retry")
                }
                Spacer()
                Button("Recognize") {
                    cropRect = editingCropRect
                    recognitionAttempt += 1
                    phase = .recognizing
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("PhotoImportSheet.recognize")
            }
        }
    }

    private func cropHeadline(for context: CropContext) -> String {
        switch context {
        case .firstFailure:
            return "Couldn't find the board. Drag the corners to frame just the board, then tap Recognize."
        case .retryFailure:
            return "Still couldn't read the board. Tighten the crop to just the board, or retake the photo with more even lighting."
        case .fromPreview:
            return "Adjust the crop, then tap Recognize."
        }
    }
```

1f. In the preview builder, replace the confidence/Reset `HStack` (currently lines 150–159) with:

```swift
            HStack(spacing: 12) {
                Text("Confidence \(Int((board.confidence * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Adjust Crop") {
                    if displayImage == nil {
                        displayImage = BoardImageIngestion.displayImage(from: imageData)
                    }
                    guard displayImage != nil else { return }
                    editingCropRect = cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                    phase = .cropping(.fromPreview(board, edited: editedBoard))
                }
                .font(.caption)
                .accessibilityIdentifier("PhotoImportSheet.adjustCrop")
                if hasEdits {
                    Button("Reset") { editedBoard = nil }
                        .font(.caption)
                        .accessibilityIdentifier("PhotoImportSheet.reset")
                }
            }
```

1g. Update the file-header comment: the state list gains the `cropping` phase and the failure state's description becomes "terminal coaching copy, reached only for undecodable image data (nothing to crop)". Also update `BoardRecognitionError.userFacingMessage`'s doc comment in `RecognizedBoard.swift` — the `.recognitionFailed` copy is now only the fallback shown when the display decode fails; do not change the strings themselves.

- [ ] **Step 2: Build all four affected platforms**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
set -o pipefail
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **` three times. (tvOS/watchOS don't link GobanRecogKit; they're verified once in Task 7.)

- [ ] **Step 3: Run the existing camera UI tests (must stay green — the failing-image test now lands in the crop phase, which keeps the `PhotoImportSheet.retry` id and "Retake Photo" label)**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -testPlan FullTestPlan \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeUITests/CameraImportUITests" \
  -only-testing:"KataGo AnytimeUITests/PhotoImportUITests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. If a cold-install flake reds, re-run once warm before diagnosing.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git add "KataGoUICore/Sources/GobanRecogKit/PhotoImportSheet.swift" \
        "KataGoUICore/Sources/GobanRecogKit/RecognizedBoard.swift"
git commit -m "feat(import): crop phase in PhotoImportSheet replaces dead-end recognition failure"
```

---

### Task 5: Crop-recovery UI-test seam (composed canvas image)

**Files:**
- Create: `KataGo iOS/App/CropImportUITestSupport.swift` (**needs pbxproj registration**, target `KataGo Anytime`)
- Modify: `KataGo iOS/App/ContentView.swift` (the DEBUG seam block at lines 83–87)

**Interfaces:**
- Consumes: `PhotoImportUITestSupport.boardImageData` (the bundled 1280×960 wide-margin 9×9 board), `PendingPhotoImport`, `TopUIState`.
- Produces (Task 6 relies on): launch argument `--uitest-crop-import`; game name `"UITest Crop Board"`; an image whose **full frame fails recognition** but whose **central [0.25,0.75]² region (the board) recognizes** once cropped.

- [ ] **Step 1: Create the seam**

Create `KataGo iOS/App/CropImportUITestSupport.swift`:

```swift
//
//  CropImportUITestSupport.swift
//  KataGo iOS
//
//  DEBUG-only seam for the crop-recovery UI test. Feeds the photo-import
//  funnel an image the recognizer cannot read full-frame but can read once
//  cropped: the bundled wide-margin 9x9 board (PhotoImportUITestSupport's
//  blob, 1280×960) drawn at 50% linear scale in the center of a 2560×1920
//  canvas whose border carries frame-scale distractor edges (a competing
//  coarse grid and thick frame bars), which defeat full-frame board
//  detection. The UI test drives: full-frame failure → crop phase → corner
//  drags → Recognize → preview → Import. PNG output keeps the composition
//  lossless and pixel-deterministic. Mirrors the other import seams;
//  compiled out of Release entirely.
//

#if DEBUG
import CoreGraphics
import Foundation
import KataGoUICore
import UIKit

enum CropImportUITestSupport {
    /// Pass in `XCUIApplication.launchArguments` to auto-present the
    /// photo-import sheet with the composed crop-recovery canvas.
    static let launchArg = "--uitest-crop-import"

    /// Fixed name so the UI test can find the imported game in the library.
    static let importedGameName = "UITest Crop Board"

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArg)
    }

    /// Idempotently presents the photo-import sheet with the composed canvas.
    /// No-op unless the launch argument is present and nothing is pending yet.
    @MainActor
    static func presentIfNeeded(into topUIState: TopUIState) {
        guard isActive else { return }
        guard topUIState.pendingPhotoImport == nil else { return }
        guard let data = composedCanvasPNG() else { return }
        topUIState.pendingPhotoImport = PendingPhotoImport(
            imageData: data,
            suggestedName: importedGameName,
            source: .fileOrLibrary
        )
    }

    /// The board blob at 50% linear scale centered in a 2× canvas — the board
    /// is exactly the central [0.25,0.75]² of the frame — surrounded by
    /// distractors: a wood-toned base, a competing coarse dark grid across
    /// the whole canvas, and thick dark bars hugging the frame (fake table
    /// edges). The grid is drawn first so the board covers its center.
    static func composedCanvasPNG() -> Data? {
        guard let boardData = PhotoImportUITestSupport.boardImageData,
              let board = UIImage(data: boardData)?.cgImage else { return nil }
        let size = CGSize(width: board.width * 2, height: board.height * 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            // Wood-toned base.
            cg.setFillColor(UIColor(red: 0.72, green: 0.55, blue: 0.35, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            // Competing coarse dark grid across the whole canvas.
            cg.setStrokeColor(UIColor(white: 0.12, alpha: 1).cgColor)
            cg.setLineWidth(10)
            let step = size.width / 7
            for i in 0...7 {
                let p = CGFloat(i) * step
                cg.move(to: CGPoint(x: p, y: 0))
                cg.addLine(to: CGPoint(x: p, y: size.height))
                cg.move(to: CGPoint(x: 0, y: p))
                cg.addLine(to: CGPoint(x: size.width, y: p))
            }
            cg.strokePath()
            // Thick dark bars hugging the frame (fake table edges).
            cg.setFillColor(UIColor(white: 0.08, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: size.width, height: 24))
            cg.fill(CGRect(x: 0, y: size.height - 24, width: size.width, height: 24))
            cg.fill(CGRect(x: 0, y: 0, width: 24, height: size.height))
            cg.fill(CGRect(x: size.width - 24, y: 0, width: 24, height: size.height))
            // The real board, centered at half scale.
            UIImage(cgImage: board).draw(in: CGRect(x: size.width / 4,
                                                    y: size.height / 4,
                                                    width: size.width / 2,
                                                    height: size.height / 2))
        }
        return image.pngData()
    }
}
#endif
```

- [ ] **Step 2: Wire the seam into ContentView**

In `KataGo iOS/App/ContentView.swift`, inside the existing `#if DEBUG` block (lines 83–87), add the third seam after the camera one:

```swift
                #if DEBUG
                PhotoImportUITestSupport.presentIfNeeded(into: topUIState)
                CameraCaptureUITestSupport.presentIfNeeded(into: topUIState)
                CropImportUITestSupport.presentIfNeeded(into: topUIState)
                #endif
```

- [ ] **Step 3: Register the file and build**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo Anytime" "KataGo iOS/App/CropImportUITestSupport.swift"
set -o pipefail
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `added to KataGo Anytime: CropImportUITestSupport.swift`, then `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git add "KataGo iOS/App/CropImportUITestSupport.swift" \
        "KataGo iOS/App/ContentView.swift" \
        "KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "test(import): DEBUG seam composing a crop-recovery canvas image"
```

---

### Task 6: Crop-recovery UI tests

**Files:**
- Create: `KataGo iOSUITests/PhotoImportCropUITests.swift` (**needs pbxproj registration**, target `KataGo AnytimeUITests`)

**Interfaces:**
- Consumes: `--uitest-crop-import` seam + `"UITest Crop Board"` (Task 5), `--uitest-camera-import` seam (existing), identifiers `PhotoImportSheet.recognize` / `.cropBack` / `.adjustCrop` / `.retry` / `.board` and `BoardCropView.cropArea` (Tasks 3–4).

**Spec deviation (deliberate):** the spec listed the composed-canvas "full-frame fails / center-crop succeeds" assertion under unit tests. It lives here as a UI test instead, because Debug unit tests must never run the C++ recognizer (Global Constraints); the UI test asserts both directions end-to-end — crop phase appearing proves the full-frame failure, the preview appearing after Recognize proves the cropped success.

- [ ] **Step 1: Write the tests**

Create `KataGo iOSUITests/PhotoImportCropUITests.swift`:

```swift
//
//  PhotoImportCropUITests.swift
//  KataGo iOSUITests
//
//  End-to-end crop-recovery flow. The DEBUG --uitest-crop-import seam feeds a
//  composed image whose full frame defeats detection but whose central
//  [0.25,0.75]² is the bundled wide-margin 9x9 board. The sheet must land in
//  the crop phase (not a dead-end failure), corner drags must tighten the
//  rect around the board, and Recognize must reach the preview, from which
//  Import creates the game. Also covers Adjust Crop → Back from a successful
//  preview (camera seam, which additionally shows Retake in the crop phase).
//
//  Drag geometry: BoardCropView constrains itself to the image's aspect
//  ratio, so the "BoardCropView.cropArea" element frame ≡ the displayed
//  image and normalized offsets address image fractions directly. The crop
//  rect starts full-frame, so its corners sit at the element's corners; a
//  drag from (0.02,0.02) to (0.22,0.22) grabs the top-left corner (7–8pt
//  from it on a ~340pt-wide sheet, inside the 24pt grab radius) and lands
//  the crop edge at ~0.20 — outside the board's 0.25 with margin.
//

import XCTest

final class PhotoImportCropUITests: XCTestCase {

    private let builtInTitle = "Built-in KataGo Network"
    private let sheetTitle = "Import from Photo"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCropRecoveryImportsBoardAfterCornerDrags() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-crop-import"]
        app.launch()
        launchBuiltInEngine(app)

        let title = app.staticTexts[sheetTitle]
        XCTAssertTrue(title.waitForExistence(timeout: 360),
                      "PhotoImportSheet never appeared — the crop-import launch-arg hook did not fire")

        // Full-frame recognition fails on the composed image → crop phase.
        let recognize = app.buttons["PhotoImportSheet.recognize"].firstMatch
        XCTAssertTrue(recognize.waitForExistence(timeout: 120),
                      "Crop phase ('PhotoImportSheet.recognize') never appeared — full-frame recognition did not fail into the crop UI")
        // A file/library-sourced import offers no camera retry.
        XCTAssertFalse(app.buttons["PhotoImportSheet.retry"].exists,
                       "Retake/retry must not appear for a file-sourced import")

        // Tighten the crop to ~[0.20,0.80]² around the central board.
        let cropArea = app.descendants(matching: .any)["BoardCropView.cropArea"].firstMatch
        XCTAssertTrue(cropArea.waitForExistence(timeout: 10), "Crop area not found")
        drag(cropArea, from: CGVector(dx: 0.02, dy: 0.02), to: CGVector(dx: 0.22, dy: 0.22))
        drag(cropArea, from: CGVector(dx: 0.98, dy: 0.98), to: CGVector(dx: 0.78, dy: 0.78))

        recognize.tap()

        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 120),
                      "Preview never appeared after Recognize — the cropped region did not recognize")

        let importButton = app.buttons["Import"].firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "Import button not found")
        importButton.tap()

        let cell = app.staticTexts["UITest Crop Board"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30),
                      "Imported game 'UITest Crop Board' not found in the library")
    }

    @MainActor
    func testAdjustCropFromPreviewAndBackPreservesPreview() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--uitest-camera-import"] // recognizable board → preview
        app.launch()
        launchBuiltInEngine(app)

        let board = app.descendants(matching: .any)["PhotoImportSheet.board"].firstMatch
        XCTAssertTrue(board.waitForExistence(timeout: 360), "Preview board never appeared")

        let adjust = app.buttons["PhotoImportSheet.adjustCrop"].firstMatch
        XCTAssertTrue(adjust.waitForExistence(timeout: 10), "'Adjust Crop' button not found in preview")
        adjust.tap()

        // Crop phase from a successful preview offers Back and, for a
        // camera source, Retake.
        let back = app.buttons["PhotoImportSheet.cropBack"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "'Back' button not found in crop phase")
        XCTAssertTrue(app.buttons["PhotoImportSheet.retry"].exists,
                      "Camera-sourced crop phase should offer Retake Photo")

        back.tap()
        XCTAssertTrue(board.waitForExistence(timeout: 10),
                      "Preview did not return after Back from the crop phase")
    }

    // MARK: - Helpers

    /// DEBUG forces the model picker — launch the built-in network. Once the
    /// engine is up, GameSplitView mounts and the DEBUG hook auto-presents
    /// the photo-import sheet.
    @MainActor
    private func launchBuiltInEngine(_ app: XCUIApplication) {
        let row = app.staticTexts[builtInTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Model picker row '\(builtInTitle)' not found")
        row.tap()
        let play = app.buttons["ModelDetailView.downloadPlayButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Play button not found")
        play.tap()
    }

    @MainActor
    private func drag(_ element: XCUIElement, from: CGVector, to: CGVector) {
        let start = element.coordinate(withNormalizedOffset: from)
        let end = element.coordinate(withNormalizedOffset: to)
        start.press(forDuration: 0.15, thenDragTo: end)
    }
}
```

- [ ] **Step 2: Register and run**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
ruby scripts_add_swift_files.rb "KataGo AnytimeUITests" "KataGo iOSUITests/PhotoImportCropUITests.swift"
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -testPlan FullTestPlan \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeUITests/PhotoImportCropUITests" 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

**Contingencies (composition is empirical — recognition on the composed canvas has two required properties, and this UI test is what pins them):**
- **Full-frame recognition unexpectedly SUCCEEDS** (test fails with "crop phase never appeared" and a board preview is visible in the failure screenshot): strengthen the distractors in `composedCanvasPNG()` — widen the frame bars to 48px, densify the competing grid (`size.width / 5` step, line width 16), or shrink the board to 40% linear scale (`size.width * 0.3` origin, `0.4` size — and update the test's drag targets and doc comments from 0.25/0.75 to 0.30/0.70 accordingly).
- **Cropped recognition FAILS** (test fails at "Preview never appeared after Recognize"): the crop drags landed inside the board or the distractor grid bleeds into the crop. Loosen the drags to (0.24,0.24)/(0.76,0.76) → crop ≈ [0.22,0.78]², or lighten the grid stroke near the board (draw grid lines only outside the central 55%).
- Recognition is deterministic per image (fixed RNG seed, single-threaded cv), so once green this composition stays green; iterate on the composition, not on retries. For faster iteration than a full UI-test cycle, the recognizer can also be driven headlessly with `swift run gobanrecog-cli` (macOS, Release, raw-BGR input — see the CLI's usage header), but the UI test is the gate.
- **Handle drags flaky under XCUITest** (corner grabs intermittently classified as move/miss across runs): fall back to the spec's documented escape hatch — extend the Task 5 seam with a second launch argument `--uitest-crop-import-preset` that, in addition to presenting the canvas, has `PhotoImportSheet` treat a DEBUG-only preset rect `CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)` as the initial `editingCropRect` (plumbed via a `ProcessInfo` check in `CropImportUITestSupport`, read by the sheet host in `GameSplitView` through a new optional `initialCropRect` init parameter defaulting to nil). The test then skips the drags and taps Recognize directly. Only add this if the drag-based test proves flaky; the drag path is the primary, user-representative test.

- [ ] **Step 3: Commit**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
git add "KataGo iOSUITests/PhotoImportCropUITests.swift" \
        "KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "test(import): end-to-end crop-recovery and adjust-crop UI tests"
```

---

### Task 7: Full verification sweep

**Files:** none (verification only; fix-forward anything it finds).

- [ ] **Step 1: Full unit-test target**

```bash
cd "/Users/chinchangyang/Code/KataGo-ios-dev/ios/KataGo iOS"
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 2: The three photo-import UI suites together**

```bash
set -o pipefail
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -testPlan FullTestPlan \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeUITests/PhotoImportUITests" \
  -only-testing:"KataGo AnytimeUITests/CameraImportUITests" \
  -only-testing:"KataGo AnytimeUITests/PhotoImportCropUITests" 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. (Known pre-existing flakes: cold-install menu timing → re-run warm; rare churn-induced `np_percentile` crash → re-run.)

- [ ] **Step 3: All five schemes build**

```bash
set -o pipefail
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" \
  -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **` five times.

- [ ] **Step 4: Commit any verification fixes**

```bash
git add -A "KataGoUICore/Sources/GobanRecogKit" "KataGo iOSTests" "KataGo iOSUITests" "KataGo iOS/App"
git commit -m "fix(import): verification-sweep follow-ups for crop recovery"  # only if fixes were needed
```

Do **not** push.

---

## Deferred (explicitly out of scope, per spec)

- Pinch-zoom/pan of the photo inside the crop view.
- 4-corner perspective quad + C++ quad injection.
- Manual device QA: the real IMG_0820 photo (wood-floor empty board) cropped to the board — the human acceptance case; and macOS mouse-drag sanity of the crop rect. Flag both to the user at completion.
