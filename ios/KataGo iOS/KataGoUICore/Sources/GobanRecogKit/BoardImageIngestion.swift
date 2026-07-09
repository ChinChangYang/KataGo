//
//  BoardImageIngestion.swift
//  GobanRecogKit
//
//  Turns a user-picked image (encoded Data — JPEG/PNG/HEIC) into the tightly
//  packed BGR byte buffer the C++ `recognizeGoban` seam expects.
//
//  ⚠️ TWO correctness-critical points, both verified empirically (see the
//  end-to-end + BGR-canary tests):
//
//  1. CHANNEL ORDER IS BGR, NOT RGB. The recognition pipeline computes stone
//     "warmth" as (R − B) / Σ under BGR channel indexing; feeding RGB silently
//     inverts the white/black discriminator. We render into a 32-bit context
//     whose in-memory byte order is B, G, R, (skip) and then compact to a
//     24-bit BGR buffer.
//
//  2. NO COLOR MANAGEMENT. The reference pipeline was calibrated against
//     `cv2.imread`, which ignores a JPEG's ICC profile and returns the raw
//     decoded pixels. Many phone photos carry a Display P3 profile; if we let
//     Core Graphics color-manage P3 → sRGB the pixel values shift enough to
//     break detection (the golden `img0811` fixture abstains under DeviceRGB but
//     recognizes byte-for-byte when decoded in its own space). So we draw into a
//     context using the thumbnail's OWN color space — an identity transform that
//     preserves the raw stored values, matching `cv2.imread`.
//

import CoreGraphics
import Foundation
import ImageIO

/// A tightly packed 24-bit BGR image: `bytes` is `width * height * 3` bytes,
/// row stride `width * 3`, channel order B, G, R — the exact layout of
/// `cv2.imread` and the `recognizeGoban` contract.
public struct BGRImage: Sendable {
    public let bytes: [UInt8]
    public let width: Int
    public let height: Int

    public init(bytes: [UInt8], width: Int, height: Int) {
        self.bytes = bytes
        self.width = width
        self.height = height
    }
}

public enum BoardImageIngestion {

    /// The pipeline's validated resolution envelope: the recognizer's detection
    /// thresholds were tuned on 800×600…1280×960 images, so real photos are
    /// downscaled to a long side of at most this before recognition. A thumbnail
    /// request never upscales a smaller image, so already-small inputs pass
    /// through at their native size (round-tripped through the transform to bake
    /// EXIF orientation).
    public static let maxPixelSize = 1280

    /// Decodes `data` and produces a BGR buffer for `recognizeGoban`, or `nil` if
    /// the data is not a decodable image.
    ///
    /// Steps: create an image source → request an orientation-baked, downscaled
    /// thumbnail (`kCGImageSourceCreateThumbnailWithTransform` +
    /// `kCGImageSourceThumbnailMaxPixelSize`) → draw it into a BGRA context in
    /// the image's own color space → compact to tightly packed BGR.
    public static func bgrImage(from data: Data,
                                maxPixelSize: Int = BoardImageIngestion.maxPixelSize) -> BGRImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return bgrImage(from: source, maxPixelSize: maxPixelSize)
    }

    /// Same as `bgrImage(from:maxPixelSize:)` but from a file URL (used by the
    /// Files / NSOpenPanel entry points in later tasks).
    public static func bgrImage(fromFileURL url: URL,
                                maxPixelSize: Int = BoardImageIngestion.maxPixelSize) -> BGRImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return bgrImage(from: source, maxPixelSize: maxPixelSize)
    }

    private static func bgrImage(from source: CGImageSource, maxPixelSize: Int) -> BGRImage? {
        let options: [CFString: Any] = [
            // Always synthesize a thumbnail (never reuse an embedded one, which
            // may be a low-quality EXIF preview) …
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // … bake EXIF orientation into the pixels so `rows` is upright …
            kCGImageSourceCreateThumbnailWithTransform: true,
            // … and cap the long side at the pipeline's validated envelope.
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return bgrBuffer(from: cgImage)
    }

    /// Draws `cgImage` into a BGRA context in the image's own color space and
    /// returns the compacted tightly packed BGR buffer.
    static func bgrBuffer(from cgImage: CGImage) -> BGRImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // Draw into the image's OWN color space so the draw is an identity
        // transform (no ICC color management), matching cv2.imread.
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        // byteOrder32Little + alphaNoneSkipFirst ⇒ in-memory bytes are B, G, R,
        // skip. (A 32-bit word laid out A,R,G,B from MSB→LSB is stored
        // little-endian as B,G,R,A; "skip first" leaves the A byte unused.)
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let bgraRowBytes = width * 4
        var bgra = [UInt8](repeating: 0, count: bgraRowBytes * height)

        let drew: Bool = bgra.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bgraRowBytes,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        // Compact BGRA → tightly packed 24-bit BGR (drop the skipped alpha byte).
        // recognizeGoban wraps the buffer as a 3-channel Mat, so it must be
        // width*3-strided with no padding.
        let pixelCount = width * height
        var bgr = [UInt8](repeating: 0, count: pixelCount * 3)
        bgra.withUnsafeBufferPointer { src in
            bgr.withUnsafeMutableBufferPointer { dst in
                for i in 0..<pixelCount {
                    dst[i * 3 + 0] = src[i * 4 + 0] // B
                    dst[i * 3 + 1] = src[i * 4 + 1] // G
                    dst[i * 3 + 2] = src[i * 4 + 2] // R
                }
            }
        }
        return BGRImage(bytes: bgr, width: width, height: height)
    }
}
