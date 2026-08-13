# Download Center + Range Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-view `Downloader` with one app-wide `DownloadCenter` that verifies every byte it installs, survives app exit, and resumes an interrupted download with HTTP `Range` — and give opening-book downloads the spinning KataGo icon the network picker has.

**Architecture:** A `@MainActor @Observable` `DownloadCenter` singleton in `KataGoUICore` vends one observable `Download` per **destination URL**. Transfers run on a single background `URLSession`; a partial lives in a staging directory with a JSON sidecar carrying its ETag and declared total, and only reaches its destination after its assembled size matches the total the server declared. Resume re-requests the **stable catalog URL** with `Range:`/`If-Range:` and accepts **exactly 206**. All decision logic (status → resume/restart/fail, verification, backoff, sweep, button role) is factored into pure `Sendable` value types so the iOS-simulator test target can cover it; the transport itself is proven by a manual device matrix, because background sessions ignore `URLProtocol` stubs.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, SwiftPM package `KataGoUICore`, Swift Testing (`import Testing`), `URLSession` background configuration, `Xcodeproj` Ruby gem for test-target file surgery.

**Spec:** `docs/adr/0005-downloads-run-through-one-center-resumed-by-range.md` (Accepted). Vocabulary: `CONTEXT.md` § Downloads.

## Global Constraints

- **English only** in every committed byte — source, comments, commit messages, docs. Scan the diff before committing.
- **Never modify a SwiftData `@Model` schema.** Nothing in this plan touches one; if you think you need to, stop.
- **Tests must be offline.** No test may download anything, and no test may carry a download fallback branch. The one new runtime kill switch (`--uitest-disable-downloads`) exists so auto-resume can never put traffic into the UI suite.
- **Never run two `xcodebuild` invocations at once** — the DerivedData lock produces spurious `TEST FAILED`. Never delegate a build to a subagent.
- **Piped `xcodebuild` exit codes lie.** Always `grep -E "BUILD (SUCCEEDED|FAILED)"` (or use `set -o pipefail`) and judge by the grep, not `$?`.
- **SwiftPM package tests never run under `xcodebuild`.** They need `swift test`. This plan adds none.
- **New files under `KataGoUICore/Sources/…` need no project surgery** (SwiftPM globs the target directory). **New files in an app or test target folder DO** — the project has no filesystem-synchronized groups (`objectVersion = 60`), so every file needs a `PBXFileReference`, a `PBXGroup` child entry, and a `PBXBuildFile`. Use the `xcodeproj` Ruby gem.
- **Prefer `trash` over `rm`** for anything you delete on disk.
- **Space pushes ~1 day apart.** Every push to `ios-dev` triggers Xcode Cloud and distributes to TestFlight. Commit freely; batch the pushes.
- The five schemes that must build: `KataGo Anytime` (iOS), `KataGo Anytime Mac`, `KataGo Anytime Vision`, `KataGo Anytime TV`, `KataGo Anytime Watch`. All commands run from `ios/KataGo iOS`.
- Package platforms include tvOS, and **tvOS links `KataGoUICore`** even though it has no download UI — every new package file must compile for tvOS. `sessionSendsLaunchEvents` is unavailable on macOS; guard it.

---

## File Structure

**New, in the package (no project surgery):**

| File | Responsibility |
|---|---|
| `KataGoUICore/Sources/KataGoUICore/Services/Downloads/DownloadState.swift` | The state enum and `DownloadButtonRole` — the whole vocabulary of "what is this download doing", nothing else |
| `…/Downloads/HTTPRangeDecisions.swift` | Pure HTTP decisions: `Content-Range` parsing, resume/restart/fail, verification, retry backoff, progress math |
| `…/Downloads/DownloadStaging.swift` | Where a partial lives: staging paths, the `PartialMetadata` sidecar, destination-directory preparation, the pure sweep rule |
| `…/Downloads/Download.swift` | One observable download: its key, destination, state, byte counts |
| `…/Downloads/DownloadCenter.swift` | The registry, the single-transfer queue, the background session, launch restore |
| `…/Downloads/DownloadSessionDelegate.swift` | The `nonisolated` URLSession delegate and the synchronous file absorption that must happen before the temp file evaporates |
| `KataGoUICore/Sources/KataGoUICore/Rendering/DownloadProgressIcon.swift` | The rotating icon, one definition, three call sites |

**New tests (surgery required), in `ios/KataGo iOS/KataGo iOSTests/`:**
`DownloadDecisionTests.swift`, `DownloadStagingTests.swift`, `DownloadButtonRoleTests.swift`.

**Modified:** `Services/Downloader.swift` (guard → shim → deleted), `Model/NeuralNetworkModel.swift`, `Vision/VisionModelDetailState.swift`, `KataGo iOS/Models/ModelPickerView.swift`, `KataGo iOS/Models/OpeningBookPickerView.swift`, `KataGo iOS/App/KataGo_iOSApp.swift`, `KataGo iOS/App/ContentView.swift`, `KataGo Anytime Vision/VisionModelsOrnament.swift`, `KataGo Anytime Vision/KataGoVisionApp.swift`, `KataGo Anytime Mac/{ModelsViewController,ModelsWindowController,OpeningBooksViewController,OpeningBooksWindowController,ModelRowView,OpeningBookRowView,AppDelegate}.swift`, `KataGo iOSTests/VisionModelDetailStateTests.swift`.

**Deliberately not in scope:** a free-space precheck. I floated one earlier; re-reading the spec, ADR 0005 decision 5 removes the error surface a precheck needs to be useful ("Failure is silent but never lossy"), so adding one would either be invisible or contradict the decision. Raise it as its own ADR if the tester feedback ever asks for it.

---

### Task 1: Stop installing error pages as assets

The shipped `Downloader` moves whatever arrived onto the destination without ever reading a status code. A GitHub release redirect that has expired returns **HTTP 618** with a 430-byte XML body and a believable `Content-Disposition`; `URLSession` reports that as success. This is a live corruption path in shipping code and it does not need the rest of this plan to fix. Ship it alone.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloader.swift:62-76`

**Interfaces:**
- Consumes: nothing
- Produces: nothing. Behaviour-only change; the public API is untouched.

- [ ] **Step 1: Read the current delegate method**

Run: `sed -n '60,90p' "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloader.swift"`
Expected: `didFinishDownloadingTo` moving the file with no status check, then `didCompleteWithError`.

- [ ] **Step 2: Add the status guard**

Replace the body of `urlSession(_:downloadTask:didFinishDownloadingTo:)` with:

```swift
    nonisolated public func urlSession(_: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // A response is not a success. `URLSession` delivers 4xx, 5xx — and
        // GitHub release assets' non-standard `618 jwt:expired`, which is
        // neither — through this method exactly like a 200. Moving the body
        // unconditionally installs an error page as the asset, and every
        // `fileExists` check downstream then reads it as downloaded forever,
        // recoverable only by deleting the file by hand.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            Task { @MainActor in
                isDownloading = false
                progress = 0.0
            }
            return
        }

        // Remove if exists
        try? FileManager.default.removeItem(at: destinationURL)
        // The downloaded file will be removed automatically.
        try? FileManager.default.moveItem(at: location, to: destinationURL)

        Task { @MainActor in
            downloadedFileURL = destinationURL
            isDownloading = false
            // Hash the file and fire precompile now that it's at its final URL.
            await self.onDownloadComplete?(destinationURL)
        }
    }
```

- [ ] **Step 3: Build the two schemes that compile this file's consumers**

Run (one at a time — never concurrently):
```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```
Expected: `** BUILD SUCCEEDED **` from each.

- [ ] **Step 4: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloader.swift"
git commit -m "fix(downloads): refuse to install a non-200 body as a downloaded asset"
```

---

### Task 2: Correct the two drifted catalog sizes

`FD3 Network` and `Strong Large Board Net M2` both carry a copy-pasted `271_357_345`. Neither matches the live asset, so the picker shows both wrong today — and any future verification against catalog size would fail every download of either. Independent of everything else.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NeuralNetworkModel.swift:137` and `:200`

**Interfaces:**
- Consumes: nothing
- Produces: nothing. `fileSize` stays display-and-tvOS-eligibility only.

- [ ] **Step 1: Re-verify both sizes against the live server**

This is a one-time fact check by hand, not a test — no test may reach the network.

```bash
for u in \
  https://media.katagotraining.org/uploaded/networks/models_extra/fd3.bin.gz \
  https://media.katagotraining.org/uploaded/networks/models_extra/M2-s40190750-d164645490.bin.gz ; do
  echo "$u"; curl -sIL "$u" | grep -i '^content-length'
done
```
Expected: `271365609` for fd3, `271378684` for M2. If either differs, use what the server says and note the new value in the commit message.

- [ ] **Step 2: Apply both edits**

`NeuralNetworkModel.swift:137` — inside the `"FD3 Network"` entry:
```swift
            fileSize: 271_365_609
```
`NeuralNetworkModel.swift:200` — inside the `"Strong Large Board Net M2"` entry:
```swift
            fileSize: 271_378_684
```

- [ ] **Step 3: Confirm the duplicate is gone**

Run: `grep -n "271_357_345" "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NeuralNetworkModel.swift"`
Expected: no output.

- [ ] **Step 4: Build iOS**

Run:
```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/NeuralNetworkModel.swift"
git commit -m "fix(models): correct the FD3 and M2 catalog sizes

Both carried a copy-pasted 271_357_345 against live content-lengths of
271,365,609 and 271,378,684, so the picker has been showing the wrong size
for both since they were added."
```

---

### Task 3: The pure HTTP decisions

Every judgement the transport makes about a response — resume or restart or refuse, verified or short, retry or give up, what fraction to rotate the icon by — lives here as free functions on `Sendable` value types with no I/O. This is the only part of the transport a unit test can reach, so it carries the weight.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads/DownloadState.swift`
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads/HTTPRangeDecisions.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/DownloadDecisionTests.swift`
- Create: `ios/KataGo iOS/scripts/add_download_test_files.rb`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public enum DownloadState: String, Equatable, Sendable, CaseIterable { case idle, waiting, transferring, paused, interrupted, succeeded }`
  - `public enum DownloadButtonRole: String, Equatable, Sendable, CaseIterable { case play, download, pause, resume }` with `var systemImageName: String`, `var actionTitle: String`, `static func role(isOnDisk: Bool, state: DownloadState, hasPartial: Bool) -> DownloadButtonRole`
  - `public struct ContentRangeHeader: Equatable, Sendable { let first: Int64; let last: Int64; let total: Int64?; init?(_ raw: String) }`
  - `public enum ResumeDecision: Equatable, Sendable { case append(expectedTotal: Int64?); case restart(expectedTotal: Int64?); case fail(reason: String); static func decide(sentRange:requestedOffset:statusCode:contentRange:contentLength:) -> ResumeDecision }`
  - `public enum TransferVerification: Equatable, Sendable { case verified; case sizeMismatch(expected: Int64, actual: Int64); static func check(assembledBytes: Int64, declaredTotal: Int64?) -> TransferVerification }`
  - `public enum RetryBackoff { static let delays: [Double]; static func delay(forAttempt: Int) -> Double? }`
  - `public enum DownloadProgressMath { static func fraction(received: Int64, total: Int64?) -> Double }`

- [ ] **Step 1: Write `DownloadState.swift`**

```swift
//
//  DownloadState.swift
//  KataGo Anytime
//
//  The vocabulary of a download's life (CONTEXT.md § Downloads). Deliberately
//  free of transport: nothing here knows what HTTP is.
//

import Foundation

/// Where one download stands. `succeeded` is the only state the rest of the
/// app is entitled to infer anything from — it means a complete, *verified*
/// asset is at its destination.
public enum DownloadState: String, Equatable, Sendable, CaseIterable {
    /// Never asked for, or asked for and long since finished and forgotten.
    case idle
    /// Asked for, not yet started, because another download is transferring.
    /// Distinct from `paused`: nobody stopped it.
    case waiting
    /// Bytes are moving right now.
    case transferring
    /// Stopped by the user. Keeps its partial and never resumes itself.
    case paused
    /// Stopped by anything other than the user. Keeps its partial and is
    /// eligible to resume itself at launch and when connectivity returns.
    case interrupted
    /// Verified and moved to its destination.
    case succeeded
}

/// What the one download button in a detail view should do right now.
///
/// One button, four roles — never a button that appears and disappears. The
/// iOS UI suite taps `ModelDetailView.downloadPlayButton` in nine files and
/// would break the moment that identifier stopped being always present.
public enum DownloadButtonRole: String, Equatable, Sendable, CaseIterable {
    /// The asset is on disk; the button activates it.
    case play
    /// Nothing on disk, nothing in flight, no partial.
    case download
    /// A transfer is running or queued behind one.
    case pause
    /// Stopped with a partial kept — one tap away from continuing.
    case resume

    public var systemImageName: String {
        switch self {
        case .play: return "play.fill"
        case .download, .resume: return "arrow.down"
        case .pause: return "stop.circle"
        }
    }

    /// The button's spoken label. Icon-only labels use this as their
    /// accessibility text, so `download` and `resume` must read differently
    /// even though they share a glyph.
    public var actionTitle: String {
        switch self {
        case .play: return "Play"
        case .download: return "Download"
        case .pause: return "Stop Download"
        case .resume: return "Resume Download"
        }
    }

    /// A download stopped before it wrote anything has nothing to resume, so
    /// it reads as a fresh `download` rather than a `resume` that would
    /// promise progress it does not have.
    public static func role(isOnDisk: Bool,
                            state: DownloadState,
                            hasPartial: Bool) -> DownloadButtonRole {
        if isOnDisk { return .play }
        switch state {
        case .transferring, .waiting:
            return .pause
        case .paused, .interrupted:
            return hasPartial ? .resume : .download
        case .idle, .succeeded:
            return .download
        }
    }
}
```

