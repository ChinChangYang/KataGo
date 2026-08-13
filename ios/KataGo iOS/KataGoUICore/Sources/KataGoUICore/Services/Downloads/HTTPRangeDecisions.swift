//
//  HTTPRangeDecisions.swift
//  KataGo Anytime
//
//  Every judgement the download transport makes about a response, as pure
//  functions over value types. No URLSession, no FileManager — this is the
//  part the iOS-simulator test target can actually reach, because a
//  background URLSession ignores URLProtocol stubs.
//

import Foundation

/// A parsed `Content-Range: bytes <first>-<last>/<total>` header.
/// `total` is nil for the legal `*` form.
///
/// Parsing is the ONLY way to make one — there is deliberately no memberwise
/// initializer — so `first >= 0` and `last >= first` hold for every value that
/// exists.
public struct ContentRangeHeader: Equatable, Sendable {
    public let first: Int64
    public let last: Int64
    public let total: Int64?

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let body = trimmed.dropFirst("bytes ".count)
        let halves = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let first = Int64(bounds[0]),
              let last = Int64(bounds[1]),
              first >= 0, last >= first else { return nil }
        self.first = first
        self.last = last
        self.total = halves[1] == "*" ? nil : Int64(halves[1])
    }
}

/// What to do with the bytes a finished transfer produced.
public enum ResumeDecision: Equatable, Sendable {
    /// The server honoured our range: append this body to the partial.
    case append(expectedTotal: Int64?)
    /// The server sent the whole asset: throw the partial away and use this.
    case restart(expectedTotal: Int64?)
    /// Not a body worth keeping. The partial is left exactly as it was.
    case fail(reason: String)

    /// - Parameters:
    ///   - sentRange: whether the request carried a `Range` header. The
    ///     transport always sends one (it fetches in fixed-size chunks), but
    ///     the no-range case stays modelled so it cannot silently accept a
    ///     206 it never asked for.
    ///   - requestedOffset: the first byte our `Range` header asked for.
    ///   - contentLength: the response's declared body length, or nil when it
    ///     declared none. For a 200 this is the asset's total.
    ///
    /// A ranged request accepts **exactly 206**. 200 means the server ignored
    /// the range and is sending the whole asset — which also covers the
    /// `If-Range` miss, i.e. the asset changed under us — so the partial is
    /// discarded and this body replaces it. Everything else is an error,
    /// including GitHub's `618 jwt:expired`, which is neither 4xx nor 5xx and
    /// which a `(200...299)` range check would also have let through.
    public static func decide(sentRange: Bool,
                              requestedOffset: Int64,
                              statusCode: Int,
                              contentRange: String?,
                              contentLength: Int64?) -> ResumeDecision {
        if sentRange {
            switch statusCode {
            case 206:
                guard let raw = contentRange, let parsed = ContentRangeHeader(raw) else {
                    return .fail(reason: "206 without a usable Content-Range")
                }
                guard parsed.first == requestedOffset else {
                    return .fail(reason: "206 starting at \(parsed.first), asked for \(requestedOffset)")
                }
                return .append(expectedTotal: parsed.total)
            case 200:
                return .restart(expectedTotal: contentLength)
            default:
                return .fail(reason: "unexpected status \(statusCode) for a ranged request")
            }
        } else {
            guard statusCode == 200 else {
                return .fail(reason: "unexpected status \(statusCode)")
            }
            return .restart(expectedTotal: contentLength)
        }
    }
}

/// The gate a download passes before its file may reach its destination.
public enum TransferVerification: Equatable, Sendable {
    case verified
    case sizeMismatch(expected: Int64, actual: Int64)

    /// Verifies against the total the **server** declared, never the catalog's
    /// hand-maintained `fileSize` — catalog sizes drift, and a download that
    /// arrived intact must not be refused because a literal in the app is
    /// stale.
    ///
    /// A server that declares no total leaves nothing to check. `URLSession`
    /// already fails a transfer whose body ends prematurely when a length was
    /// declared, so the undeclared case is passed rather than refused; it
    /// would otherwise make such an asset permanently undownloadable.
    public static func check(assembledBytes: Int64, declaredTotal: Int64?) -> TransferVerification {
        guard let declaredTotal, declaredTotal > 0 else { return .verified }
        guard assembledBytes == declaredTotal else {
            return .sizeMismatch(expected: declaredTotal, actual: assembledBytes)
        }
        return .verified
    }
}

/// Three retries, then the download lands paused with its partial intact —
/// one tap from resuming, and no error message (ADR 0005 decision 5).
public enum RetryBackoff {
    public static let delays: [Double] = [2, 8, 30]

    /// Seconds to wait before attempt `attempt` (0-based), or nil when the
    /// retries are exhausted.
    public static func delay(forAttempt attempt: Int) -> Double? {
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}

/// Progress as a fraction, guarded. An unknown total yields 0 rather than the
/// NaN that `received / -1`-style arithmetic produces — a NaN rotation angle
/// makes SwiftUI drop the icon entirely.
public enum DownloadProgressMath {
    public static func fraction(received: Int64, total: Int64?) -> Double {
        guard let total, total > 0 else { return 0 }
        let clamped = min(max(received, 0), total)
        return Double(clamped) / Double(total)
    }
}
