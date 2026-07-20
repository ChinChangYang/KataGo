//
//  VisionBranchFrame.swift
//  KataGoUICore
//
//  Pure geometry for the visionOS red branch frame — the 3D stand-in for
//  iOS's red rectangle around the goban while a branch is active: four
//  corner-tiled bars hugging the board-top perimeter, derived from the
//  same analytic BoardGeometryRules the board itself uses, so any
//  rectangle in 2...37 gets a snug frame. The bars are rendered as OPAQUE
//  unlit boxes on purpose: opaque geometry depth-sorts normally, unlike
//  the transparent ownership quads (RealityKit cannot sort scene
//  transparents behind attachment planar UI).
//

import Foundation
import KataGoGameStore
import simd

public struct VisionBranchFrame: Equatable, Sendable {
    public struct Bar: Equatable, Sendable {
        /// Center in boardRoot space (slab footprint centered on the origin).
        public let center: SIMD3<Float>
        /// Box extents: x span, y height, z depth (meters).
        public let size: SIMD3<Float>
    }

    /// In-plane bar width, meters.
    public static let barThickness: Float = 0.005
    /// Box height — a thin opaque slab, not a zero-height plane.
    public static let barHeight: Float = 0.0012
    /// Base of the bars above the board top; below the ownership quads'
    /// +0.0002 plane is fine because the bars live on the perimeter margin,
    /// which the grid's overlays never reach.
    public static let lift: Float = 0.0003

    /// Exactly four: [far (-z), near (+z), left (-x), right (+x)]. The far
    /// and near bars span the full X extent; the side bars tile between
    /// them, so the corners are covered exactly once.
    public let bars: [Bar]

    public static func make(width: Int, height: Int) -> VisionBranchFrame {
        let dimensions = BoardGeometryRules.dimensions(width: width,
                                                       height: height)
        let slabX = Float(dimensions.boardXMM / 1000)
        let slabZ = Float(dimensions.boardZMM / 1000)
        let t = barThickness
        let y = Float(dimensions.topY) + lift + barHeight / 2
        let edgeX = slabX / 2 - t / 2
        let edgeZ = slabZ / 2 - t / 2
        let spanBar = SIMD3<Float>(slabX, barHeight, t)
        let sideBar = SIMD3<Float>(t, barHeight, slabZ - 2 * t)
        return VisionBranchFrame(bars: [
            Bar(center: SIMD3<Float>(0, y, -edgeZ), size: spanBar),
            Bar(center: SIMD3<Float>(0, y, edgeZ), size: spanBar),
            Bar(center: SIMD3<Float>(-edgeX, y, 0), size: sideBar),
            Bar(center: SIMD3<Float>(edgeX, y, 0), size: sideBar),
        ])
    }
}
