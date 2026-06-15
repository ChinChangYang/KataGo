import CryptoKit
import Foundation

/// Errors thrown by CoreMLCacheKey operations.
public enum CoreMLCacheKeyError: Error, Sendable {
    /// Default `downloadedHasher` was not replaced with a real implementation.
    /// Production call sites must inject `BinFileHasher.shared.identityForDownloadedFile`;
    /// landing this error means a programmer wiring bug.
    case downloadedHasherNotInjected
}

/// Pin set is keyed by `(digest, epoch)` — see CoreMLModelCache.
public struct DigestEpoch: Hashable, Sendable {
    public let digest: String
    public let epoch: UUID
    public init(digest: String, epoch: UUID) { self.digest = digest; self.epoch = epoch }
}

public struct CoreMLCacheKey: Sendable {
    public let sourceIdentity: String
    public let boardXLen: Int32
    public let boardYLen: Int32
    public let computePrecision: String   // "FP16" | "FP32"
    public let optimizeIdentityMask: Bool
    public let minBatchSize: Int
    public let maxBatchSize: Int
    public let converterVersion: String
    public let osMajorVersion: Int

    public init(
        sourceIdentity: String,
        boardXLen: Int32, boardYLen: Int32,
        computePrecision: String,
        optimizeIdentityMask: Bool,
        minBatchSize: Int, maxBatchSize: Int,
        converterVersion: String,
        osMajorVersion: Int
    ) {
        Self.requireStructurallyValid(field: "sourceIdentity", value: sourceIdentity)
        Self.requireStructurallyValid(field: "computePrecision", value: computePrecision)
        Self.requireStructurallyValid(field: "converterVersion", value: converterVersion)
        self.sourceIdentity = sourceIdentity
        self.boardXLen = boardXLen
        self.boardYLen = boardYLen
        self.computePrecision = computePrecision
        self.optimizeIdentityMask = optimizeIdentityMask
        self.minBatchSize = minBatchSize
        self.maxBatchSize = maxBatchSize
        self.converterVersion = converterVersion
        self.osMajorVersion = osMajorVersion
    }

    /// True iff `value` contains only printable ASCII excluding `=`, `\n`,
    /// space, and other controls. Public so tests can verify the rule
    /// without needing exit-test support (iOS Testing has no exit tests).
    public static func isFreeOfStructuralCollisionBytes(_ value: String) -> Bool {
        if value.isEmpty { return false }
        for byte in value.utf8 {
            let ok = (byte >= 0x21 && byte != 0x3D && byte <= 0x7E)
            if !ok { return false }
        }
        return true
    }

    private static func requireStructurallyValid(field: String, value: String) {
        precondition(isFreeOfStructuralCollisionBytes(value),
                     "CoreMLCacheKey.\(field) contains a structurally illegal byte (must be printable ASCII excluding '=', '\\n', space)")
    }

    public var canonicalBytes: Data {
        var s = ""
        s += "sourceIdentity=\(sourceIdentity)\n"
        s += "boardXLen=\(boardXLen)\n"
        s += "boardYLen=\(boardYLen)\n"
        s += "computePrecision=\(computePrecision)\n"
        s += "optimizeIdentityMask=\(optimizeIdentityMask)\n"
        s += "minBatchSize=\(minBatchSize)\n"
        s += "maxBatchSize=\(maxBatchSize)\n"
        s += "converterVersion=\(converterVersion)\n"
        s += "osMajorVersion=\(osMajorVersion)\n"
        return Data(s.utf8)
    }

    public var digest: String {
        let hash = SHA256.hash(data: canonicalBytes)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

extension CoreMLCacheKey {
    /// Build the `"builtin:..."` source identity. Quantizes mtime to whole
    /// milliseconds (Int64 base-10) so the digest is stable across Foundation
    /// `Double`-formatting changes. Sanitizes disallowed bytes in `version`
    /// to `_` BEFORE assembly, since CFBundleVersion is not constrained to
    /// printable ASCII.
    public static func builtInIdentity(
        version: String, size: Int64, mtime: Date
    ) -> String {
        let mtimeMs = Int64((mtime.timeIntervalSince1970 * 1000).rounded())
        var sanitized = ""
        for scalar in version.unicodeScalars {
            let v = scalar.value
            let printable = (v >= 0x21 && v != 0x3D && v <= 0x7E)
            sanitized.append(printable ? Character(scalar) : "_")
        }
        return "builtin:\(sanitized):\(size):\(mtimeMs)"
    }
}

extension CoreMLCacheKey {
    /// Path-comparing dispatch. Built-in: `"builtin:<bundleVersion>:<size>:<mtimeMs>"`.
    /// Downloaded: delegates to the injected `downloadedHasher` (default = throws,
    /// which forces a deliberate caller-side wiring). Both sides
    /// `.resolvingSymlinksInPath().standardizedFileURL` so macOS firmlinks
    /// (`/var` ↔ `/private/var`) don't fool the comparison.
    public static func sourceIdentity(
        for modelPath: String,
        downloadedHasher: @Sendable (URL) async throws -> String = { _ in
            throw CoreMLCacheKeyError.downloadedHasherNotInjected
        }
    ) async throws -> String {
        let candidate = URL(fileURLWithPath: modelPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let bundleURL = Bundle.main
            .url(forResource: "default_model", withExtension: "bin.gz")?
            .resolvingSymlinksInPath()
            .standardizedFileURL

        if let bundleURL, candidate == bundleURL {
            let attrs = try FileManager.default.attributesOfItem(atPath: bundleURL.path)
            let size = (attrs[.size] as? Int64) ?? 0
            let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
            return builtInIdentity(version: version, size: size, mtime: mtime)
        }
        return try await downloadedHasher(URL(fileURLWithPath: modelPath))
    }
}
