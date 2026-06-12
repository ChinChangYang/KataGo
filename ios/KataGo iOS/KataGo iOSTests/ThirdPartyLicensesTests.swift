import Testing
@testable import KataGo_Anytime

struct ThirdPartyLicensesTests {
    @Test func listsEveryShippedThirdPartyComponent() {
        let all = ThirdPartyLicense.all

        // Exhaustive list of components compiled/linked into the iOS binary.
        #expect(all.count == 16)

        // Every entry is fully populated with a real license body (not a stub).
        for license in all {
            #expect(!license.name.isEmpty)
            #expect(!license.subtitle.isEmpty)
            #expect(license.text.count > 100)
        }

        // Identifiers are unique (drives SwiftUI List + ForEach).
        #expect(Set(all.map(\.id)).count == all.count)

        // The MLX trigger plus a few representative components are present.
        let names = Set(all.map(\.name))
        for expected in ["KataGo", "MLX", "metal-cpp", "swift-numerics", "coremltools"] {
            #expect(names.contains(expected), "Missing component: \(expected)")
        }
    }
}