- [ ] **Step 2: Write `HTTPRangeDecisions.swift`**

```swift
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

    public init(first: Int64, last: Int64, total: Int64?) {
        self.first = first
        self.last = last
        self.total = total
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
```

- [ ] **Step 3: Write the failing test file**

Create `ios/KataGo iOS/KataGo iOSTests/DownloadDecisionTests.swift`:

```swift
//
//  DownloadDecisionTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure download decisions: Content-Range parsing, the
//  resume/restart/fail rule (including GitHub's non-standard 618), the
//  verification gate, the retry schedule, the NaN-proof progress fraction,
//  and the four-role download button.
//

import Foundation
import Testing
@testable import KataGoUICore

struct ContentRangeHeaderTests {
    @Test func parsesACompleteRange() {
        let parsed = ContentRangeHeader("bytes 200-1023/1024")
        #expect(parsed?.first == 200)
        #expect(parsed?.last == 1023)
        #expect(parsed?.total == 1024)
    }

    @Test func parsesAnUnknownTotal() {
        let parsed = ContentRangeHeader("bytes 0-99/*")
        #expect(parsed?.first == 0)
        #expect(parsed?.total == nil)
    }

    @Test func rejectsJunk() {
        #expect(ContentRangeHeader("items 0-9/10") == nil)
        #expect(ContentRangeHeader("bytes 10-9/100") == nil)
        #expect(ContentRangeHeader("bytes abc/100") == nil)
        #expect(ContentRangeHeader("") == nil)
    }
}

struct ResumeDecisionTests {
    @Test func rangedRequestAcceptsExactly206() {
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 200,
                                             statusCode: 206,
                                             contentRange: "bytes 200-1023/1024",
                                             contentLength: 824)
        #expect(decision == .append(expectedTotal: 1024))
    }

    @Test func theFirstChunkIsStillARangedRequest() {
        // Every request the transport makes carries a Range, including the
        // first, so offset 0 must accept a 206 rather than demanding a 200.
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 0,
                                             statusCode: 206,
                                             contentRange: "bytes 0-33554431/240027267",
                                             contentLength: 33_554_432)
        #expect(decision == .append(expectedTotal: 240_027_267))
    }

    @Test func rangedRequestTreats200AsTheWholeAsset() {
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 200,
                                             statusCode: 200,
                                             contentRange: nil,
                                             contentLength: 4096)
        #expect(decision == .restart(expectedTotal: 4096))
    }

    @Test func rangedRequestRejectsAMisalignedRange() {
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 200,
                                             statusCode: 206,
                                             contentRange: "bytes 0-1023/1024",
                                             contentLength: 1024)
        guard case .fail = decision else {
            Issue.record("a 206 starting somewhere else must not be appended")
            return
        }
    }

    @Test func rangedRequestRejects206WithoutAContentRange() {
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 200,
                                             statusCode: 206,
                                             contentRange: nil,
                                             contentLength: 824)
        guard case .fail = decision else {
            Issue.record("a 206 with no Content-Range has no verifiable offset")
            return
        }
    }

    // The one that matters: GitHub release assets answer an expired redirect
    // with 618, which is neither 4xx nor 5xx, and whose 430-byte XML body
    // carries a believable Content-Disposition.
    @Test func expiredJwt618IsNeverABody() {
        let ranged = ResumeDecision.decide(sentRange: true,
                                           requestedOffset: 1_000,
                                           statusCode: 618,
                                           contentRange: nil,
                                           contentLength: 430)
        let fresh = ResumeDecision.decide(sentRange: false,
                                          requestedOffset: 0,
                                          statusCode: 618,
                                          contentRange: nil,
                                          contentLength: 430)
        guard case .fail = ranged, case .fail = fresh else {
            Issue.record("618 must fail on both the fresh and the ranged path")
            return
        }
    }

    @Test func anUnrangedRequestAcceptsOnly200() {
        #expect(ResumeDecision.decide(sentRange: false,
                                      requestedOffset: 0,
                                      statusCode: 200,
                                      contentRange: nil,
                                      contentLength: 99) == .restart(expectedTotal: 99))
        for status in [206, 204, 301, 403, 404, 500, 503] {
            guard case .fail = ResumeDecision.decide(sentRange: false,
                                                     requestedOffset: 0,
                                                     statusCode: status,
                                                     contentRange: nil,
                                                     contentLength: nil) else {
                Issue.record("status \(status) must not be installed as an asset")
                return
            }
        }
    }
}

struct TransferVerificationTests {
    @Test func exactSizePasses() {
        #expect(TransferVerification.check(assembledBytes: 1024, declaredTotal: 1024) == .verified)
    }

    @Test func shortBodyFails() {
        #expect(TransferVerification.check(assembledBytes: 430, declaredTotal: 240_027_267)
                == .sizeMismatch(expected: 240_027_267, actual: 430))
    }

    @Test func longBodyFails() {
        #expect(TransferVerification.check(assembledBytes: 2048, declaredTotal: 1024)
                == .sizeMismatch(expected: 1024, actual: 2048))
    }

    @Test func anUndeclaredTotalLeavesNothingToCheck() {
        #expect(TransferVerification.check(assembledBytes: 7, declaredTotal: nil) == .verified)
        #expect(TransferVerification.check(assembledBytes: 7, declaredTotal: 0) == .verified)
    }
}

struct RetryBackoffTests {
    @Test func threeRetriesThenGiveUp() {
        #expect(RetryBackoff.delay(forAttempt: 0) == 2)
        #expect(RetryBackoff.delay(forAttempt: 1) == 8)
        #expect(RetryBackoff.delay(forAttempt: 2) == 30)
        #expect(RetryBackoff.delay(forAttempt: 3) == nil)
        #expect(RetryBackoff.delay(forAttempt: -1) == nil)
    }
}

struct DownloadProgressMathTests {
    @Test func fractionIsTheObviousRatio() {
        #expect(DownloadProgressMath.fraction(received: 512, total: 1024) == 0.5)
        #expect(DownloadProgressMath.fraction(received: 0, total: 1024) == 0)
        #expect(DownloadProgressMath.fraction(received: 1024, total: 1024) == 1)
    }

    @Test func unknownTotalIsZeroNotNaN() {
        let unknown = DownloadProgressMath.fraction(received: 900, total: nil)
        #expect(unknown == 0)
        #expect(unknown.isFinite)
        let negative = DownloadProgressMath.fraction(received: 900, total: -1)
        #expect(negative == 0)
        #expect(negative.isFinite)
    }

    @Test func overshootIsClamped() {
        #expect(DownloadProgressMath.fraction(received: 5000, total: 1024) == 1)
        #expect(DownloadProgressMath.fraction(received: -5, total: 1024) == 0)
    }
}

struct DownloadButtonRoleTests {
    @Test func onDiskAlwaysPlays() {
        for state in DownloadState.allCases {
            #expect(DownloadButtonRole.role(isOnDisk: true, state: state, hasPartial: true) == .play)
        }
    }

    @Test func runningAndQueuedBothOfferStop() {
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .transferring, hasPartial: true) == .pause)
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .waiting, hasPartial: false) == .pause)
    }

    @Test func stoppedWithBytesOffersResume() {
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .paused, hasPartial: true) == .resume)
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .interrupted, hasPartial: true) == .resume)
    }

    @Test func stoppedWithNothingOffersAFreshDownload() {
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .paused, hasPartial: false) == .download)
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .idle, hasPartial: false) == .download)
    }

    @Test func downloadAndResumeShareAGlyphButNotAVoice() {
        #expect(DownloadButtonRole.download.systemImageName == DownloadButtonRole.resume.systemImageName)
        #expect(DownloadButtonRole.download.actionTitle != DownloadButtonRole.resume.actionTitle)
    }
}
```

- [ ] **Step 4: Write the project-surgery script**

Create `ios/KataGo iOS/scripts/add_download_test_files.rb`:

```ruby
#!/usr/bin/env ruby
# Adds the download-feature test files to the "KataGo AnytimeTests" target.
# The project has no filesystem-synchronized groups (objectVersion = 60), so a
# new .swift file in an app or test folder is invisible until it has a
# PBXFileReference, a PBXGroup child entry and a PBXBuildFile. Idempotent.
#
#   gem install xcodeproj      # once
#   ruby scripts/add_download_test_files.rb
require 'xcodeproj'

PROJECT = File.expand_path('../KataGo Anytime.xcodeproj', __dir__)
TARGET  = 'KataGo AnytimeTests'
GROUP   = 'KataGo iOSTests'
FILES   = %w[
  DownloadDecisionTests.swift
  DownloadStagingTests.swift
]

project = Xcodeproj::Project.open(PROJECT)
target  = project.targets.find { |t| t.name == TARGET }
raise "target #{TARGET.inspect} not found" unless target

group = project.main_group[GROUP] ||
        project.groups.find { |g| g.path == GROUP } ||
        project.main_group.recursive_children.find { |g| g.respond_to?(:path) && g.path == GROUP }
raise "group #{GROUP.inspect} not found" unless group

FILES.each do |name|
  if group.files.any? { |f| f.display_name == name }
    puts "skip  #{name} (already referenced)"
    next
  end
  ref = group.new_reference(name)
  target.add_file_references([ref])
  puts "add   #{name}"
end

project.save
puts "saved #{PROJECT}"
```

The `FILES` array lists both test files the feature will add, but `DownloadStagingTests.swift` does not exist until Task 4. **For this task, list only the first entry:**

```ruby
FILES   = %w[
  DownloadDecisionTests.swift
]
```

Task 4 adds the second entry and re-runs the script; it is idempotent, so the already-added file is skipped. `DownloadButtonRoleTests` needs no entry of its own — it is a second `struct` inside `DownloadDecisionTests.swift`.

- [ ] **Step 5: Run the surgery and verify the file is a member**

```bash
cd "ios/KataGo iOS"
gem list -i xcodeproj > /dev/null 2>&1 || gem install xcodeproj
ruby scripts/add_download_test_files.rb
grep -c "DownloadDecisionTests.swift" "KataGo Anytime.xcodeproj/project.pbxproj"
```
Expected: the script prints `add   DownloadDecisionTests.swift` and `saved …`; the grep prints `3` (file reference, group child, build file).

- [ ] **Step 6: Run the new tests**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/ResumeDecisionTests" \
  -only-testing:"KataGo AnytimeTests/ContentRangeHeaderTests" \
  -only-testing:"KataGo AnytimeTests/TransferVerificationTests" \
  -only-testing:"KataGo AnytimeTests/RetryBackoffTests" \
  -only-testing:"KataGo AnytimeTests/DownloadProgressMathTests" \
  -only-testing:"KataGo AnytimeTests/DownloadButtonRoleTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|BUILD FAILED"
```
Expected: `** TEST SUCCEEDED **`

If you see stale default-argument behaviour in a `static let`/default-arg you just edited, trash `SwiftExplicitPrecompiledModules` in DerivedData and re-run — the explicit-modules cache keeps the old values in the test target.

- [ ] **Step 7: Build the other four schemes** (these files compile into tvOS via `KataGoUICore`)

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```
Expected: four `** BUILD SUCCEEDED **`, one at a time.

- [ ] **Step 8: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads" \
        "ios/KataGo iOS/KataGo iOSTests/DownloadDecisionTests.swift" \
        "ios/KataGo iOS/scripts/add_download_test_files.rb" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(downloads): pure resume, verification and button-role decisions"
```

---

### Task 4: Staging — where a partial lives

A partial never touches a destination, because eleven bare `fileExists` predicates decide "downloaded" and not one of them checks a size, so anything that lands on a destination path reads as downloaded forever. Partials live in their own directory under Application Support with a JSON sidecar carrying the ETag and the server's declared total, excluded from backup, and swept at startup.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads/DownloadStaging.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/DownloadStagingTests.swift`
- Modify: `ios/KataGo iOS/scripts/add_download_test_files.rb` (add the second entry)

**Interfaces:**
- Consumes: nothing from Task 3
- Produces:
  - `public struct PartialMetadata: Codable, Equatable, Sendable` with `destinationPath: String`, `sourceURLString: String`, `etag: String?`, `declaredTotal: Int64?`, `pausedByUser: Bool`
  - `public struct StagedPartial: Equatable, Sendable` with `key, modified, hasMetadata, destinationExists`
  - `public enum StagingSweep { static let maxAge: TimeInterval; static func keysToDiscard(_:now:maxAge:) -> [String] }`
  - `public enum DownloadStaging` with `directory()`, `ensureDirectory() throws -> URL`, `key(for: URL) -> String`, `partialURL(forKey:)`, `metadataURL(forKey:)`, `readMetadata(forKey:)`, `writeMetadata(_:forKey:)`, `partialSize(forKey:) -> Int64`, `discardPartial(forKey:)`, `appendChunk(from:toKey:) -> Int64`, `replacePartial(withTemp:forKey:) -> Int64`, `install(key:destination:) -> Bool`, `prepareDestinationDirectory(for:)`, `scan() -> [StagedPartial]`, and `#if DEBUG _directoryOverride`

- [ ] **Step 1: Write the failing test file**

Create `ios/KataGo iOS/KataGo iOSTests/DownloadStagingTests.swift`:

