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
    /// PV playback: one continuation stone lands per this interval.
    public static let pvStoneSeconds: TimeInterval = 0.9
    /// Choreography beat: transitions, pass chips, punish stones.
    public static let choreographyBeatSeconds: TimeInterval = 1.2
}

/// A hypothetical stone placed on the report's base position during a
/// choreography frame. The LAST placed stone of a frame carries the red
/// current-move dot.
public struct PlacedStone: Equatable {
    public let vertex: String
    public let color: PlayerColor

    public init(vertex: String, color: PlayerColor) {
        self.vertex = vertex
        self.color = color
    }
}

/// The on-board caption for an acted-out pass beat. Carries WHO acts; the
/// TV layer owns the user-facing copy.
public enum PassChipKind: Equatable {
    /// Tenuki phases: the opponent ignores the candidate ("White plays elsewhere").
    case playsElsewhere(PlayerColor)
    /// The pass slide: the side to move passes ("Black passes").
    case passes(PlayerColor)
}

/// One board state of a slide's choreography. Frames are ordered; each shows
/// when its anchor is satisfied. A frame uses EITHER a .pv overlay OR
/// placedStones, never both (PV prefixes already draw their own stones) —
/// pinned by a test invariant, not types.
public struct BroadcastBoardFrame: Equatable {
    public enum Anchor: Equatable {
        /// Show the moment the fact at this index starts typing.
        case fact(Int)
        /// Show after the previous frame has been visible this long.
        case afterPrevious(TimeInterval)
    }

    public let anchor: Anchor
    public let placedStones: [PlacedStone]
    public let overlay: ReportBoardOverlay
    public let passChip: PassChipKind?

    public init(anchor: Anchor, placedStones: [PlacedStone],
                overlay: ReportBoardOverlay, passChip: PassChipKind?) {
        self.anchor = anchor
        self.placedStones = placedStones
        self.overlay = overlay
        self.passChip = passChip
    }

    /// Merged, deduped, "pass"-filtered vertex list for the renderer. A
    /// literal "pass" would draw OFF-GRID: BoardPoint(move:) maps the pass
    /// move to a synthetic point below the board and the base-vertex
    /// compactMap has no pass guard. frames(for:model:) never emits one;
    /// this filters defensively anyway.
    public func blackVertices(base: [String]) -> [String] {
        merged(base: base, color: .black)
    }

    public func whiteVertices(base: [String]) -> [String] {
        merged(base: base, color: .white)
    }

    /// The red current-move dot: the newest placed stone. The renderer's
    /// dot layer no-ops unless a stone sits at the point, which the merged
    /// vertex lists guarantee.
    public var lastMoveVertex: String? {
        placedStones.last.flatMap { $0.vertex == "pass" ? nil : $0.vertex }
    }

