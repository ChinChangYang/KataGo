//
//  BoardTopTexture.swift
//  KataGoUICore
//
//  Runtime board-top texture for the 3D goban: procedural wood grain, grid
//  lines, and star points, a Swift port of the asset pipeline generator that
//  used to bake these into per-size PNGs. The bundled board USDZs carry only
//  a 4x4 placeholder top texture; the scene loader swaps in this image, so
//  any width x height renders with the exact look the baked 9/13/19 boards
//  shipped with (same base wood color, grain model, 0.8 mm lines, 2 mm
//  hoshi dots at 5 px/mm with the long side clamped to 2048).
//
//  Determinism: the grain noise comes from a SplitMix64-seeded Box-Muller
//  stream keyed on the board size, so the same board always renders the
//  same wood (bit-parity with the numpy pipeline is NOT a goal; the sine
//  grain and all geometry are exact ports).
//

import CoreGraphics
import Foundation

public struct BoardTopTexture: Sendable {
    public let widthPX: Int
    public let heightPX: Int
    /// RGBA8, row-major from the top-left corner.
    public let pixels: [UInt8]

    /// The buffer as a CGImage (sRGB, alpha last) for TextureResource creation.
    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: widthPX,
                       height: heightPX,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: widthPX * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    public static func generate(boardWidth: Int, boardHeight: Int) -> BoardTopTexture {
        let size = BoardGeometryRules.textureSize(width: boardWidth, height: boardHeight)
        let (widthPX, heightPX) = (size.x, size.y)
        let (boardXMM, boardZMM) = BoardGeometryRules.boardMM(width: boardWidth,
                                                              height: boardHeight)
        let ppmX = Double(widthPX) / boardXMM
        let ppmY = Double(heightPX) / boardZMM
        let spacingX = 22.0 * ppmX
        let spacingY = 23.7 * ppmY
        let marginX = (Double(widthPX) - Double(boardWidth - 1) * spacingX) / 2
        let marginY = (Double(heightPX) - Double(boardHeight - 1) * spacingY) / 2
        let halfLineWidth = 0.5 * BoardGeometryRules.lineWidthMM * ppmX

        func lineCoverage(_ coordinate: Double, center: Double) -> Double {
            min(max(halfLineWidth + 0.5 - abs(coordinate - center), 0), 1)
        }

        // Per-axis line coverage (max over the grid lines on that axis) and
        // the grid-rectangle extent gates that clip line overshoot.
        var coverageX = [Double](repeating: 0, count: widthPX)
        var insideX = [Bool](repeating: false, count: widthPX)
        for x in 0..<widthPX {
            let coordinate = Double(x)
            for i in 0..<boardWidth {
                coverageX[x] = max(coverageX[x],
                                   lineCoverage(coordinate, center: marginX + Double(i) * spacingX))
            }
            insideX[x] = coordinate >= marginX - halfLineWidth
                && coordinate <= marginX + Double(boardWidth - 1) * spacingX + halfLineWidth
        }
        var coverageY = [Double](repeating: 0, count: heightPX)
        var insideY = [Bool](repeating: false, count: heightPX)
        for y in 0..<heightPX {
            let coordinate = Double(y)
            for j in 0..<boardHeight {
                coverageY[y] = max(coverageY[y],
                                   lineCoverage(coordinate, center: marginY + Double(j) * spacingY))
            }
            insideY[y] = coordinate >= marginY - halfLineWidth
                && coordinate <= marginY + Double(boardHeight - 1) * spacingY + halfLineWidth
        }

        var mask = [Double](repeating: 0, count: widthPX * heightPX)
        for y in 0..<heightPX {
            let rowBase = y * widthPX
            let rowCoverage = coverageY[y]
            let rowInside = insideY[y]
            for x in 0..<widthPX {
                let vertical = rowInside ? coverageX[x] : 0
                let horizontal = insideX[x] ? rowCoverage : 0
                mask[rowBase + x] = max(vertical, horizontal)
            }
        }

        // Star points: windowed distance-field dots from the shared rule.
        let hoshiRadius = BoardGeometryRules.starPointRadiusMM * ppmX
        let pad = Int(hoshiRadius.rounded(.up)) + 2
        for point in BoardStarPoints.points(width: boardWidth, height: boardHeight) {
            let centerX = marginX + Double(point.x) * spacingX
            let centerY = marginY + Double(point.y) * spacingY
            let x0 = max(Int(centerX) - pad, 0), x1 = min(Int(centerX) + pad + 1, widthPX)
            let y0 = max(Int(centerY) - pad, 0), y1 = min(Int(centerY) + pad + 1, heightPX)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let dx = Double(x) - centerX
                    let dy = Double(y) - centerY
                    let dot = min(max(hoshiRadius + 0.5 - (dx * dx + dy * dy).squareRoot(), 0), 1)
                    if dot > mask[y * widthPX + x] {
                        mask[y * widthPX + x] = dot
                    }
                }
            }
        }

        // Wood grain + composite. One gaussian per pixel in row-major order.
        var noise = GaussianNoise(seed: 33 &+ (UInt64(boardWidth) << 32) &+ UInt64(boardHeight))
        var pixels = [UInt8](repeating: 255, count: widthPX * heightPX * 4)
        let lineColor = (r: 95.0, g: 65.0, b: 25.0)
        for y in 0..<heightPX {
            let wobbleOffset = 6.0 * sin(Double(y) * 0.004) + 3.0 * sin(Double(y) * 0.013 + 0.7)
            let rowBase = y * widthPX
            for x in 0..<widthPX {
                let wobble = Double(x) + wobbleOffset
                let grain = 3.5 * sin(wobble * 0.09)
                    + 2.5 * sin(wobble * 0.023 + 1.2)
                    + 1.5 * sin(wobble * 0.24 + 0.4)
                    + 1.2 * noise.next()
                let blend = mask[rowBase + x]
                let wood = 1 - blend
                let red = (216.0 + grain) * wood + lineColor.r * blend
                let green = (185.0 + grain * 0.9) * wood + lineColor.g * blend
                let blue = (92.0 + grain * 0.7) * wood + lineColor.b * blend
                let offset = (rowBase + x) * 4
                pixels[offset] = UInt8(min(max(red, 0), 255))
                pixels[offset + 1] = UInt8(min(max(green, 0), 255))
                pixels[offset + 2] = UInt8(min(max(blue, 0), 255))
            }
        }
        return BoardTopTexture(widthPX: widthPX, heightPX: heightPX, pixels: pixels)
    }
}

/// Deterministic standard-normal stream: SplitMix64 + Box-Muller (the spare
/// of each pair is served before the next draw).
private struct GaussianNoise {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) {
        state = seed
    }

    private mutating func nextUniform() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        // (0, 1]: never zero, so log() below is finite.
        return (Double(z >> 11) + 1) * 0x1p-53
    }

    mutating func next() -> Double {
        if let value = spare {
            spare = nil
            return value
        }
        let radius = (-2 * Foundation.log(nextUniform())).squareRoot()
        let angle = 2 * Double.pi * nextUniform()
        spare = radius * sin(angle)
        return radius * cos(angle)
    }
}
