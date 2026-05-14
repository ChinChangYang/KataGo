import Foundation
import Testing
@testable import KataGo_Anytime

@MainActor
struct CoreMLCacheReadinessTests {
    @Test func updateForFileNamesSetsReadyFromProjectionAndCache() async throws {
        // Two filenames: "a" has a digest and is cached; "b" has a digest
        // but is not cached. Expect only "a" in readyFileNames.
        let digestFor: @Sendable (String) async throws -> String? = { fileName in
            switch fileName {
            case "a": return "digest-a"
            case "b": return "digest-b"
            default:  return nil
            }
        }
        let hasEntry: @Sendable (String) async -> Bool = { digest in
            return digest == "digest-a"
        }

        let readiness = CoreMLCacheReadiness(
            digestFor: digestFor,
            hasEntry: hasEntry)

        await readiness.update(forFileNames: ["a", "b"])

        #expect(readiness.readyFileNames == ["a"])
    }

    @Test func updateForFileNamesTreatsNilDigestAsNotReady() async throws {
        // "missing" has no digest (file not downloaded). It must not
        // appear in readyFileNames even if hasEntry would say true for
        // some other digest.
        let digestFor: @Sendable (String) async throws -> String? = { _ in nil }
        let hasEntry: @Sendable (String) async -> Bool = { _ in true }

        let readiness = CoreMLCacheReadiness(
            digestFor: digestFor,
            hasEntry: hasEntry)

        await readiness.update(forFileNames: ["missing"])

        #expect(readiness.readyFileNames.isEmpty)
    }

    @Test func updateForFileNamesSwallowsDigestErrors() async throws {
        struct E: Error {}
        let digestFor: @Sendable (String) async throws -> String? = { fileName in
            if fileName == "throws" { throw E() }
            return "digest-\(fileName)"
        }
        let hasEntry: @Sendable (String) async -> Bool = { _ in true }

        let readiness = CoreMLCacheReadiness(
            digestFor: digestFor,
            hasEntry: hasEntry)

        await readiness.update(forFileNames: ["throws", "ok"])

        // "throws" is excluded; "ok" projected to "digest-ok" and present.
        #expect(readiness.readyFileNames == ["ok"])
    }
}
