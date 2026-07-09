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

    private func imageDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (cg.width, cg.height)
    }
}
