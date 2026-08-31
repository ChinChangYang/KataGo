//
//  StoneMotionLayer.swift
//  KataGoUICore
//
//  Stone motion on the 2D board (ADR 0015). Provenance, never diffs: the
//  command sites declare what they are about to do to the board
//  (`GobanState.stonePlanner`), and each published position resolves its stone
//  diff against that queue. A change no intent accounts for mounts instantly,
//  which is what keeps jumps, chart scrubs, game switches and board reloads
//  from animating by accident — and what makes every race degrade to a missed
//  animation rather than a wrong one. See `StoneAnimationPlanner` for why a
//  diff-time heuristic cannot do this job.
//
//  The `Canvas` in `StoneView` still draws every stone of the position, every
//  frame; nothing here is ever part of the position. What this adds is a
//  handful of TRANSIENT views over it:
//
//    • the arriving stone, settling from `settleScale` down to 1x over its own
//      Canvas twin (never below 1x — see MotionPreference.settleScale);
//    • copies of the stones that just left, shrinking and fading at points the
//      Canvas no longer draws at all.
//
//  A `StoneView` given no `StoneMotionState` is inert by construction, which is
//  how `ReportBoardView`, the game-list thumbnail and the GIF renderer stay
//  exactly as static as they were.
//

import SwiftUI
import SwiftData

/// The motion layer's state: the previous board, the transient stones, and the
/// sound cues. Owned by `BoardView` as `@State`; created with the `GobanState`
/// whose planner it resolves against.
///
/// Main-actor because it is a view model, and because its deadline-guarded
/// sound Tasks mirror `VisionBoardSceneModel`'s. `GobanState` itself is
/// deliberately NOT main-actor (its navigation methods are nonisolated), which
/// is exactly why the planner lives over there and this object only reads it.
@MainActor
@Observable
public final class StoneMotionState {

    /// One transient stone drawn over the Canvas.
    ///
    /// `id` is a fresh UUID per instance, so `ForEach` gives every new one its
    /// own identity — which is what makes its `onAppear`, and therefore its
    /// animation, run. Two stones arriving at the same point in quick
    /// succession must not be mistaken for one still-settling stone.
    public struct MotionStone: Identifiable, Equatable {
        public enum Kind: Equatable, Sendable {
            /// Settling onto the board.
            case arriving
            /// Leaving it: an undone stone, or one a capture took.
            case departing
        }

        public let id = UUID()
        public let point: BoardPoint
        public let color: PlayerColor
        public let kind: Kind
        /// How long to wait before the animation starts. Non-zero only for a
        /// captured stone: it leaves as the capturing stone LANDS, so the eye
        /// sees the capture happen rather than having already happened.
        public let delay: TimeInterval

        public init(point: BoardPoint,
                    color: PlayerColor,
                    kind: Kind,
                    delay: TimeInterval = 0) {
            self.point = point
            self.color = color
            self.kind = kind
            self.delay = delay
        }
    }

    /// The intent queue's owner. Held, not copied: the planner is a value type,
    /// and resolving has to consume the intents the command sites enqueued.
    private let gobanState: GobanState

    /// The two observable properties: what the layer view draws. Everything
    /// else below is `@ObservationIgnored` bookkeeping — it changes on every
    /// publish, and invalidating a view on it would put the whole board's
    /// motion back inside `BoardView.body`.
    public private(set) var arrivals: [MotionStone] = []
    public private(set) var departures: [MotionStone] = []

    /// Plays the placement click; `BoardView` wires it to the `AudioModel`.
    /// Sound is layer-driven here for the reason it is scene-driven on the
    /// volumetric board: it should fire when the stone LANDS, not when the
    /// command went out.
    @ObservationIgnored public var playStoneSound: (() -> Void)?
    /// Plays the capture rattle. Same wiring, same reason.
    @ObservationIgnored public var playCaptureSound: (() -> Void)?

    /// The board as it stood at the previous publish, by point. A dictionary
    /// rather than two sets so a point that CHANGES colour (only reachable
    /// across a jump) counts as a removal and not also as an addition —
    /// the same shape `VisionBoardSceneModel.applyStones` diffs.
    @ObservationIgnored private var previous: [BoardPoint: PlayerColor] = [:]
    /// False until the first board this layer has seen. The first one is a
    /// baseline, never a diff: whatever is on screen when the board mounts was
    /// put there by the record, not by a move.
    @ObservationIgnored private var hasSnapshot = false
    /// The record the snapshot belongs to. A different one is a different
    /// world — see `noteBoard`.
    @ObservationIgnored private var lastRecordID: PersistentIdentifier?

