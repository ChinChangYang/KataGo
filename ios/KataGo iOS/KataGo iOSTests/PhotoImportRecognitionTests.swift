//
//  PhotoImportRecognitionTests.swift
//  KataGo AnytimeTests
//
//  Tests for the photo-import pipeline's Swift layer (GobanRecogKit): image
//  ingestion (CGImageSource thumbnail → BGR) and the async recognizer's
//  entry/error behavior.
//
//  ⚠️ Why there is no full end-to-end "recognize → exact board" test here:
//  the app test target builds Debug, and the C++ recognition core has an
//  optimization-sensitive comparator (an invalid strict-weak ordering). Under
//  the simulator's Debug libc++ hardening that comparator NON-DETERMINISTICALLY
//  trips a trap that aborts the test process mid-recognition (it also makes the
//  golden img0811 abstain in Debug while it recognizes correctly in Release).
//  This is a pre-existing C++-core property, verified only under Release — where
//  the Task 9/10 CLI proves img0811 exact and the 600-image eval passes. So the
//  Swift layer is tested for exactly what it owns, deterministically:
//    - ingestion decodes a real Display-P3 photo to the same tightly packed BGR
//      that cv2.imread produces (the pipeline's calibration reference),
//    - the BGR channel order is load-bearing (the canary),
//    - the >1280 downscale caps the long side,
//    - the async API rejects undecodable data.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import GobanRecogKit

// Token whose bundle is the .xctest test bundle (Swift Testing suites are
// structs, so there is no `self` class to hand `Bundle(for:)`).
private final class FixtureBundleToken {}

private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
    let bundle = Bundle(for: FixtureBundleToken.self)
    // Fall back to the full filename with a nil extension for compound
    // extensions like "bgr.raw" that `withExtension:` doesn't split cleanly.
    let url = bundle.url(forResource: name, withExtension: ext)
        ?? bundle.url(forResource: "\(name).\(ext)", withExtension: nil)
    return try #require(url, "missing bundled fixture \(name).\(ext)")
}

private func fixtureData(_ name: String, _ ext: String = "jpg") throws -> Data {
    try Data(contentsOf: fixtureURL(name, ext))
}

/// Mean absolute per-byte difference between two equal-length buffers.
private func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    precondition(a.count == b.count)
    var total = 0
    for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
    return Double(total) / Double(a.count)
}

struct PhotoImportIngestionTests {

    // MARK: - Golden real-photo ingestion (Display-P3 color management + BGR)

    /// img0811 (602×626, tagged Display P3) ingested through our pipeline must
    /// match `cv2.imread`'s output within a hair. This proves BOTH:
    ///   - the BGR channel order, and
    ///   - the "decode in the image's own color space" fix — without it, Core
    ///     Graphics color-manages Display P3 → sRGB and the pixels shift enough
    ///     to break detection.
    @Test func ingestsRealPhotoToBGRMatchingOpenCVReference() throws {
        let image = try #require(BoardImageIngestion.bgrImage(from: fixtureData("img0811")))
        #expect(image.width == 602)
        #expect(image.height == 626)

        let reference = [UInt8](try fixtureData("img0811", "bgr.raw"))
        #expect(image.bytes.count == reference.count)
        // ImageIO vs libjpeg differ only by a few LSB of YCbCr rounding.
        #expect(meanAbsDiff(image.bytes, reference) < 1.0)
    }

    // MARK: - BGR canary

    /// The ingested buffer matches the BGR reference closely; a channel-swapped
    /// copy (what a silent RGB ingestion bug would produce) diverges massively
    /// from it. If ingestion secretly produced RGB, the first assertion would
    /// fail. Byte-level so it never runs the recognizer on adversarial input
    /// (which would trip the Debug libc++ hardening trap in the C++ core).
    @Test func bgrChannelOrderIsLoadBearing() throws {
        let image = try #require(BoardImageIngestion.bgrImage(from: fixtureData("img0811")))
        let reference = [UInt8](try fixtureData("img0811", "bgr.raw"))

        // Correct BGR ⇒ near-zero diff (measured ~0.17).
        let bgrDiff = meanAbsDiff(image.bytes, reference)
        #expect(bgrDiff < 1.0)

        // Swap B and R (simulate RGB ingestion) ⇒ large diff on a warm wood board
        // (measured ~33).
        var swapped = image.bytes
        for i in stride(from: 0, to: swapped.count, by: 3) {
            swapped.swapAt(i, i + 2)
        }
        let rgbDiff = meanAbsDiff(swapped, reference)
        #expect(rgbDiff > 10.0)
        // And the two interpretations are unambiguously separated.
        #expect(rgbDiff > bgrDiff * 20)
    }

    // MARK: - Downscale path (input > 1280 long side)

    /// A >1280 image is downscaled to the pipeline's validated envelope: the long
    /// side is capped at 1280 and the aspect ratio is preserved. (That the
    /// downscaled board still recognizes is verified in Release via the CLI —
    /// see the file header.)
    @Test func downscaleCapsLongSideToEnvelope() throws {
        let upscaled = try upscaledPNG(fixtureData("img_00009"), scale: 1.5)
        let dims = try imageDimensions(upscaled)
        #expect(max(dims.width, dims.height) > BoardImageIngestion.maxPixelSize)

        let image = try #require(BoardImageIngestion.bgrImage(from: upscaled))
        #expect(max(image.width, image.height) == BoardImageIngestion.maxPixelSize)
        // img_00009 is 4:3, so 1280×960 after the cap.
        #expect(image.width == 1280)
        #expect(image.height == 960)
        #expect(image.bytes.count == image.width * image.height * 3)
    }

    /// A small image at or below the envelope is passed through at native size
    /// (thumbnail requests never upscale).
    @Test func smallImageIsNotUpscaled() throws {
        let image = try #require(BoardImageIngestion.bgrImage(from: fixtureData("img0811")))
        #expect(image.width == 602)
        #expect(image.height == 626)
    }

    // MARK: - Async API error handling

    @Test func recognizeRejectsUndecodableData() async {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        await #expect(throws: BoardRecognitionError.invalidImage) {
            _ = try await BoardRecognizer.recognize(imageData: garbage)
        }
    }

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

    // MARK: - Helpers

    private func upscaledPNG(_ data: Data, scale: Double) throws -> Data {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = Int(Double(cg.width) * scale)
        let h = Int(Double(cg.height) * scale)
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                         bytesPerRow: w * 4, space: colorSpace, bitmapInfo: info))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let big = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, big, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

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

    private func imageDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (cg.width, cg.height)
    }
}
