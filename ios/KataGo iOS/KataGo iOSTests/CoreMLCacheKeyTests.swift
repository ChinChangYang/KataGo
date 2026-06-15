import Testing
import Foundation
@testable import KataGo_Anytime
@testable import KataGoUICore

struct CoreMLCacheKeyTests {

    private let sample = CoreMLCacheKey(
        sourceIdentity: "builtin:1.0.42:104857600:1735689600000",
        boardXLen: 19, boardYLen: 19,
        computePrecision: "FP16",
        optimizeIdentityMask: false,
        minBatchSize: 1, maxBatchSize: 8,
        converterVersion: "1.1.0",
        osMajorVersion: 26
    )

    @Test func canonicalBytesIsKeyEqualsValueLF() {
        let s = String(decoding: sample.canonicalBytes, as: UTF8.self)
        let expected = """
        sourceIdentity=builtin:1.0.42:104857600:1735689600000
        boardXLen=19
        boardYLen=19
        computePrecision=FP16
        optimizeIdentityMask=false
        minBatchSize=1
        maxBatchSize=8
        converterVersion=1.1.0
        osMajorVersion=26

        """
        #expect(s == expected)
    }

    // Frozen-digest test (round 4). Compute once during implementation and
    // freeze; any future canonicalization change fails this loudly.
    @Test func digestPinnedConstant_BuiltIn() {
        #expect(sample.digest == "2b6a5145576110e213feab2017f5cb35")
    }

    @Test func digestPinnedConstant_Downloaded() {
        let downloaded = CoreMLCacheKey(
            sourceIdentity: "sha256:" + String(repeating: "0", count: 64),
            boardXLen: 19, boardYLen: 19,
            computePrecision: "FP16",
            optimizeIdentityMask: false,
            minBatchSize: 1, maxBatchSize: 8,
            converterVersion: "1.1.0",
            osMajorVersion: 26
        )
        #expect(downloaded.digest == "4df7bc6e56be55402c885ef98d30d072")
    }

    @Test func differentBoardSizeYieldsDifferentDigest() {
        let other = CoreMLCacheKey(
            sourceIdentity: sample.sourceIdentity,
            boardXLen: 13, boardYLen: 13,
            computePrecision: sample.computePrecision,
            optimizeIdentityMask: sample.optimizeIdentityMask,
            minBatchSize: sample.minBatchSize, maxBatchSize: sample.maxBatchSize,
            converterVersion: sample.converterVersion,
            osMajorVersion: sample.osMajorVersion
        )
        #expect(other.digest != sample.digest)
    }

    @Test func osMajorVersionInKey() {
        let other = CoreMLCacheKey(
            sourceIdentity: sample.sourceIdentity,
            boardXLen: sample.boardXLen, boardYLen: sample.boardYLen,
            computePrecision: sample.computePrecision,
            optimizeIdentityMask: sample.optimizeIdentityMask,
            minBatchSize: sample.minBatchSize, maxBatchSize: sample.maxBatchSize,
            converterVersion: sample.converterVersion,
            osMajorVersion: 27
        )
        #expect(other.digest != sample.digest)
    }

    // The spec's structural-collision rule (round 7) excludes `=`, `\n`,
    // space, and control bytes from string fields that flow into
    // `canonicalBytes`. We test the predicate directly because iOS
    // Testing does not support exit tests; trapping `preconditionFailure`
    // would require a process-spawn that iOS does not expose.
    @Test func rejectsStructuralCollisionBytes_Equals() {
        #expect(!CoreMLCacheKey.isFreeOfStructuralCollisionBytes("x=y"))
    }

    @Test func rejectsStructuralCollisionBytes_Newline() {
        #expect(!CoreMLCacheKey.isFreeOfStructuralCollisionBytes("x\ny"))
    }

    @Test func rejectsStructuralCollisionBytes_Space() {
        #expect(!CoreMLCacheKey.isFreeOfStructuralCollisionBytes("x y"))
    }

    @Test func rejectsStructuralCollisionBytes_Control() {
        #expect(!CoreMLCacheKey.isFreeOfStructuralCollisionBytes("x\u{0007}y"))
    }