```swift
//
//  DownloadStagingTests.swift
//  KataGo AnytimeTests
//
//  Pins staging: keys are stable and destination-specific, the sidecar
//  round-trips, appending grows a partial, installing only ever moves a
//  verified file, and the sweep discards exactly the orphaned, superseded and
//  stale partials — nothing else.
//

import Foundation
import Testing
@testable import KataGoUICore

struct StagingSweepTests {
    private func partial(_ key: String,
                         ageDays: Double = 0,
                         hasMetadata: Bool = true,
                         destinationExists: Bool = false,
                         now: Date) -> StagedPartial {
        StagedPartial(key: key,
                      modified: now.addingTimeInterval(-ageDays * 24 * 60 * 60),
                      hasMetadata: hasMetadata,
                      destinationExists: destinationExists)
    }

    @Test func aFreshTrackedPartialSurvives() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keep = partial("a", ageDays: 2, now: now)
        #expect(StagingSweep.keysToDiscard([keep], now: now).isEmpty)
    }

    @Test func aPartialWithNoSidecarIsOrphaned() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let orphan = partial("a", hasMetadata: false, now: now)
        #expect(StagingSweep.keysToDiscard([orphan], now: now) == ["a"])
    }

    @Test func aPartialWhoseDestinationAlreadyExistsIsSuperseded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let done = partial("a", destinationExists: true, now: now)
        #expect(StagingSweep.keysToDiscard([done], now: now) == ["a"])
    }

    @Test func sevenDaysIsTheCutoff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justUnder = partial("young", ageDays: 6.9, now: now)
        let justOver = partial("old", ageDays: 7.1, now: now)
        #expect(StagingSweep.keysToDiscard([justUnder, justOver], now: now) == ["old"])
    }

    @Test func nothingInMeansNothingOut() {
        #expect(StagingSweep.keysToDiscard([], now: Date()).isEmpty)
    }
}

@MainActor
struct DownloadStagingTests {
    /// Every test runs against its own throwaway directory, so none of them
    /// can see, corrupt or depend on real app data.
    private func withTemporaryStaging(_ body: (URL) throws -> Void) rethrows {
        let root = URL.temporaryDirectory
            .appendingPathComponent("staging-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DownloadStaging._directoryOverride = root
        defer {
            DownloadStaging._directoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    @Test func keysAreStableAndDestinationSpecific() {
        let a = URL(fileURLWithPath: "/tmp/models/fd3.bin.gz")
        let b = URL(fileURLWithPath: "/tmp/models/m2.bin.gz")
        #expect(DownloadStaging.key(for: a) == DownloadStaging.key(for: a))
        #expect(DownloadStaging.key(for: a) != DownloadStaging.key(for: b))
        #expect(DownloadStaging.key(for: a).count == 32)
    }

    @Test func keysIgnorePathNoise() {
        let plain = URL(fileURLWithPath: "/tmp/models/fd3.bin.gz")
        let noisy = URL(fileURLWithPath: "/tmp/models/./fd3.bin.gz")
        #expect(DownloadStaging.key(for: plain) == DownloadStaging.key(for: noisy))
    }

    @Test func sidecarRoundTrips() throws {
        try withTemporaryStaging { _ in
            let key = "abc123"
            let written = PartialMetadata(destinationPath: "/tmp/books/9x9.kbook.gz",
                                          sourceURLString: "https://example.invalid/9x9.kbook.gz",
                                          etag: "\"deadbeef\"",
                                          declaredTotal: 240_027_267,
                                          pausedByUser: true)
            DownloadStaging.writeMetadata(written, forKey: key)
            #expect(DownloadStaging.readMetadata(forKey: key) == written)
        }
    }

    @Test func missingSidecarReadsAsNil() throws {
        try withTemporaryStaging { _ in
            #expect(DownloadStaging.readMetadata(forKey: "never-written") == nil)
        }
    }

    @Test func appendingGrowsThePartial() throws {
        try withTemporaryStaging { root in
            let key = "grow"
            let first = root.appendingPathComponent("chunk1")
            let second = root.appendingPathComponent("chunk2")
            try Data(repeating: 0x41, count: 10).write(to: first)
            try Data(repeating: 0x42, count: 5).write(to: second)

            #expect(DownloadStaging.partialSize(forKey: key) == 0)
            #expect(DownloadStaging.replacePartial(withTemp: first, forKey: key) == 10)
            #expect(DownloadStaging.appendChunk(from: second, toKey: key) == 15)

            let bytes = try Data(contentsOf: DownloadStaging.partialURL(forKey: key))
            #expect(bytes == Data(repeating: 0x41, count: 10) + Data(repeating: 0x42, count: 5))
        }
    }

    @Test func installMovesThePartialAndClearsTheSidecar() throws {
        try withTemporaryStaging { root in
            let key = "install"
            let temp = root.appendingPathComponent("body")
            try Data(repeating: 0x2A, count: 32).write(to: temp)
            _ = DownloadStaging.replacePartial(withTemp: temp, forKey: key)
            DownloadStaging.writeMetadata(PartialMetadata(destinationPath: "x",
                                                          sourceURLString: "y",
                                                          etag: nil,
                                                          declaredTotal: 32,
                                                          pausedByUser: false),
                                          forKey: key)

            let destination = root
                .appendingPathComponent("dest", isDirectory: true)
                .appendingPathComponent("asset.bin.gz")
            #expect(DownloadStaging.install(key: key, destination: destination))

            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(try Data(contentsOf: destination).count == 32)
            #expect(!FileManager.default.fileExists(atPath: DownloadStaging.partialURL(forKey: key).path))
            #expect(DownloadStaging.readMetadata(forKey: key) == nil)
        }
    }

    @Test func discardRemovesBothFiles() throws {
        try withTemporaryStaging { root in
            let key = "discard"
            let temp = root.appendingPathComponent("body")
            try Data(repeating: 1, count: 4).write(to: temp)
            _ = DownloadStaging.replacePartial(withTemp: temp, forKey: key)
            DownloadStaging.writeMetadata(PartialMetadata(destinationPath: "x",
                                                          sourceURLString: "y",
                                                          etag: nil,
                                                          declaredTotal: nil,
                                                          pausedByUser: false),
                                          forKey: key)

            DownloadStaging.discardPartial(forKey: key)

            #expect(DownloadStaging.partialSize(forKey: key) == 0)
            #expect(DownloadStaging.readMetadata(forKey: key) == nil)
        }
    }

    @Test func scanSeesWhatWasStaged() throws {
        try withTemporaryStaging { root in
            let temp = root.appendingPathComponent("body")
            try Data(repeating: 9, count: 3).write(to: temp)
            _ = DownloadStaging.replacePartial(withTemp: temp, forKey: "scanned")

            let found = DownloadStaging.scan()
            #expect(found.map(\.key) == ["scanned"])
            #expect(found.first?.hasMetadata == false)
        }
    }
}
```

- [ ] **Step 2: Add the file to the test target and confirm the tests fail to compile**

```bash
cd "ios/KataGo iOS"
# add DownloadStagingTests.swift to the FILES array in scripts/add_download_test_files.rb first
ruby scripts/add_download_test_files.rb
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/StagingSweepTests" 2>&1 | grep -E "BUILD FAILED|cannot find"
```
Expected: `BUILD FAILED` with `cannot find 'DownloadStaging' in scope`.

- [ ] **Step 3: Write `DownloadStaging.swift`**

```swift
//
//  DownloadStaging.swift
//  KataGo Anytime
//
//  Where a partial lives while it is incomplete, and the one place that moves
//  a finished file to its destination.
//
//  Partials are kept OUT of every destination directory on purpose: eleven
//  `fileExists` predicates across the app decide "this asset is downloaded"
//  and not one of them checks a size, so a half-written file on a destination
//  path would read as downloaded forever. Caches is no good either — the
//  system evicts it under storage pressure, which would silently reintroduce
//  the restart-from-zero bug this feature exists to remove.
//

import Foundation
import CryptoKit

/// The sidecar written beside a partial: everything needed to resume it after
/// the app has been quit, and nothing that could be recomputed.
public struct PartialMetadata: Codable, Equatable, Sendable {
    /// Where the bytes are headed. Also how a relaunch rebuilds the download
    /// without the UI having been on screen.
    public var destinationPath: String
    /// The stable catalog URL, never a resolved redirect — GitHub's expires in
    /// about thirty minutes.
    public var sourceURLString: String
    /// Sent back as `If-Range` so a changed asset restarts instead of
    /// splicing new bytes onto old ones.
    public var etag: String?
    /// The total the server declared. The authority for both progress and
    /// verification; the catalog's `fileSize` is not.
    public var declaredTotal: Int64?
    /// True when the user stopped it. A paused download never resumes itself.
    public var pausedByUser: Bool

    public init(destinationPath: String,
                sourceURLString: String,
                etag: String?,
                declaredTotal: Int64?,
                pausedByUser: Bool) {
        self.destinationPath = destinationPath
        self.sourceURLString = sourceURLString
        self.etag = etag
        self.declaredTotal = declaredTotal
        self.pausedByUser = pausedByUser
    }
}

/// One partial as found on disk by a sweep.
public struct StagedPartial: Equatable, Sendable {
    public let key: String
    public let modified: Date
    public let hasMetadata: Bool
    public let destinationExists: Bool

    public init(key: String, modified: Date, hasMetadata: Bool, destinationExists: Bool) {
        self.key = key
        self.modified = modified
        self.hasMetadata = hasMetadata
        self.destinationExists = destinationExists
    }
}

/// The garbage-collection rule, kept pure so it can be tested without a disk.
public enum StagingSweep {
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Discard a partial when it is orphaned (no sidecar, so it can never be
    /// resumed), superseded (its destination already holds a complete file),
    /// or simply stale. Nothing garbage-collected partials before, because
    /// none existed; this ships with the feature rather than after it.
    public static func keysToDiscard(_ partials: [StagedPartial],
                                     now: Date,
                                     maxAge: TimeInterval = maxAge) -> [String] {
        partials.filter { partial in
            !partial.hasMetadata
                || partial.destinationExists
                || now.timeIntervalSince(partial.modified) > maxAge
        }.map(\.key)
    }
}

public enum DownloadStaging {
    #if DEBUG
    /// Test-only override so unit tests never touch real app data. Never set
    /// in production (mirrors `OpeningBook._booksDirectoryOverride`).
    nonisolated(unsafe) public static var _directoryOverride: URL?
    #endif

    private static let partialExtension = "partial"
    private static let metadataExtension = "partialmeta"

    /// `Application Support/<bundleID>/Downloads/`.
    public static func directory() -> URL {
        #if DEBUG
        if let override = _directoryOverride { return override }
        #endif
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "KataGoAnytime"
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory() throws -> URL {
        let dir = directory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }

    /// A download is identified by **where it is going**, not by file name —
    /// that is what makes a second concurrent transfer of the same asset
    /// unrepresentable. The key is a digest so it is a legal file name and
    /// carries no path separators.
    public static func key(for destinationURL: URL) -> String {
        let canonical = destinationURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    public static func partialURL(forKey key: String) -> URL {
        directory().appendingPathComponent(key).appendingPathExtension(partialExtension)
    }

    public static func metadataURL(forKey key: String) -> URL {
        directory().appendingPathComponent(key).appendingPathExtension(metadataExtension)
    }

    public static func readMetadata(forKey key: String) -> PartialMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(forKey: key)) else { return nil }
        return try? JSONDecoder().decode(PartialMetadata.self, from: data)
    }

    public static func writeMetadata(_ metadata: PartialMetadata, forKey key: String) {
        try? ensureDirectory()
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL(forKey: key), options: .atomic)
    }

    /// Bytes already on disk for this key. 0 when there is no partial — which
    /// is also the offset the next request should ask for.
    public static func partialSize(forKey key: String) -> Int64 {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: partialURL(forKey: key).path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Replaces the partial wholesale. Used for the first chunk and whenever
    /// the server answered a ranged request with the entire asset.
    /// - Returns: the partial's new size in bytes.
    @discardableResult
    public static func replacePartial(withTemp temp: URL, forKey key: String) -> Int64 {
        try? ensureDirectory()
        let destination = partialURL(forKey: key)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: temp, to: destination)
        return partialSize(forKey: key)
    }

    /// Appends one ranged chunk. Streams rather than loading the chunk into
    /// memory, so a 32 MiB chunk of a 240 MB book costs a 1 MiB buffer.
    /// - Returns: the partial's new size in bytes.
    @discardableResult
    public static func appendChunk(from temp: URL, toKey key: String) -> Int64 {
        try? ensureDirectory()
        let destination = partialURL(forKey: key)
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            return replacePartial(withTemp: temp, forKey: key)
        }
        guard let sink = try? FileHandle(forWritingTo: destination),
              let source = try? FileHandle(forReadingFrom: temp) else {
            return partialSize(forKey: key)
        }
        defer {
            try? sink.close()
            try? source.close()
        }
        _ = try? sink.seekToEnd()
        while let chunk = try? source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try? sink.write(contentsOf: chunk)
        }
        return partialSize(forKey: key)
    }

    /// Moves a verified partial to its destination and clears the sidecar.
    /// The caller has already checked the size; this never verifies, so that
    /// there is exactly one gate and it is impossible to bypass by calling
    /// the wrong function.
    public static func install(key: String, destination: URL) -> Bool {
        prepareDestinationDirectory(for: destination)
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        do {
            try fm.moveItem(at: partialURL(forKey: key), to: destination)
        } catch {
            return false
        }
        try? fm.removeItem(at: metadataURL(forKey: key))
        return true
    }

    public static func discardPartial(forKey key: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: partialURL(forKey: key))
        try? fm.removeItem(at: metadataURL(forKey: key))
    }

    /// Creates the destination's directory. The center must do this itself:
    /// both book download paths used to call `OpeningBook.ensureBooksDirectory()`
    /// from the view immediately before downloading, and after a relaunch there
    /// is no view left to do it — the final move would fail silently.
    public static func prepareDestinationDirectory(for destination: URL) {
        let dir = destination.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Books are large and re-downloadable, so their directory stays out of
        // iCloud backup exactly as `OpeningBook.ensureBooksDirectory()` marks
        // it. Documents' root must NOT be excluded, so this is targeted rather
        // than applied to whatever directory happens to be created.
        if dir.standardizedFileURL == OpeningBook.booksDirectory().standardizedFileURL {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try? mutable.setResourceValues(values)
        }
    }

    /// Every partial currently on disk, for the startup sweep.
    public static func scan() -> [StagedPartial] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory(),
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        return entries.compactMap { url -> StagedPartial? in
            guard url.pathExtension == partialExtension else { return nil }
            let key = url.deletingPathExtension().lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let metadata = readMetadata(forKey: key)
            let destinationExists = metadata.map {
                fm.fileExists(atPath: $0.destinationPath)
            } ?? false
            return StagedPartial(key: key,
                                 modified: modified,
                                 hasMetadata: metadata != nil,
                                 destinationExists: destinationExists)
        }
    }
}
```

