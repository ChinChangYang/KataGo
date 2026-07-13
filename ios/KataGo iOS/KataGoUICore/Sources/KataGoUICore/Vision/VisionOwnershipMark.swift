//
//  VisionOwnershipMark.swift
//  KataGoUICore
//
//  Pure quad mapping behind the visionOS 3D ownership overlay: an
//  OwnershipUnit (whiteness/scale/opacity already digitized by
//  AnalysisLineParser) becomes a board-hugging quad sized per axis —
//  cells on the bundled boards are anisotropic (22 × 23.7 mm) — plus a
//  material-cache key over the digitized appearance, so the scene model
//  reuses a handful of materials instead of rebuilding one per tick.
//

public struct VisionOwnershipMark: Equatable, Sendable {
    public let width: Float
    public let depth: Float
    public let whiteness: Float
    public let opacity: Float
    public let materialKey: Int

    public static func make(unit: OwnershipUnit,
                            cellSpacingX: Float,
                            cellSpacingZ: Float) -> VisionOwnershipMark {
        VisionOwnershipMark(width: cellSpacingX * unit.scale,
                            depth: cellSpacingZ * unit.scale,
                            whiteness: unit.whiteness,
                            opacity: unit.opacity,
                            materialKey: Int((unit.whiteness * 1000).rounded()) * 100_000
                                + Int((unit.opacity * 1000).rounded()))
    }
}