    /// How the next reported capture should sound, set by the last non-empty
    /// stone diff. Nothing is settling before the first diff, so a rattle
    /// arriving that early is due at once.
    @ObservationIgnored private var captureCue: StoneAnimationPlanner.CaptureCue = .immediately
    /// When the stone currently settling finishes — the instant its placement
    /// click fires. A capture reported mid-settle rides it.
    @ObservationIgnored private var landingDeadline: ContinuousClock.Instant?
    /// Bumped by every record change so an already-scheduled click or prune
    /// can tell its stone's world was torn down and stay quiet.
    @ObservationIgnored private var stoneSyncEpoch = 0

    public init(gobanState: GobanState) {
        self.gobanState = gobanState
    }

    // MARK: - Board updates

    /// Takes one published position and decides what, if anything, moves.
    ///
    /// Called from `BoardView`'s `onAppear` and its `positionGeneration`
    /// observer — never from a `body`, because this mutates observable state
    /// and reads (and clears) flags on `GobanState`.
    public func noteBoard(recordID: PersistentIdentifier?,
                          black: [BoardPoint],
                          white: [BoardPoint],
                          captured: [CapturedStone],
                          width: Int,
                          height: Int) {
        // A different record is a different world: what was in flight belonged
        // to the game that just left. Cancel its pending sounds and take the
        // incoming board as a fresh baseline rather than diffing it against
        // the previous game's stones. This also makes the FIRST call a
        // baseline whatever order `onAppear` and the observer run in — the
        // stored id starts nil and a mounted board always has one.
        if recordID != lastRecordID {
            lastRecordID = recordID
            prepareForRecordChange()
        }

        // The pass point is an off-board sentinel the Canvas never draws; it
        // must not read as a stone arriving or leaving.
        let pass = BoardPoint.pass(width: width, height: height)
        var desired: [BoardPoint: PlayerColor] = [:]
        for point in black where point != pass { desired[point] = .black }
        for point in white where point != pass { desired[point] = .white }

        guard hasSnapshot else {
            previous = desired
            hasSnapshot = true
            // A mount consumes the game-switch silence: the remount it was
            // armed for is this one.
            gobanState.stoneMotionInitialSyncArmed = false
            captureCue = .immediately
            return
        }

        let removals = Set(previous.keys.filter { desired[$0] != previous[$0] })
        let additions = Set(desired.keys.filter { previous[$0] == nil })

        let effect = gobanState.stonePlanner.resolve(additions: additions,
                                                     removals: removals)
        let isInitialSync = gobanState.stoneMotionInitialSyncArmed
        let cue = StoneAnimationPlanner.soundCue(effect: effect,
                                                 additions: additions.count,
                                                 removals: removals.count,
                                                 isInitialSync: isInitialSync)
        // Only a NON-EMPTY diff re-cues the rattle and consumes the mount
        // flag: an empty re-publish (a refused move still advances the cursor,
        // and a re-entry republishes the same board) must not overwrite the
        // cue the capturing move's diff just set, nor spend the silence the
        // switch armed.
        if let capture = StoneAnimationPlanner.captureCue(effect: effect,
                                                          additions: additions.count,
                                                          removals: removals.count) {
            captureCue = capture
        }
        if !additions.isEmpty || !removals.isEmpty {
            gobanState.stoneMotionInitialSyncArmed = false
        }
        if cue == .playImmediately {
            playStoneSound?()
        }

        // A stone undone or captured while it was still settling must not
        // leave its settling copy standing over an empty point; a point a
        // stone re-mounts on must not keep a departing copy fading over the
        // new stone. (The volumetric board does both through `flyingAway`.)
        if !removals.isEmpty {
            arrivals.removeAll { removals.contains($0.point) }
        }
        if !additions.isEmpty {
            departures.removeAll { additions.contains($0.point) }
        }

        var newArrivals: [MotionStone] = []
        var newDepartures: [MotionStone] = []
        switch effect {
        case .none:
            break
        case .flyIn(let point):
            if let color = desired[point] {
                newArrivals.append(MotionStone(point: point, color: color, kind: .arriving))
            }
            // Everything the arriving stone TOOK leaves with it, starting when
            // it lands. `Stones.capturedPoints` annotates the move at the
            // displayed index, which after a backward step names a move the
            // board is walking away from — so it is narrowed to the stones
            // that actually left in THIS diff.
            for stone in captured where removals.contains(stone.point) {
                newDepartures.append(MotionStone(point: stone.point,
                                                 color: stone.color,
                                                 kind: .departing,
                                                 delay: MotionPreference.settleDuration))
            }
        case .flyAway(let point):
            if let color = previous[point] {
                newDepartures.append(MotionStone(point: point, color: color, kind: .departing))
            }
        }

        previous = desired

        if cue == .playAfterFlyIn, case .flyIn(let point) = effect {
            scheduleLandingClick(at: point)
        }
        if !newArrivals.isEmpty || !newDepartures.isEmpty {
            arrivals.append(contentsOf: newArrivals)
            departures.append(contentsOf: newDepartures)
            scheduleCleanup(arrivals: newArrivals, departures: newDepartures)
        }
    }

