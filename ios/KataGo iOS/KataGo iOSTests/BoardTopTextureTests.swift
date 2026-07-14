//
//  BoardTopTextureTests.swift
//  KataGo AnytimeTests
//
//  The runtime board-top texture generator (wood grain + grid lines +
//  hoshi), a Swift port of the asset pipeline's gen_board_top. Probes work
//  in the pipeline's own pixel math: 22 x 23.7 mm cells at the texture's
//  px/mm, grid centered, lines 0.8 mm wide in RGB(95, 65, 25) over wood
//  around RGB(216, 185, 92). Line-center pixels read dark (R < 130) and
//  mid-cell pixels read wood (R > 170) with wide margins over the grain
//  noise. Small boards only: debug-build generation is per-pixel math.
//

import Foundation
import Testing
@testable import KataGoUICore

struct BoardTopTextureTests {
    private struct Probe {
        let texture: BoardTopTexture
        let ppmX: Double
        let ppmY: Double
        let marginX: Double
        let marginY: Double
        let spacingX: Double
        let spacingY: Double

        init(width: Int, height: Int) {
            texture = BoardTopTexture.generate(boardWidth: width, boardHeight: height)
            let (bxMM, bzMM) = BoardGeometryRules.boardMM(width: width, height: height)
            ppmX = Double(texture.widthPX) / bxMM
            ppmY = Double(texture.heightPX) / bzMM
            spacingX = 22.0 * ppmX
            spacingY = 23.7 * ppmY
            marginX = (Double(texture.widthPX) - Double(width - 1) * spacingX) / 2
            marginY = (Double(texture.heightPX) - Double(height - 1) * spacingY) / 2
        }

        func red(atX x: Double, y: Double) -> Int {
            let xi = min(max(Int(x.rounded()), 0), texture.widthPX - 1)
            let yi = min(max(Int(y.rounded()), 0), texture.heightPX - 1)
            return Int(texture.pixels[(yi * texture.widthPX + xi) * 4])
        }

        func lineX(_ i: Int) -> Double { marginX + Double(i) * spacingX }
        func lineY(_ j: Int) -> Double { marginY + Double(j) * spacingY }
    }

    @Test func dimensionsMatchGeometryRules() {
        let probe = Probe(width: 9, height: 9)
        let expected = BoardGeometryRules.textureSize(width: 9, height: 9)
        #expect(probe.texture.widthPX == expected.x)
        #expect(probe.texture.heightPX == expected.y)
        #expect(probe.texture.pixels.count == expected.x * expected.y * 4)
    }

    @Test func generationIsDeterministic() {
        let first = BoardTopTexture.generate(boardWidth: 5, boardHeight: 5)
        let second = BoardTopTexture.generate(boardWidth: 5, boardHeight: 5)
        #expect(first.pixels == second.pixels)
    }

    @Test func linesLandOnTheGridAndCellsStayWood() {
        let probe = Probe(width: 9, height: 9)
        let midCellY = probe.lineY(0) + probe.spacingY / 2
        for i in 0..<9 {
            #expect(probe.red(atX: probe.lineX(i), y: midCellY) < 130)
        }
        let midCellX = probe.lineX(4) + probe.spacingX / 2
        for j in 0..<9 {
            #expect(probe.red(atX: midCellX, y: probe.lineY(j)) < 130)
        }
        // Mid-cell wood, away from any line or hoshi.
        #expect(probe.red(atX: probe.lineX(0) + probe.spacingX / 2,
                          y: probe.lineY(6) + probe.spacingY / 2) > 170)
    }

    @Test func linesClipToTheGridRectangle() {
        let probe = Probe(width: 9, height: 9)
        // The slab margin outside the outer lines is pure wood: sample along
        // a line's axis beyond the grid rectangle.
        #expect(probe.red(atX: probe.lineX(2), y: probe.marginY * 0.3) > 170)
        #expect(probe.red(atX: probe.marginX * 0.3, y: probe.lineY(2)) > 170)
    }

    @Test func hoshiDotsFollowTheSharedRule() {
        let nine = Probe(width: 9, height: 9)
        // (2,2) is a 9x9 hoshi: a probe 5 px diagonally off the intersection
        // is outside the 0.4 mm line half-width but inside the 2 mm dot.
        let offset = 5.0
        #expect(nine.red(atX: nine.lineX(2) + offset, y: nine.lineY(2) + offset) < 130)
        // 8x8 has no hoshi: the same relative probe reads wood.
        let eight = Probe(width: 8, height: 8)
        #expect(eight.red(atX: eight.lineX(2) + offset, y: eight.lineY(2) + offset) > 170)
    }

    @Test func rectangularGridHasWidthColumnsAndHeightRows() {
        let probe = Probe(width: 13, height: 9)
        let midCellY = probe.lineY(0) + probe.spacingY / 2
        for i in 0..<13 {
            #expect(probe.red(atX: probe.lineX(i), y: midCellY) < 130)
            if i < 12 {
                #expect(probe.red(atX: probe.lineX(i) + probe.spacingX / 2, y: midCellY) > 170)
            }
        }
        let midCellX = probe.lineX(0) + probe.spacingX / 2
        for j in 0..<9 {
            #expect(probe.red(atX: midCellX, y: probe.lineY(j)) < 130)
            if j < 8 {
                #expect(probe.red(atX: midCellX, y: probe.lineY(j) + probe.spacingY / 2) > 170)
            }
        }
    }
}
