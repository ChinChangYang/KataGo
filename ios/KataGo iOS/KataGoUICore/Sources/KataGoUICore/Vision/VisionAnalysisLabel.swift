//
//  VisionAnalysisLabel.swift
//  KataGoUICore
//
//  Pure mapping from the "Analysis information" setting (an index into
//  Config.analysisInformations) to the lines shown on a visionOS
//  candidate-marker attachment — exact 2D AnalysisView format parity
//  (winrateText/visitsText/scoreText). None, or any index matching no
//  mode, yields no lines; hiding the markers themselves under None is
//  the view's concern.
//

import Foundation
import KataGoGameStore

public func visionAnalysisLabelLines(analysisInformation: Int,
                                     winrate: Float,
                                     visits: Int,
                                     scoreLead: Float) -> [String] {
    guard Config.analysisInformations.indices.contains(analysisInformation) else {
        return []
    }

    let winrateLine = String(format: "%2.0f%%", (winrate * 100).rounded())
    let scoreLine = String(format: "%+.0f", scoreLead.rounded())

    switch Config.analysisInformations[analysisInformation] {
    case Config.analysisInformationWinrate:
        return [winrateLine]
    case Config.analysisInformationScore:
        return [scoreLine]
    case Config.analysisInformationAll:
        return [winrateLine, convertToSIUnits(visits), scoreLine]
    default:
        return []
    }
}