- [ ] **Step 4: Run the staging tests**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/StagingSweepTests" \
  -only-testing:"KataGo AnytimeTests/DownloadStagingTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|BUILD FAILED"
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Build all five schemes, one at a time**

Use the five commands from the Global Constraints. Expected: five `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads/DownloadStaging.swift" \
        "ios/KataGo iOS/KataGo iOSTests/DownloadStagingTests.swift" \
        "ios/KataGo iOS/scripts/add_download_test_files.rb" \
        "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"
git commit -m "feat(downloads): staged partials with an ETag sidecar and a sweep rule"
```

---

### Task 5: The center, the session, and the delegate

The transport. One background `URLSession`, one transfer at a time app-wide, and — a refinement of ADR 0005 decision 3 that the ADR text does not spell out — **the asset is fetched in fixed 32 MiB ranged chunks rather than one open-ended request.**

That refinement is load-bearing, so here is why. `URLSessionDownloadTask` hands you a temp file only when a transfer *finishes*; a dropped connection delivers `didCompleteWithError` and the bytes of that attempt are gone. With one open-ended request, a drop at 95% of a 240 MB book loses 228 MB — precisely the case resumability exists for. The alternative Apple offers, `cancel(byProducingResumeData:)`, is the one the ADR rejected because the resume data pins a redirect that expires in about thirty minutes. Chunking gives lossless resume with neither problem: each chunk lands whole and is appended, so a drop costs at most 32 MiB, a pause costs at most 32 MiB, and every request re-resolves the redirect from the stable catalog URL so expiry can never bite. The cost is one extra request round-trip per 32 MiB — eight for the largest book, well under a tenth of its transfer time.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads/Download.swift`
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads/DownloadCenter.swift`
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads/DownloadSessionDelegate.swift`

**Interfaces:**
- Consumes: everything from Tasks 3 and 4 — `DownloadState`, `ResumeDecision.decide(sentRange:requestedOffset:statusCode:contentRange:contentLength:)`, `TransferVerification.check(assembledBytes:declaredTotal:)`, `RetryBackoff.delay(forAttempt:)`, `DownloadProgressMath.fraction(received:total:)`, `DownloadStaging.*`, `PartialMetadata`, `StagingSweep.keysToDiscard(_:now:maxAge:)`
- Produces:
  - `@MainActor @Observable public final class Download: Identifiable` — `key: String`, `destinationURL: URL`, `sourceURL: URL?`, `state: DownloadState`, `receivedBytes: Int64`, `totalBytes: Int64?`, `progress: Double`, `isBusy: Bool`, `hasPartial: Bool`
  - `@MainActor @Observable public final class DownloadCenter` — `static let shared`, `static let disableLaunchArgument`, `static let sessionIdentifier`, `lastFinishedDestination: URL?`, `finishedGeneration: Int`, `download(for: URL) -> Download`, `start(_:from:)`, `pause(_:)`, `restoreOnLaunch()`, `sweepStaging()`, `awaitBackgroundURLSessionEvents() async`

**No unit tests in this task, deliberately.** A background `URLSession` ignores `URLProtocol` subclasses, so a stubbed transport is not available; every decision this file makes is already pinned by Tasks 3 and 4, and what remains — session wiring, queueing, relaunch reattachment — is proven by the device matrix in Task 12. Do not invent a test that reaches the network to fill the gap.

- [ ] **Step 1: Write `Download.swift`**

```swift
//
//  Download.swift
//  KataGo Anytime
//
//  One catalog asset being brought onto the device. Vended by DownloadCenter,
//  never constructed by a view — the center keys them by destination URL, and
//  that is what makes a second concurrent transfer of the same asset
//  unrepresentable rather than merely discouraged.
//

import Foundation

@MainActor
@Observable
public final class Download: Identifiable {
    /// Digest of the destination path. Also the staging file name and the
    /// task description that survives a background relaunch.
    public let key: String

    /// Where the verified bytes will land.
    public let destinationURL: URL

    /// The stable catalog URL. Never a resolved redirect.
    public internal(set) var sourceURL: URL?

    public internal(set) var state: DownloadState = .idle

    /// Bytes on disk, including the chunk currently in flight.
    public internal(set) var receivedBytes: Int64 = 0

    /// The total the server declared, or nil until the first response.
    public internal(set) var totalBytes: Int64?

    /// Sent back as `If-Range` so a changed asset restarts cleanly.
    @ObservationIgnored internal var etag: String?

    /// Which retry we are on, 0-based. Reset by an explicit start or pause.
    @ObservationIgnored internal var attempt: Int = 0

    /// The pending back-off sleep, cancelled by a pause or a fresh start.
    @ObservationIgnored internal var retryTask: Task<Void, Never>?

    /// The partial's size when the in-flight chunk began, so live progress can
    /// be reported without re-stat'ing the file on every callback.
    @ObservationIgnored internal var chunkStartOffset: Int64 = 0

    public nonisolated var id: String { key }

    /// 0...1, and always finite: an undeclared total yields 0 rather than the
    /// NaN that would make SwiftUI drop the rotating icon entirely.
    public var progress: Double {
        DownloadProgressMath.fraction(received: receivedBytes, total: totalBytes)
    }

    /// Running or queued behind another transfer. Not "stopped but resumable".
    public var isBusy: Bool { state == .transferring || state == .waiting }

    public var hasPartial: Bool { receivedBytes > 0 }

    internal init(key: String, destinationURL: URL) {
        self.key = key
        self.destinationURL = destinationURL
    }
}
```

- [ ] **Step 2: Write `DownloadSessionDelegate.swift`**

```swift
//
//  DownloadSessionDelegate.swift
//  KataGo Anytime
//
//  The URLSession face of DownloadCenter. Kept in its own file because it is
//  the only nonisolated code in the feature and the isolation boundary is the
//  thing most likely to be got wrong by a later edit.
//

import Foundation

/// Absorbs finished chunks and forwards everything else to the center.
///
/// `@unchecked Sendable`: `center` is written exactly once, on the main actor,
/// before the session that owns this delegate can deliver anything, and every
/// use of it hops back to the main actor first. `@MainActor` classes are
/// implicitly `Sendable`, so holding the reference across the boundary is safe.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    weak var center: DownloadCenter?

    /// What absorbing a finished chunk produced. `Sendable` so it can cross
    /// back to the main actor.
    private enum AbsorbOutcome: Sendable {
        case absorbed(key: String, assembled: Int64, total: Int64?, etag: String?)
        case rejected(key: String, reason: String)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription else { return }
        let written = totalBytesWritten
        Task { @MainActor [weak center] in
            center?.chunkProgress(key: key, bytesInChunk: written)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted the moment this method returns, so ALL of
        // the file work happens here, synchronously, on the delegate queue.
        // Hopping to an actor first and moving the file there is the classic
        // way to lose a download to a race that only shows up under load.
        let outcome = Self.absorb(temp: location, task: downloadTask)
        Task { @MainActor [weak center] in
            guard let center, let outcome else { return }
            switch outcome {
            case let .absorbed(key, assembled, total, etag):
                center.absorbed(key: key, assembled: assembled, total: total, etag: etag)
            case let .rejected(key, reason):
                center.rejected(key: key, reason: reason)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        // Success is already handled by didFinishDownloadingTo; only failures
        // and cancellations reach the center from here.
        guard let key = task.taskDescription, let error else { return }
        let isCancellation = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor [weak center] in
            center?.failed(key: key, isCancellation: isCancellation)
        }
    }

    #if !os(macOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak center] in
            center?.backgroundEventsFinished()
        }
    }
    #endif

    // MARK: - Absorption

    /// Decides what a finished chunk was and writes it into staging. Pure I/O
    /// plus one call into `ResumeDecision`; no policy lives here.
    private static func absorb(temp: URL, task: URLSessionDownloadTask) -> AbsorbOutcome? {
        guard let key = task.taskDescription else { return nil }

        let response = task.response as? HTTPURLResponse
        let status = response?.statusCode ?? -1
        let rangeHeader = task.originalRequest?.value(forHTTPHeaderField: "Range")
        let requestedOffset = offset(fromRangeHeader: rangeHeader)

        var declaredLength: Int64?
        if let response, response.expectedContentLength >= 0 {
            declaredLength = response.expectedContentLength
        }

        let decision = ResumeDecision.decide(
            sentRange: rangeHeader != nil,
            requestedOffset: requestedOffset,
            statusCode: status,
            contentRange: response?.value(forHTTPHeaderField: "Content-Range"),
            contentLength: declaredLength)

        let etag = response?.value(forHTTPHeaderField: "ETag")

        switch decision {
        case let .append(total):
            // Offset 0 has nothing to append to; moving the file is both
            // cheaper and the only thing that works on the first chunk.
            let assembled = requestedOffset == 0
                ? DownloadStaging.replacePartial(withTemp: temp, forKey: key)
                : DownloadStaging.appendChunk(from: temp, toKey: key)
            return .absorbed(key: key, assembled: assembled, total: total, etag: etag)

        case let .restart(total):
            // The server ignored our range and sent the whole asset, so
            // whatever we had is superseded rather than extended.
            let assembled = DownloadStaging.replacePartial(withTemp: temp, forKey: key)
            return .absorbed(key: key, assembled: assembled, total: total, etag: etag)

        case let .fail(reason):
            // Nothing is written. The partial survives exactly as it was, so a
            // refused body can never corrupt bytes we already verified.
            return .rejected(key: key, reason: reason)
        }
    }

    /// `bytes=1024-2047` -> 1024. Absent or unparseable -> 0.
    static func offset(fromRangeHeader header: String?) -> Int64 {
        guard let header, header.hasPrefix("bytes=") else { return 0 }
        let spec = header.dropFirst("bytes=".count)
        let first = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first
        return first.flatMap { Int64($0) } ?? 0
    }
}
```

- [ ] **Step 3: Write `DownloadCenter.swift`**

```swift
//
//  DownloadCenter.swift
//  KataGo Anytime
//
//  The one place a catalog asset is fetched. See
//  docs/adr/0005-downloads-run-through-one-center-resumed-by-range.md.
//
//  Keyed by DESTINATION URL, not by file name: that is what makes a duplicate
//  transfer of the same asset unrepresentable, and the background session has
//  to persist that mapping anyway in order to move a file after a relaunch.
//
//  Assets are fetched in fixed-size ranged chunks. A URLSessionDownloadTask
//  surrenders its bytes only when it FINISHES, so one open-ended request would
//  lose everything to a dropped connection — exactly the case resumability
//  exists for — and the resume-data alternative pins a redirect that expires
//  in about thirty minutes. Chunking bounds the loss at one chunk and
//  re-resolves the redirect on every request.
//

import Foundation
import CoreMLCacheKit

@MainActor
@Observable
public final class DownloadCenter {

    public static let shared = DownloadCenter()

    /// Pass in `XCUIApplication.launchArguments` to make the center inert.
    /// Without it, a background session that auto-resumes at launch would
    /// issue unattended network traffic inside a suite whose offline
    /// guarantee is the reason `ModelStagingUITestSupport` exists at all.
    public static let disableLaunchArgument = "--uitest-disable-downloads"

    /// Stable across launches — the system matches a relaunch's background
    /// events to the session by this string.
    public static let sessionIdentifier = "tw.chinchangyang.KataGoAnytime.downloads"

    /// 32 MiB. Big enough that the per-request round trip is noise against the
    /// transfer (eight requests for the largest book, ~1.5 s on a healthy
    /// link), small enough that a drop or a pause never costs more than that.
    static let chunkSize: Int64 = 32 * 1024 * 1024

    /// The destination of the download that most recently succeeded, paired
    /// with a counter so a consumer can react to two finishes of the same
    /// asset. This is how a freshly downloaded opening book gets activated
    /// even when the detail view that started it has been popped.
    public private(set) var lastFinishedDestination: URL?
    public private(set) var finishedGeneration: Int = 0

    @ObservationIgnored private var downloads: [String: Download] = [:]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var activeKey: String?
    @ObservationIgnored private var activeTask: URLSessionDownloadTask?
    @ObservationIgnored private var pausedKeys: Set<String> = []
    @ObservationIgnored private var backgroundEvents: CheckedContinuation<Void, Never>?
    @ObservationIgnored private let sessionDelegate = DownloadSessionDelegate()
    @ObservationIgnored public let downloadsDisabled: Bool

