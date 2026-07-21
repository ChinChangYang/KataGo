//
//  BroadcastScript.swift
//  KataGoUICore
//
//  Pure slide-building for the tvOS Deep-Report Broadcast. A slideshow is
//  derived from a DeepReportModel that may still be generating: only slides
//  whose sections landed exist, and a candidate slide's fact list can grow
//  once (its tenuki line) while probes are still running. All content reuses
//  ReportNarrator's per-section facts and the report UI's titles, so the
//  broadcast can never drift from what the iOS report sheet shows.
//

import Foundation

public enum BroadcastSlideKind: Equatable, Sendable {
    case best
    case alternative
    case pass
}

/// One board-plus-facts segment of the broadcast.
public struct BroadcastSlide {
    public let kind: BroadcastSlideKind
    public let title: String
    public let facts: [String]
    public let overlay: ReportBoardOverlay
    public let markedMove: ReportMarkedMove?
}

/// Broadcast pacing knobs (QA-tunable, not load-bearing).
public enum BroadcastConstants {
    /// Typewriter reveal speed.
    public static let charactersPerSecond: Double = 30
    /// Absorb-the-board pause after a slide's text completes.
    public static let dwellSeconds: TimeInterval = 2.5
    /// Short facts must not flash by: a slide's floor including typing time.
    public static let minimumSlideSeconds: TimeInterval = 6.0
    /// Controller poll cadence while waiting on generation stages.
    public static let pollSeconds: TimeInterval = 0.1
}

public extension DeepReportModel.Stage {
    /// Generation reached an end state — no further sections will land.
    /// (`.narrating` is NOT settled: it precedes `.complete`, though facts
    /// no longer change there.)
    var isSettled: Bool {
        switch self {
        case .complete, .failed, .cancelled: return true
        case .idle, .snapshot, .passProbe, .tenuki, .narrating: return false
        }
    }
}

@MainActor
public enum BroadcastScript {
    /// The slides whose report sections have landed, in broadcast order.
    /// Overlay choices mirror the iOS report sheet: the best candidate shows
    /// its variation (its Δ-vs-root is ~zero by construction), the
    /// alternative shows Δ-ownership with the candidate marked, and the pass
    /// comparison shows its Δ grid with the best move marked.
    public static func slides(from model: DeepReportModel) -> [BroadcastSlide] {
        var slides: [BroadcastSlide] = []
        if let best = model.candidates.first {
            slides.append(BroadcastSlide(
                kind: .best,
                title: "Best Move \(best.vertex)",
                facts: ReportNarrator.positionFacts(from: model)
                    + ReportNarrator.candidateFacts(from: model, index: 0),
                overlay: .pv(best.pv, startingWith: model.sideToMove),
                markedMove: nil))
        }
        if model.candidates.count > 1 {
            let alternative = model.candidates[1]
            let hasDelta = !alternative.ownershipDelta.isEmpty
            slides.append(BroadcastSlide(
                kind: .alternative,
                title: "Alternative \(alternative.vertex)",
                facts: ReportNarrator.candidateFacts(from: model, index: 1),
                overlay: hasDelta
                    ? .ownershipDelta(alternative.ownershipDelta)
                    : .pv(alternative.pv, startingWith: model.sideToMove),
                markedMove: hasDelta
                    ? ReportMarkedMove(vertex: alternative.vertex, color: model.sideToMove)
                    : nil))
        }
        if let pass = model.passComparison {
            slides.append(BroadcastSlide(
                kind: .pass,
                title: "Playing vs. Passing",
                facts: ReportNarrator.passFacts(from: model),
                overlay: .ownershipDelta(pass.ownershipDelta),
                markedMove: model.candidates.first.map {
                    ReportMarkedMove(vertex: $0.vertex, color: model.sideToMove)
                }))
        }
        return slides
    }

    /// Whether a slide's fact list can still gain a line (a candidate's
    /// tenuki fact lands mid-typewriter on the first slide). The typewriter
    /// waits on this instead of the whole generation, so an early slide never
    /// blocks on later stages that belong to other slides.
    public static func factsMayGrow(kind: BroadcastSlideKind, model: DeepReportModel) -> Bool {
        guard !model.stage.isSettled else { return false }
        switch kind {
        case .best:
            return model.candidates.first?.tenuki == nil
        case .alternative:
            return model.candidates.count > 1 && model.candidates[1].tenuki == nil
        case .pass:
            return false
        }
    }

    /// Word-chunks with separators preserved: joined chunks reproduce the
    /// exact text, so the typewriter can append chunk-by-chunk.
    public static func typewriterChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