    /// The engine reported a capture (a `showboard` capture counter rose).
    ///
    /// Deferred by one main-actor turn so it reads the cue THIS update pass's
    /// stone diff set: the counter observer and the diff run in the same
    /// SwiftUI pass, in an order SwiftUI does not define, and the counter can
    /// also arrive on a later, empty sync of the same block. One turn's wait is
    /// imperceptible and settles both. Verbatim in shape from
    /// `VisionBoardSceneModel.noteCapture`.
    public func noteCapture() {
        let epoch = stoneSyncEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.captureCue {
            case .immediately:
                break
            case .atLanding:
                // No deadline means the settle already finished (its click has
                // played), so the rattle is due now rather than never.
                if let deadline = self.landingDeadline {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                }
            }
            // A game switch during the settle tore down the world the capture
            // belonged to — the same guard the landing click uses.
            guard self.stoneSyncEpoch == epoch else { return }
            self.playCaptureSound?()
        }
    }

    /// Drops everything the previous record left in flight: pending clicks and
    /// rattles (through the epoch), the transient stones, and the snapshot the
    /// next board would otherwise be diffed against.
    public func prepareForRecordChange() {
        stoneSyncEpoch &+= 1
        arrivals.removeAll()
        departures.removeAll()
        previous.removeAll()
        hasSnapshot = false
        captureCue = .immediately
        landingDeadline = nil
    }

    // MARK: - Scheduling

    private func scheduleLandingClick(at point: BoardPoint) {
        let epoch = stoneSyncEpoch
        // Published so a capture reported while this stone is still settling
        // rattles at touchdown instead of at parse time.
        let deadline = ContinuousClock.now.advanced(by: .seconds(MotionPreference.settleDuration))
        landingDeadline = deadline
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self, self.stoneSyncEpoch == epoch else { return }
            if self.landingDeadline == deadline { self.landingDeadline = nil }
            // The stone has to still be on the board: an undo can pull it back
            // mid-settle, and a stone that never seated must not click.
            guard self.previous[point] != nil else { return }
            self.playStoneSound?()
        }
    }

    /// Retires each transient when its animation is over. A Task per stone
    /// rather than one timer: the captured stones start late (they wait for the
    /// landing), so they do not all end together.
    private func scheduleCleanup(arrivals newArrivals: [MotionStone],
                                 departures newDepartures: [MotionStone]) {
        let epoch = stoneSyncEpoch
        for stone in newArrivals {
            let id = stone.id
            let seconds = stone.delay + MotionPreference.settleDuration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, self.stoneSyncEpoch == epoch else { return }
                self.arrivals.removeAll { $0.id == id }
            }
        }
        for stone in newDepartures {
            let id = stone.id
            let seconds = stone.delay + MotionPreference.removalDuration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, self.stoneSyncEpoch == epoch else { return }
                self.departures.removeAll { $0.id == id }
            }
        }
    }
}

// MARK: - The view

/// The transient stones, drawn over `StoneView`'s Canvas.
///
/// A separate view on purpose: it reads `StoneMotionState`, so a stone arriving
/// or retiring invalidates THIS view and never `BoardView.body`. The animations
/// themselves run on per-item `@State`, so not even this view is re-evaluated
/// per frame.
public struct StoneMotionLayer: View {
    let dimensions: Dimensions
    let verticalFlip: Bool
    let isClassicStoneStyle: Bool
    let state: StoneMotionState