    /// Lazy so that merely constructing a `Download` — in a SwiftUI preview,
    /// say — never spins up a background session.
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Not discretionary: the user asked for this and is watching a
        // progress icon. Discretionary would let the system defer it to a
        // charging-and-on-Wi-Fi window, which reads as a broken button.
        configuration.isDiscretionary = false
        // A background session already waits for connectivity; setting this
        // states the intent and keeps the behaviour if the configuration ever
        // stops being a background one.
        configuration.waitsForConnectivity = true
        #if !os(macOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        sessionDelegate.center = self
        return URLSession(configuration: configuration,
                          delegate: sessionDelegate,
                          delegateQueue: nil)
    }()

    private init() {
        downloadsDisabled = ProcessInfo.processInfo.arguments.contains(Self.disableLaunchArgument)
    }

    // MARK: - Vending

    /// The one `Download` for this destination, created on first ask and
    /// seeded from any partial already on disk.
    public func download(for destinationURL: URL) -> Download {
        let key = DownloadStaging.key(for: destinationURL)
        if let existing = downloads[key] { return existing }

        let download = Download(key: key, destinationURL: destinationURL)
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        if let metadata = DownloadStaging.readMetadata(forKey: key) {
            download.sourceURL = URL(string: metadata.sourceURLString)
            download.etag = metadata.etag
            download.totalBytes = metadata.declaredTotal
            download.state = metadata.pausedByUser ? .paused : .interrupted
        }
        downloads[key] = download
        return download
    }

    // MARK: - Commands

    public func start(_ download: Download, from sourceURL: URL) {
        guard !downloadsDisabled else { return }
        download.retryTask?.cancel()
        download.retryTask = nil
        download.attempt = 0
        download.sourceURL = sourceURL
        pausedKeys.remove(download.key)
        persist(download, pausedByUser: false)
        enqueue(download)
    }

    /// Stop means pause. The partial survives and nothing resumes it until the
    /// user says so — which is why every consumer reads `state` rather than
    /// the old `isDownloading` true->false edge, an edge a pause and a
    /// completion share.
    public func pause(_ download: Download) {
        download.retryTask?.cancel()
        download.retryTask = nil
        download.attempt = 0
        if activeKey == download.key {
            pausedKeys.insert(download.key)
            activeTask?.cancel()
            activeTask = nil
            activeKey = nil
        }
        queue.removeAll { $0 == download.key }
        download.state = .paused
        persist(download, pausedByUser: true)
        advanceQueue()
    }

    // MARK: - Launch

    /// Sweeps staging, reattaches to anything the background daemon kept
    /// running while the app was gone, and resumes what was interrupted.
    /// Paused downloads are left alone by design.
    public func restoreOnLaunch() {
        sweepStaging()
        guard !downloadsDisabled else { return }
        session.getAllTasks { tasks in
            // Only Strings cross the boundary — never the tasks themselves.
            let live = Set(tasks.compactMap { task -> String? in
                task.state == .completed ? nil : task.taskDescription
            })
            Task { @MainActor [weak self] in
                self?.finishRestore(liveKeys: live)
            }
        }
    }

    public func sweepStaging() {
        let doomed = StagingSweep.keysToDiscard(DownloadStaging.scan(), now: Date())
        for key in doomed where key != activeKey {
            DownloadStaging.discardPartial(forKey: key)
        }
    }

    /// Suspends until the background session has delivered every event it
    /// woke the app up for. Driven by `Scene.backgroundTask(.urlSession(_:))`.
    public func awaitBackgroundURLSessionEvents() async {
        await withCheckedContinuation { continuation in
            // Two overlapping wake-ups: let the earlier one go rather than
            // leak a continuation, which traps at runtime.
            backgroundEvents?.resume()
            backgroundEvents = continuation
        }
    }

    // MARK: - Delegate callbacks

    func chunkProgress(key: String, bytesInChunk: Int64) {
        guard activeKey == key, let download = downloads[key] else { return }
        download.receivedBytes = download.chunkStartOffset + bytesInChunk
    }

    func absorbed(key: String, assembled: Int64, total: Int64?, etag: String?) {
        activeKey = nil
        activeTask = nil
        guard let download = downloads[key] else {
            advanceQueue()
            return
        }
        download.receivedBytes = assembled
        if let total { download.totalBytes = total }
        if let etag { download.etag = etag }
        download.attempt = 0
        persist(download, pausedByUser: false)

        // A server that declared no total gave us all it was going to give.
        guard let expected = download.totalBytes, assembled < expected else {
            finish(download, assembledBytes: assembled)
            return
        }
        beginNextChunk(for: download)
    }

    func rejected(key: String, reason: String) {
        if activeKey == key {
            activeKey = nil
            activeTask = nil
        }
        guard let download = downloads[key] else {
            advanceQueue()
            return
        }
        // Nothing was written for a refused body, so the partial is still
        // exactly the bytes we already proved were ours.
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        download.state = .interrupted
        scheduleRetry(download)
        advanceQueue()
    }

    func failed(key: String, isCancellation: Bool) {
        if activeKey == key {
            activeKey = nil
            activeTask = nil
        }
        // A pause cancels its own task; that is not a failure and must not
        // arm a retry that would undo the pause.
        if pausedKeys.remove(key) != nil {
            advanceQueue()
            return
        }
        guard let download = downloads[key] else {
            advanceQueue()
            return
        }
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        download.state = .interrupted
        scheduleRetry(download)
        advanceQueue()
    }

    func backgroundEventsFinished() {
        backgroundEvents?.resume()
        backgroundEvents = nil
    }

    // MARK: - Internals

    private func enqueue(_ download: Download) {
        guard activeKey != download.key, !queue.contains(download.key) else { return }
        guard activeKey == nil else {
            // Waiting, not paused: nobody stopped it. Parallel transfers were
            // measured to buy nothing, so a queue is strictly better — full
            // throughput to one file and an honest ETA.
            download.state = .waiting
            queue.append(download.key)
            return
        }
        beginNextChunk(for: download)
    }

    private func advanceQueue() {
        guard activeKey == nil else { return }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let download = downloads[next], download.state == .waiting {
                beginNextChunk(for: download)
                return
            }
        }
    }

    private func beginNextChunk(for download: Download) {
        guard !downloadsDisabled, let sourceURL = download.sourceURL else { return }

        let offset = DownloadStaging.partialSize(forKey: download.key)
        download.receivedBytes = offset
        download.chunkStartOffset = offset

        if let total = download.totalBytes, offset >= total {
            finish(download, assembledBytes: offset)
            return
        }

        var request = URLRequest(url: sourceURL)
        request.setValue("bytes=\(offset)-\(offset + Self.chunkSize - 1)",
                         forHTTPHeaderField: "Range")
        // If-Range only matters once we have bytes to protect. Sending the
        // ETag we were given means a changed asset comes back 200 (whole
        // body) instead of splicing new bytes onto old ones.
        if offset > 0, let etag = download.etag {
            request.setValue(etag, forHTTPHeaderField: "If-Range")
        }

        let task = session.downloadTask(with: request)
        // Survives a background relaunch, which is how the delegate finds its
        // way back to the right staging file when no view ever ran.
        task.taskDescription = download.key
        activeKey = download.key
        activeTask = task
        download.state = .transferring
        task.resume()
    }

    private func finish(_ download: Download, assembledBytes: Int64) {
        activeKey = nil
        activeTask = nil

        switch TransferVerification.check(assembledBytes: assembledBytes,
                                          declaredTotal: download.totalBytes) {
        case .verified:
            if DownloadStaging.install(key: download.key, destination: download.destinationURL) {
                download.state = .succeeded
                download.receivedBytes = assembledBytes
                lastFinishedDestination = download.destinationURL
                finishedGeneration &+= 1
                prewarmCacheIdentity(for: download.destinationURL)
            } else {
                download.state = .interrupted
                scheduleRetry(download)
            }

        case .sizeMismatch:
            // These bytes are not what the server promised, so they are not
            // worth resuming from either. Throw them away and start over
            // rather than append onto a body of unknown provenance.
            DownloadStaging.discardPartial(forKey: download.key)
            download.receivedBytes = 0
            download.state = .interrupted
            scheduleRetry(download)
        }
        advanceQueue()
    }

    private func scheduleRetry(_ download: Download) {
        guard !downloadsDisabled else { return }
        guard let delay = RetryBackoff.delay(forAttempt: download.attempt) else {
            // Retries exhausted. Land paused with the partial intact — one tap
            // from resuming — and say nothing. Retries plus a preserved
            // partial make the common failure recoverable without a message.
            download.state = .paused
            persist(download, pausedByUser: true)
            return
        }
        download.attempt += 1
        download.retryTask = Task { [weak self, weak download] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled,
                  let self, let download,
                  download.state == .interrupted else { return }
            self.enqueue(download)
        }
    }

    private func finishRestore(liveKeys: Set<String>) {
        for key in liveKeys {
            guard let download = rehydrate(key: key) else { continue }
            download.state = .transferring
            if activeKey == nil { activeKey = key }
        }
        for partial in DownloadStaging.scan() where !liveKeys.contains(partial.key) {
            guard let metadata = DownloadStaging.readMetadata(forKey: partial.key),
                  !metadata.pausedByUser,
                  let download = rehydrate(key: partial.key) else { continue }
            download.state = .interrupted
            download.attempt = 0
            enqueue(download)
        }
    }

    private func rehydrate(key: String) -> Download? {
        if let existing = downloads[key] { return existing }
        guard let metadata = DownloadStaging.readMetadata(forKey: key) else { return nil }
        let download = Download(key: key,
                                destinationURL: URL(fileURLWithPath: metadata.destinationPath))
        download.sourceURL = URL(string: metadata.sourceURLString)
        download.etag = metadata.etag
        download.totalBytes = metadata.declaredTotal
        download.receivedBytes = DownloadStaging.partialSize(forKey: key)
        downloads[key] = download
        return download
    }

    private func persist(_ download: Download, pausedByUser: Bool) {
        guard let source = download.sourceURL else { return }
        DownloadStaging.writeMetadata(
            PartialMetadata(destinationPath: download.destinationURL.path,
                            sourceURLString: source.absoluteString,
                            etag: download.etag,
                            declaredTotal: download.totalBytes,
                            pausedByUser: pausedByUser),
            forKey: download.key)
    }

    /// A network's Core ML cache key needs the file's hash, so computing it
    /// now keeps the first engine launch that selects it off the hot path.
    /// This used to be wired by hand at three call sites and on no book path;
    /// it is one center-owned hook because books are far larger and have no
    /// cache key at all.
    private func prewarmCacheIdentity(for url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent != OpeningBook.booksDirectory().standardizedFileURL else { return }
        Task.detached(priority: .userInitiated) {
            _ = try? await BinFileHasher.shared.identityForDownloadedFile(url)
        }
    }
}
```

If `import CoreMLCacheKit` is redundant because `Exports.swift` already re-exports `BinFileHasher`, drop it — the build will tell you.

- [ ] **Step 4: Build all five schemes, one at a time**

Expected: five `** BUILD SUCCEEDED **`. The likely failures and their fixes:
- `sessionSendsLaunchEvents` unavailable on macOS → the `#if !os(macOS)` guard is missing.
- A `Sendable` complaint on `getAllTasks` → you are letting a `URLSessionTask` cross the boundary; only the `Set<String>` may.
- `main actor-isolated property cannot be referenced from a nonisolated context` in the delegate → you dropped a `Task { @MainActor in }` hop.

- [ ] **Step 5: Run the full unit suite to prove nothing regressed**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan FastTestPlan 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|BUILD FAILED"
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloads"
git commit -m "feat(downloads): one center, one background session, chunked Range resume"
```

---

### Task 6: Put every existing consumer on the center without touching one of them

`Downloader` is public API for three app targets and five call sites; deleting it outright would mean one commit that rewrites all of them. Instead it becomes a thin facade over the center. Nothing else in the tree changes, the app immediately gains verification, resume and background survival, and each UI can then migrate on its own.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloader.swift` (whole file replaced)

**Interfaces:**
- Consumes: `DownloadCenter.shared.download(for:)`, `.start(_:from:)`, `.pause(_:)`, `Download.progress/isBusy/state`
- Produces: the same public surface it had — `destinationURL`, `progress`, `isDownloading`, `downloadedFileURL`, `onDownloadComplete`, `init(destinationURL:)`, `download(from:)`, `cancel()` — minus the `NSObject`/`URLSessionDownloadDelegate` conformance, which nothing referenced.

- [ ] **Step 1: Replace the file**

```swift
//
//  Downloader.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/5/25.
//
//  TRANSITIONAL. Downloads now run through `DownloadCenter` (ADR 0005); this
//  is a facade over it so the five consumers can move one at a time rather
//  than in a single commit that rewrites three app targets at once. Delete it
//  once the last consumer is gone — nothing new should be written against it.
//

import Foundation
import SwiftUI

@MainActor
@Observable
public final class Downloader {

    nonisolated public let destinationURL: URL

    /// The real thing. Memoized by the center against `destinationURL`, so two
    /// `Downloader`s for the same asset share one transfer — which is what
    /// closed the duplicate-download bug that made "too slow" look like a
    /// bandwidth problem.
    @ObservationIgnored private let entry: Download

    /// Ignored. The center pre-hashes a finished network itself, once, instead
    /// of at three hand-wired call sites and on no book path. Kept only so the
    /// existing assignments still compile during the migration.
    @ObservationIgnored public var onDownloadComplete: (@MainActor (URL) async -> Void)?

    public var progress: Double { entry.progress }

    /// True while transferring OR queued. A paused download reads false here,
    /// exactly as a cancelled one used to — consumers that need to tell those
    /// apart must move to `Download.state`.
    public var isDownloading: Bool { entry.isBusy }

    public var downloadedFileURL: URL? { entry.state == .succeeded ? destinationURL : nil }

    public init(destinationURL: URL) {
        self.destinationURL = destinationURL
        self.entry = DownloadCenter.shared.download(for: destinationURL)
    }

    /// `async throws` is preserved for source compatibility; it neither
    /// suspends nor throws. It never did — the old body returned as soon as
    /// `resume()` was called.
    public func download(from sourceURL: URL) async throws {
        DownloadCenter.shared.start(entry, from: sourceURL)
    }

    /// Now a pause: the partial is kept and one more tap continues it.
    public func cancel() {
        DownloadCenter.shared.pause(entry)
    }
}
```

