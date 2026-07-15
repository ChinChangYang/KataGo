import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct ThirdPartyLicensesTests {
    @Test func listsEveryShippedThirdPartyComponent() {
        let all = ThirdPartyLicense.all

        // Exhaustive list: 17 code components compiled/linked into the app
        // binaries, plus 3 content entries (kata1 networks, extra networks,
        // opening books).
        #expect(all.count == 20)

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
        for expected in ["KataGo", "MLX", "metal-cpp", "swift-numerics", "coremltools", "OpenCV"] {
            #expect(names.contains(expected), "Missing component: \(expected)")
        }
    }

    @Test func attributesTheDownloadedContent() {
        let byName = Dictionary(uniqueKeysWithValues:
            ThirdPartyLicense.all.map { ($0.name, $0) })

        // kata1 networks: the site's MIT-style Neural Net License, verbatim.
        let nets = byName["KataGo Neural Networks"]
        #expect(nets != nil)
        #expect(nets?.text.contains("katagotraining.org/network_license") == true)
        #expect(nets?.text.contains("neural net files or training weight files") == true)

        // Extra networks: factual attribution, no license claim (the files
        // carry no explicit statement upstream).
        let extras = byName["KataGo Extra Neural Networks"]
        #expect(extras != nil)
        #expect(extras?.text.contains("no explicit license statement") == true)
        #expect(extras?.text.contains("katagotraining.org/extra_networks") == true)

        // Opening books: MIT via the ChinChangYang/KataGoBooks packaging,
        // with both copyright lines retained.
        let books = byName["KataGo Opening Books"]
        #expect(books != nil)
        #expect(books?.subtitle.hasPrefix("MIT") == true)
        #expect(books?.text.contains("Copyright (c) 2026 Chin-Chang Yang") == true)
        #expect(books?.text.contains("David J Wu (\"lightvector\") and other KataGo authors") == true)
    }

    @Test func shippedScopesOpenCVToTheLinkGraph() {
        // iOS links GobanRecogKit, so this platform's list is the full
        // registry (the test suite only runs on the iOS simulator; the
        // tvOS/visionOS/watchOS arm is compile-time).
        #expect(ThirdPartyLicense.shipped.map(\.id) == ThirdPartyLicense.all.map(\.id))

        // The filter itself: OpenCV is the only entry that differs across
        // platforms (it ships only where GobanRecogKit is linked).
        let without = ThirdPartyLicense.shipped(includesOpenCV: false)
        #expect(without.count == ThirdPartyLicense.all.count - 1)
        #expect(!without.contains { $0.name == "OpenCV" })
        #expect(ThirdPartyLicense.shipped(includesOpenCV: true).map(\.id)
                == ThirdPartyLicense.all.map(\.id))
    }
}