    public init(dimensions: Dimensions,
                verticalFlip: Bool,
                isClassicStoneStyle: Bool,
                state: StoneMotionState) {
        self.dimensions = dimensions
        self.verticalFlip = verticalFlip
        self.isClassicStoneStyle = isClassicStoneStyle
        self.state = state
    }

    public var body: some View {
        ZStack {
            // Departures first: a stone leaving is underneath the one that
            // took it, exactly as the Canvas stamps captured stones under the
            // capturing one's shadow.
            ForEach(state.departures) { stone in
                DepartingStoneView(stone: stone,
                                   dimensions: dimensions,
                                   verticalFlip: verticalFlip,
                                   isClassicStoneStyle: isClassicStoneStyle)
            }
            ForEach(state.arrivals) { stone in
                ArrivingStoneView(stone: stone,
                                  dimensions: dimensions,
                                  verticalFlip: verticalFlip,
                                  isClassicStoneStyle: isClassicStoneStyle)
            }
        }
        // Pinned to the rect `Dimensions` measures from: `.position` is
        // relative to the parent, and a layer that collapsed to its content
        // would put every stone somewhere else.
        .frame(width: dimensions.totalWidth, height: dimensions.totalHeight)
        // Decoration only. The tap that plays a move belongs to the board
        // underneath, and this sits over the intersection it just used.
        .allowsHitTesting(false)
    }
}

/// One stone settling onto the board: `settleScale` down to 1x with a contact
/// shadow fading out under it.
private struct ArrivingStoneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let stone: StoneMotionState.MotionStone
    let dimensions: Dimensions
    let verticalFlip: Bool
    let isClassicStoneStyle: Bool

    @State private var settled = false

    var body: some View {
        ZStack {
            // The contact shadow sells the descent, so Reduce Motion has no
            // use for it: with nothing travelling there is no contact to mark.
            if !reduceMotion {
                Ellipse()
                    .fill(Color.black)
                    .frame(width: dimensions.stoneLength * 1.05,
                           height: dimensions.stoneLength * 0.8)
                    .blur(radius: dimensions.squareLengthDiv8)
                    .opacity(settled ? 0 : MotionPreference.contactShadowOpacity)
            }
            StoneSprites.sprite(isClassicStoneStyle: isClassicStoneStyle,
                                color: stone.color,
                                dimensions: dimensions)
                .scaleEffect(settled
                             ? 1
                             : MotionPreference.scale(MotionPreference.settleScale,
                                                      reduceMotion: reduceMotion))
                // Under Reduce Motion this ramp is masked by the Canvas twin
                // the record already drew, so the stone simply appears — see
                // MotionPreference.scale(_:reduceMotion:).
                .opacity(reduceMotion ? (settled ? 1 : 0) : 1)
        }
        .position(dimensions.screenCenter(for: stone.point, verticalFlip: verticalFlip))
        .onAppear {
            // Driven from onAppear, never from `body`: the first render has to
            // happen at the START of the animation for there to be one.
            withAnimation(.easeOut(duration: MotionPreference.settleDuration)) {
                settled = true
            }
        }
    }
}

/// One stone leaving the board: an undone stone, or one a capture took. It has
/// no Canvas twin — it is not in the position any more — so this copy is the
/// only thing on screen at that point, and its fade is fully visible under
/// Reduce Motion.
private struct DepartingStoneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let stone: StoneMotionState.MotionStone
    let dimensions: Dimensions
    let verticalFlip: Bool
    let isClassicStoneStyle: Bool

    @State private var gone = false

    var body: some View {
        StoneSprites.sprite(isClassicStoneStyle: isClassicStoneStyle,
                            color: stone.color,
                            dimensions: dimensions)
            .scaleEffect(gone
                         ? MotionPreference.scale(MotionPreference.departureScale,
                                                  reduceMotion: reduceMotion)
                         : 1)
            .opacity(gone ? 0 : 1)
            .position(dimensions.screenCenter(for: stone.point, verticalFlip: verticalFlip))
            .onAppear {
                // A captured stone carries the settle as its delay, so it goes
                // as the capturing stone lands rather than a flight early.
                withAnimation(.easeIn(duration: MotionPreference.removalDuration)
                    .delay(stone.delay)) {
                    gone = true
                }
            }
    }
}
