import Foundation
import Testing
@testable import KataGo_Anytime

struct PrecompileSchedulerTests {
    @MainActor
    @Test func ephemeralStateAndCachedReadyMergeCorrectly() async throws {
        let scheduler = PrecompileScheduler(worker: { _ in })
        scheduler._setEphemeralForTests(["a.bin.gz": .compiling])
        scheduler._setCachedReadyForTests(["b.bin.gz", "a.bin.gz"])

        // Ephemeral wins where both exist.
        #expect(scheduler.status["a.bin.gz"] == .compiling)
        // CachedReady fills in where ephemeral is absent.
        #expect(scheduler.status["b.bin.gz"] == .ready)
        // Unknown remains nil (badge resolves to .idle via the ?? .idle
        // fallback at the call site).
        #expect(scheduler.status["c.bin.gz"] == nil)
    }


    @Test func skipsWhenBackendIsMpsGpu() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("mpsGPU", forKey: "backend_default_model.bin.gz")

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { _ in
            await counter.inc()
        }
        await scheduler.scheduleForModel(fileName: "default_model.bin.gz")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.get() == 0)
    }

    @Test func runsWhenBackendIsCoreml() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("coremlNE", forKey: "backend_default_model.bin.gz")

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { _ in
            await counter.inc()
        }
        await scheduler.scheduleForModel(fileName: "default_model.bin.gz")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await counter.get() == 1)
    }

    @Test func dedupesIdenticalEnqueues() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("coremlNE", forKey: "backend_default_model.bin.gz")

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()
        let scheduler = await PrecompileScheduler(defaults: defaults) { _ in
            await counter.inc()
            try? await Task.sleep(for: .milliseconds(50))
        }
        async let a: Void = scheduler.scheduleForModel(fileName: "default_model.bin.gz")
        async let b: Void = scheduler.scheduleForModel(fileName: "default_model.bin.gz")
        _ = await (a, b)
        try await Task.sleep(for: .milliseconds(120))
        #expect(await counter.get() == 1)
    }
}