    private func merged(base: [String], color: PlayerColor) -> [String] {
        var seen = Set(base)
        var result = base
        for stone in placedStones
        where stone.color == color && stone.vertex != "pass"
            && seen.insert(stone.vertex).inserted {
            result.append(stone.vertex)
        }
        return result
    }
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
                    + ReportNarrator.candidateFacts(from: model, index: 0, includeContinuation: false),
                overlay: .pv(best.pv, startingWith: model.sideToMove),
                markedMove: nil))
        }
        if model.candidates.count > 1 {
            let alternative = model.candidates[1]
            let hasDelta = !alternative.ownershipDelta.isEmpty
            slides.append(BroadcastSlide(
                kind: .alternative,
                title: "Alternative \(alternative.vertex)",
                facts: ReportNarrator.candidateFacts(from: model, index: 1, includeContinuation: false),
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
                facts: ReportNarrator.passFacts(from: model, includeContestedAreas: false),
                overlay: .ownershipDelta(pass.ownershipDelta),
                markedMove: model.candidates.first.map {
                    ReportMarkedMove(vertex: $0.vertex, color: model.sideToMove)
                }))
        }
        return slides
    }

    /// The slide's board choreography, in presentation order. Derived from
    /// the same model snapshot as the slide's facts, so .fact anchors can
    /// never drift from the fact list: anchor indices are COMPUTED from
    /// positionFacts(from:).count — test generators legally stage candidates
    /// with no position, which shifts every index (never hard-code 2/3).
    public static func frames(for slide: BroadcastSlide,
                              model: DeepReportModel) -> [BroadcastBoardFrame] {
        let side = model.sideToMove
        let opponent: PlayerColor = side == .black ? .white : .black
        let beat = BroadcastConstants.choreographyBeatSeconds
        let bestVertex = model.candidates.first.flatMap { $0.vertex == "pass" ? nil : $0.vertex }

        switch slide.kind {
        case .best:
            guard let best = model.candidates.first else { return [] }
            let bestFactIndex = ReportNarrator.positionFacts(from: model).count
            var frames = [BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                              overlay: .none, passChip: nil)]
            frames += pvPlayback(best.pv, startingWith: side,
                                 firstAnchor: .fact(bestFactIndex))
            if let tenuki = best.tenuki {
                frames += tenukiPhase(candidate: best.vertex, punish: tenuki.vertex,
                                      factIndex: bestFactIndex + 1,
                                      side: side, opponent: opponent)
            }
            return frames

        case .alternative:
            guard model.candidates.count > 1 else { return [] }
            let alternative = model.candidates[1]
            var frames: [BroadcastBoardFrame] = []
            // Entry choreography (grilled): show the best move, undo it to
            // the previous board, then play the alternative. A "pass" best
            // has nothing to show — open on the previous board directly.
            if let bestVertex {
                frames.append(BroadcastBoardFrame(
                    anchor: .fact(0),
                    placedStones: [PlacedStone(vertex: bestVertex, color: side)],
                    overlay: .none, passChip: nil))
                frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: [],
                                                  overlay: .none, passChip: nil))
            } else {
                frames.append(BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                                  overlay: .none, passChip: nil))
            }
            if !alternative.ownershipDelta.isEmpty {
                if alternative.vertex != "pass" {
                    let altStone = [PlacedStone(vertex: alternative.vertex, color: side)]
                    frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                      placedStones: altStone,
                                                      overlay: .none, passChip: nil))
                    frames.append(BroadcastBoardFrame(
                        anchor: .afterPrevious(beat),
                        placedStones: altStone,
                        overlay: .ownershipDelta(alternative.ownershipDelta),
                        passChip: nil))
                } else {
                    frames.append(BroadcastBoardFrame(
                        anchor: .afterPrevious(beat),
                        placedStones: [],
                        overlay: .ownershipDelta(alternative.ownershipDelta),
                        passChip: nil))
                }
            } else {
                // Δ never landed: play the alternative's PV instead —
                // prefix 1 IS the alternative stone, so the .pv/placedStones
                // exclusivity holds.
                frames += pvPlayback(alternative.pv, startingWith: side,
                                     firstAnchor: .afterPrevious(beat))
            }
            if let tenuki = alternative.tenuki {
                frames += tenukiPhase(candidate: alternative.vertex,
                                      punish: tenuki.vertex, factIndex: 1,
                                      side: side, opponent: opponent)
            }
            return frames

        case .pass:
            guard let pass = model.passComparison else { return [] }
            var frames = [BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                              overlay: .none, passChip: nil)]
            let bestStones = bestVertex.map { [PlacedStone(vertex: $0, color: side)] } ?? []
            if !bestStones.isEmpty {
                frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: bestStones,
                                                  overlay: .none, passChip: nil))
            }
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: [],
                                              overlay: .none, passChip: .passes(side)))
            if pass.punishmentVertex != "pass" {
                frames.append(BroadcastBoardFrame(
                    anchor: .afterPrevious(beat),
                    placedStones: [PlacedStone(vertex: pass.punishmentVertex,
                                               color: opponent)],
                    overlay: .none, passChip: .passes(side)))
            }
            // Canonical end: the board the static pass slide always showed.
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: bestStones,
                                              overlay: .ownershipDelta(pass.ownershipDelta),
                                              passChip: nil))
            return frames
        }
    }

    /// One frame per PV prefix: the first at `firstAnchor`, the rest a stone
    /// cadence apart. Empty PVs produce no frames. "pass" entries inside a
    /// PV are harmless: the overlay's renderer skips them (numbering
    /// advances unseen), so the beat passes with no new stone.
    private static func pvPlayback(_ pv: [String], startingWith side: PlayerColor,
                                   firstAnchor: BroadcastBoardFrame.Anchor)
        -> [BroadcastBoardFrame] {
        guard !pv.isEmpty else { return [] }
        return (1...pv.count).map { count in
            BroadcastBoardFrame(
                anchor: count == 1 ? firstAnchor
                                   : .afterPrevious(BroadcastConstants.pvStoneSeconds),
                placedStones: [],
                overlay: .pv(Array(pv.prefix(count)), startingWith: side),
                passChip: nil)
        }
    }

    /// The acted-out tenuki idea: candidate stone → "opponent plays
    /// elsewhere" chip → the same color's punish stone (two consecutive
    /// same-color stones). A "pass" candidate or punish vertex has no stone
    /// to act with: no phase — the typed fact still tells the story.
    private static func tenukiPhase(candidate: String, punish: String,
                                    factIndex: Int, side: PlayerColor,
                                    opponent: PlayerColor) -> [BroadcastBoardFrame] {
        guard candidate != "pass", punish != "pass" else { return [] }
        let beat = BroadcastConstants.choreographyBeatSeconds
        let candidateStone = PlacedStone(vertex: candidate, color: side)
        return [
            BroadcastBoardFrame(anchor: .fact(factIndex),
                                placedStones: [candidateStone],
                                overlay: .none, passChip: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [candidateStone],
                                overlay: .none,
                                passChip: .playsElsewhere(opponent)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [candidateStone,
                                               PlacedStone(vertex: punish, color: side)],
                                overlay: .none,
                                passChip: .playsElsewhere(opponent)),
        ]
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
