import Foundation
import Testing
@testable import KataGo_Anytime

struct RootViewBundleUpgradeTests {
    @Test func bundleUpgradeRetriggers() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("1.0.41", forKey: "CoreMLCache.firstLaunchPrecompileVersion")

        var enqueued = 0
        let stored = defaults.string(forKey: "CoreMLCache.firstLaunchPrecompileVersion") ?? ""
        if BundleVersionWarmDecision.shouldRewarm(stored: stored, current: "1.0.42") {
            enqueued += 1
            defaults.set("1.0.42", forKey: "CoreMLCache.firstLaunchPrecompileVersion")
        }
        #expect(enqueued == 1)
        #expect(defaults.string(forKey: "CoreMLCache.firstLaunchPrecompileVersion") == "1.0.42")

        // Re-fire — no enqueue, no flag change.
        let stored2 = defaults.string(forKey: "CoreMLCache.firstLaunchPrecompileVersion") ?? ""
        #expect(!BundleVersionWarmDecision.shouldRewarm(stored: stored2, current: "1.0.42"))
    }

    @Test func emptyStoredVersionTriggersFirstWarm() {
        #expect(BundleVersionWarmDecision.shouldRewarm(stored: "", current: "1.0.42"))
    }
}
