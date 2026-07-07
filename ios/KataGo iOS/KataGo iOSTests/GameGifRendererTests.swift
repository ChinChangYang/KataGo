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
@testable import KataGoUICore

/// End-to-end coverage of the export pipeline: SGF replay → per-move
/// `WidgetBoardView` frames → `ImageRenderer` → `AnimatedGifEncoder` → a real
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

    @Test func emptyGameThrows() async {
        await #expect(throws: GameGifRenderer.RenderError.self) {
            _ = try await GameGifRenderer.render(
                sgf: "(;FF[4]GM[1]SZ[9])", options: GifExportOptions(), gameName: "Empty"
            )
        }
    }
}
