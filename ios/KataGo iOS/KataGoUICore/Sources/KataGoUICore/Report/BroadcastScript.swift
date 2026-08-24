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

public enum BroadcastSlideKind: Hashable, Sendable {
    case best
    case alternative
    case pass
    /// A replay-only slide carrying a synced per-move GameRecord comment.
    /// Built by BroadcastController (never by slides(from:)); it shows over
    /// the LIVE hero board — frames(for:model:) is empty and currentFrame
    /// stays nil while it types.
    case comment
    /// A pass that was actually PLAYED — as opposed to `.pass`, which weighs
    /// the hypothetical "what if the side to move passed here?". Built by
    /// BroadcastController (never by slides(from:)) and presented standalone,
    /// exactly like `.comment`: replay earns it inside the cycle that plays
    /// the recorded move, live from a rise in passCount across an advance.
    case playedPass
    /// The terminal beat: both players passed, so the game is over. Built by
    /// BroadcastController, presented standalone exactly once per game.
    case gameOver
}

/// One board-plus-facts segment of the broadcast. Board content lives in the
/// slide's frame timeline (frames(for:model:)) — the slide itself carries
/// only identity, title, and text.
public struct BroadcastSlide: Equatable {
    public let kind: BroadcastSlideKind
    public let title: String
    public let facts: [String]
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
    /// A wedged speech synthesizer must degrade to silent pacing, not a dead
    /// broadcast: the end-of-slide speech hold never exceeds this floor or
    /// the slide's spoken length at the assumed worst-case rate, whichever
    /// is larger.
    public static let speechHoldFloorSeconds: TimeInterval = 10.0
    /// Deliberately far below any real synthesizer rate (en-US speaks at
    /// roughly 14-17 characters/second) so the ceiling only ever cuts off a
    /// synthesizer that has genuinely wedged.
    public static let assumedMinimumSpokenCharactersPerSecond: Double = 5.0
}

/// One replay/broadcast pacing profile. The live self-play broadcast always
/// runs `.live`; the review replay maps TVAutoPlaySpeed onto tighter
/// profiles. Only the typewriter, dwell, and floor scale — choreography
/// beats, PV cadence, and the poll interval stay stock, and speech is never
/// rate-shifted (an unfinished utterance holds the slide).
///
/// A pacing profile deliberately carries NO slide budget: pacing decides how
/// fast a cycle is narrated, never how much of the analysis is narrated. The
/// removed `maxSlideCount` let Fast drop the Alternative and Playing-vs-
/// Passing slides outright — a speed control silently deleting analysis. Every
/// profile now shows every slide the report produced.
public struct BroadcastPacing: Equatable, Sendable {
    public let charactersPerSecond: Double
    public let dwellSeconds: TimeInterval
    public let minimumSlideSeconds: TimeInterval

    public init(charactersPerSecond: Double, dwellSeconds: TimeInterval,
                minimumSlideSeconds: TimeInterval) {
        self.charactersPerSecond = charactersPerSecond
        self.dwellSeconds = dwellSeconds
        self.minimumSlideSeconds = minimumSlideSeconds
    }

    public static let live = BroadcastPacing(
        charactersPerSecond: BroadcastConstants.charactersPerSecond,
        dwellSeconds: BroadcastConstants.dwellSeconds,
        minimumSlideSeconds: BroadcastConstants.minimumSlideSeconds)
}

/// A hypothetical stone placed on the report's base position during a
/// choreography frame. The LAST placed stone of a frame carries the red
/// current-move dot.
public struct PlacedStone: Equatable, Sendable {
    public let vertex: String
    public let color: PlayerColor

    public init(vertex: String, color: PlayerColor) {
        self.vertex = vertex
        self.color = color
    }
}

/// What an acted-out beat's board caption says: which player, and which KIND
/// of beat it is. The two kinds are not interchangeable — a pass forfeits the
/// move, a tenuki relocates it — and a frame that carried only a
/// `PlayerColor` could not tell them apart, so the TV layer captioned every
/// beat "plays elsewhere" (the regression this type exists to prevent).
/// Named for the concept, not for either case, so neither reads as the
/// default the other can be folded into.
public enum BeatCaption: Equatable, Sendable {
    /// The pass beat: the named player passes — forfeiting the move.
    case passes(PlayerColor)
    /// A tenuki beat: the named player ignores the move under discussion and
    /// plays elsewhere.
    case playsElsewhere(PlayerColor)
}

