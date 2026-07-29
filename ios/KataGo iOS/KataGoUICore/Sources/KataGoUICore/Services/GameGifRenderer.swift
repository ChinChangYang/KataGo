//
//  GameGifRenderer.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2026/7/7.
//

import CoreGraphics
import Foundation
import KataGoGameStore
import SwiftUI

/// User-tunable knobs for a game GIF export.
public struct GifExportOptions: Equatable, Sendable {
    /// Pixel width/height of each square frame.
    public var pixelSize: CGFloat
    /// How long each move is shown, in seconds.
    public var secondsPerMove: Double
    /// How long the final position is held before the GIF loops, in seconds.
    public var finalHoldSeconds: Double
    /// Whether the GIF repeats forever (vs. plays once).
    public var loops: Bool
    /// Whether to draw A–T / 1–N board coordinates.
    public var showCoordinates: Bool
    /// Draw stones in the app's Classic (glossy) style vs. Fast (flat) style,
    /// matching the live board's `stoneStyle` setting.
    public var isClassicStoneStyle: Bool
    /// Mirror the board vertically, matching the live board's Vertical Flip.
    public var verticalFlip: Bool

    public init(pixelSize: CGFloat = 480,
                secondsPerMove: Double = 0.6,
                finalHoldSeconds: Double = 1.5,
                loops: Bool = true,
                showCoordinates: Bool = false,
                isClassicStoneStyle: Bool = false,
                verticalFlip: Bool = false) {
        self.pixelSize = pixelSize
        self.secondsPerMove = secondsPerMove
        self.finalHoldSeconds = finalHoldSeconds
        self.loops = loops
        self.showCoordinates = showCoordinates
        self.isClassicStoneStyle = isClassicStoneStyle
        self.verticalFlip = verticalFlip
    }

    /// The smallest square raster that still renders every coordinate label
    /// intact for a `width` x `height` board.
    ///
    /// `ReportBoardView` builds its `Dimensions` with `showPass: false` and
    /// `isDrawingCapturedStones: false`, so on a square frame the cell pitch is
    /// exactly `pixelSize / (max(width, height) + 2)` — the board, one
    /// coordinate band per side, and a half-square margin per side. The board's
    /// labels are clipped to a cell-sized frame, so below
    /// `WidgetCoordinateMetrics.requiredCell` they truncate: a 37x37 exported at
    /// the Low quality's 320 px rendered its last column as "…" instead of "AM",
    /// with "AA"…"AL" collapsed into one unreadable run.
    public static func minimumPixelSize(width: Int, height: Int) -> CGFloat {
        let span = CGFloat(max(width, height) + 2)
        let pitch = WidgetCoordinateMetrics.requiredCell(width: width, height: height)
        return (pitch * span).rounded(.up)
    }

    /// `pixelSize`, raised when coordinates are on to the smallest raster that
    /// keeps every label intact. The user ticked "Show coordinates" in the
    /// export sheet, so the GIF grows a little rather than silently dropping
    /// them — the opposite of the widget, where nobody asked for them and
    /// hiding is the right answer.
    public func effectivePixelSize(width: Int, height: Int) -> CGFloat {
        guard showCoordinates else { return pixelSize }
        return max(pixelSize, Self.minimumPixelSize(width: width, height: height))
    }
}

/// Renders a game's main line to an animated GIF — one frame per move, the
/// position built up stone by stone with the last move highlighted — entirely
/// off-screen and engine-free (positions come from `SgfHelper.gifFrames()`).
///
/// `@MainActor` because SwiftUI's `ImageRenderer` must run on the main actor;
/// the loop yields between frames so long games don't block the UI.
@MainActor
public enum GameGifRenderer {
    public enum RenderError: Error {
        case emptyGame
        case frameRenderFailed
    }

    /// Renders `sgf` to a GIF file and returns its URL (in the temporary
    /// directory, named after `gameName`). `progress` is reported in `0...1`.
    public static func render(sgf: String,
                              options: GifExportOptions,
                              gameName: String,
                              progress: (Double) -> Void = { _ in }) async throws -> URL {
        let helper = SgfHelper(sgf: sgf)
        let frames = helper.gifFrames()
        guard frames.count > 1 else { throw RenderError.emptyGame }

        let width = max(helper.xSize, 1)
        let height = max(helper.ySize, 1)
        // Wide boards need a bigger raster before their "A"+letter column
        // labels stop truncating; every board that already fits is untouched.
        let side = options.effectivePixelSize(width: width, height: height)

        let url = temporaryFileURL(for: gameName)
        let encoder = try AnimatedGifEncoder(url: url, frameCount: frames.count, loops: options.loops)

        for (index, frame) in frames.enumerated() {
            let isLast = index == frames.count - 1
            // The same board the app draws (wood, stone style, star points,
            // last-move dot), rendered engine-free from the replayed frame so
            // the GIF matches the live board — see ReportBoardView.
            let content = ReportBoardView(
                width: width,
                height: height,
                blackVertices: frame.blackStones,
                whiteVertices: frame.whiteStones,
                overlay: .none,
                lastMoveVertex: frame.lastMove,
                isClassicStoneStyle: options.isClassicStoneStyle,
                showCoordinate: options.showCoordinates,
                verticalFlip: options.verticalFlip
            )
            .frame(width: side, height: side)

            let renderer = ImageRenderer(content: content)
            renderer.scale = 1  // frame points == GIF pixels
            guard let cgImage = renderer.cgImage else {
                throw RenderError.frameRenderFailed
            }
            encoder.append(cgImage, delay: isLast ? options.finalHoldSeconds : options.secondsPerMove)

            progress(Double(index + 1) / Double(frames.count))
            await Task.yield()
        }

        try encoder.finalize()
        return url
    }

    /// A stable temp-directory URL named after the game (sanitized), overwritten
    /// on re-export. `ShareLink`/share sheets read the file lazily, so it must
    /// outlive this call — the temporary directory suffices for the session.
    private static func temporaryFileURL(for gameName: String) -> URL {
        let trimmed = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed.isEmpty ? "KataGoAnytime"
            : String(trimmed.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        return URL.temporaryDirectory.appendingPathComponent("\(safe).gif")
    }
}
