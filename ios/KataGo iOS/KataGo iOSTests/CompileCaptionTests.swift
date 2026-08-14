import Foundation
import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

/// Pins the two halves of ADR 0007: the compile caption is raised only by work
/// that really is a compile, and the counter behind it cannot be driven
/// negative by a release that arrives late.
///
/// The reporting seam is exercised through an injected `CompileReporter`, never
/// through the process-wide one — `registerEngineLaunchStatusUpdater` has no
/// unregister, and these tests are app-hosted, so touching the global would
/// leak into every other suite in the process.
struct CompileCaptionTests {

    /// Records begin/end events off-actor, the way the real reporter is called.
    private actor Recorder {
        private(set) var begans = 0
        private(set) var endeds = 0
        func recordBegan() { begans += 1 }
        func recordEnded() { endeds += 1 }
    }

    private func makeSpan() -> (CompileReportSpan, Recorder) {
        let recorder = Recorder()
        let reporter = CompileReporter(
            began: { await recorder.recordBegan() },
            ended: { await recorder.recordEnded() })
        return (CompileReportSpan(reporter), recorder)
    }

    // MARK: - The gate: only a genuine compile reports

    @Test func aSpanThatNeverRanTheCompileReportsNothing() async {
        let (span, recorder) = makeSpan()

        // A cache HIT never enters the miss callback, so `reportingCompile` is
        // never called. This is the whole point of the fix: before ADR 0007 the
        // caption was raised before the hit/miss branch and lit on every launch.
        await span.drain().value

        #expect(await recorder.begans == 0)
        #expect(await recorder.endeds == 0)
    }

    @Test func runningTheCompileRaisesTheCaption() async throws {
        let (span, recorder) = makeSpan()

        let result = try await reportingCompile(in: span) { "compiled" }

        #expect(result == "compiled")
        // Raised, and still held: the caption must outlive the compile itself,
        // because the index write and the ANE program build come after it.
        #expect(await recorder.begans == 1)
        #expect(await recorder.endeds == 0)

        await span.drain().value
        #expect(await recorder.endeds == 1)
    }

    @Test func aThrowingCompileStillBalances() async {
        let (span, recorder) = makeSpan()
        struct ConverterFailure: Error {}

        await #expect(throws: ConverterFailure.self) {
            try await reportingCompile(in: span) { throw ConverterFailure() }
        }

        // `convertOnCooperativePool` throws on converter failure and returns
        // promptly. Without the enclosing load's drain the caption would pin on
        // for the life of the process under a FAILED engine launch.
        #expect(await recorder.begans == 1)
        await span.drain().value
        #expect(await recorder.endeds == 1)
    }

    @Test func theCorruptHitRetryIsCountedNotFlagged() async throws {
        let (span, recorder) = makeSpan()

        // `loadCoreMLHandle` retries once on a corrupt cache hit, which runs the
        // miss callback a second time. A Bool would leak the second raise.
        _ = try await reportingCompile(in: span) { 1 }
        _ = try await reportingCompile(in: span) { 2 }

        #expect(await recorder.begans == 2)
        await span.drain().value
        #expect(await recorder.endeds == 2)
    }

    @Test func drainingTwiceDoesNotDoubleRelease() async throws {
        let (span, recorder) = makeSpan()
        _ = try await reportingCompile(in: span) { 0 }

        await span.drain().value
        await span.drain().value

        #expect(await recorder.endeds == 1)
    }

    // MARK: - The counter: commutative, and clamped at zero

    @MainActor
    @Test func theCaptionShowsWhileAnyCompileIsRunning() {
        let status = EngineLaunchStatus()
        #expect(status.isCompiling == false)

        status.compileBegan()
        #expect(status.isCompiling)

        // Two overlapping compiles: the first one finishing must not blank a
        // caption the second one is still making true.
        status.compileBegan()
        status.compileEnded()
        #expect(status.isCompiling)

        status.compileEnded()
        #expect(status.isCompiling == false)
    }

    @MainActor
    @Test func aLateReleaseCannotSilenceTheNextCompile() {
        let status = EngineLaunchStatus()
        status.compileBegan()
        status.compileEnded()

        // The launch-timeout path abandons a compile it cannot cancel, so that
        // compile's release can land after everything else has settled. Without
        // the clamp the count would go to -1 here and the next real compile
        // would raise it only back to 0 — a silent caption during a compile.
        status.compileEnded()
        status.compileEnded()

        status.compileBegan()
        #expect(status.isCompiling)
    }
}
