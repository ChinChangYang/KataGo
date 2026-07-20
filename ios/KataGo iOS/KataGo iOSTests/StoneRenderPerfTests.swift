//
//  StoneRenderPerfTests.swift
//  KataGo iOSTests
//

import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import KataGoUICore

/// Render-cost regression guard for the stone layer: rasterizes a dense 19×19
/// board through `ImageRenderer` (the same pipeline as the game-list thumbnail
/// and GIF export) in both stone styles. XCTest (not Swift Testing) so a single
/// class can be selected with -only-testing and so `measure` is available.
@MainActor
final class StoneRenderPerfTests: XCTestCase {

    private static let side: CGFloat = 400
    private static let scale: CGFloat = 2

    /// A full 19×19 with alternating colors — the worst case the bug report
    /// describes ("lots of stones on the board").
    private func denseStones() -> Stones {
        let stones = Stones()
        var black: [BoardPoint] = []
        var white: [BoardPoint] = []
        for x in 0..<19 {
            for y in 0..<19 {
                if (x + y).isMultiple(of: 2) {
                    black.append(BoardPoint(x: x, y: y))
                } else {
                    white.append(BoardPoint(x: x, y: y))
                }
            }
        }
        stones.blackPoints = black
        stones.whitePoints = white
        return stones
    }

