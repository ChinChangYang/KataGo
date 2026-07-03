//
//  DeepReportModel.swift
//  KataGoUICore
//
//  Value types + observable progress model for the Deep Analysis Report.
//  All winrate/scoreLead values in these types are normalized to the reported
//  position's side-to-move; ownership grids/deltas stay White-perspective
//  (the engine's emission under reportAnalysisWinratesAs = WHITE) and are
//  converted at render time.
//

import Foundation
import Observation

/// Spec constants for the ~5 s "quick" report.
public enum ReportConstants {
    public static let snapshotBudget: TimeInterval = 2.0
    public static let passBudget: TimeInterval = 1.0
    public static let tenukiBudget: TimeInterval = 1.0
    public static let candidateCount = 2
    public static let probeInterval = 50      // centiseconds → 0.5 s reports
    /// Report interval for the COLD probes (pass/tenuki): analyzing with an
    /// explicit player clears the search tree, and a cold tree emits nothing
    /// at a callback with no completed visits — 0.1 s intervals give up to
    /// nine callback chances within the 1 s budget instead of one.
    public static let coldProbeInterval = 10   // centiseconds
    /// Wall-clock pause between sending `stop` and reading a stage's last
    /// line, so a final in-flight report crossing the pipe still lands.
    public static let stopGrace: TimeInterval = 0.2
    public static let probeMaxMoves = 8
    public static let winrateNoise: Float = 0.02
    public static let scoreNoise: Float = 1.0
    public static let lowVisitThreshold = 100
    public static let contestedPointCount = 8
}

/// Converts the engine's White-perspective values to a side's perspective.
public enum ReportPerspective {
    public static func winrate(_ whiteWinrate: Float, for side: PlayerColor) -> Float {
        side == .white ? whiteWinrate : 1.0 - whiteWinrate
    }
    public static func score(_ whiteScoreLead: Float, for side: PlayerColor) -> Float {
        side == .white ? whiteScoreLead : -whiteScoreLead
    }
}

public struct PositionSummary: Sendable {
    public let winrate: Float
    public let scoreLead: Float
    public let visits: Int
    public init(winrate: Float, scoreLead: Float, visits: Int) {
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.visits = visits
    }
}

public struct TenukiFollowUp: Sendable {
    public let vertex: String
    public let winrate: Float
    public let scoreLead: Float
    public let visits: Int
    public let pv: [String]
    public init(vertex: String, winrate: Float, scoreLead: Float, visits: Int, pv: [String]) {
        self.vertex = vertex
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.visits = visits
        self.pv = pv
    }
}

public struct CandidateReport: Identifiable, Sendable {
    public let vertex: String
    public let visits: Int
    public let winrate: Float
    public let scoreLead: Float
    /// vs. the position summary (positive = better than the position value).
    public let winrateDelta: Float
    public let scoreLeadDelta: Float
    public let pv: [String]
    /// White-perspective subtree-vs-root ownership delta.
    public let ownershipDelta: [BoardPoint: Float]
    public var tenuki: TenukiFollowUp?
    public var id: String { vertex }
    public init(vertex: String, visits: Int, winrate: Float, scoreLead: Float,
                winrateDelta: Float, scoreLeadDelta: Float, pv: [String],
                ownershipDelta: [BoardPoint: Float], tenuki: TenukiFollowUp?) {
        self.vertex = vertex
        self.visits = visits
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.winrateDelta = winrateDelta
        self.scoreLeadDelta = scoreLeadDelta
        self.pv = pv
        self.ownershipDelta = ownershipDelta
        self.tenuki = tenuki
    }
}

public struct ContestedPoint: Identifiable, Sendable {
    public let point: BoardPoint
    public let vertex: String
    public let delta: Float
    public let regionName: String
    public var id: Int { point.hashValue }
    public init(point: BoardPoint, vertex: String, delta: Float, regionName: String) {
        self.point = point
        self.vertex = vertex
        self.delta = delta
        self.regionName = regionName
    }
}

