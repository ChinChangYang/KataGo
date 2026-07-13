//
//  VisionBoardSupport.swift
//  KataGoUICore
//
//  visionOS renders only the board sizes with bundled 3D goban assets.
//  Anything else (including rectangular boards) must be gated before any
//  engine load, mirroring the tvOS oversized-board discipline.
//

/// Board sizes with bundled `go_board_{n}x{n}.usdz` assets.
public let visionSupportedBoardSizes: Set<Int> = [9, 13, 19]

public func visionBoardIsSupported(width: Int, height: Int) -> Bool {
    width == height && visionSupportedBoardSizes.contains(width)
}
