//
//  AnimatedGifEncoder.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2026/7/7.
//

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Streams `CGImage` frames into an animated GIF on disk using ImageIO. Frames
/// are added one at a time and released by the caller between appends, so peak
/// memory stays at roughly a single frame regardless of how long the game is.
///
/// No third-party dependencies — `ImageIO`/`UniformTypeIdentifiers` are available
/// on iOS, visionOS, and macOS.
public final class AnimatedGifEncoder {
    public enum EncodeError: Error {
        case cannotCreateDestination
        case finalizeFailed
    }

    private let destination: CGImageDestination

    /// Creates a GIF at `url` sized for `frameCount` frames.
    /// - Parameter loops: when true the GIF repeats forever; when false it plays
    ///   through once.
    public init(url: URL, frameCount: Int, loops: Bool) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else {
            throw EncodeError.cannotCreateDestination
        }
        self.destination = destination

        // A loop count of 0 means "repeat forever"; 1 means "play once".
        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loops ? 0 : 1
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
    }

    /// Appends one frame shown for `delay` seconds.
    public func append(_ image: CGImage, delay: Double) {
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                // Unclamped delay so fast frames aren't floored to ~0.1s by
                // viewers that clamp the (legacy) DelayTime field.
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ]
        CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
    }

    /// Writes the GIF out. Must be called exactly once, after all frames are
    /// appended.
    public func finalize() throws {
        guard CGImageDestinationFinalize(destination) else {
            throw EncodeError.finalizeFailed
        }
    }
}
