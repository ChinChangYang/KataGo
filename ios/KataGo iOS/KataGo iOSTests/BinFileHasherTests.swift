import Foundation
import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct BinFileHasherTests {

    private func tempFile(_ bytes: Data) throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return url
    }

    @Test func computeReturnsSha256HexPrefix() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        let hasher = BinFileHasher(defaults: defaults)
        let url = try tempFile(Data("hello".utf8))
        let id = try await hasher.identityForDownloadedFile(url)
        // SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        #expect(id == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func memoIsReusedOnSecondCall() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        let hasher = BinFileHasher(defaults: defaults)
        let url = try tempFile(Data("hello".utf8))
        _ = try await hasher.identityForDownloadedFile(url)

        let id2 = try await hasher.identityForDownloadedFile(url)
        #expect(id2 == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

        let memoKey = "binFileSha256_\(url.lastPathComponent)"
        #expect(defaults.string(forKey: memoKey)?.hasPrefix("sha256:") == true)
    }

    @Test func memoInvalidatesOnSizeChange() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        let hasher = BinFileHasher(defaults: defaults)
        let url = try tempFile(Data("hello".utf8))
        _ = try await hasher.identityForDownloadedFile(url)

        try Data("helloo".utf8).write(to: url)   // size changes 5 → 6
        let id = try await hasher.identityForDownloadedFile(url)
        // SHA-256("helloo") differs.
        #expect(id != "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
