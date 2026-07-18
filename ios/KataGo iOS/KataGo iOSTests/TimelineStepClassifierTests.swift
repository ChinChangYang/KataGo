//
//  TimelineStepClassifierTests.swift
//  KataGo AnytimeTests
//

import Foundation
import Testing
@testable import KataGoUICore

struct TimelineStepClassifierTests {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    @Test func freshClassifierReadsSwipe() {
        let classifier = TimelineStepClassifier()
        #expect(classifier.stepCount(at: date(100)) == TimelineStepClassifier.swipeStepCount)
    }

    @Test func heldPressReadsClickLongPastGrace() {
        var classifier = TimelineStepClassifier()
        classifier.arrowPressBegan(at: date(0))
        // Hold-to-auto-repeat: move commands keep arriving while the press is
        // down, long after any grace interval — every one must read as a click.
        #expect(classifier.stepCount(at: date(5)) == TimelineStepClassifier.clickStepCount)
    }

    @Test func withinGraceAfterReleaseReadsClick() {
        var classifier = TimelineStepClassifier()
        classifier.arrowPressBegan(at: date(0))
        classifier.arrowPressEnded(at: date(0.30))
        #expect(classifier.stepCount(at: date(0.40)) == TimelineStepClassifier.clickStepCount)
    }

    @Test func beyondGraceAfterReleaseReadsSwipe() {
        var classifier = TimelineStepClassifier()
        classifier.arrowPressBegan(at: date(0))
        classifier.arrowPressEnded(at: date(0.30))
        #expect(classifier.stepCount(at: date(0.60)) == TimelineStepClassifier.swipeStepCount)
    }

    @Test func fastTapFullyBeforeQueryReadsClick() {
        var classifier = TimelineStepClassifier()
        // The release-before-move-command ordering: the press came and went
        // before the move command was dispatched.
        classifier.arrowPressBegan(at: date(0))
        classifier.arrowPressEnded(at: date(0.05))
        #expect(classifier.stepCount(at: date(0.10)) == TimelineStepClassifier.clickStepCount)
    }

    @Test func graceBoundaryIsInclusive() {
        var classifier = TimelineStepClassifier()
        classifier.arrowPressBegan(at: date(0))
        classifier.arrowPressEnded(at: date(1.0))
        let boundary = 1.0 + TimelineStepClassifier.clickGraceInterval
        #expect(classifier.stepCount(at: date(boundary)) == TimelineStepClassifier.clickStepCount)
        #expect(classifier.stepCount(at: date(boundary + 0.000001)) == TimelineStepClassifier.swipeStepCount)
    }

    @Test func queryBeforePressEventStillReadsClick() {
        var classifier = TimelineStepClassifier()
        // A negative elapsed interval (clock skew, event reordering) must fall
        // on the click side — under-stepping is the harmless direction.
        classifier.arrowPressBegan(at: date(1.0))
        classifier.arrowPressEnded(at: date(1.1))
        #expect(classifier.stepCount(at: date(0.95)) == TimelineStepClassifier.clickStepCount)
    }

    @Test func overlappingPressesStayClickWhileOneIsDown() {
        var classifier = TimelineStepClassifier()
        classifier.arrowPressBegan(at: date(0))
        classifier.arrowPressBegan(at: date(0.02))
        classifier.arrowPressEnded(at: date(0.04))
        // One press released, the other still down — well past grace.
        #expect(classifier.stepCount(at: date(3)) == TimelineStepClassifier.clickStepCount)
    }

    @Test func endedWithoutBeganClampsAndStillWorks() {
        var classifier = TimelineStepClassifier()
        // A stray release (recognizer re-armed mid-press) must not underflow.
        classifier.arrowPressEnded(at: date(0))
        #expect(classifier.stepCount(at: date(0.10)) == TimelineStepClassifier.clickStepCount)
        #expect(classifier.stepCount(at: date(1.0)) == TimelineStepClassifier.swipeStepCount)
        // A subsequent normal cycle still behaves.
        classifier.arrowPressBegan(at: date(2.0))
        #expect(classifier.stepCount(at: date(2.5)) == TimelineStepClassifier.clickStepCount)
        classifier.arrowPressEnded(at: date(2.6))
        #expect(classifier.stepCount(at: date(3.0)) == TimelineStepClassifier.swipeStepCount)
    }

    @Test func resetClearsPressState() {
        var classifier = TimelineStepClassifier()
        classifier.arrowPressBegan(at: date(0))
        classifier.reset()
        #expect(classifier.stepCount(at: date(0.01)) == TimelineStepClassifier.swipeStepCount)
    }

    @Test func staleClickDoesNotCaptureLaterSwipe() {
        var classifier = TimelineStepClassifier()
        classifier.arrowPressBegan(at: date(0))
        classifier.arrowPressEnded(at: date(0.1))
        #expect(classifier.stepCount(at: date(1.0)) == TimelineStepClassifier.swipeStepCount)
    }
}
