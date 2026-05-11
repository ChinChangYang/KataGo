import CryptoKit
import Foundation

/// Async streaming SHA-256 with `(size, mtime)` UserDefaults memoization.
/// Hashing 270 MB takes ~seconds; runs off-MainActor on the cooperative pool.
public final class BinFileHasher: @unchecked Sendable {
    public static let shared = BinFileHasher(defaults: .standard)

    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Returns `"sha256:<hex>"`. Reuses memo iff `(size, mtime)` match.
    public func identityForDownloadedFile(_ url: URL) async throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int64) ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1

        let name = url.lastPathComponent
        let kSha = "binFileSha256_\(name)"
        let kSize = "binFileSize_\(name)"
        let kMtime = "binFileMtime_\(name)"

        if let memo = defaults.string(forKey: kSha),
           defaults.object(forKey: kSize) as? Int64 == size,
           defaults.object(forKey: kMtime) as? Double == mtime {
            return memo
        }

        let urlCopy = url
        let hex = try await Task.detached(priority: .userInitiated) { () throws -> String in
            let handle = try FileHandle(forReadingFrom: urlCopy)
            defer { try? handle.close() }
            var hasher = SHA256()
            while try autoreleasepool(invoking: { () throws -> Bool in
                // Propagate I/O errors. A silently-truncated read here
                // would produce a SHA-256 of a partial file and corrupt
                // the cache key the result feeds.
                let chunk = (try handle.read(upToCount: 1 << 20)) ?? Data()
                if chunk.isEmpty { return false }
                hasher.update(data: chunk)
                return true
            }) {}
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value

        let id = "sha256:\(hex)"
        defaults.set(id, forKey: kSha)
        defaults.set(size, forKey: kSize)
        defaults.set(mtime, forKey: kMtime)
        return id
    }
}
