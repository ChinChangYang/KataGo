//
//  VisionFocusRing.swift
//  KataGoUICore
//
//  Pure geometry and palette for the visionOS focus ring — the flat
//  annulus shown on the board top when the controller cursor sits on an
//  occupied intersection (the ghost stone hides there instead of
//  overlapping the concrete stone). Static by design: no animation
//  facility exists in the scene and a breathing cursor was declined.
//  Rendered as OPAQUE unlit geometry for the same reason as the branch
//  frame: opaque geometry depth-sorts normally, unlike the transparent
//  ownership quads (RealityKit cannot sort scene transparents behind
//  attachment planar UI).
//

import Foundation
import KataGoGameStore
import simd

/// The board-top overlay z-ladder for the visionOS scene: ownership quads
/// lowest, the focus ring between, marker attachments on top. The scene
/// model consumes these values, so the ordering the tests pin is the
/// ordering that renders — a literal drifting in one place cannot silently
/// reorder the layers.
public enum VisionOverlayLift {
    public static let ownershipQuad: Float = 0.0002
    public static let focusRing: Float = 0.0005
    public static let markerAttachment: Float = 0.0008
}

public struct VisionFocusRing {
    /// Stone equator radius — an asset contract, measured from
    /// stone_black/white.usdz (extent ±0.0112 m). The stones are wider
    /// than the 22 mm grid pitch, so the ring necessarily tucks under
    /// direct neighbors; opaque stones occlude it correctly and the arcs
    /// stay visible in the diagonal gaps.
    public static let stoneEquatorRadius: Float = 0.0112
    /// 0.6 mm clearance outside the stone's widest silhouette, so the
    /// ring shows around the whole stone when viewed from above.
    public static let innerRadius: Float = 0.0118
    /// 1.4 mm band — the candidate marker ring's proven line width
    /// (22 mm / 16).
    public static let outerRadius: Float = 0.0132
    /// Above the ownership quads, below the marker attachments.
    public static let lift: Float = VisionOverlayLift.focusRing
    /// Max chord deviation at the outer edge is ~16 µm — invisible.
    public static let segmentCount = 64

    /// Contrast-adaptive grayscale: light ring on a black stone, dark
    /// ring on a white stone. Unknown occupants (never produced by the
    /// resolver) read light.
    public static func whiteness(occupant: PlayerColor) -> Float {
        occupant == .white ? 0.10 : 0.92
    }

    /// Flat annulus in the XZ plane at y = 0 (the lift is applied to the
    /// entity position): inner/outer rim vertices interleaved, triangles
    /// wound counter-clockwise seen from +Y.
    public struct Geometry: Equatable, Sendable {
        public let positions: [SIMD3<Float>]
        public let triangleIndices: [UInt32]
    }

    public static func makeGeometry(segments: Int = segmentCount) -> Geometry {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(2 * segments)
        var indices: [UInt32] = []
        indices.reserveCapacity(6 * segments)
        for i in 0..<segments {
            let theta = 2 * Float.pi * Float(i) / Float(segments)
            let direction = SIMD3<Float>(cos(theta), 0, sin(theta))
            positions.append(innerRadius * direction)
            positions.append(outerRadius * direction)
            let j = (i + 1) % segments
            let innerI = UInt32(2 * i), outerI = UInt32(2 * i + 1)
            let innerJ = UInt32(2 * j), outerJ = UInt32(2 * j + 1)
            indices.append(contentsOf: [innerI, outerJ, outerI,
                                        innerI, innerJ, outerJ])
        }
        return Geometry(positions: positions, triangleIndices: indices)
    }
}
