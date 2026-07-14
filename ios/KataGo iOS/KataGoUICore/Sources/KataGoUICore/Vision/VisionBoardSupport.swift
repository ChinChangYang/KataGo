//
//  VisionBoardSupport.swift
//  KataGoUICore
//
//  visionOS renders any board from 2x2 to 37x37, square or rectangular:
//  the bundled geometry-only USDZs cover every square (rectangles reuse the
//  width-matched square with a depth-stretched slab) and the board-top
//  texture is generated per size. 37 is the engine's compiled ceiling
//  (COMPILE_MAX_BOARD_LEN) and 2 the GTP minimum. Whether a supported board
//  also FITS the launched NN buffer is a separate gate (`boardFits`) —
//  oversized boards fatally abort on the first analysis, mirroring the tvOS
//  discipline.
//

/// The renderable board range on visionOS (both dimensions).
public let visionSupportedBoardSizeRange = 2...37

public func visionBoardIsSupported(width: Int, height: Int) -> Bool {
    visionSupportedBoardSizeRange.contains(width)
        && visionSupportedBoardSizeRange.contains(height)
}
