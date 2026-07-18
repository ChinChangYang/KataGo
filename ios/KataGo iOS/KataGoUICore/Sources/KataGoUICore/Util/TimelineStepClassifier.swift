import Foundation

/// Classifies a Siri-Remote move command on the tvOS review timeline as an
/// edge CLICK (step 1 move) or a touch-surface SWIPE (jump 10 moves). Both
/// gestures deliver the identical SwiftUI move command; only a click also
/// produces `UIPress` arrow events, so the tvOS window-level press observer
/// feeds raw arrow press down/up into this type and the move-command handler
/// asks `stepCount(at:)` which magnitude to step.
///
/// Extracted into `KataGoUICore` (dependency-light, platform-agnostic) so the
/// classification timing is unit-testable from the iOS test host: its only
/// consumer, the tvOS `TVReviewScreen`, is a TV-target-only view the test
/// target can't reach.
///
/// The rule tolerates either delivery order between the move command and the
/// press events (undocumented on tvOS 26): a press currently down is a click
/// (which also covers hold-to-auto-repeat, where repeated move commands arrive
/// while the press stays down), and a press event within the last
/// `clickGraceInterval` is a click (covering a move command dispatched just
/// after release). Anything else — in particular a pure touch swipe, which
/// produces no arrow press at all — is a swipe. Only left/right arrow presses
/// are reported to this type; the timeline's down focus-hop never touches it.
/// Misclassification is asymmetric by design: every ambiguous case falls on
/// the click side, because under-stepping by 9 moves is harmless while a
/// surprise 10-move jump on a precise single step is not.
public struct TimelineStepClassifier: Sendable {
    public static let clickStepCount = 1
    /// Matches the iOS toolbar's 10-move jump buttons.
    public static let swipeStepCount = 10
    /// Hold-repeat is covered by the down-count, so the grace only needs to
    /// absorb run-loop dispatch skew between a release and its move command;
    /// keeping it short shrinks the only misclassification window (a swipe
    /// started this soon after a click release under-steps as a click).
    public static let clickGraceInterval: TimeInterval = 0.15

    /// A count, not a Bool: overlapping presses (second edge pressed before
    /// the first is released) must keep reading as "down" until the last one
    /// ends. Clamped at zero so a stray release after re-arming cannot
    /// underflow into a permanently-swipe state.
    private var arrowPressesDown = 0
    /// Updated by BOTH began and ended, so a fast down/up pair fully processed
    /// before the move command still classifies as a click.
    private var lastArrowPressEvent: Date?

    public init() {}

    public mutating func arrowPressBegan(at date: Date) {
        arrowPressesDown += 1
        lastArrowPressEvent = date
    }

    /// Call for both ended and cancelled presses.
    public mutating func arrowPressEnded(at date: Date) {
        arrowPressesDown = max(0, arrowPressesDown - 1)
        lastArrowPressEvent = date
    }

    /// Forget all press state — the failsafe when the observer is disarmed
    /// mid-press (focus left the timeline before the release arrived).
    public mutating func reset() {
        arrowPressesDown = 0
        lastArrowPressEvent = nil
    }

    /// The move-command magnitude: `clickStepCount` while an arrow press is
    /// down or within `clickGraceInterval` of the last press event (a negative
    /// elapsed interval counts as within — the safe side), else
    /// `swipeStepCount`.
    public func stepCount(at date: Date) -> Int {
        if arrowPressesDown > 0 {
            return Self.clickStepCount
        }
        if let lastArrowPressEvent,
           date.timeIntervalSince(lastArrowPressEvent) <= Self.clickGraceInterval {
            return Self.clickStepCount
        }
        return Self.swipeStepCount
    }
}