    @Test func rejectsStructuralCollisionBytes_DEL() {
        #expect(!CoreMLCacheKey.isFreeOfStructuralCollisionBytes("x\u{007F}y"))
    }

    @Test func rejectsStructuralCollisionBytes_Empty() {
        #expect(!CoreMLCacheKey.isFreeOfStructuralCollisionBytes(""))
    }

    @Test func acceptsValidPrintableASCII() {
        // Coverage check: a typical sourceIdentity passes.
        #expect(CoreMLCacheKey.isFreeOfStructuralCollisionBytes("sha256:abc123"))
        #expect(CoreMLCacheKey.isFreeOfStructuralCollisionBytes("FP16"))
        #expect(CoreMLCacheKey.isFreeOfStructuralCollisionBytes("1.1.0"))
    }

    @Test func builtInIdentity_QuantizedToMs() throws {
        // Two Dates differing only in sub-millisecond precision must
        // produce identical sourceIdentity strings — guards against
        // Foundation Double-formatting drift.
        let a = Date(timeIntervalSince1970: 1735689600.0001)
        let b = Date(timeIntervalSince1970: 1735689600.0004)
        let ia = CoreMLCacheKey.builtInIdentity(version: "1.0.42",
                                                size: 104_857_600, mtime: a)
        let ib = CoreMLCacheKey.builtInIdentity(version: "1.0.42",
                                                size: 104_857_600, mtime: b)
        #expect(ia == ib)
        #expect(ia == "builtin:1.0.42:104857600:1735689600000")
    }

    @Test func builtInIdentity_NoDoubleInterpolation() throws {
        let id = CoreMLCacheKey.builtInIdentity(
            version: "1.0.42", size: 104_857_600,
            mtime: Date(timeIntervalSince1970: 1735689600.5))
        // The mtime segment is the last colon-separated component and
        // must be Int64 ms with no decimal point.
        let mtimeSegment = id.split(separator: ":").last!
        #expect(!mtimeSegment.contains("."))
    }

    @Test func bundleVersionSanitization() throws {
        // CFBundleVersion is not constrained to printable ASCII. Disallowed
        // bytes are sanitized to `_` BEFORE assembly so the resulting
        // identity string passes the structural-collision regex.
        let id = CoreMLCacheKey.builtInIdentity(
            version: "1.0 dev=42", size: 100,
            mtime: Date(timeIntervalSince1970: 0))
        #expect(id == "builtin:1.0_dev_42:100:0")
        // And it survives full key construction without preconditionFailure.
        _ = CoreMLCacheKey(
            sourceIdentity: id, boardXLen: 19, boardYLen: 19,
            computePrecision: "FP16", optimizeIdentityMask: false,
            minBatchSize: 1, maxBatchSize: 8,
            converterVersion: "1.1.0", osMajorVersion: 26)
    }

    @Test func builtInDispatchByPath() async throws {
        // The bundled default_model.bin.gz is in the test bundle's resources
        // when run from the iOS simulator. If it isn't present, the production
        // graceful-degradation path takes over (downloaded branch). Test the
        // built-in branch with whatever path Bundle.main returns.
        guard let bundleURL = Bundle.main.url(
            forResource: "default_model", withExtension: "bin.gz"
        ) else {
            Issue.record("default_model.bin.gz missing from test bundle — built-in dispatch path not exercised; CI must ensure this resource is included")
            return
        }
        let id = try await CoreMLCacheKey.sourceIdentity(
            for: bundleURL.path,
            downloadedHasher: { _ in
                Issue.record("downloadedHasher must not be called for the bundle path")
                throw CancellationError()
            })
        #expect(id.hasPrefix("builtin:"))
    }

    @Test func downloadedDispatchHashesOnDemand() async throws {
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(UUID()).bin.gz")
        try Data("hello".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let hasher = BinFileHasher(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let id = try await CoreMLCacheKey.sourceIdentity(
            for: tempURL.path,
            downloadedHasher: hasher.identityForDownloadedFile)
        #expect(id == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
}