/// One board state of a slide's choreography. Frames are ordered; each shows
/// when its anchor is satisfied. A frame uses EITHER a .pv overlay OR
/// placedStones, never both (PV prefixes already draw their own stones) —
/// pinned by a test invariant, not types.
public struct BroadcastBoardFrame: Equatable, Sendable {
    public enum Anchor: Equatable, Sendable {
        /// Show the moment the fact at this index starts typing.
        case fact(Int)
        /// Show after the previous frame has been visible this long.
        case afterPrevious(TimeInterval)
    }

    public let anchor: Anchor
    public let placedStones: [PlacedStone]
    public let overlay: ReportBoardOverlay
    /// What this beat's board caption says — a pass beat or a tenuki beat and
    /// whose it is; nil = no caption. The TV layer owns the wording ("Black
    /// passes" / "White plays elsewhere"); this names the beat only.
    public let caption: BeatCaption?

    public init(anchor: Anchor, placedStones: [PlacedStone],
                overlay: ReportBoardOverlay, caption: BeatCaption?) {
        self.anchor = anchor
        self.placedStones = placedStones
        self.overlay = overlay
        self.caption = caption
    }

    /// The renderer's vertex lists: the base position with this frame's placed
    /// stones FORCE-PLAYED onto it, captures resolved, so a beat never draws a
    /// position the rules could not produce.
    ///
    /// Both colors resolve TOGETHER, in placement order, and that is
    /// load-bearing rather than incidental. `tenukiPhase` places the candidate
    /// stone and then a stone the engine chose on the board that stone had
    /// already cleared — so when the candidate captures, the punish point holds
    /// an enemy stone in the base and only becomes legal once the capture is
    /// applied. Resolving each color on its own would never see that capture
    /// and would drop the punish stone.
    ///
    /// A literal "pass" would draw OFF-GRID (BoardPoint(move:) maps it to a
    /// synthetic point below the board), so it places nothing.
    /// `frames(for:model:)` never emits one; this handles it anyway.
    public func stones(black: [String], white: [String],
                       width: Int, height: Int) -> (black: [String], white: [String]) {
        guard !placedStones.isEmpty else { return (black, white) }
        let moves = placedStones.map { VariationMove(vertex: $0.vertex, color: $0.color) }
        return VariationResolver.resolveVertices(width: width, height: height,
                                                 blackVertices: black, whiteVertices: white,
                                                 moves: moves) ?? (black, white)
    }

    /// The red current-move dot: the newest placed stone. The renderer's dot
    /// layer no-ops unless a stone sits at the point — which is no longer
    /// guaranteed, since a placed stone that self-captures comes straight back
    /// off. Drawing nothing is the right answer there.
    public var lastMoveVertex: String? {
        placedStones.last.flatMap { $0.vertex == "pass" ? nil : $0.vertex }
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

    /// Both the pass comparison and the Alternative slot are decided: no later
    /// stage can add either, so a cursor waiting on one may stop waiting.
    ///
    /// runProbes' order is snapshot → pass → alternative-parity → tenuki, and
    /// the parity stage never assigns a stage value of its own (it probes
    /// inside the .passProbe window), so the first stage value that proves
    /// BOTH sections final is .tenuki(_). refine() keeps the same invariant.
    var isPastSectionProbes: Bool {
        switch self {
        case .tenuki, .narrating, .complete, .failed, .cancelled: return true
        case .idle, .snapshot, .passProbe: return false
        }
    }

    /// True once the tenuki probe for `index` has run to completion, whether
    /// or not it produced anything. A card waiting on that candidate's
    /// continuation fact must consult this as well as the fact itself: a probe
    /// that returns nil leaves `candidate.tenuki` nil forever, and a pin that
    /// watched only the fact would hold the card until generation settled.
    func hasFinishedTenukiProbe(index: Int) -> Bool {
        switch self {
        case .tenuki(let running): return running > index
        case .narrating, .complete, .failed, .cancelled: return true
        case .idle, .snapshot, .passProbe: return false
        }
    }
}

/// What the presentation cursor should do next. A cycle walks
/// `canonicalSlideOrder` and asks for this — it never indexes into a list that
/// is still being built (see `nextSlide(presented:model:)`).
public enum NextBroadcastSlide: Equatable {
    /// Present this card now.
    case ready(BroadcastSlide)
    /// An earlier canonical card has not landed yet but still may. Hold.
    case waiting(BroadcastSlideKind)
    /// Every canonical kind is either presented or decided-absent.
    case finished
}

@MainActor
public enum BroadcastScript {
    /// The order the viewer expects, and the report sheet's own section order.
    /// The cursor walks THIS. It is deliberately not "the order sections
    /// landed": the pass probe runs BEFORE the alternative-parity probe, so
    /// arrival order routinely disagrees with reading order, and passFacts
    /// contrasts against the best move that the Alternative card just weighed.
    public static let canonicalSlideOrder: [BroadcastSlideKind] = [.best, .alternative, .pass]

