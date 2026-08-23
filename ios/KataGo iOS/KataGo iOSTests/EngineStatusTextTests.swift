//
//  EngineStatusTextTests.swift
//  KataGo iOSTests
//
//  The engine-availability state is shown INLINE, where analysis would appear —
//  never as a screen that replaces the board. These pin the strings that state
//  says, including the two rules ADR 0007 settled: the compile caption is
//  raised only by work that really is a compile, and it makes no claim about
//  whether that work will happen again.
//

import Testing
@testable import KataGoUICore

@MainActor
struct EngineStatusTextTests {

    // MARK: - decide

    /// Launching says one thing: the engine is loading. The view ticks the
    /// dots onto the headline, so the headline itself carries none.
    @Test func launchingSaysLoadingAndNothingElse() {
        let text = EngineStatusText.decide(availability: .launching,
                                           isCompiling: false,
                                           note: nil)

        #expect(text.headline == "Loading engine")
        #expect(text.secondary == nil)
        #expect(text.note == nil)
    }

    /// ADR 0007: the caption appears only while a compile is genuinely running.
    /// A cache hit — the overwhelmingly common launch — says nothing.
    @Test func aGenuineCompileAddsTheCaptionAndACacheHitDoesNot() {
        let compiling = EngineStatusText.decide(availability: .launching,
                                                isCompiling: true,
                                                note: nil)
        let warm = EngineStatusText.decide(availability: .launching,
                                           isCompiling: false,
                                           note: nil)

        #expect(compiling.secondary == "Compiling Core ML model…")
        #expect(warm.secondary == nil)
        // The headline is the same either way: it answers "is this stuck?",
        // which is the user's actual question.
        #expect(compiling.headline == warm.headline)
    }

    /// ADR 0007 forbids a recurrence claim ("first launch only") and a duration.
    @Test func theCompileCaptionPromisesNothingAboutRecurrence() {
        let caption = EngineStatusText.compilingCaption

        #expect(!caption.lowercased().contains("first"))
        #expect(!caption.lowercased().contains("only"))
        #expect(!caption.lowercased().contains("once"))
        #expect(!caption.contains("second"))
        #expect(!caption.contains("minute"))
    }

    /// The compile caption is raised by `EngineLaunchStatus`, so the two must
    /// spell it identically or the launch screen and the inline line drift.
    @Test func theLaunchStatusAndTheInlineLineShareOneCaption() {
        let status = EngineLaunchStatus()

        #expect(status.compileCaption == nil)
        status.compileBegan()
        #expect(status.compileCaption == EngineStatusText.compilingCaption)
        status.compileEnded()
        #expect(status.compileCaption == nil)
    }

    /// Absent is the iOS "no model chosen" state — an availability, not an
    /// error, so it never says "failed".
    @Test func absentSaysNoModelChosen() {
        let text = EngineStatusText.decide(availability: .absent,
                                           isCompiling: false,
                                           note: nil)

        #expect(text.headline == "No model chosen")
        #expect(text.secondary == nil)
    }

    /// A failure carries its reason: it is the only place the user can learn
    /// what went wrong, and the inline line is not size-constrained.
    @Test func failedShowsTheReasonUnderTheHeadline() {
        let text = EngineStatusText.decide(
            availability: .failed(reason: "The last launch did not finish loading b18."),
            isCompiling: false,
            note: nil)

        #expect(text.headline == "Engine failed")
        #expect(text.secondary == "The last launch did not finish loading b18.")
    }

    /// Held is a board too big for the RUNNING engine's NN buffer. The number
    /// is in the line because the exit — the Max Board Size setting — is
    /// meaningless without it.
    @Test func heldNamesTheMaxBoardSizeItIsHeldAgainst() {
        let text = EngineStatusText.decide(availability: .held(maxBoardLength: 19),
                                           isCompiling: false,
                                           note: nil)

        #expect(text.headline == "Board larger than Max Board Size 19")
        #expect(text.secondary == nil)
    }

    /// Ready says nothing at all — that is what makes this a status line and
    /// not a screen.
    @Test func readySaysNothing() {
        let text = EngineStatusText.decide(availability: .ready,
                                           isCompiling: true,
                                           note: nil)

        #expect(text.headline == nil)
        #expect(text.secondary == nil)
        #expect(text.note == nil)
    }

    /// The note is host-owned ("⟨title⟩ was removed — using the built-in
    /// network") and is orthogonal to availability: a ready engine running the
    /// fallback net still has something to say.
    @Test func theNoteSurvivesEveryStateIncludingReady() {
        let note = "b40 was removed — using the built-in network"

        let states: [EngineAvailability] = [.absent, .launching, .ready,
                                           .failed(reason: "boom"),
                                           .held(maxBoardLength: 9)]
        for availability in states {
            let text = EngineStatusText.decide(availability: availability,
                                               isCompiling: false,
                                               note: note)
            #expect(text.note == note)
        }
    }

    // MARK: - tvLine

    /// tvOS must never truncate or wrap: one short fixed line per state.
    @Test func tvLineIsOneShortLinePerState() throws {
        let lines: [String?] = [
            EngineStatusText.tvLine(availability: .launching, isCompiling: false),
            EngineStatusText.tvLine(availability: .launching, isCompiling: true),
            EngineStatusText.tvLine(availability: .absent, isCompiling: false),
            EngineStatusText.tvLine(availability: .failed(reason: "x"), isCompiling: false),
            EngineStatusText.tvLine(availability: .held(maxBoardLength: 37), isCompiling: false)
        ]

        for line in lines {
            let line = try #require(line)
            #expect(!line.isEmpty)
            #expect(line.count <= 40)
            #expect(!line.contains("\n"))
        }
    }

    /// The reason can be any length and comes from the engine, so tvOS gets a
    /// fixed pointer at Settings instead. A raw reason would clip.
    @Test func tvLineNeverRepeatsTheFailureReason() {
        let reason = String(repeating: "a very long engine failure reason ", count: 5)
        let line = EngineStatusText.tvLine(availability: .failed(reason: reason),
                                           isCompiling: false)

        #expect(line == "Engine failed — see Settings")
        #expect(line?.contains("very long") == false)
    }

    /// Compiling outranks the plain loading line on tvOS: with only one line to
    /// spend, the more informative one wins.
    @Test func tvLinePrefersTheCompileCaptionWhileCompiling() {
        #expect(EngineStatusText.tvLine(availability: .launching, isCompiling: false)
                == "Loading engine…")
        #expect(EngineStatusText.tvLine(availability: .launching, isCompiling: true)
                == EngineStatusText.compilingCaption)
    }

    @Test func tvLineIsNilWhenReady() {
        #expect(EngineStatusText.tvLine(availability: .ready, isCompiling: true) == nil)
    }
}