- [ ] **Step 2: Confirm no consumer needed the dropped conformance**

Run:
```bash
cd "ios/KataGo iOS"
grep -rn "URLSessionDownloadDelegate\|downloader as\?\|Downloader: NSObject" --include=*.swift . | grep -v "\.build/"
```
Expected: no hits outside `Downloader.swift` itself (which no longer has any).

- [ ] **Step 3: Build all five schemes, one at a time**

Expected: five `** BUILD SUCCEEDED **`. Any failure here is a consumer that leaned on the old type's identity; fix it in place rather than restoring the conformance.

- [ ] **Step 4: Run the full unit suite**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan FastTestPlan 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|BUILD FAILED"
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Smoke-test one real download by hand**

Launch the iOS app in the simulator, open Select a Model → Lionffen b6c64 Network (2 MB, quick), tap Download. Expect the icon to spin, the button to become a stop symbol, and the row to flip to Play. Then delete it, start it again, tap stop halfway, and tap again — it must continue rather than restart (watch the icon's rotation resume from where it was, not from zero).

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloader.swift"
git commit -m "refactor(downloads): Downloader becomes a facade over DownloadCenter"
```

---

### Task 7: The rotating icon, shared — and the iOS model detail on explicit state

The icon the tester asked for, defined once, and the first consumer moved off the `isDownloading` edge.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/DownloadProgressIcon.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/Models/ModelPickerView.swift:60-183` (the whole of `ModelDetailView`), `:226` (the picker's construction site), `:419-453` (two previews)

**Interfaces:**
- Consumes: `Download`, `DownloadCenter.shared`, `DownloadButtonRole`
- Produces: `public struct DownloadProgressIcon: View` with `init(icon: Image, progress: Double)`; `ModelDetailView(model:download:selectedModel:)` replacing `ModelDetailView(model:downloader:selectedModel:)`

- [ ] **Step 1: Write `DownloadProgressIcon.swift`**

```swift
//
//  DownloadProgressIcon.swift
//  KataGo Anytime
//
//  The spinning KataGo icon shown while a catalog asset downloads. One
//  definition, three call sites (iOS networks, iOS opening books, visionOS
//  networks) — before this it was two hand-copied modifier chains that had
//  already drifted apart by one `.frame`.
//

import SwiftUI

public struct DownloadProgressIcon: View {

    private let icon: Image
    private let progress: Double

    /// - Parameters:
    ///   - icon: taken un-resized, and as an `Image` rather than a name,
    ///     because `.loadingIcon` is an asset-catalog symbol that exists in
    ///     each app target's own catalog and cannot be vended by the package.
    ///   - progress: 0...1. A non-finite value rotates by nothing rather than
    ///     handing SwiftUI a NaN angle, which drops the view entirely.
    public init(icon: Image, progress: Double) {
        self.icon = icon
        self.progress = progress
    }

    public var body: some View {
        icon
            .resizable()
            .scaledToFit()
            .clipShape(.circle)
            .rotationEffect(.degrees(progress.isFinite ? progress * 360 : 0))
    }
}
```

- [ ] **Step 2: Rewrite `ModelDetailView`**

Replace `ModelPickerView.swift:60-183` with:

```swift
struct ModelDetailView: View {
    var model: NeuralNetworkModel
    /// Vended by the center and memoized against the destination, so pushing
    /// this view a second time lands on the same object instead of minting a
    /// second concurrent transfer of the same file.
    let download: Download
    @State var isDownloaded = false
    @State private var isShowingConfigSheet = false
    @Binding var selectedModel: NeuralNetworkModel?

    private var role: DownloadButtonRole {
        DownloadButtonRole.role(isOnDisk: isDownloaded,
                                state: download.state,
                                hasPartial: download.hasPartial)
    }

    func downloadPlayButton(model: NeuralNetworkModel) -> some View {
        Button {
            switch role {
            case .play:
                selectedModel = model
            case .download, .resume:
                if let modelURL = URL(string: model.url) {
                    DownloadCenter.shared.start(download, from: modelURL)
                }
            case .pause:
                DownloadCenter.shared.pause(download)
            }
        } label: {
            Label {
                Text(role.actionTitle)
            } icon: {
                if role == .pause {
                    Image(systemName: role.systemImageName, variableValue: download.progress)
                        .symbolVariableValueMode(.draw)
                } else {
                    Image(systemName: role.systemImageName)
                }
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderedProminent)
        // Nine UI-test files tap this identifier. It must stay on ONE
        // always-present button across every role — a button that appears and
        // disappears takes the offline suite down with it.
        .accessibilityIdentifier("ModelDetailView.downloadPlayButton")
    }

    var body: some View {
        VStack {
            DownloadProgressIcon(icon: Image(.loadingIcon), progress: download.progress)

            VStack(alignment: .leading) {
                Text(model.title)
                    .bold()

                HStack {
                    Text(model.builtIn ? "" : model.fileSize.humanFileSize)
                        .foregroundStyle(.secondary)

                    downloadPlayButton(model: model)

                    Button {
                        isShowingConfigSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Backend Settings")

                    Spacer()

                    if !model.builtIn && isDownloaded {
                        ModelTrashButton(
                            model: model,
                            isDownloaded: $isDownloaded
                        )
                    }
                }
                .padding(.vertical)

                ScrollView {
                    Text(model.description)
                }
            }
        }
        .padding()
        .onAppear { refreshDownloadedFlag() }
        // Explicit state, not the old `isDownloading` true->false edge: a
        // pause takes that same edge, so the edge could never tell a stopped
        // download from a finished one. The center pre-hashes the finished
        // file itself, so nothing is wired here any more.
        .onChange(of: download.state) { _, newState in
            if newState == .succeeded { isDownloaded = true }
        }
        .sheet(isPresented: $isShowingConfigSheet) {
            BackendConfigSheet(model: model)
        }
        .navigationTitle(model.title)
    }

    private func refreshDownloadedFlag() {
        if model.builtIn {
            isDownloaded = true
        } else if let downloadedURL = model.downloadedURL {
            isDownloaded = FileManager.default.fileExists(atPath: downloadedURL.path)
        } else {
            isDownloaded = false
        }
    }
}
```

- [ ] **Step 3: Update the picker's construction site**

`ModelPickerView.swift:224-228` becomes:

```swift
                                ModelDetailView(
                                    model: model,
                                    download: DownloadCenter.shared.download(for: destinationURL),
                                    selectedModel: $selectedModel
                                )
```

- [ ] **Step 4: Update the two previews**

In both `#Preview("Model Detail xSmall")` and `#Preview("Model Detail accessibility5")`, replace the `downloader:` argument with:

```swift
                download: DownloadCenter.shared.download(
                    for: NeuralNetworkModel.allCases[1].downloadedURL!
                ),
```

- [ ] **Step 5: Build iOS and run the UI tests that tap the button**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeUITests/KataGo_iOSUITests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|BUILD FAILED"
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`. That suite taps `ModelDetailView.downloadPlayButton` to launch the built-in network, which is the exact regression this task could cause.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Rendering/DownloadProgressIcon.swift" \
        "ios/KataGo iOS/KataGo iOS/Models/ModelPickerView.swift"
git commit -m "feat(downloads): shared rotating icon, iOS model detail on explicit state"
```

---

### Task 8: The opening-book detail gets the icon — and its activation stops depending on being on screen

The headline of the second tester report. The book detail is restructured to mirror the network detail: the spinning icon on top, then title, then the size-and-button row. And the activation of a freshly downloaded book moves off a view that may well have been popped by the time the download finishes.

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Models/OpeningBookPickerView.swift:53-132` (the whole of `OpeningBookDetailView`), `:142` (construction site), `:173-180` (preview)
- Modify: `ios/KataGo iOS/KataGo iOS/App/ContentView.swift` (near the existing `loadIfNeeded` call at `:130`)

**Interfaces:**
- Consumes: `DownloadProgressIcon`, `Download`, `DownloadCenter.shared`, `DownloadButtonRole`, `DownloadCenter.finishedGeneration`, `DownloadCenter.lastFinishedDestination`
- Produces: `OpeningBookDetailView(book:download:)` replacing `OpeningBookDetailView(book:downloader:)`

- [ ] **Step 1: Rewrite `OpeningBookDetailView`**

Replace `OpeningBookPickerView.swift:53-132` with:

```swift
struct OpeningBookDetailView: View {
    let book: OpeningBook
    /// Memoized by the center against the book's destination, so re-entering
    /// this screen shows the transfer that is already running rather than
    /// starting a second one.
    let download: Download
    @State private var isDownloaded = false
    @Environment(BookLookup.self) private var bookLookup: BookLookup?

    /// `isOnDisk: false` on purpose. A book has nothing to activate, so the
    /// `.play` role is unreachable here — the Downloaded label and the trash
    /// button take the button's place once the file has landed.
    private var role: DownloadButtonRole {
        DownloadButtonRole.role(isOnDisk: false,
                                state: download.state,
                                hasPartial: download.hasPartial)
    }

    private var downloadButton: some View {
        Button {
            switch role {
            case .download, .resume:
                if let url = URL(string: book.url) {
                    DownloadCenter.shared.start(download, from: url)
                }
            case .pause:
                DownloadCenter.shared.pause(download)
            case .play:
                break // unreachable; see `role`
            }
        } label: {
            Label {
                Text(role.actionTitle)
            } icon: {
                if role == .pause {
                    Image(systemName: role.systemImageName, variableValue: download.progress)
                        .symbolVariableValueMode(.draw)
                } else {
                    Image(systemName: role.systemImageName)
                }
            }
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("OpeningBookDetailView.downloadButton")
    }

    var body: some View {
        VStack {
            // The tester asked for the network picker's spinning icon here.
            // Same view, same modifiers — not a second copy of them.
            DownloadProgressIcon(icon: Image(.loadingIcon), progress: download.progress)

            VStack(alignment: .leading) {
                Text(book.title)
                    .bold()

                HStack {
                    if isDownloaded {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let onDisk = book.onDiskSize {
                            Text(onDisk.humanFileSize)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(book.fileSize.humanFileSize)
                            .foregroundStyle(.secondary)
                        downloadButton
                    }

                    Spacer()

                    if isDownloaded {
                        OpeningBookTrashButton(book: book, isDownloaded: $isDownloaded)
                    }
                }
                .padding(.vertical)

                ScrollView {
                    Text(book.description)
                }
            }
        }
        .padding()
        .navigationTitle(book.title)
        .onAppear { isDownloaded = book.isDownloaded }
        // Explicit state, not the `isDownloading` true->false edge a pause and
        // a completion used to share. Activation is NOT done here any more —
        // see ContentView — because this view is often gone by the time a
        // 240 MB book finishes.
        .onChange(of: download.state) { _, newState in
            if newState == .succeeded { isDownloaded = book.isDownloaded }
        }
    }
}
```

- [ ] **Step 2: Update the construction site and the preview**

`OpeningBookPickerView.swift:139-143`:
```swift
                    NavigationLink {
                        OpeningBookDetailView(
                            book: book,
                            download: DownloadCenter.shared.download(for: book.downloadedURL)
                        )
                    } label: {
```

`#Preview("Opening Book Detail")`:
```swift
        OpeningBookDetailView(
            book: OpeningBook.allCases[3],
            download: DownloadCenter.shared.download(for: OpeningBook.allCases[3].downloadedURL)
        )
```

- [ ] **Step 3: Read the region of ContentView that already loads books**

Run: `sed -n '110,150p' "ios/KataGo iOS/KataGo iOS/App/ContentView.swift"`
Expected: a `bookLookup…loadIfNeeded(boardSize:)` call around line 130. Note which view modifier chain it sits in and what the `bookLookup` reference is called — the next step attaches to the same view and reuses that reference verbatim.

- [ ] **Step 4: Activate a finished book from a view that is always mounted**

Add to that same view's modifier chain:

```swift
        // A book that finishes downloading is loaded here, not in the detail
        // view that started it: a 240 MB book routinely outlives its screen,
        // and the old `.onChange` on the detail view simply did not run once
        // the user had navigated away. The center's generation counter makes
        // two finishes of the same book distinguishable.
        .onChange(of: DownloadCenter.shared.finishedGeneration) { _, _ in
            guard let finished = DownloadCenter.shared.lastFinishedDestination,
                  let book = OpeningBook.allCases.first(where: {
                      $0.downloadedURL.standardizedFileURL == finished.standardizedFileURL
                  }) else { return }
            bookLookup.loadIfNeeded(boardSize: book.boardSize)
        }
```

If `bookLookup` at that site is optional, use `bookLookup?.loadIfNeeded(boardSize: book.boardSize)`.

- [ ] **Step 5: Build iOS and run the book unit tests**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/OpeningBookTests" \
  -only-testing:"KataGo AnytimeTests/BookLookupTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|BUILD FAILED"
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 6: Verify the icon by hand**

Launch the iOS app in the simulator, Select a Model → Opening Books → 6×6 Opening Book (13.5 MB). The KataGo icon must be on the screen and must rotate as the download runs, exactly as on a network detail page. Tap stop mid-way: the icon must stop rotating and hold its angle, and the button must read "Resume Download" to VoiceOver.

- [ ] **Step 7: Commit**

```bash
git add "ios/KataGo iOS/KataGo iOS/Models/OpeningBookPickerView.swift" \
        "ios/KataGo iOS/KataGo iOS/App/ContentView.swift"
git commit -m "feat(books): spinning KataGo icon on the book detail, activation off the view"
```

---

### Task 9: visionOS

One `Primary` enum disappears into the shared `DownloadButtonRole`, and the `.frame(width: 160, height: 160)` that was the only difference between the two icon chains moves to the call site.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Vision/VisionModelDetailState.swift:18-73`
- Modify: `ios/KataGo iOS/KataGo Anytime Vision/VisionModelsOrnament.swift:37`, `:66-75`, `:103-118`, `:124-152`, `:190-236`
- Modify: `ios/KataGo iOS/KataGo iOSTests/VisionModelDetailStateTests.swift`

**Interfaces:**
- Consumes: `DownloadButtonRole`, `DownloadState`, `Download`, `DownloadCenter.shared`, `DownloadProgressIcon`
- Produces: `VisionModelDetailState.primary: DownloadButtonRole` (was a private `Primary` enum), and `make(isBuiltIn:fileSize:isDownloaded:downloadState:hasPartial:isActive:engineIsRunning:)`

- [ ] **Step 1: Confirm the icon asset is square**

The `.frame` moves from inside the modifier chain to outside it. For a square source those are identical; for a non-square one they clip to different circles.

```bash
grep -a -o "MediaBox *\[[^]]*\]" \
  "ios/KataGo iOS/KataGo Anytime Vision/Assets.xcassets/LoadingIcon.imageset/LoadingIcon.pdf" | head -1
```
Expected: a box whose width equals its height (e.g. `[0 0 512 512]`). If it is **not** square, stop and instead give `DownloadProgressIcon` an optional `side: CGFloat?` parameter applied between `.scaledToFit()` and `.clipShape(.circle)`, and pass `side: 160` here.

- [ ] **Step 2: Rewrite `VisionModelDetailState`**

Replace the `Primary` enum and `make` with:

```swift
public struct VisionModelDetailState: Equatable, Sendable {
    /// The shared four-role button vocabulary. visionOS used to carry its own
    /// three-case copy; there is one now, so a paused download reads as
    /// "resume" here exactly as it does on iOS.
    public let primary: DownloadButtonRole
    public let primarySystemImage: String
    public let primaryDisabled: Bool
    public let showsTrash: Bool
    public let sizeText: String

    public static func make(isBuiltIn: Bool,
                            fileSize: Int,
                            isDownloaded: Bool,
                            downloadState: DownloadState,
                            hasPartial: Bool,
                            isActive: Bool,
                            engineIsRunning: Bool) -> VisionModelDetailState {
        let onDisk = isBuiltIn || isDownloaded
        let primary = DownloadButtonRole.role(isOnDisk: onDisk,
                                              state: downloadState,
                                              hasPartial: hasPartial)
        // Only activation waits for the engine. Downloading, pausing and
        // resuming are always allowed — a boot chooser has no engine yet and
        // must still be able to fetch the net it is about to boot.
        let disabled = primary == .play ? (isActive || !engineIsRunning) : false
        return VisionModelDetailState(
            primary: primary,
            primarySystemImage: primary.systemImageName,
            primaryDisabled: disabled,
            showsTrash: onDisk && !isBuiltIn,
            sizeText: isBuiltIn ? "" : humanFileSize(fileSize))
    }

    /// The iOS `Int.humanFileSize` formatter, verbatim.
    public static func humanFileSize(_ bytes: Int) -> String {
        let size = Double(bytes)
        guard size > 0 else { return "0 B" }
        let units = ["B", "kB", "MB", "GB", "TB"]
        let exponent = Int(floor(log(size) / log(1024)))
        let scaledSize = size / pow(1024, Double(exponent))
        let formattedSize = String(format: "%.2f", scaledSize)

        return "\(formattedSize) \(units[exponent])"
    }
}
```

- [ ] **Step 3: Update `VisionModelDetailStateTests`**

Change the private factory's signature and every expectation:

```swift
    private func make(isBuiltIn: Bool = false,
                      fileSize: Int = 863_846_339,
                      isDownloaded: Bool = false,
                      downloadState: DownloadState = .idle,
                      hasPartial: Bool = false,
                      isActive: Bool = false,
                      engineIsRunning: Bool = true) -> VisionModelDetailState {
        VisionModelDetailState.make(isBuiltIn: isBuiltIn,
                                    fileSize: fileSize,
                                    isDownloaded: isDownloaded,
                                    downloadState: downloadState,
                                    hasPartial: hasPartial,
                                    isActive: isActive,
                                    engineIsRunning: engineIsRunning)
    }
```

Then, across the eight tests: `.activate` becomes `.play`, `.stopDownload` becomes `.pause`, `isDownloading: true` becomes `downloadState: .transferring`, and add one new case:

```swift
    @Test func aPausedDownloadWithBytesOffersResume() {
        let state = make(downloadState: .paused, hasPartial: true)
        #expect(state.primary == .resume)
        #expect(!state.primaryDisabled)
    }
```

- [ ] **Step 4: Update `VisionModelsOrnament`**

- Delete `@State private var downloaders: [String: Downloader] = [:]` (`:37`) and the whole `downloader(for:)` helper (`:103-118`). The center memoizes by destination, which is what that dictionary was hand-rolling, and it does it across screens and launches rather than for a card's lifetime.
- At `:66-75`, pass the center's object:

```swift
                    VisionModelDetailView(model: model,
                                          engine: engine,
                                          isBootChooser: isBootChooser,
                                          download: DownloadCenter.shared.download(
                                              for: model.downloadedURL
                                                  ?? URL.documentsDirectory
                                                      .appendingPathComponent(model.fileName)),
                                          onActivate: onActivate)
```

- In `VisionModelDetailView`, replace `let downloader: Downloader` with `let download: Download`, and the `state` computed property with:

```swift
    private var state: VisionModelDetailState {
        // Pre-boot chooser: no engine yet, so nothing is active and
        // activation is always allowed (it IS the boot).
        VisionModelDetailState.make(
            isBuiltIn: model.builtIn,
            fileSize: model.fileSize,
            isDownloaded: isDownloaded,
            downloadState: download.state,
            hasPartial: download.hasPartial,
            isActive: !isBootChooser && model.title == engine.activeModel.title,
            engineIsRunning: isBootChooser || engine.phase == .running)
    }
```

- Replace the icon (`:147-152`) with:

```swift
            DownloadProgressIcon(icon: Image(.loadingIcon), progress: download.progress)
                .frame(width: 160, height: 160)
```

- Replace the button action and label (`:209-236`):

```swift
    private var primaryButton: some View {
        Button {
            switch state.primary {
            case .play:
                onActivate(model)
            case .download, .resume:
                if let modelURL = URL(string: model.url) {
                    DownloadCenter.shared.start(download, from: modelURL)
                }
            case .pause:
                DownloadCenter.shared.pause(download)
            }
        } label: {
            if state.primary == .pause {
                Image(systemName: state.primarySystemImage, variableValue: download.progress)
                    .symbolVariableValueMode(.draw)
            } else {
                Image(systemName: state.primarySystemImage)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(state.primaryDisabled)
        .accessibilityLabel(state.primary == .play ? "Activate model" : state.primary.actionTitle)
    }
```

- Replace the completion edge (`:200-206`):

```swift
        .onChange(of: download.state) { _, newState in
            if newState == .succeeded { isDownloaded = true }
        }
```

- [ ] **Step 5: Build visionOS and iOS, then run the vision state tests**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/VisionModelDetailStateTests" \
  -only-testing:"KataGo AnytimeTests/VisionModelListItemTests" \
  2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|BUILD FAILED"
```
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Vision/VisionModelDetailState.swift" \
        "ios/KataGo iOS/KataGo Anytime Vision/VisionModelsOrnament.swift" \
        "ios/KataGo iOS/KataGo iOSTests/VisionModelDetailStateTests.swift"
git commit -m "feat(vision): model card on the shared download center and button roles"
```

---

### Task 10: macOS — closing a window detaches observation instead of killing transfers

The one deliberate behaviour change, isolated in its own commit so it can be reverted alone. Four in-code comments promise the opposite of what the app will now do; rewriting them is part of the task, not an afterthought.

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/ModelsViewController.swift:14-23`, `:94-96`, `:252-256`, `:276-364`, `:676-686`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/ModelsWindowController.swift:20-22`, `:66-72`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/OpeningBooksViewController.swift:25`, `:100-102`, `:114-171`, `:256-263`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/OpeningBooksWindowController.swift:16-18`, `:50-55`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/ModelRowView.swift:191-236`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/OpeningBookRowView.swift:127-157`

**Interfaces:**
- Consumes: `Download`, `DownloadCenter.shared`
- Produces: `ModelsViewController.detachDownloadObservation()` and `attachDownloadObservation()` replacing `cancelAllDownloads()`; the same pair on `OpeningBooksViewController`; `ModelRowView.configure(model:isActive:isAvailable:isReady:download:onDownload:onCancel:onDelete:onSetActive:)` and `OpeningBookRowView.configure(book:isDownloaded:download:onDownload:onCancel:onDelete:)`, both taking `Download?` where they took `Downloader?`

- [ ] **Step 1: Replace the download plumbing in `ModelsViewController`**

Delete `private var downloaders: [String: Downloader] = [:]` and replace `isDownloading`, `startDownload`, `cancelDownload`, `cancelAllDownloads` and `trackDownloader` with:

```swift
    /// File names whose `Download` is currently mirrored onto a row. Emptied
    /// when the window closes, which DETACHES the mirror — it does not stop
    /// anything.
    private var observedFileNames: Set<String> = []

    private func download(for model: NeuralNetworkModel) -> Download? {
        model.downloadedURL.map { DownloadCenter.shared.download(for: $0) }
    }

    /// True while a transfer for this model is running or queued. A paused
    /// download is deliberately not "downloading" — its row offers to resume.
    private func isDownloading(_ model: NeuralNetworkModel) -> Bool {
        download(for: model)?.isBusy ?? false
    }

    // MARK: - Download

    /// Starts, or resumes, the download for `model`. The center refuses a
    /// duplicate by construction (it keys downloads by destination), so the
    /// guard here is about not re-arming a second observer.
    private func startDownload(_ model: NeuralNetworkModel) {
        guard !model.builtIn,
              !isDownloading(model),
              let entry = download(for: model),
              let sourceURL = URL(string: model.url) else { return }

        DownloadCenter.shared.start(entry, from: sourceURL)
        track(entry, fileName: model.fileName)
        reloadRow(for: model.fileName)
    }

    /// Pauses a model's transfer. The partial survives; the row's download
    /// arrow resumes it.
    private func cancelDownload(_ model: NeuralNetworkModel) {
        guard let entry = download(for: model) else { return }
        DownloadCenter.shared.pause(entry)
        reloadRow(for: model.fileName)
    }

    /// Re-attaches the row mirror to every transfer already in flight. Called
    /// when the window appears, because the window can be closed and reopened
    /// while a download runs.
    func attachDownloadObservation() {
        for model in models {
            guard let entry = download(for: model), entry.isBusy else { continue }
            track(entry, fileName: model.fileName)
        }
        reloadVisibleRows()
    }

    /// Stops mirroring download state onto rows.
    ///
    /// This does NOT cancel anything. Downloads belong to the app-wide
    /// `DownloadCenter` now and keep running with the window shut; reopening
    /// it re-attaches and shows live progress. Cancelling on close used to be
    /// the promise, and it was the reason a long download could not survive
    /// tidying up your windows.
    func detachDownloadObservation() {
        observedFileNames.removeAll()
    }

    private func track(_ entry: Download, fileName: String) {
        guard !observedFileNames.contains(fileName) else { return }
        observedFileNames.insert(fileName)
        rearm(entry, fileName: fileName)
    }

    /// Self-rescheduling observation of one `Download`. Same
    /// `withObservationTracking` contract as `MainWindowController`: the
    /// callback fires once per change BEFORE the value commits, so we hop to a
    /// `Task { @MainActor }` to read the committed value and RE-ARM tracking
    /// (otherwise observation stops after the first change).
    private func rearm(_ entry: Download, fileName: String) {
        withObservationTracking {
            _ = entry.receivedBytes
            _ = entry.state
        } onChange: { [weak self, weak entry] in
            Task { @MainActor in
                guard let self, let entry,
                      self.observedFileNames.contains(fileName) else { return }

                self.reloadRow(for: fileName)
                if entry.state == .succeeded {
                    self.observedFileNames.remove(fileName)
                    self.recomputeAvailability()
                    self.reloadRow(for: fileName)
                    if self.selectedModel?.fileName == fileName {
                        self.rebuildDetailPane()
                    }
                    return
                }
                self.rearm(entry, fileName: fileName)
            }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        attachDownloadObservation()
    }
```

If `viewWillAppear()` is already overridden, add the `attachDownloadObservation()` call to the existing override instead of adding a second one.

At `:681`, the cell configuration becomes `download: download(for: model),`.

- [ ] **Step 2: Rewrite the `ModelsViewController` header comment (`:14-23`)**

```swift
//  Download lifecycle
//  ------------------
//  Downloads belong to the app-wide `DownloadCenter`, keyed by destination
//  URL; this controller only mirrors one onto a row. Progress reaches the row
//  through a self-rescheduling `withObservationTracking` observer (the same
//  pattern `MainWindowController` uses), which reloads just the affected row.
//  On completion the verified file lands at `downloadedURL` and the row flips
//  to its "Downloaded" state. Closing the window calls
//  `detachDownloadObservation()`, which stops the mirror and nothing else —
//  the transfer keeps running and reopening the window picks it back up.
```

- [ ] **Step 3: Rewrite `ModelsWindowController`**

Header (`:20-22`):
```swift
//  On close, the view controller stops mirroring download progress onto its
//  rows (see `ModelsViewController.detachDownloadObservation`). The transfers
//  themselves keep running in the app-wide download center, so a dismissed
//  window no longer throws away a download in progress.
```

`windowWillClose` (`:66-72`):
```swift
    // MARK: - NSWindowDelegate

    /// Detaches the row mirror. Deliberately does NOT cancel: a download that
    /// survives quitting the app should certainly survive closing a window.
    func windowWillClose(_ notification: Notification) {
        modelsViewController.detachDownloadObservation()
    }
```

- [ ] **Step 4: Apply the same four changes to the books side**

`OpeningBooksViewController`: same replacement, with `download(for: book) = DownloadCenter.shared.download(for: book.downloadedURL)` (non-optional), `books` instead of `models`, `selectedBook`, and `onBooksChanged()` called on `.succeeded` in place of `recomputeAvailability()`. **Delete the `_ = try? OpeningBook.ensureBooksDirectory()` call at `:120`** — the center creates the destination directory itself (and keeps its backup exclusion), which is the only thing that works after a relaunch when no view is around to call it.

`OpeningBooksWindowController` header (`:16-18`):
```swift
//  On close it stops mirroring download progress onto its rows (see
//  `OpeningBooksViewController.detachDownloadObservation`); the transfers keep
//  running in the app-wide download center.
```
and `windowWillClose` calls `booksViewController.detachDownloadObservation()`.

- [ ] **Step 5: Update both row views**

`ModelRowView.swift:191` doc line and `:196` parameter:
```swift
    ///   - download: the download for this model, if it has a destination
    ///     (drives the progress bar and the Paused state).
```
```swift
                   download: Download?,
```
and `:212-236`:
```swift
        let state = download?.state ?? .idle
        let isDownloading = download?.isBusy ?? false
        // A paused download still has bytes on disk, and a bar frozen where it
        // stopped is the only thing that tells the user resuming is cheap.
        let isPaused = (state == .paused || state == .interrupted)
            && (download?.hasPartial ?? false)

        // Status text: Active > Downloading > Paused > Downloaded.
        if isActive {
            statusField.stringValue = "Active"
            statusField.textColor = .systemGreen
        } else if isDownloading {
            statusField.stringValue = "Downloading…"
            statusField.textColor = .secondaryLabelColor
        } else if isPaused {
            statusField.stringValue = "Paused"
            statusField.textColor = .secondaryLabelColor
        } else if isAvailable {
            statusField.stringValue = isReady ? "Ready" : "Downloaded"
            statusField.textColor = .secondaryLabelColor
        } else {
            statusField.stringValue = "Not downloaded"
            statusField.textColor = .secondaryLabelColor
        }

        // Controls: the bar shows while downloading AND while paused; only a
        // live transfer can be stopped.
        progressIndicator.isHidden = !(isDownloading || isPaused)
        cancelButton.isHidden = !isDownloading
        if isDownloading || isPaused {
            progressIndicator.doubleValue = download?.progress ?? 0
        }
```

`OpeningBookRowView.swift:127-157` takes the identical treatment, keeping its existing `bytes` line.

- [ ] **Step 6: Confirm nothing still promises cancel-on-close**

Run:
```bash
cd "ios/KataGo iOS"
grep -rn "leaves a background download running\|cancelAllDownloads" --include=*.swift "KataGo Anytime Mac"
```
Expected: no output.

- [ ] **Step 7: Build macOS and run the Mac unit tests**

```bash
cd "ios/KataGo iOS"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" \
  -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Verify the behaviour change by hand**

Run the Mac app **from a signed Debug build** (an unsigned one crashes on CloudKit). Open Models, start the Official network (863 MB), close the window at ~5%, wait ten seconds, reopen. The row must still say "Downloading…" with a bar well past where you left it. Then quit the app mid-download, relaunch, open Models: the row must show a partial and resume rather than start from zero.

If the window appears to hang instead of opening, it is the macOS approval dialog behind another window — ask for it to be approved. Do not kill and relaunch.

- [ ] **Step 9: Commit**

```bash
git add "ios/KataGo iOS/KataGo Anytime Mac"
git commit -m "feat(mac): closing a downloads window detaches observation, not the transfer"
```

---

### Task 11: Launch restore, the background handoff, and the end of the shim

**Files:**
- Delete: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloader.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/App/KataGo_iOSApp.swift:117-135`
- Modify: `ios/KataGo iOS/KataGo Anytime Vision/KataGoVisionApp.swift:34-48`
- Modify: `ios/KataGo iOS/KataGo Anytime Mac/AppDelegate.swift:35-88`
- Modify: `ios/KataGo iOS/KataGo iOSUITests/PortraitUITestCase.swift`

**Interfaces:**
- Consumes: `DownloadCenter.shared.restoreOnLaunch()`, `.awaitBackgroundURLSessionEvents()`, `.sessionIdentifier`, `.disableLaunchArgument`
- Produces: nothing new

- [ ] **Step 1: Confirm the shim has no callers left**

```bash
cd "ios/KataGo iOS"
grep -rn "Downloader" --include=*.swift . | grep -v "\.build/" | grep -v "DownloadSessionDelegate"
```
Expected: only `Services/Downloader.swift` itself. If anything else appears, that consumer was missed in Tasks 7–10 — migrate it before deleting.

- [ ] **Step 2: Delete the shim**

```bash
trash "ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Services/Downloader.swift"
```

- [ ] **Step 3: Wire the iOS scene**

In `KataGo_iOSApp.swift`, add a `.task` to `modelRunnerRoot`:

```swift
            .task {
                // Sweeps stale partials, reattaches to whatever the background
                // daemon finished while we were gone, and resumes what was
                // interrupted. Paused downloads are left alone by design. A
                // no-op under `--uitest-disable-downloads`.
                DownloadCenter.shared.restoreOnLaunch()
            }
```

and attach the background handoff to the scene (`body`, alongside `.modelContainer`):

```swift
    var body: some Scene {
        scene
            .modelContainer(SharedModelContainer.shared)
            // The system relaunches the app when a background transfer needs
            // attention; this is where those events are drained. The app has
            // never had a UIApplicationDelegate and does not gain one for it.
            .backgroundTask(.urlSession(DownloadCenter.sessionIdentifier)) {
                await DownloadCenter.shared.awaitBackgroundURLSessionEvents()
            }
    }
```

If the compiler rejects `.urlSession(_:)`, use the predicate form and ignore the context:
`.backgroundTask(.urlSession(matching: { $0 == DownloadCenter.sessionIdentifier })) { _ in … }`.

- [ ] **Step 4: Wire the visionOS scene**

The same two additions in `KataGoVisionApp.swift`: a `.task { DownloadCenter.shared.restoreOnLaunch() }` on `VisionRootView()`, and the `.backgroundTask` modifier on the `WindowGroup` alongside `.modelContainer`.

- [ ] **Step 5: Wire macOS**

In `AppDelegate.applicationDidFinishLaunching`, after `warnIfLibraryStorageUnavailable(in: wc)`:

```swift
        // Sweep stale partials and resume anything a previous run left
        // interrupted. macOS needs no background-relaunch handoff — the
        // process is either running or gone.
        DownloadCenter.shared.restoreOnLaunch()
```

- [ ] **Step 6: Make the UI suite inert**

In `PortraitUITestCase.swift` (the shared base every UI test launches through), add the kill switch to the launch arguments alongside the existing ones:

```swift
        // The download center resumes interrupted transfers at launch. The UI
        // suite is offline by contract — `ModelStagingUITestSupport` exists
        // precisely so no test has to reach the network — so the center is
        // made inert here rather than relying on there happening to be no
        // partial left on the simulator from an earlier manual run.
        app.launchArguments.append(DownloadCenter.disableLaunchArgument)
```

If `PortraitUITestCase` does not own the `XCUIApplication` construction for every test, add the argument at each `app.launchArguments` site instead, and say so in the commit message.

- [ ] **Step 7: Build all five schemes and run the full test plan**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan FullTestPlan 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|Executed .* tests"
```
Expected: judge by **0 failures**, not by the pass count. Then the five builds, one at a time.

- [ ] **Step 8: Commit**

```bash
git add -A "ios/KataGo iOS"
git commit -m "feat(downloads): resume at launch, background handoff, retire Downloader"
```

---

### Task 12: Verification, the ADR amendment, and the QA matrix

**Files:**
- Modify: `docs/adr/0005-downloads-run-through-one-center-resumed-by-range.md`

**Interfaces:**
- Consumes: everything
- Produces: nothing in code

- [ ] **Step 1: Amend the ADR with the chunking refinement**

Decision 3 says "Resume is `Range: bytes=<offset>-` against the catalog URL" — an open-ended range. The implementation fetches fixed-size chunks instead, for a reason a future reader would otherwise have to rediscover. Append to the ADR, after **Consequences**:

```markdown
## Amendment 2026-08-13 — transfers are chunked

Decision 3 described one open-ended `Range: bytes=<offset>-` per attempt.
Implementation showed that loses more than it saves: a `URLSessionDownloadTask`
surrenders its bytes only when it *finishes*, so a dropped connection at 95% of
a 240 MB book discards 228 MB — exactly the case resumability exists for — and
the only Apple-supplied alternative, `cancel(byProducingResumeData:)`, is the
one this ADR rejected for pinning a redirect that expires in about thirty
minutes.

The transport therefore requests fixed **32 MiB** ranged chunks in sequence,
appending each to the partial. Everything decision 3 promised still holds — the
request goes to the stable catalog URL, carries `If-Range`, accepts exactly 206,
and takes its total from `Content-Range`. What changes is the bound on loss: a
drop or a pause now costs at most one chunk instead of the whole attempt. The
price is one extra round trip per 32 MiB — eight for the largest book, under a
tenth of its transfer time on a healthy link.
```

`CONTEXT.md` needs no new term: a chunk is an implementation detail of a
*transfer*, and the glossary is implementation-free by design.

- [ ] **Step 2: Full five-scheme build from a clean DerivedData**

Run the five build commands **one at a time**. Expected: five `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Full test plan**

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -testPlan FullTestPlan 2>&1 | tee /tmp/full-test.log | grep -E "TEST (SUCCEEDED|FAILED)"
grep -c "error:" /tmp/full-test.log
```
Expected: judge by 0 failures against the known baseline, not by the absolute count.

- [ ] **Step 4: Scan the whole diff for non-English content**

```bash
git diff master...HEAD | grep -nP '[^\x00-\x7F]' | grep -v '…\|—\|×\|’' || echo "clean"
```
Expected: `clean`, or only the typographic characters the codebase already uses.

- [ ] **Step 5: Device QA matrix — the part no simulator can prove**

Background sessions, real suspension and real network loss do not reproduce in a simulator. Run these on a device and record the result; this is the acceptance gate for the feature.

| # | Scenario | Expected |
|---|---|---|
| 1 | Start the 9×9 book (240 MB), background the app for two minutes | Progress advanced on return; no restart |
| 2 | Start it, force-quit the app at ~20%, relaunch | Resumes from roughly where it stopped, not from zero |
| 3 | Start it, enable airplane mode for a minute, disable | Recovers on its own within the 2/8/30 s schedule; no error alert |
| 4 | Start it, tap stop, leave the app overnight, resume next day | Continues from the partial — the case resume data would have failed, because the signed redirect is long dead |
| 5 | Start two books back to back | The second reads as waiting, not transferring; the first keeps full throughput |
| 6 | Delete a downloaded book, re-download | Completes and the eye button offers book view without revisiting the detail screen |
| 7 | Fill the device near capacity, start the 8×8 book | Fails silently, keeps its partial, no crash and no half file at the destination |
| 8 | macOS: close the Models window mid-download, reopen | Row still downloading, bar advanced |
| 9 | visionOS: start a net from the Models ornament, dismiss it, reopen | Same download, live progress |
| 10 | Any completed download | The file at the destination is byte-for-byte the published asset (`shasum` against a `curl` of the same URL) |

- [ ] **Step 6: Commit the amendment**

```bash
git add docs/adr/0005-downloads-run-through-one-center-resumed-by-range.md
git commit -m "docs(adr): record that download transfers are chunked, and why"
```

---

## Notes for whoever executes this

**Push cadence.** Every push to `ios-dev` distributes through Xcode Cloud. Land Tasks 1–2 and push; they are user-visible fixes with no architectural risk. Then land Tasks 3–12 locally and push once, about a day later.

**What is genuinely unproven when the plan is done.** The pure decisions are unit-tested and the UI is covered by the existing suite, but the transport itself — background session behaviour under real suspension, resume across a relaunch, recovery from a real network drop — has no automated coverage and cannot get any without either reaching the network or stubbing a session type that ignores stubs. Task 12's matrix is the coverage. Do not report the feature as verified until that matrix has been run on hardware.

**If a task turns out to be wrong,** say so and stop rather than working around it. The two most likely places: the `.backgroundTask(.urlSession(_:))` overload (Task 11 Step 3 names the fallback), and the assumption that `LoadingIcon.pdf` is square (Task 9 Step 1 names the fallback).

**One place the ADR contradicts itself, and how the plan resolves it.** Decision 4 says an interrupted download "resumes at launch and whenever connectivity returns". Decision 5 says that after three retries it "lands **paused** with its partial intact", and a paused download never resumes itself. Those cannot both hold for an outage longer than about forty seconds. The plan follows decision 5, because it is the more specific of the two and because the alternative — a download that silently wakes up hours later — is exactly the kind of surprise decision 5's "silent but never lossy" rule exists to avoid. In practice the gap is narrow: a background session with `waitsForConnectivity` holds an in-flight transfer rather than failing it, so only an outage that outlasts the retry schedule *and* kills the connection reaches the paused state, and the next launch resumes it. If the tester reports a download that "gave up", this is the behaviour to revisit — and it wants an ADR amendment, not a quiet change.

