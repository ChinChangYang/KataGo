//
//  AnalysisColor.swift
//  KataGoUICore
//
//  Quality-color mapping for analysis candidates, shared by the 2D board
//  dots (AnalysisView) and the visionOS 3D candidate markers.
//

import SwiftUI

/// Discretized hue (0 = red/rare ... 0.5 = cyan/most-visited) for a
/// candidate with `visits` out of the position's `maxVisits`.
public func analysisBaseHue(visits: Int, maxVisits: Int) -> Double {
    let ratio = min(1, max(0.01, Float(visits)) / max(0.01, Float(maxVisits)))
    let fraction = 2 / (pow((1 / ratio) - 1, 0.9) + 1)
    var hue: Float

    if fraction < 1 {
        hue = cbrt(fraction * fraction) / 2
    } else {
        hue = 1 - (sqrt(2 - fraction) / 2)
    }

    // discrete for performance
    let digit: Float = 10
    let discretedHue = (hue * digit).rounded() / digit

    return Double(discretedHue) / 2
}

public func analysisBaseColor(visits: Int, maxVisits: Int) -> Color {
    Color(
        hue: analysisBaseHue(visits: visits, maxVisits: maxVisits),
        saturation: 1,
        brightness: 1
    )
}
