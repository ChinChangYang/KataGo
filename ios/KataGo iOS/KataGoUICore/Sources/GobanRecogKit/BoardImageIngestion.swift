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

    /// Decode ceiling for crop-aware ingestion. A tight crop would otherwise
    /// demand an unbounded decode (maxPixelSize / cropFraction); 4096 bounds
    /// the transient BGRA buffer to ~50 MB while keeping the full 1280
    /// envelope for crops down to ~31% of the frame.
    public static let cropDecodeCapPixelSize = 4096

    /// Long-side cap for `displayImage(from:)` — a screen-resolution preview
    /// for the crop UI, never recognition input.
    public static let displayMaxPixelSize = 1600

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
        let standardized = cropNormalized.standardized
        // Only reach for `.intersection` when actually clamping is needed: it
        // recomputes width/height as maxX-minX, and binary floating point
        // addition (e.g. 0.4 + 0.2 = 0.6000000000000001) can perturb an
        // already-in-bounds width/height by an ULP or two — enough for the
        // later `.integral` rounding to overshoot by a pixel. A rect already
        // inside the unit square needs no clamping, so its bits pass through
        // untouched.
        let crop = unit.contains(standardized) ? standardized : standardized.intersection(unit)
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