    /// The one builder per kind. Deriving a card from its KIND rather than
    /// from a position in an array is what stops a list that grows behind the
    /// cursor from binding one card's title to another card's facts: the
    /// alternative-parity stage can take `candidates` 1 → 2 after the pass
    /// section already landed, which used to renumber every later card.
    ///
    /// Standalone kinds are built by BroadcastController and return nil here,
    /// so they can never enter the cursor.
    public static func slide(of kind: BroadcastSlideKind,
                             from model: DeepReportModel) -> BroadcastSlide? {
        switch kind {
        case .best:
            guard let best = model.candidates.first else { return nil }
            return BroadcastSlide(
                kind: .best,
                title: "Best Move \(best.vertex)",
                facts: ReportNarrator.positionFacts(from: model)
                    + ReportNarrator.candidateFacts(from: model, index: 0,
                                                    includeContinuation: false))
        case .alternative:
            guard model.candidates.count > 1 else { return nil }
            return BroadcastSlide(
                kind: .alternative,
                title: "Alternative \(model.candidates[1].vertex)",
                facts: ReportNarrator.candidateFacts(from: model, index: 1,
                                                     includeContinuation: false))
        case .pass:
            guard model.passComparison != nil else { return nil }
            return BroadcastSlide(
                kind: .pass,
                title: "Playing vs. Passing",
                facts: ReportNarrator.passFacts(from: model, split: true))
        case .comment, .playedPass, .gameOver:
            return nil
        }
    }

    /// A card that does not exist yet but whose section is still being probed.
    /// False once the section is decided, so a position that genuinely has no
    /// pass comparison never holds the cycle (ADR 0003: a dropped section is
    /// absent, and absent must not mean "wait forever").
    public static func mayStillLand(kind: BroadcastSlideKind,
                                    model: DeepReportModel) -> Bool {
        guard slide(of: kind, from: model) == nil else { return false }
        guard !model.stage.isSettled else { return false }
        switch kind {
        case .best, .alternative, .pass:
            return !model.stage.isPastSectionProbes
        case .comment, .playedPass, .gameOver:
            return false
        }
    }

    /// The cursor. Walks canonical order, skipping kinds already presented and
    /// kinds decided-absent, and holds on the first kind that has not landed
    /// yet but still may.
    public static func nextSlide(presented: Set<BroadcastSlideKind>,
                                 model: DeepReportModel) -> NextBroadcastSlide {
        for kind in canonicalSlideOrder where !presented.contains(kind) {
            if let slide = slide(of: kind, from: model) { return .ready(slide) }
            if mayStillLand(kind: kind, model: model) { return .waiting(kind) }
        }
        return .finished
    }

