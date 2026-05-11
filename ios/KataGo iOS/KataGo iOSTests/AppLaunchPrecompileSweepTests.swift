import Foundation
import Testing
import KataGoInterface
@testable import KataGo_Anytime

struct AppLaunchPrecompileSweepTests {

    // Shared fixture: scheduler whose worker only counts invocations
    // per fileName. Backend keys are left unset in the per-test
    // UserDefaults suite so the mpsGPU skip never fires.
    private func makeFixture() async -> (PrecompileScheduler, FileNameCounter) {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        let counter = FileNameCounter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { fileName in
            await counter.inc(fileName)
        }
        return (scheduler, counter)
    }

    actor FileNameCounter {
        private var counts: [String: Int] = [:]
        func inc(_ fileName: String) { counts[fileName, default: 0] += 1 }
        func count(_ fileName: String) -> Int { counts[fileName] ?? 0 }
        func total() -> Int { counts.values.reduce(0, +) }
    }

    @MainActor
    @Test func sweepsBothWhenCacheEmpty() async throws {
        let (scheduler, counter) = await makeFixture()
        // status is empty -> both targets are not .ready.

        await runCacheEmptySweep(scheduler: scheduler)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await counter.count("default_model.bin.gz") == 1)
        #expect(await counter.count("b18c384nbt-humanv0.bin.gz") == 1)
        #expect(await counter.total() == 2)
    }

    @MainActor
    @Test func sweepsOnlyAuxWhenBuiltInReady() async throws {
        let (scheduler, counter) = await makeFixture()
        scheduler._setCachedReadyForTests(["default_model.bin.gz"])

        await runCacheEmptySweep(scheduler: scheduler)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await counter.count("default_model.bin.gz") == 0)
        #expect(await counter.count("b18c384nbt-humanv0.bin.gz") == 1)
    }

    @MainActor
    @Test func sweepsNothingWhenBothReady() async throws {
        let (scheduler, counter) = await makeFixture()
        scheduler._setCachedReadyForTests([
            "default_model.bin.gz",
            "b18c384nbt-humanv0.bin.gz"
        ])

        await runCacheEmptySweep(scheduler: scheduler)
        try await Task.sleep(for: .milliseconds(50))

        #expect(await counter.total() == 0)
    }

    @MainActor
    @Test func sweepDoesNotReScheduleQueuedOrCompiling() async throws {
        let (scheduler, counter) = await makeFixture()
        scheduler._setEphemeralForTests([
            "default_model.bin.gz": .compiling,
            "b18c384nbt-humanv0.bin.gz": .queued
        ])

        await runCacheEmptySweep(scheduler: scheduler)
        try await Task.sleep(for: .milliseconds(50))

        // Neither target is .ready, but both are in-flight. The sweep
        // calls scheduleForModel anyway; scheduleForModel's inFlight
        // dedup is what blocks the worker from being invoked again.
        // What we assert here is the user-visible outcome: the worker
        // is not run a second time.
        #expect(await counter.count("default_model.bin.gz") == 0)
        #expect(await counter.count("b18c384nbt-humanv0.bin.gz") == 0)
    }
}
