//
//  GameGifRendererTests.swift
//  KataGo iOSTests
//

import Testing
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import KataGoGameStore
@testable import KataGoUICore

/// End-to-end coverage of the export pipeline: SGF replay → per-move
/// `ReportBoardView` frames → `ImageRenderer` → `AnimatedGifEncoder` → a real
/// GIF on disk. `@MainActor` because `GameGifRenderer` (and `ImageRenderer`) are.
@MainActor
struct GameGifRendererTests {
    @Test func rendersGifWithOneFramePerMovePlusStart() async throws {
        // Same capture game as the frame tests; 4 moves → 5 frames.
        let sgf = "(;FF[4]GM[1]SZ[9];B[aa];W[ba];B[gg];W[ab])"
        let options = GifExportOptions(
            pixelSize: 120, secondsPerMove: 0.2, finalHoldSeconds: 0.4,
            loops: true, showCoordinates: true
        )

        var lastProgress = 0.0
        let url = try await GameGifRenderer.render(
            sgf: sgf, options: options, gameName: "RenderTest"
        ) { lastProgress = $0 }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(lastProgress == 1.0)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 5)   // start position + 4 moves
        #expect((CGImageSourceGetType(source) as String?) == UTType.gif.identifier)
    }

    /// A 37x37 exported at the Low quality's 320 px put the cell pitch at
    /// 8.21 pt — under what the widest column label ("AM") needs at the 5 pt
    /// font floor — so the GIF rendered "…" in its place, with "AA"…"AL"
    /// collapsed into one unreadable run. The user ticked "Show coordinates",
    /// so the raster is raised just enough to keep every label intact instead
    /// of dropping them. Boards that already fit must not move at all.
    @Test func effectivePixelSize_raisesOnlyForBoardsThatWouldTruncate() {
        let low = GifExportOptions(pixelSize: 320, showCoordinates: true)
        #expect(low.effectivePixelSize(width: 9, height: 9) == 320)
        #expect(low.effectivePixelSize(width: 19, height: 19) == 320)
        #expect(low.effectivePixelSize(width: 26, height: 26) == 320)
        #expect(low.effectivePixelSize(width: 37, height: 37) > 320)

        // The raised raster actually clears the pitch it was derived from.
        let raised = low.effectivePixelSize(width: 37, height: 37)
        #expect(raised / CGFloat(37 + 2)
                >= WidgetCoordinateMetrics.requiredCell(width: 37, height: 37))

        // High quality already clears it, so nothing moves.
        let high = GifExportOptions(pixelSize: 640, showCoordinates: true)
        #expect(high.effectivePixelSize(width: 37, height: 37) == 640)

        // Coordinates off: the user gets exactly the raster they picked.
        let bare = GifExportOptions(pixelSize: 320, showCoordinates: false)
        #expect(bare.effectivePixelSize(width: 37, height: 37) == 320)
    }

    /// The frame is square, so its cell pitch is bounded by whichever board
    /// dimension is LONGER — a tall-and-narrow board keeps single-letter
    /// columns and needs less room than a wide one of the same long side.
    @Test func effectivePixelSize_gatesOnTheLongSide() {
        let low = GifExportOptions(pixelSize: 320, showCoordinates: true)
        #expect(low.effectivePixelSize(width: 9, height: 37) == 320)
        #expect(low.effectivePixelSize(width: 37, height: 9) > 320)
    }

    /// End-to-end: the widest board the app can create still exports at the
    /// Low quality without faulting, now at the raised raster.
    @Test func rendersWideBoardAtLowQuality() async throws {
        let sgf = "(;FF[4]GM[1]SZ[37];B[aa];W[bb];B[cc])"
        let options = GifExportOptions(pixelSize: 320, secondsPerMove: 0.2,
                                       finalHoldSeconds: 0.4, loops: true,
                                       showCoordinates: true)
        let url = try await GameGifRenderer.render(
            sgf: sgf, options: options, gameName: "WideBoard")
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 4)   // start + 3 moves
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Frames are rendered at scale 1, so the raster IS the pixel size.
        #expect(CGFloat(frame.width) == options.effectivePixelSize(width: 37, height: 37))
    }

    @Test func emptyGameThrows() async {
        await #expect(throws: GameGifRenderer.RenderError.self) {
            _ = try await GameGifRenderer.render(
                sgf: "(;FF[4]GM[1]SZ[9])", options: GifExportOptions(), gameName: "Empty"
            )
        }
    }
}