    /// Every canonical card that has landed so far, in canonical order.
    /// Presentation does NOT walk this — it walks `nextSlide` — but the slide
    /// COUNT (the progress dots) and the tests still want the list form.
    public static func slides(from model: DeepReportModel) -> [BroadcastSlide] {
        canonicalSlideOrder.compactMap { slide(of: $0, from: model) }
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
                                              overlay: .none, caption: nil)]
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
                    overlay: .none, caption: nil))
                frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: [],
                                                  overlay: .none, caption: nil))
            } else {
                frames.append(BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                                  overlay: .none, caption: nil))
            }
            if !alternative.ownershipDelta.isEmpty {
                if alternative.vertex != "pass" {
                    let altStone = [PlacedStone(vertex: alternative.vertex, color: side)]
                    frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                      placedStones: altStone,
                                                      overlay: .none, caption: nil))
                    frames.append(BroadcastBoardFrame(
                        anchor: .afterPrevious(beat),
                        placedStones: altStone,
                        overlay: .ownershipDelta(alternative.ownershipDelta),
                        caption: nil))
                } else {
                    frames.append(BroadcastBoardFrame(
                        anchor: .afterPrevious(beat),
                        placedStones: [],
                        overlay: .ownershipDelta(alternative.ownershipDelta),
                        caption: nil))
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
            let bestStones = bestVertex.map { [PlacedStone(vertex: $0, color: side)] } ?? []
            // Fact 0 ("If Black passes instead: …"): open on the bare board,
            // then act the PASS BEAT — caption only, no stone. `.passes` is
            // load-bearing here: this beat forfeits the move, it does not
            // relocate it, and the caption must not read "plays elsewhere".
            var frames = [BroadcastBoardFrame(anchor: .fact(0), placedStones: [],
                                              overlay: .none, caption: nil)]
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: [],
                                              overlay: .none,
                                              caption: .passes(side)))
            // A barrier holds the beat drain so the next stone waits for its
            // sentence: a .fact-anchored copy of the LAST APPENDED frame
            // (never a hardcoded board — with a "pass" punishment the two
            // barriers are both caption-frame copies). Emitting one is a
            // visual no-op; its .fact index must exist or every later frame
            // strands.
            func appendBarrier(at factIndex: Int) {
                guard let last = frames.last else { return }
                frames.append(BroadcastBoardFrame(anchor: .fact(factIndex),
                                                  placedStones: last.placedStones,
                                                  overlay: last.overlay,
                                                  caption: last.caption))
            }
            // Fact 1 ("White would punish at …") types over the unchanged
            // chip board, then the punish stone lands.
            appendBarrier(at: 1)
            if pass.punishmentVertex != "pass" {
                frames.append(BroadcastBoardFrame(
                    anchor: .afterPrevious(beat),
                    placedStones: [PlacedStone(vertex: pass.punishmentVertex,
                                               color: opponent)],
                    overlay: .none, caption: .passes(side)))
            }
            // Fact 2 (contested areas) exists exactly when contestedPoints is
            // non-empty — the same condition as passFacts. Then the payoff:
            // bare board → best move → the Δ the static slide always showed.
            if !pass.contestedPoints.isEmpty {
                appendBarrier(at: 2)
            }
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: [],
                                              overlay: .none, caption: nil))
            if !bestStones.isEmpty {
                frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                                  placedStones: bestStones,
                                                  overlay: .none, caption: nil))
            }
            frames.append(BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                              placedStones: bestStones,
                                              overlay: .ownershipDelta(pass.ownershipDelta),
                                              caption: nil))
            return frames

        case .comment, .playedPass, .gameOver:
            // Standalone slides: the live board IS the visual, so there is
            // nothing to act out (currentFrame stays nil while they type).
            return []
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
                caption: nil)
        }
    }

    /// The acted-out tenuki idea: candidate stone → the TENUKI BEAT's
    /// "opponent plays elsewhere" caption → the same color's punish stone
    /// (two consecutive same-color stones). The opponent here relocates the
    /// move, never forfeits it, so the caption is `.playsElsewhere` — the
    /// pass slide's beat is the other case. A "pass" candidate or punish
    /// vertex has no stone to act with: no phase — the typed fact still tells
    /// the story.
    private static func tenukiPhase(candidate: String, punish: String,
                                    factIndex: Int, side: PlayerColor,
                                    opponent: PlayerColor) -> [BroadcastBoardFrame] {
        guard candidate != "pass", punish != "pass" else { return [] }
        let beat = BroadcastConstants.choreographyBeatSeconds
        let candidateStone = PlacedStone(vertex: candidate, color: side)
        return [
            BroadcastBoardFrame(anchor: .fact(factIndex),
                                placedStones: [candidateStone],
                                overlay: .none, caption: nil),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [candidateStone],
                                overlay: .none,
                                caption: .playsElsewhere(opponent)),
            BroadcastBoardFrame(anchor: .afterPrevious(beat),
                                placedStones: [candidateStone,
                                               PlacedStone(vertex: punish, color: side)],
                                overlay: .none,
                                caption: .playsElsewhere(opponent)),
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
                && !model.stage.hasFinishedTenukiProbe(index: 0)
        case .alternative:
            return model.candidates.count > 1 && model.candidates[1].tenuki == nil
                && !model.stage.hasFinishedTenukiProbe(index: 1)
        case .pass:
            return false
        case .comment, .playedPass, .gameOver:
            // Standalone slides carry their full text from the start.
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
