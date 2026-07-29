//
//  BoardLineView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2023/9/9.
//

import SwiftUI
import KataGoGameStore

public struct BoardLineView: View {
    let dimensions: Dimensions
    let showPass: Bool
    let verticalFlip: Bool
    @Environment(BoardSize.self) var board

    public init(dimensions: Dimensions, showPass: Bool, verticalFlip: Bool) {
        self.dimensions = dimensions
        self.showPass = showPass
        self.verticalFlip = verticalFlip
    }

    public var body: some View {
        ZStack {
            drawBoardBackground(dimensions: dimensions)
            drawLines(dimensions: dimensions)
            drawStarPoints(dimensions: dimensions)

            if showPass {
                drawPassArea(dimensions: dimensions)
            }

            if dimensions.coordinate {
                drawCoordinate(dimensions: dimensions)
            }
        }
    }

    /// Coordinate labels are clipped to a square-sized frame and their font
    /// floors at `WidgetCoordinateMetrics.fontFloor`, so below that pitch they
    /// TRUNCATE — a wide board's "A"+letter columns collapse to "…". The two
    /// engine-free renderers that share this idiom handle it: the Saved Game
    /// widget hides its labels (`WidgetBoardView.coordinateLabelsFit`) and the
    /// GIF exporter raises its raster (`GifExportOptions.effectivePixelSize`).
    ///
    /// The LIVE board can do neither — its pitch is set by the layout — so it
    /// carries a known, accepted limitation on the widest boards in SHORT
    /// windows. A 37x37 with coordinates needs a container of roughly
    /// 356 x 390 pt (on macOS, which puts the pass tile to the right instead of
    /// below, transpose it: 383 x 376). Measured containers:
    ///
    /// | surface | container | widest intact board |
    /// |---|---|---|
    /// | iPhone portrait | 386 x >=434 pt | 37x37 |
    /// | iPhone landscape | 402 pt tall in total | truncates (never observed; derived) |
    /// | iPad mini portrait | 436 x >=488 pt | 37x37 |
    /// | iPad mini landscape | ~806 x 354 pt | ~32x32 |
    /// | macOS | width floored at 480 pt | width can never truncate |
    /// | tvOS | fixed 1080 x 1080 pt | 37x37, 2.9x margin |
    ///
    /// Deliberately not "fixed": shrinking past the floor makes every board's
    /// labels tinier, and hiding labels the user switched on in Settings is a
    /// worse surprise than a clipped one on the rarest board size. Every board
    /// the stock engine can open (up to 19x19) is intact everywhere.
    /// `BoardCoordinateFitTests` pins the thresholds and
    /// `BoardAccessibilityUITests.testCoordinatePitchClearsTheWidestBoardsFloor`
    /// re-measures the live container, so a layout change that pushes the
    /// COMMON sizes over the line fails loudly.
    private func drawCoordinate(dimensions: Dimensions) -> some View {
        Group {
            ForEach(0..<Int(dimensions.width), id: \.self) { i in
                horizontalCoordinate(i: i, dimensions: dimensions)
            }

            ForEach(0..<Int(dimensions.height), id: \.self) { i in
                verticalCoordinate(i: i, dimensions: dimensions)
            }
        }
    }

    private func horizontalCoordinate(i: Int, dimensions: Dimensions) -> some View {
        Text(Coordinate.xLabelMap[i] ?? "")
            .foregroundStyle(.black)
            .font(.system(size: 500))
            .minimumScaleFactor(0.01)
            .bold()
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(x: dimensions.boardLineStartX + (CGFloat(i) * dimensions.squareLength),
                      y: dimensions.boardLineStartY - dimensions.squareLength)
            // Decorative: BoardAccessibilityOverlay owns the speakable board
            // targets; a bare edge label "A" would collide with them in Voice
            // Control's name space.
            .accessibilityHidden(true)
    }