public struct PassComparison: Sendable {
    public let punishmentVertex: String
    public let winrate: Float
    public let scoreLead: Float
    /// Best candidate minus pass scenario (positive = passing costs this much).
    public let winrateDeltaVsBest: Float
    public let scoreLeadDeltaVsBest: Float
    public let ownershipDelta: [BoardPoint: Float]
    public let contestedPoints: [ContestedPoint]
    public init(punishmentVertex: String, winrate: Float, scoreLead: Float,
                winrateDeltaVsBest: Float, scoreLeadDeltaVsBest: Float,
                ownershipDelta: [BoardPoint: Float], contestedPoints: [ContestedPoint]) {
        self.punishmentVertex = punishmentVertex
        self.winrate = winrate
        self.scoreLead = scoreLead
        self.winrateDeltaVsBest = winrateDeltaVsBest
        self.scoreLeadDeltaVsBest = scoreLeadDeltaVsBest
        self.ownershipDelta = ownershipDelta
        self.contestedPoints = contestedPoints
    }
}

/// Ownership-delta math over the engine's flat grids (emission order:
/// y from height-1 down to 0, x from 0 to width-1 — matching
/// AnalysisLineParser.extractOwnershipUnits).
public enum OwnershipDelta {
    public static func grid(base: [Float], probe: [Float],
                            width: Int, height: Int) -> [BoardPoint: Float] {
        let count = width * height
        guard base.count == count, probe.count == count else { return [:] }
        var result: [BoardPoint: Float] = [:]
        var i = 0
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width {
                result[BoardPoint(x: x, y: y)] = probe[i] - base[i]
                i += 1
            }
        }
        return result
    }

    public static func contestedPoints(in grid: [BoardPoint: Float],
                                       width: Int, height: Int) -> [ContestedPoint] {
        grid.sorted {
            if $0.value.magnitude != $1.value.magnitude {
                return $0.value.magnitude > $1.value.magnitude
            }
            return ($0.key.x, $0.key.y) < ($1.key.x, $1.key.y)
        }
        .prefix(ReportConstants.contestedPointCount)
        .compactMap { point, delta in
            guard let vertex = Coordinate(x: point.x, y: point.y + 1,
                                          width: width, height: height)?.move else { return nil }
            return ContestedPoint(point: point,
                                  vertex: vertex,
                                  delta: delta,
                                  regionName: regionName(point: point, width: width, height: height))
        }
    }

    /// Deterministic board-thirds region name. BoardPoint y = 0 is the BOTTOM
    /// row, so the upper third is high y. "center" for the middle-middle third.
    public static func regionName(point: BoardPoint, width: Int, height: Int) -> String {
        let col = min(point.x * 3 / max(width, 1), 2)
        let row = min(point.y * 3 / max(height, 1), 2)
        let vertical = ["lower", "middle", "upper"][row]
        let horizontal = ["left", "center", "right"][col]
        if vertical == "middle" && horizontal == "center" { return "center" }
        if vertical == "middle" { return "\(horizontal) side" }
        return "\(vertical) \(horizontal)"
    }
}

/// Progress + result state the report sheet observes. Sections fill in as
/// probe stages land; `narrative` grows token-wise while streaming.
@Observable
@MainActor
public final class DeepReportModel {
    public enum Stage: Equatable {
        case idle
        case snapshot
        case passProbe
        case tenuki(Int)
        case narrating
        case complete
        case failed(String)
        case cancelled
    }

    public var stage: Stage = .idle
    public var moveNumber: Int = 0
    public var sideToMove: PlayerColor = .black
    public var boardWidth: Int = 19
    public var boardHeight: Int = 19
    public var blackVertices: [String] = []
    public var whiteVertices: [String] = []
    public var position: PositionSummary?
    public var candidates: [CandidateReport] = []
    public var passComparison: PassComparison?
    public var narrative: String = ""
    public var narrativeUnavailableReason: String?
    /// Live search speed captured when the report started (nil when unknown).
    public var visitsPerSecondText: String?

    public var isGenerating: Bool {
        switch stage {
        case .snapshot, .passProbe, .tenuki, .narrating: return true
        case .idle, .complete, .failed, .cancelled: return false
        }
    }

    public init() {}
}