    private func renderDenseBoard(classic: Bool,
                                  dark: Bool = false,
                                  scale: CGFloat = StoneRenderPerfTests.scale) -> CGImage? {
        let dimensions = Dimensions(size: CGSize(width: Self.side, height: Self.side),
                                    width: 19,
                                    height: 19)
        let content = ZStack {
            Color(red: 0.75, green: 0.6, blue: 0.4)
            StoneView(dimensions: dimensions,
                      isClassicStoneStyle: classic,
                      verticalFlip: false,
                      isDrawingCapturedStones: false)
        }
        .frame(width: Self.side, height: Self.side)
        .environment(denseStones())
        .environment(GobanState())
        .environment(\.colorScheme, dark ? .dark : .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// Average seconds per render over `count` renders, after the caller has
    /// warmed up shader compilation and first-render caches.
    private func averageRenderSeconds(classic: Bool, count: Int = 5) -> Double {
        let start = ContinuousClock.now
        for _ in 0..<count {
            _ = renderDenseBoard(classic: classic)
        }
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
        return seconds / Double(count)
    }

    func testClassicDenseBoardRenderTime() {
        // Warm-up: shader pipeline compilation and first-render caches.
        XCTAssertNotNil(renderDenseBoard(classic: true))
        // Hard bound so this can actually fail (measure{} alone never does
        // without a stored baseline): the per-stone-view renderer took ~76 ms
        // per frame here, the Canvas renderer ~0.9 ms. 20 ms rejects the old
        // cost with ~20× headroom over the new one.
        XCTAssertLessThan(averageRenderSeconds(classic: true), 0.020)
        measure {
            _ = renderDenseBoard(classic: true)
        }
    }

    func testFastDenseBoardRenderTime() {
        XCTAssertNotNil(renderDenseBoard(classic: false))
        // Old per-stone-view cost ~13 ms per frame, Canvas ~0.5 ms.
        XCTAssertLessThan(averageRenderSeconds(classic: false), 0.005)
        measure {
            _ = renderDenseBoard(classic: false)
        }
    }

    /// Dumps the rendered boards (style × color scheme × scale) as PNGs for
    /// visual comparison when the stone rendering changes; the paths are
    /// printed so a harness can collect them.
    func testDumpRenderedBoards() throws {
        let dumpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stone-render-parity", isDirectory: true)
        try FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        for classic in [true, false] {
            for dark in [false, true] {
                for scale in [1, 2] as [CGFloat] {
                    let image = try XCTUnwrap(renderDenseBoard(classic: classic, dark: dark, scale: scale))
                    let name = "\(classic ? "classic" : "fast")-\(dark ? "dark" : "light")-s\(Int(scale))"
                    let url = dumpDir.appendingPathComponent("\(name).png")
                    let destination = try XCTUnwrap(
                        CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                    print("StoneRenderPerfTests dumped \(url.path)")
                }
            }
        }
    }
}

/// Guards the load-bearing assumption of the Canvas stone renderer: a Canvas
/// symbol carrying the classic stone's `.colorEffect` Metal shader must
/// rasterize with the shader applied, pixel-identical to applying the shader
/// on a directly composited view. (Historical gotcha, found while spiking
/// this: an UNRESOLVABLE shader on a sibling symbol in the same `symbols:`
/// block can corrupt other symbols' rasterization — which is why
/// Shaders.metal is compiled into every target that renders StoneView.)
@MainActor
final class StoneSymbolRenderingTests: XCTestCase {

    private enum SymbolID: Hashable { case white, black }

    private static let stoneLength: CGFloat = 100

    private func renderSymbolProbe() -> CGImage? {
        let d = Self.stoneLength
        let content = ZStack {
            Color(red: 0.75, green: 0.6, blue: 0.4)
            Canvas { context, _ in
                if let black = context.resolveSymbol(id: SymbolID.black) {
                    context.draw(black, at: CGPoint(x: 60, y: 60))
                }
                if let white = context.resolveSymbol(id: SymbolID.white) {
                    context.draw(white, at: CGPoint(x: 180, y: 60))
                }
            } symbols: {
                // Blue base: if the shader is DROPPED this renders a blue
                // circle; if the symbol rasterizes EMPTY the board shows
                // through; if the shader runs we get the glossy black stone.
                Circle()
                    .foregroundStyle(Color.blue)
                    .colorEffect(ShaderLibrary.stone(.float(Float(d)), .float3(0, 0, 0)))
                    .frame(width: d, height: d)
                    .tag(SymbolID.black)
                Circle()
                    .colorEffect(ShaderLibrary.stone(.float(Float(d)), .float3(0.9, 0.9, 0.9)))
                    .frame(width: d, height: d)
                    .tag(SymbolID.white)
            }
            // Direct (non-symbol) shader stone as in production today, for
            // in-image comparison probes at the same crescent offsets.
            Circle()
                .colorEffect(ShaderLibrary.stone(.float(Float(d)), .float3(0, 0, 0)))
                .frame(width: d, height: d)
                .position(x: 60, y: 180)
        }
        .frame(width: 240, height: 240)
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.cgImage
    }

    /// Reads the RGBA of one pixel given in point coordinates (scale 2).
    private func rgba(at point: CGPoint, in image: CGImage) throws -> (r: Int, g: Int, b: Int) {
        let x = Int(point.x * 2), y = Int(point.y * 2)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - (image.height - 1), width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    func testSymbolsPreserveShader() throws {
        let image = try XCTUnwrap(renderSymbolProbe())

        // White symbol control: bright body proves the shader executed there
        // (a dropped shader renders flat `.primary` = black in light mode).
        let whiteBody = try rgba(at: CGPoint(x: 215, y: 60), in: image)
        XCTAssertGreaterThan(whiteBody.r, 180, "white classic stone body should be bright: \(whiteBody)")

        // Black stone glint crescent at UV(0.28, 0.28): symbol-rendered vs
        // direct colorEffect (production path today) must match.
        let symbolCrescent = try rgba(at: CGPoint(x: 38, y: 38), in: image)
        let directCrescent = try rgba(at: CGPoint(x: 38, y: 158), in: image)
        print("StoneSymbolRenderingTests symbolCrescent=\(symbolCrescent) directCrescent=\(directCrescent)")
        XCTAssertGreaterThan(directCrescent.r, 80, "direct black stone should show grey glint: \(directCrescent)")
        XCTAssertEqual(Double(symbolCrescent.r), Double(directCrescent.r), accuracy: 30,
                       "symbol black glint should match direct: \(symbolCrescent) vs \(directCrescent)")

        // Discriminator: if the shader was dropped for the black symbol its
        // blue base shows; if the symbol rasterized empty the board brown
        // shows. Either way the center would not be pure black.
        let blackCenter = try rgba(at: CGPoint(x: 60, y: 60), in: image)
        XCTAssertLessThan(blackCenter.b, 60, "black symbol center should be black, not blue/board: \(blackCenter)")
        XCTAssertLessThan(blackCenter.r, 60, "black symbol center should be black, not board: \(blackCenter)")
    }
}