    private func verticalCoordinate(i: Int, dimensions: Dimensions) -> some View {
        Text(String(i + 1))
            .foregroundStyle(.black)
            .font(.system(size: 500))
            .minimumScaleFactor(0.01)
            .bold()
            .frame(width: dimensions.squareLength, height: dimensions.squareLength)
            .position(x: dimensions.boardLineStartX - dimensions.squareLength,
                      y: dimensions.boardLineStartY + (BoardPoint.getPositionY(y: i, height: dimensions.height, verticalFlip: verticalFlip) * dimensions.squareLength))
            // Decorative — see horizontalCoordinate.
            .accessibilityHidden(true)
    }

    private func drawBoardBackground(dimensions: Dimensions) -> some View {
        Group {
            // The wood asset lives in KataGoGameStore (bottom of the bridge-free
            // stack) so the widget appex draws the SAME texture as this board.
            Image("Wood", bundle: .kataGoGameStore)
                .resizable()
                .frame(width: dimensions.gobanWidth,
                       height: dimensions.gobanHeight)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv8, y: dimensions.squareLengthDiv8)
                .position(x: dimensions.gobanStartX + (dimensions.gobanWidth / 2),
                          y: dimensions.gobanStartY + (dimensions.gobanHeight / 2))
        }
    }

    private func drawPassArea(dimensions: Dimensions) -> some View {
        Group {
            #if os(macOS)
            // macOS relocates the pass tile to the RIGHT of the board's bottom row
            // (see `Dimensions.macPassTileCenter`). `MacBoardInteractionLayer`
            // hit-tests this SAME center, so the visible tile and clickable region
            // stay in lockstep. The "Pass" label sits ONE SQUARE ABOVE the tile so
            // it stays legible above the analysis readout that also renders on the
            // tile itself (the right-side margin above the tile is clear — no
            // coordinate labels there).
            let tileCenter = dimensions.macPassTileCenter()
            let labelCenter = CGPoint(x: tileCenter.x, y: tileCenter.y - dimensions.squareLength)
            #else
            let passPoint = BoardPoint.pass(width: Int(board.width), height: Int(board.height))
            let tileCenter = CGPoint(
                x: dimensions.boardLineStartX + CGFloat(passPoint.x) * dimensions.squareLength,
                y: dimensions.boardLineStartY + CGFloat(passPoint.y) * dimensions.squareLength)
            // Label one square to the LEFT of the below-board tile.
            let labelCenter = CGPoint(
                x: dimensions.boardLineStartX + CGFloat(passPoint.x - 1) * dimensions.squareLength,
                y: dimensions.boardLineStartY + CGFloat(passPoint.y) * dimensions.squareLength)
            #endif

            Image("Wood", bundle: .kataGoGameStore)
                .resizable()
                .frame(width: dimensions.squareLength,
                       height: dimensions.squareLength)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv8, y: dimensions.squareLengthDiv8)
                .position(tileCenter)

            Text("Pass")
                .font(.system(size: 500))
                .minimumScaleFactor(0.01)
                .frame(width: dimensions.squareLength, height: dimensions.squareLength)
                .shadow(radius: dimensions.squareLengthDiv16, x: dimensions.squareLengthDiv8, y: dimensions.squareLengthDiv8)
                .position(labelCenter)
                // Decorative: this label sits BESIDE the pass tile, so a
                // Voice Control "Tap Pass" aimed at it would miss the tile.
                // BoardAccessibilityOverlay's "Pass" element covers the tile
                // itself.
                .accessibilityHidden(true)
        }
    }

    private func drawLines(dimensions: Dimensions) -> some View {
        Path { path in
            // Draw horizontal lines
            for i in 0..<Int(dimensions.height) {
                let y = dimensions.boardLineStartY + CGFloat(i) * dimensions.squareLength
                path.move(to: CGPoint(x: dimensions.boardLineStartX, y: y))
                path.addLine(to: CGPoint(x: dimensions.boardLineStartX + dimensions.boardLineBoundWidth, y: y))
            }

            // Draw vertical lines
            for i in 0..<Int(dimensions.width) {
                let x = dimensions.boardLineStartX + CGFloat(i) * dimensions.squareLength
                path.move(to: CGPoint(x: x, y: dimensions.boardLineStartY))
                path.addLine(to: CGPoint(x: x, y: dimensions.boardLineStartY + dimensions.boardLineBoundHeight))
            }
        }
        .stroke(Color.black)
    }

    private func drawStarPoint(x: Int, y: Int, dimensions: Dimensions) -> some View {
        // Big black dot
        Circle()
            .frame(width: dimensions.squareLengthDiv4, height: dimensions.squareLengthDiv4)
            .foregroundStyle(Color.black)
            .position(x: dimensions.boardLineStartX + CGFloat(x) * dimensions.squareLength,
                      y: dimensions.boardLineStartY + CGFloat(y) * dimensions.squareLength)
    }

    private func drawStarPointsForSize(points: [BoardPoint], dimensions: Dimensions) -> some View {
        ForEach(points, id: \.self) { point in
            drawStarPoint(x: point.x, y: point.y, dimensions: dimensions)
        }
    }

    private func drawStarPoints(dimensions: Dimensions) -> some View {
        let points = BoardStarPoints.points(width: Int(dimensions.width), height: Int(dimensions.height))
            .map { BoardPoint(x: $0.x, y: $0.y) }
        return drawStarPointsForSize(points: points, dimensions: dimensions)
    }
}

