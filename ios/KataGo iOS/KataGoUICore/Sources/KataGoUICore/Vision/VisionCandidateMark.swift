//
//  VisionCandidateMark.swift
//  KataGoUICore
//
//  Pure mapping behind the visionOS flat candidate markers — exact 2D
//  AnalysisView parity: fill hue from the visits ratio at 0.8 opacity,
//  the hidden-below-visit-ratio dim treatment (bare 0.2 circle, no
//  text), the blue best-move ring keyed on max utilityLcb (drawn even
//  while hidden), and a 1.0-cell circle sized for the fixed-scale
//  volumetric window with supersampled text.
//

import Foundation
import KataGoGameStore

public struct VisionCandidateMark: Equatable, Sendable {
    public let hue: Double
    public let opacity: Double
    public let showsRing: Bool
    public let labelLines: [String]
    public let boldLineIndex: Int?
    public let diameterMeters: Float

    /// Volumetric windows are fixed-scale: 1088 pt = 0.8 m (VisionRootView).
    public static let pointsPerMeter: Float = 1360
    /// Render the attachment 4x and scale the entity back down, so the
    /// fit-to-circle text rasterizes crisp instead of at ~30 pt.
    public static let supersample: Float = 4

    public var framePoints: CGFloat {
        CGFloat(diameterMeters * Self.pointsPerMeter * Self.supersample)
    }
    /// 2D parity: ring line width = squareLength / 16.
    public var ringLineWidthPoints: CGFloat { framePoints / 16 }
    public var entityScale: Float { 1 / Self.supersample }

    public static func make(visits: Int,
                            maxVisits: Int,
                            utilityLcb: Float,
                            maxUtilityLcb: Float?,
                            hiddenAnalysisVisitRatio: Float,
                            analysisInformation: Int,
                            winrate: Float,
                            scoreLead: Float,
                            cellSpacingX: Float,
                            cellSpacingZ: Float) -> VisionCandidateMark {
        // 2D parity (AnalysisView): strict less-than hides; a hidden
        // candidate keeps a faint circle but loses its text.
        let isHidden = Float(visits) < hiddenAnalysisVisitRatio * Float(maxVisits)
        let labelLines = isHidden ? [] : visionAnalysisLabelLines(
            analysisInformation: analysisInformation,
            winrate: winrate,
            visits: visits,
            scoreLead: scoreLead)
        let information = Config.analysisInformations.indices.contains(analysisInformation)
            ? Config.analysisInformations[analysisInformation] : ""
        let winrateLeads = information == Config.analysisInformationWinrate
            || information == Config.analysisInformationAll
        return VisionCandidateMark(
            hue: analysisBaseHue(visits: visits, maxVisits: maxVisits),
            opacity: isHidden ? 0.2 : 0.8,
            // Float == on purpose — the same comparison the 2D ring uses;
            // the ring also draws on hidden candidates.
            showsRing: maxUtilityLcb.map { utilityLcb == $0 } ?? false,
            labelLines: labelLines,
            boldLineIndex: !isHidden && winrateLeads ? 0 : nil,
            diameterMeters: min(cellSpacingX, cellSpacingZ))
    }
}
