//
//  GifPreviewTimingTests.swift
//  KataGo iOSTests
//

import Testing
@testable import KataGoUICore

/// Unit coverage for the GIF export **preview** timing model. It must reproduce
/// the exported GIF's pacing exactly (`GameGifRenderer`/`AnimatedGifEncoder`):
/// the first `n - 1` frames each span `secondsPerMove`, the final frame holds for
/// `finalHoldSeconds`, and the whole thing loops only when `loops` is true.
struct GifPreviewTimingTests {
    // 5 frames (a 4-move game), 0.5s per move, 2.0s final hold. Cycle = 4*0.5 + 2.0.
    private func looping(_ loops: Bool) -> GifPreviewTiming {
        GifPreviewTiming(frameCount: 5, secondsPerMove: 0.5, finalHoldSeconds: 2.0, loops: loops)
    }

    @Test func cycleAndFrameStarts() {
        let t = looping(true)
        #expect(t.cycle == 4.0)          // 4 moves * 0.5 + 2.0 hold
        #expect(t.start(of: 0) == 0.0)
        #expect(t.start(of: 3) == 1.5)
        #expect(t.start(of: 4) == 2.0)   // final frame appears here
    }

    @Test func firstFramesAreEvenlySpaced() {
        let t = looping(true)
        #expect(t.index(atElapsed: 0.0) == 0)
        #expect(t.index(atElapsed: 0.4) == 0)
        #expect(t.index(atElapsed: 0.5) == 1)   // exact boundary snaps forward
        #expect(t.index(atElapsed: 0.99) == 1)
        #expect(t.index(atElapsed: 1.0) == 2)
        #expect(t.index(atElapsed: 1.5) == 3)
    }

    @Test func finalFrameIsHeldThroughItsHold() {
        let t = looping(true)
        #expect(t.index(atElapsed: 2.0) == 4)   // final frame appears
        #expect(t.index(atElapsed: 3.0) == 4)   // still held mid-hold
        #expect(t.index(atElapsed: 3.99) == 4)  // still held at end of hold
    }

    @Test func loopingWrapsAtCycle() {
        let t = looping(true)
        #expect(t.index(atElapsed: 4.0) == 0)   // wraps to the start
        #expect(t.index(atElapsed: 4.5) == 1)
        #expect(t.index(atElapsed: 8.0) == 0)   // and again a cycle later
        #expect(t.isFinished(atElapsed: 100.0) == false)  // looping never finishes
    }

    @Test func notLoopingClampsToFinalFrame() {
        let t = looping(false)
        #expect(t.index(atElapsed: 1.9) == 3)   // still in the last move window
        #expect(t.index(atElapsed: 2.0) == 4)   // reaches the final frame...
        #expect(t.index(atElapsed: 3.0) == 4)   // ...and stays there
        #expect(t.index(atElapsed: 100.0) == 4) // frozen forever
    }

    @Test func isFinishedFlipsWhenFinalFrameReached() {
        let t = looping(false)
        #expect(t.isFinished(atElapsed: 1.9) == false)
        #expect(t.isFinished(atElapsed: 2.0) == true)
        #expect(t.isFinished(atElapsed: 100.0) == true)
    }

    /// The final-hold duration must change when the loop wraps — proof the hold is
    /// actually reflected in the timeline, not just the encoder.
    @Test func finalHoldChangesLoopWrapPoint() {
        let shortHold = GifPreviewTiming(frameCount: 5, secondsPerMove: 0.5, finalHoldSeconds: 0.5, loops: true)
        #expect(shortHold.cycle == 2.5)               // 2.0 + 0.5
        #expect(shortHold.index(atElapsed: 2.4) == 4) // final frame still held
        #expect(shortHold.index(atElapsed: 2.5) == 0) // wraps sooner than the 2.0s-hold case

        let longHold = looping(true)                  // 2.0s hold, cycle 4.0
        #expect(longHold.index(atElapsed: 2.5) == 4)  // same instant, still held
    }

    @Test func degenerateFrameCountsAreSafe() {
        for count in [0, 1] {
            let t = GifPreviewTiming(frameCount: count, secondsPerMove: 0.5, finalHoldSeconds: 2.0, loops: true)
            #expect(t.index(atElapsed: 0.0) == 0)
            #expect(t.index(atElapsed: 5.0) == 0)
            #expect(t.isFinished(atElapsed: 5.0) == false)
        }
    }
}