#Preview("9x9") {
    struct PreviewHost: View {
        @State private var boardSize = BoardSize()

        var body: some View {
            GeometryReader { geometry in
                let dimensions = Dimensions(
                    size: geometry.size,
                    width: 9,
                    height: 9,
                    showCoordinate: true
                )

                BoardLineView(
                    dimensions: dimensions,
                    showPass: true,
                    verticalFlip: false
                )
                .environment(boardSize)
            }
            .onAppear {
                boardSize.width = 9
                boardSize.height = 9
            }
        }
    }
    return PreviewHost()
}

#Preview("13x13") {
    struct PreviewHost: View {
        @State private var boardSize = BoardSize()
        let width: CGFloat = 13
        let height: CGFloat = 13

        var body: some View {
            GeometryReader { geometry in
                let dimensions = Dimensions(
                    size: geometry.size,
                    width: width,
                    height: height
                )

                BoardLineView(
                    dimensions: dimensions,
                    showPass: true,
                    verticalFlip: false
                )
                .environment(boardSize)
            }
            .onAppear {
                boardSize.width = width
                boardSize.height = height
            }
        }
    }
    return PreviewHost()
}

#Preview("19x19") {
    struct PreviewHost: View {
        @State private var boardSize = BoardSize()
        let width: CGFloat = 19
        let height: CGFloat = 19

        var body: some View {
            GeometryReader { geometry in
                let dimensions = Dimensions(
                    size: geometry.size,
                    width: width,
                    height: height,
                    showCoordinate: true
                )

                BoardLineView(
                    dimensions: dimensions,
                    showPass: true,
                    verticalFlip: false
                )
                .environment(boardSize)
            }
            .onAppear {
                boardSize.width = width
                boardSize.height = height
            }
        }
    }
    return PreviewHost()
}

#Preview("29x29") {
    struct PreviewHost: View {
        @State private var boardSize = BoardSize()
        let width: CGFloat = 29
        let height: CGFloat = 29

        var body: some View {
            GeometryReader { geometry in
                let dimensions = Dimensions(
                    size: geometry.size,
                    width: width,
                    height: height,
                    showCoordinate: true
                )

                BoardLineView(
                    dimensions: dimensions,
                    showPass: true,
                    verticalFlip: false
                )
                .environment(boardSize)
            }
            .onAppear {
                boardSize.width = width
                boardSize.height = height
            }
        }
    }
    return PreviewHost()
}
