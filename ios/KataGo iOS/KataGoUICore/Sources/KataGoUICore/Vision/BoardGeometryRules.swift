//
//  BoardGeometryRules.swift
//  KataGoUICore
//
//  Analytic construction rules for the 3D goban family, replacing the
//  bundled boards_manifest.json: the bundled USDZs are geometry-only and
//  everything per-size (intersection positions, slab dimensions, leg
//  placement, texture sizing) is computed from the same parametric rules
//  the asset pipeline used to bake them, so the formulas must reproduce the
//  legacy manifest values for 9/13/19 exactly (locked by tests).
//
//  Grid pitch is a physical constant (22 x 23.7 mm cells) for every size;
//  the slab grows with the board. Slab thickness and leg height key off the
//  WIDTH only, because a rectangular W x H board reuses the W x W square
//  asset with its slab depth-stretched; the leg radial scale uses the real
//  rectangle so the feet always keep a 4 mm gap across the center and stay
//  inside the footprint.
//

import Foundation
import simd

/// Derived physical dimensions (meters unless suffixed MM) for one board.
public struct BoardDimensions: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Slab footprint along the grid columns (x), millimeters.
    public let boardXMM: Double
    /// Slab footprint along the grid rows (z / depth), millimeters.
    public let boardZMM: Double
    /// Slab thickness, clamped like the asset pipeline.
    public let thickness: Double
    public let legHeight: Double
    /// Leg vertical scale relative to the reference (9x9) leg.
    public let kz: Double
    /// Leg/foot radial scale relative to the reference foot.
    public let kr: Double

    /// Board-top height above the floor: where stones rest.
    public var topY: Double { legHeight + thickness }
    /// Foot center inset from each slab edge.
    public var inset: Double { 0.040 * kr }
    public var footRadius: Double { 0.029 * kr }
}

public enum BoardGeometryRules {
    /// Physical cell pitch, meters (constant across every board size).
    public static let spacingX: Double = 0.022
    public static let spacingZ: Double = 0.0237
    /// Grid line width and star-point radius, millimeters (texture drawing).
    public static let lineWidthMM: Double = 0.8
    public static let starPointRadiusMM: Double = 2.0
    /// Grid margin from the outermost lines to the slab edge, millimeters.
    public static let marginXMM: Double = 13.5
    public static let marginZMM: Double = 14.7

    /// Reference (9x9) constants the scaling rules anchor on.
    private static let referenceBoardXMM: Double = 203.0
    private static let referenceThickness: Double = 0.022
    private static let referenceLegHeight: Double = 0.040

    /// Slab footprint in millimeters: grid span plus the fixed margins.
    public static func boardMM(width: Int, height: Int) -> (x: Double, z: Double) {
        (Double(width - 1) * 22.0 + 27.0, Double(height - 1) * 23.7 + 29.4)
    }

    public static func dimensions(width: Int, height: Int) -> BoardDimensions {
        let (boardXMM, boardZMM) = boardMM(width: width, height: height)
        let scale = boardXMM / referenceBoardXMM
        let thickness = min(max(referenceThickness * scale, 0.012), 0.060)
        let legHeight = min(max(referenceLegHeight * scale, 0.025), 0.070)
        let kz = legHeight / referenceLegHeight
        // Radial cap: the two feet on each axis keep a >=4 mm gap across the
        // center and stay fully inside the footprint (0.069 = inset + foot
        // radius at reference scale).
        let kr = min(kz,
                     (boardXMM / 2000.0 - 0.002) / 0.069,
                     (boardZMM / 2000.0 - 0.002) / 0.069)
        return BoardDimensions(width: width, height: height,
                               boardXMM: boardXMM, boardZMM: boardZMM,
                               thickness: thickness, legHeight: legHeight,
                               kz: kz, kr: kr)
    }

    /// World position of intersection (x, y): grid centered on the origin,
    /// GTP row 1 (y = 0) toward the viewer at +z, column A at -x.
    public static func intersection(x: Int, y: Int, width: Int, height: Int,
                                    topY: Double) -> SIMD3<Float> {
        SIMD3<Float>(Float((Double(x) - Double(width - 1) / 2) * spacingX),
                     Float(topY),
                     Float((Double(height - 1) / 2 - Double(y)) * spacingZ))
    }

    /// Generated board-top texture size in pixels: 5 px/mm target with the
    /// LONG slab side clamped to [512, 2048] and both sides multiples of 4
    /// (the pipeline rule, generalized to rectangles where the width can be
    /// the long side). Reproduces the shipped baked texture dimensions.
    public static func textureSize(width: Int, height: Int) -> SIMD2<Int> {
        let (boardXMM, boardZMM) = boardMM(width: width, height: height)
        let longMM = max(boardXMM, boardZMM)
        let shortMM = min(boardXMM, boardZMM)
        let longPX = Int((min(max(longMM * 5.0, 512.0), 2048.0) / 4.0).rounded()) * 4
        let pxPerMM = Double(longPX) / longMM
        let shortPX = Int((shortMM * pxPerMM / 4.0).rounded()) * 4
        return boardXMM >= boardZMM
            ? SIMD2<Int>(longPX, shortPX)
            : SIMD2<Int>(shortPX, longPX)
    }
}
