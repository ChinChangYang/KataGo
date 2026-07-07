//
//  AnimatedGifEncoderTests.swift
//  KataGo iOSTests
//

import Testing
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import KataGoUICore

struct AnimatedGifEncoderTests {
    /// A tiny solid-color RGBA bitmap, enough to exercise the encoder.
    private func solidImage(red: CGFloat) -> CGImage {
        let width = 8, height = 8
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func encodesAnAnimatedGifWithTheExpectedFrameCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif-encoder-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = try AnimatedGifEncoder(url: url, frameCount: 3, loops: true)
        for red in [0.2, 0.5, 0.9] {
            encoder.append(solidImage(red: red), delay: 0.1)
        }
        try encoder.finalize()

        #expect(FileManager.default.fileExists(atPath: url.path))

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        #expect((CGImageSourceGetType(source) as String?) == UTType.gif.identifier)
    }
}
