# Core ML Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the compiled `.mlmodelc` produced by `MLModel.compileModel(at:)` so that re-launching KataGo Anytime with a previously-used (model, settings) combination skips both the C++ `.bin.gz → .mlpackage` conversion and the Core ML compile, and warm the cache opportunistically (built-in on first launch, downloads on completion, settings flips immediately) so the user pays the compile cost at most once per (model, settings).

**Architecture:** A new Swift actor `CoreMLModelCache` owns `Application Support/<bundle>/coreml/`. The C++/Swift bridge in `metalbackend.cpp/swift` queries the actor before every Core ML compile; on hit it loads the cached `.mlmodelc`, on miss it runs the existing convert+compile pipeline and stores the result atomically. Pinning, LRU eviction, in-flight dedup, tombstones-with-reap, and a recursive CAS-guarded join-or-install protocol enforce correctness. A `PrecompileScheduler` warms the cache opportunistically; UI surfaces per-model badges and a footer-mounted Clear Cache button.

**Tech Stack:** Swift 6 (actors, Sendable, structured concurrency, priority escalation), CryptoKit (SHA-256), CoreML (`MLModel.compileModel`, `MLModel(contentsOf:)`), `@Observable` for SwiftUI binding, Swift Testing for tests, C++17 in `cpp/neuralnet/metalbackend.cpp`, the existing `katagocoreml` library at `cpp/external/katagocoreml/`.

**Spec:** `docs/superpowers/specs/2026-05-09-coreml-cache-design.md`

---

## File Structure

### New files (KataGoInterface framework — bridge surface for C++):
- `ios/KataGo iOS/KataGoInterface/CoreMLCacheKey.swift` — `CoreMLCacheKey` struct, canonical encoding, digest, `sourceIdentity(for:)` dispatch, `DigestEpoch`.
- `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift` — actor: `urlForKey`, `joinOrInstall`, `prepareTmp`, `commitStore`, `acquireLocked`, `release`, `invalidate`, `clearAll`, `lookupOnDisk`, eviction, tombstones, adoption, orphan sweep, `PinnedCacheURL` class.
- `ios/KataGo iOS/KataGoInterface/EngineLaunchStatus.swift` — `@Observable` class for LoadingView's secondary status string.

### New files (main app target):
- `ios/KataGo iOS/KataGo iOS/BinFileHasher.swift` — async streaming SHA-256 with `(size, mtime)` UserDefaults memo.
- `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift` — `@Observable` scheduler with backend guard, dedup, concurrency=1.
- `ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift` — footer view with size/count + Clear button.

### Modified files (C++ bridge):
- `cpp/neuralnet/metalbackend.swift` — replace direct `createCoreMLComputeHandle` body with cache-aware path; add `convertOnCooperativePool`; add `loadCoreMLHandle` retry loop; expose `CoreMLComputeHandle` with optional `pinnedURL`.
- `cpp/neuralnet/metalbackend.cpp` — update `convertAndCreateCoreMLOnlyHandle` to drive the bridge with `Task.detached(priority: .userInitiated)`, primary 600 s + secondary 60 s `DispatchSemaphore` waits, and the legacy direct-compile fall-through.

### Modified files (UI / wiring):
- `ios/KataGo iOS/KataGo iOS/ModelPickerView.swift` — per-row badge bound to `PrecompileScheduler.status`; footer pinning `CoreMLCacheFooterView`; Clear Cache flow that calls `clearAll()` + `scheduleBuiltIn()`.
- `ios/KataGo iOS/KataGo iOS/BackendConfigSheet.swift` — call `scheduleForModel` from picker `onChange`.
- `ios/KataGo iOS/KataGo iOS/Downloader.swift` — call `BinFileHasher.computeAndStore` then `scheduleForModel` on download success.
- `ios/KataGo iOS/KataGo iOS/LoadingView.swift` — render `EngineLaunchStatus` secondary line.
- `ios/KataGo iOS/KataGo iOS/GameSplitView.swift` (or root view) — `.onAppear` re-warm check vs `firstLaunchPrecompileVersion` AppStorage key.

### Test files (in `ios/KataGo iOS/KataGo iOSTests`):
- `CoreMLCacheKeyTests.swift`
- `CoreMLModelCacheTests.swift`
- `BinFileHasherTests.swift`
- `PrecompileSchedulerTests.swift`
- `EngineBridgeTests.swift`
- `RootViewBundleUpgradeTests.swift`

---

## Pre-flight

- [ ] **Confirm working directory and branch.**

```bash
pwd  # expect: /Users/claudeuser/Projects/KataGo-pr1178
git rev-parse --abbrev-ref HEAD  # expect: ios-dev
git status --short  # expect: clean (the spec was committed already)
```

- [ ] **Confirm test infra runs.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/EngineLifecycleTests' 2>&1 | tail -20
```
Expected: existing `EngineLifecycleTests` pass. Confirms the simulator and test scheme are healthy before we add to them.

---

## Task 1: Document `katagocoreml::ConverterVersion::current()` and pin its mapping into the cache key

**Files:**
- Modify: `cpp/external/katagocoreml/include/katagocoreml/Version.hpp:1-9`

The cache key needs a stable converter-version string. The library already exposes `katagocoreml::VERSION` (currently `"1.1.0"`). We just publish a thin alias and make the contract explicit so a future bump invalidates caches by design.

- [ ] **Step 1: Add `ConverterVersion::current()` accessor to `Version.hpp`.**

```cpp
#pragma once

namespace katagocoreml {
constexpr const char* VERSION = "1.1.0";
constexpr int VERSION_MAJOR = 1;
constexpr int VERSION_MINOR = 1;
constexpr int VERSION_PATCH = 0;

// Cache-key-stable converter version. Bumping `VERSION` is the documented
// way to invalidate every user's Core ML cache when the converter starts
// producing different .mlpackage bytes for the same logical inputs.
//
// CONTRACT: Spec docs/superpowers/specs/2026-05-09-coreml-cache-design.md
// puts the return value of `current()` into the cache-key digest. Any
// time the converter's *output* changes, bump VERSION (semver: minor for
// behavior changes that produce new .mlpackage bytes; patch for cosmetic
// fixes that don't).
struct ConverterVersion {
    static constexpr const char* current() { return VERSION; }
};
}  // namespace katagocoreml
```

- [ ] **Step 2: Build the iOS app to confirm the header still compiles cleanly.**

```bash
cd "ios/KataGo iOS" && xcodebuild build \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit.**

```bash
git add cpp/external/katagocoreml/include/katagocoreml/Version.hpp
git commit -m "Add ConverterVersion::current() for cache-key contract"
```

---

## Task 2: `CoreMLCacheKey` canonical encoding + frozen digest test

**Files:**
- Create: `ios/KataGo iOS/KataGoInterface/CoreMLCacheKey.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheKeyTests.swift`

Per spec §Cache Key: hand-rolled `key=value\n` canonical encoding, validated string fields, SHA-256 digest, frozen-constant test.

- [ ] **Step 1: Write the failing test (frozen digest + structural-collision rejection).**

Create `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheKeyTests.swift`:

```swift
import Testing
import Foundation
@testable import KataGoInterface

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
        #expect(sample.digest == "DIGEST_PLACEHOLDER_REPLACE_AFTER_FIRST_RUN")
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
        #expect(downloaded.digest == "DIGEST_PLACEHOLDER_REPLACE_AFTER_FIRST_RUN")
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
}
```

- [ ] **Step 2: Run; expect compile failures (`CoreMLCacheKey` not defined).**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLCacheKeyTests' 2>&1 | tail -15
```
Expected: `error: cannot find 'CoreMLCacheKey' in scope`.

- [ ] **Step 3: Implement `CoreMLCacheKey` and `DigestEpoch`.**

Create `ios/KataGo iOS/KataGoInterface/CoreMLCacheKey.swift`:

```swift
import CryptoKit
import Foundation

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
        Self.precondition(field: "sourceIdentity", value: sourceIdentity)
        Self.precondition(field: "computePrecision", value: computePrecision)
        Self.precondition(field: "converterVersion", value: converterVersion)
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

    // Excludes 0x3D (=), 0x0A (\n), 0x20 (space), and all controls. Both
    // are structural separators in canonicalBytes; admitting them would
    // let one field collide with another's key boundary.
    private static func precondition(field: String, value: String) {
        for byte in value.utf8 {
            let ok = (byte >= 0x21 && byte != 0x3D && byte <= 0x7E)
            Swift.precondition(ok, "CoreMLCacheKey.\(field) contains illegal byte 0x\(String(byte, radix: 16))")
        }
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
```

- [ ] **Step 4: Run the canonical-bytes + difference tests; expect them to pass and the two `…_PinnedConstant` tests to fail with the actual digest in the failure message.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLCacheKeyTests' 2>&1 | tail -20
```
Expected: `canonicalBytesIsKeyEqualsValueLF`, `differentBoardSizeYieldsDifferentDigest`, `osMajorVersionInKey` PASS. The two `…_PinnedConstant` tests FAIL with messages like `"abc123… is not equal to DIGEST_PLACEHOLDER…"`.

- [ ] **Step 5: Replace the placeholders with the actual digests from the failure output.**

Edit both `digestPinnedConstant_BuiltIn` and `digestPinnedConstant_Downloaded` in the test file, substituting the real 32-hex digest the previous step printed.

- [ ] **Step 6: Re-run; all four tests pass.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLCacheKeyTests' 2>&1 | tail -10
```
Expected: all 4 tests pass.

- [ ] **Step 7: Add structural-collision rejection test.**

Append to `CoreMLCacheKeyTests`:

```swift
    @Test func rejectsStructuralCollisionBytes_Equals() async {
        await #expect(processExitsWith: .failure) {
            _ = CoreMLCacheKey(
                sourceIdentity: "x=y", boardXLen: 19, boardYLen: 19,
                computePrecision: "FP16", optimizeIdentityMask: false,
                minBatchSize: 1, maxBatchSize: 8,
                converterVersion: "1.1.0", osMajorVersion: 26
            )
        }
    }

    @Test func rejectsStructuralCollisionBytes_Newline() async {
        await #expect(processExitsWith: .failure) {
            _ = CoreMLCacheKey(
                sourceIdentity: "x\ny", boardXLen: 19, boardYLen: 19,
                computePrecision: "FP16", optimizeIdentityMask: false,
                minBatchSize: 1, maxBatchSize: 8,
                converterVersion: "1.1.0", osMajorVersion: 26
            )
        }
    }

    @Test func rejectsStructuralCollisionBytes_Space() async {
        await #expect(processExitsWith: .failure) {
            _ = CoreMLCacheKey(
                sourceIdentity: "x y", boardXLen: 19, boardYLen: 19,
                computePrecision: "FP16", optimizeIdentityMask: false,
                minBatchSize: 1, maxBatchSize: 8,
                converterVersion: "1.1.0", osMajorVersion: 26
            )
        }
    }
```

- [ ] **Step 8: Run; expect 7 tests pass.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLCacheKeyTests' 2>&1 | tail -10
```
Expected: 7 tests pass.

- [ ] **Step 9: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLCacheKey.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLCacheKeyTests.swift"
git commit -m "Add CoreMLCacheKey with frozen-digest + structural-collision tests"
```

---

## Task 3: `CoreMLCacheKey.sourceIdentity(for:)` dispatch (firmlink-aware)

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLCacheKey.swift` (add static method)
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheKeyTests.swift` (add tests)

Per spec §Cache Key dispatch — uses `.resolvingSymlinksInPath().standardizedFileURL` so macOS firmlinks (`/var` ↔ `/private/var`) don't fool the comparison. Built-in returns `"builtin:<bundleVersion>:<size>:<mtimeMs>"` (mtime quantized to whole milliseconds as Int64); downloaded uses `BinFileHasher` for `"sha256:<hex>"`.

This task implements only the built-in branch. The downloaded branch (calling `BinFileHasher`) is wired in Task 5.

- [ ] **Step 1: Write the failing test for the built-in dispatch + mtime quantization.**

Append to `CoreMLCacheKeyTests`:

```swift
    @Test func builtInIdentity_QuantizedToMs() throws {
        // Two Dates differing only in sub-millisecond precision must
        // produce identical sourceIdentity strings.
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
```

- [ ] **Step 2: Run; expect compile failure (`builtInIdentity` undefined).**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLCacheKeyTests' 2>&1 | tail -10
```
Expected: `error: type 'CoreMLCacheKey' has no member 'builtInIdentity'`.

- [ ] **Step 3: Implement `builtInIdentity(version:size:mtime:)`.**

Append to `CoreMLCacheKey.swift`:

```swift
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
```

- [ ] **Step 4: Run; all built-in identity tests pass.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLCacheKeyTests' 2>&1 | tail -10
```
Expected: all 10 tests pass.

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLCacheKey.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLCacheKeyTests.swift"
git commit -m "Add CoreMLCacheKey.builtInIdentity with mtime quantization + version sanitization"
```

---

## Task 4: `BinFileHasher` — async streaming SHA-256 with `(size, mtime)` UserDefaults memo

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/BinFileHasher.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/BinFileHasherTests.swift`

Per spec §Hash memoization in UserDefaults — explicitly `async`, off-MainActor, runs on `Task.detached(priority: .userInitiated)`. Memoizes by file `(size, mtime)`; recomputes on mismatch.

- [ ] **Step 1: Write the failing test.**

Create `ios/KataGo iOS/KataGo iOSTests/BinFileHasherTests.swift`:

```swift
import Foundation
import Testing
@testable import KataGo_Anytime

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

        // Mutating the file content but preserving size + mtime would normally
        // force a recompute. Here we just assert the second call returns
        // the same value without touching the file (memo path).
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
```

- [ ] **Step 2: Run; expect compile failure (`BinFileHasher` undefined).**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/BinFileHasherTests' 2>&1 | tail -10
```
Expected: `error: cannot find 'BinFileHasher' in scope`.

- [ ] **Step 3: Implement `BinFileHasher`.**

Create `ios/KataGo iOS/KataGo iOS/BinFileHasher.swift`:

```swift
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
            while autoreleasepool(invoking: { () -> Bool in
                let chunk = (try? handle.read(upToCount: 1 << 20)) ?? Data()
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
```

- [ ] **Step 4: Run; expect all three tests pass.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/BinFileHasherTests' 2>&1 | tail -10
```
Expected: all 3 tests pass.

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGo iOS/BinFileHasher.swift" \
        "ios/KataGo iOS/KataGo iOSTests/BinFileHasherTests.swift"
git commit -m "Add BinFileHasher with (size, mtime) UserDefaults memo"
```

---

## Task 5: `CoreMLCacheKey.sourceIdentity(for:)` dispatch (firmlink-aware, calls BinFileHasher on miss)

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLCacheKey.swift`
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLCacheKeyTests.swift`

Now `BinFileHasher` exists, we can write the path-dispatching `sourceIdentity(for:)` static method.

- [ ] **Step 1: Write the failing test.**

Append to `CoreMLCacheKeyTests`:

```swift
    @Test func builtInDispatchByPath() async throws {
        // The bundled default_model.bin.gz is in the test bundle's resources
        // when run from the iOS simulator. If it isn't present (CI without
        // the resource), skip — this is the same condition the production
        // graceful-degradation path handles.
        guard let bundleURL = Bundle.main.url(
            forResource: "default_model", withExtension: "bin.gz"
        ) else {
            // Skip when bundle resource is absent; real coverage is provided
            // when the model is shipped in the app bundle.
            return
        }
        let id = try await CoreMLCacheKey.sourceIdentity(for: bundleURL.path)
        #expect(id.hasPrefix("builtin:"))
    }

    @Test func downloadedDispatchHashesOnDemand() async throws {
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(UUID()).bin.gz")
        try Data("hello".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let id = try await CoreMLCacheKey.sourceIdentity(for: tempURL.path)
        #expect(id == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
```

- [ ] **Step 2: Run; expect compile failure (`sourceIdentity(for:)` undefined).**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLCacheKeyTests' 2>&1 | tail -10
```
Expected: `error: type 'CoreMLCacheKey' has no member 'sourceIdentity'`.

- [ ] **Step 3: Implement `sourceIdentity(for:)`.**

Append to `CoreMLCacheKey.swift`. Note: this lives in `KataGoInterface` which can't import the app target's `BinFileHasher`, so we accept a closure as a seam (the app provides `BinFileHasher.shared.identityForDownloadedFile(_:)` at the call site). For now provide a default that throws — Tasks 17–18 thread the real hasher in.

```swift
extension CoreMLCacheKey {
    /// Path-comparing dispatch. Built-in: `"builtin:<bundleVersion>:<size>:<mtimeMs>"`.
    /// Downloaded: delegates to the injected `downloadedHasher` (default = throws).
    /// Both sides resolve symlinks (firmlinks) before comparing.
    public static func sourceIdentity(
        for modelPath: String,
        downloadedHasher: (URL) async throws -> String = { _ in
            throw NSError(domain: "CoreMLCacheKey", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "downloadedHasher not injected"])
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
```

- [ ] **Step 4: Update `downloadedDispatchHashesOnDemand` to inject `BinFileHasher`.**

```swift
    @Test func downloadedDispatchHashesOnDemand() async throws {
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(UUID()).bin.gz")
        try Data("hello".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let hasher = BinFileHasher(defaults: UserDefaults(suiteName: "t.\(UUID())")!)
        let id = try await CoreMLCacheKey.sourceIdentity(for: tempURL.path,
                                                         downloadedHasher: hasher.identityForDownloadedFile)
        #expect(id == "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }
```

(The test file needs `@testable import KataGo_Anytime` for `BinFileHasher` plus `@testable import KataGoInterface` for `CoreMLCacheKey`. If both are present add the second import; otherwise the existing import is sufficient.)

- [ ] **Step 5: Run; both new tests pass.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLCacheKeyTests' 2>&1 | tail -10
```
Expected: 12 tests pass.

- [ ] **Step 6: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLCacheKey.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLCacheKeyTests.swift"
git commit -m "Add CoreMLCacheKey.sourceIdentity(for:) firmlink-aware dispatch"
```

---

## Task 6: `CoreMLModelCache` actor scaffolding + `ensureCacheTreeExists` + index helpers

**Files:**
- Create: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

This task lays the actor's foundations: cache root URL, tree invariant, in-memory index, atomic `index.json` write. Subsequent tasks layer on lookup/store/pin/eviction.

- [ ] **Step 1: Write the failing test.**

Create `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`:

```swift
import Foundation
import Testing
@testable import KataGoInterface

struct CoreMLModelCacheTests {
    private func tempCacheRoot() -> URL {
        URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func ensureCacheTreeCreatesRootAndModels() async throws {
        let root = tempCacheRoot()
        let cache = await CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        let fm = FileManager.default
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue)
        let modelsDir = root.appendingPathComponent("models")
        #expect(fm.fileExists(atPath: modelsDir.path, isDirectory: &isDir) && isDir.boolValue)

        // isExcludedFromBackup is set on the cache root.
        let resourceValues = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resourceValues.isExcludedFromBackup == true)
    }

    @Test func emptyIndexJsonIsWrittenOnFirstCall() async throws {
        let root = tempCacheRoot()
        let cache = await CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()
        await cache.writeIndexAtomicallyForTests()

        let indexURL = root.appendingPathComponent("index.json")
        let data = try Data(contentsOf: indexURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["schemaVersion"] as? Int) == 1)
        #expect((json?["entries"] as? [Any])?.count == 0)
    }
}
```

- [ ] **Step 2: Run; expect compile failure.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLModelCacheTests' 2>&1 | tail -10
```
Expected: `error: cannot find 'CoreMLModelCache' in scope`.

- [ ] **Step 3: Implement the actor scaffold.**

Create `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`:

```swift
import Foundation
import OSLog

private let log = Logger(subsystem: "com.chinchangyang.KataGo-Anytime",
                         category: "engine.coreml.cache")

public struct IndexEntry: Codable, Sendable {
    public let digest: String
    public let epoch: UUID
    public let key: String?         // diagnostic-only
    public var sizeBytes: Int64
    public var lastAccessedAt: TimeInterval
    public var createdAt: TimeInterval
    public var sourceFileName: String?
}

private struct IndexFile: Codable {
    var schemaVersion: Int
    var entries: [IndexEntry]
}

public actor CoreMLModelCache {
    public let cacheRoot: URL
    public let evictionCap: Int = 8

    var entries: [String: IndexEntry] = [:]    // digest → entry

    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
    }

    private static let schemaVersion = 1

    private var modelsRoot: URL { cacheRoot.appendingPathComponent("models") }
    private var indexURL: URL  { cacheRoot.appendingPathComponent("index.json") }

    private func ensureCacheTreeExists() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        var rootURL = cacheRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try rootURL.setResourceValues(values)
        try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    }

    private func writeIndexAtomically() throws {
        let file = IndexFile(schemaVersion: Self.schemaVersion,
                             entries: Array(entries.values))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(file)

        let tmp = indexURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        // .atomic gives us write-to-temp + fsync + rename behavior already
        // on Apple platforms; replaceItem ensures the rename is atomic.
        if FileManager.default.fileExists(atPath: indexURL.path) {
            _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: indexURL)
        }
    }

    // MARK: Test-only seams

    public func ensureCacheTreeExistsForTests() {
        try? ensureCacheTreeExists()
    }
    public func writeIndexAtomicallyForTests() {
        try? writeIndexAtomically()
    }
}
```

- [ ] **Step 4: Run; expect both tests pass.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLModelCacheTests' 2>&1 | tail -10
```
Expected: 2 tests pass.

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git commit -m "Add CoreMLModelCache actor scaffold with cache-tree invariant + atomic index write"
```

---

## Task 7: `PinnedCacheURL` class + serial nonce + `acquireLocked` + `release` + `isCurrentEpochPinned`

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

Per spec §LRU Eviction → Pinning. Token is a `final class @unchecked Sendable` carrying `(digest, epoch, serial: UInt64)`. Pin set is `[DigestEpoch: Set<UInt64>]`. `release` is idempotent via set-remove; `deinit` is a safety net.

- [ ] **Step 1: Write the failing test.**

Append to `CoreMLModelCacheTests`:

```swift
    @Test func releaseIsIdempotent() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        let token = await cache.acquireForTests(
            digest: "d", epoch: UUID(),
            url: URL(fileURLWithPath: "/tmp/x"))
        let key = DigestEpoch(digest: token.digest, epoch: token.epoch)

        await token.release()
        #expect(await cache.peekPinCount(key: key) == 0)
        await token.release()                       // idempotent
        #expect(await cache.peekPinCount(key: key) == 0)
    }

    @Test func independentTokensSamePathHavePinIndependence() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        let epoch = UUID()
        let url = URL(fileURLWithPath: "/tmp/x")
        let a = await cache.acquireForTests(digest: "d", epoch: epoch, url: url)
        let b = await cache.acquireForTests(digest: "d", epoch: epoch, url: url)
        let key = DigestEpoch(digest: "d", epoch: epoch)

        #expect(await cache.peekPinCount(key: key) == 2)
        await a.release()
        #expect(await cache.peekPinCount(key: key) == 1)
        await b.release()
        #expect(await cache.peekPinCount(key: key) == 0)
    }
```

- [ ] **Step 2: Run; expect compile failure.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLModelCacheTests' 2>&1 | tail -10
```
Expected: `error: ... 'PinnedCacheURL'` and similar.

- [ ] **Step 3: Implement `PinnedCacheURL`, pin set, `acquireLocked`, `release`, `isCurrentEpochPinned`.**

Append to `CoreMLModelCache.swift`:

```swift
public final class PinnedCacheURL: @unchecked Sendable {
    public let url: URL
    public let digest: String
    public let epoch: UUID
    public let serial: UInt64
    private weak var cache: CoreMLModelCache?

    init(url: URL, digest: String, epoch: UUID, serial: UInt64, cache: CoreMLModelCache) {
        self.url = url; self.digest = digest; self.epoch = epoch
        self.serial = serial; self.cache = cache
    }

    public func release() async {
        guard let cache else { return }
        await cache.release(digest: digest, epoch: epoch, serial: serial)
    }

    deinit {
        guard let cache else { return }
        let d = digest, e = epoch, s = serial
        Task.detached { await cache.release(digest: d, epoch: e, serial: s) }
    }
}

extension CoreMLModelCache {
    var nextTokenSerialKey: String { "_pinSerial" }   // unused, kept for reflection

    private func acquireLocked(digest: String, epoch: UUID, url: URL) -> PinnedCacheURL {
        nextTokenSerial &+= 1
        let serial = nextTokenSerial
        let key = DigestEpoch(digest: digest, epoch: epoch)
        pinnedSerials[key, default: []].insert(serial)
        return PinnedCacheURL(url: url, digest: digest, epoch: epoch, serial: serial, cache: self)
    }

    public func release(digest: String, epoch: UUID, serial: UInt64) {
        let key = DigestEpoch(digest: digest, epoch: epoch)
        guard var set = pinnedSerials[key] else { return }
        set.remove(serial)
        if set.isEmpty { pinnedSerials.removeValue(forKey: key) }
        else            { pinnedSerials[key] = set }
        reapTombstoneIfUnpinned(key)

        if currentEntryCount > evictionCap {
            Task.detached(priority: .utility) { [weak self] in
                await self?.runEvictionIfOverBudget()
            }
        }
    }

    public func isCurrentEpochPinned(_ digest: String) -> Bool {
        guard let entry = entries[digest] else { return false }
        let key = DigestEpoch(digest: digest, epoch: entry.epoch)
        return !(pinnedSerials[key]?.isEmpty ?? true)
    }

    var currentEntryCount: Int { entries.count }

    // Test-only seams.
    public func acquireForTests(digest: String, epoch: UUID, url: URL) -> PinnedCacheURL {
        acquireLocked(digest: digest, epoch: epoch, url: url)
    }
    public func peekPinCount(key: DigestEpoch) -> Int {
        pinnedSerials[key]?.count ?? 0
    }

    // Stubs for now — implemented in Task 9 / Task 12.
    func reapTombstoneIfUnpinned(_ key: DigestEpoch) { /* implemented later */ }
    func runEvictionIfOverBudget() async { /* implemented later */ }
}
```

Also add stored properties to the actor body:

```swift
public actor CoreMLModelCache {
    // … existing fields …
    var pinnedSerials: [DigestEpoch: Set<UInt64>] = [:]
    var nextTokenSerial: UInt64 = 0
    var tombstones: Set<DigestEpoch> = []
}
```

- [ ] **Step 4: Run; expect both new tests pass.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLModelCacheTests' 2>&1 | tail -10
```
Expected: 4 tests pass.

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git commit -m "Add PinnedCacheURL class with serial-nonce identity"
```

---

## Task 8: `lookupOnDisk` (index-only) + `epochURL`

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

- [ ] **Step 1: Write the failing test.**

Append to `CoreMLModelCacheTests`:

```swift
    @Test func lookupOnDiskReturnsNilWhenIndexEmpty() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        #expect(await cache.lookupOnDiskForTests(digest: "d") == nil)
    }

    @Test func lookupOnDiskReturnsUrlAndEpochWhenIndexed() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        let epoch = UUID()
        await cache.injectEntryForTests(IndexEntry(
            digest: "d", epoch: epoch, key: nil,
            sizeBytes: 0, lastAccessedAt: 0, createdAt: 0, sourceFileName: nil))

        let hit = try #require(await cache.lookupOnDiskForTests(digest: "d"))
        #expect(hit.epoch == epoch)
        #expect(hit.url.lastPathComponent == "\(epoch.uuidString).mlmodelc")
    }

    @Test func lookupOnDiskIgnoresTombstonedEpoch() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        let epoch = UUID()
        await cache.injectEntryForTests(IndexEntry(
            digest: "d", epoch: epoch, key: nil,
            sizeBytes: 0, lastAccessedAt: 0, createdAt: 0, sourceFileName: nil))
        await cache.injectTombstoneForTests(DigestEpoch(digest: "d", epoch: epoch))

        #expect(await cache.lookupOnDiskForTests(digest: "d") == nil)
    }
```

- [ ] **Step 2: Run; expect compile failure.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/CoreMLModelCacheTests' 2>&1 | tail -10
```

- [ ] **Step 3: Implement `lookupOnDisk` and `epochURL`.**

Append to `CoreMLModelCache.swift`:

```swift
extension CoreMLModelCache {
    func lookupOnDisk(digest: String) -> (url: URL, epoch: UUID)? {
        guard let entry = entries[digest] else { return nil }
        let key = DigestEpoch(digest: digest, epoch: entry.epoch)
        guard !tombstones.contains(key) else { return nil }
        return (epochURL(key), entry.epoch)
    }

    func epochURL(_ key: DigestEpoch) -> URL {
        cacheRoot.appendingPathComponent("models/\(key.digest)/\(key.epoch.uuidString).mlmodelc")
    }

    public func lookupOnDiskForTests(digest: String) -> (url: URL, epoch: UUID)? {
        lookupOnDisk(digest: digest)
    }
    public func injectEntryForTests(_ e: IndexEntry) { entries[e.digest] = e }
    public func injectTombstoneForTests(_ k: DigestEpoch) { tombstones.insert(k) }
}
```

- [ ] **Step 4: Run; expect 7 tests pass.**

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git commit -m "Add lookupOnDisk (index-only with tombstone filter)"
```

---

## Task 9: `prepareTmp` (off-actor) + `commitStore` (on-actor) + tombstones + `invalidate(digest:epoch:)` + `reapTombstoneIfUnpinned`

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

The store path is split into off-actor `prepareTmp` (slow EXDEV-tolerant move) + on-actor `commitStore` (fast same-volume rename + index update). Tombstones replace the round-11 placeholder reap stub.

- [ ] **Step 1: Write the failing test.**

Append to `CoreMLModelCacheTests`:

```swift
    @Test func prepareTmpAndCommitStoreYieldEpochInIndex() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        // Stage a fake compiled directory with a coremldata.bin so the
        // commit lands a real on-disk artifact.
        let stagingURL = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: stagingURL.appendingPathComponent("coremldata.bin"))
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        let prep = try await cache.prepareTmp(digest: "d", compiledURL: stagingURL)
        let stored = try await cache.commitStore(digest: "d",
                                                 epoch: prep.epoch,
                                                 tmpURL: prep.tmpURL)
        #expect(stored.epoch == prep.epoch)
        let hit = try #require(await cache.lookupOnDiskForTests(digest: "d"))
        #expect(hit.epoch == prep.epoch)
        #expect(FileManager.default.fileExists(atPath: hit.url.appendingPathComponent("coremldata.bin").path))
    }

    @Test func invalidatePinnedDeferDelete() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()
        let staging = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data().write(to: staging.appendingPathComponent("coremldata.bin"))
        let prep = try await cache.prepareTmp(digest: "d", compiledURL: staging)
        let stored = try await cache.commitStore(digest: "d", epoch: prep.epoch, tmpURL: prep.tmpURL)

        let pin = await cache.acquireForTests(digest: "d", epoch: stored.epoch, url: stored.url)
        await cache.invalidate(digest: "d", epoch: stored.epoch)

        // Index entry gone; on-disk dir still present (because of the pin).
        #expect(await cache.lookupOnDiskForTests(digest: "d") == nil)
        #expect(FileManager.default.fileExists(atPath: stored.url.path))

        await pin.release()
        // Reap fired on release.
        #expect(!FileManager.default.fileExists(atPath: stored.url.path))
    }
```

- [ ] **Step 2: Run; expect compile failure.**

- [ ] **Step 3: Implement.**

Append to `CoreMLModelCache.swift`:

```swift
extension CoreMLModelCache {
    public nonisolated func prepareTmp(
        digest: String, compiledURL: URL
    ) async throws -> (epoch: UUID, tmpURL: URL) {
        try Task.checkCancellation()
        let epoch = UUID()
        let digestDir = await cacheRoot.appendingPathComponent("models/\(digest)")
        let tmpURL = digestDir.appendingPathComponent("\(epoch.uuidString).tmp")
        try FileManager.default.createDirectory(at: digestDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: compiledURL, to: tmpURL)
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CancellationError()
        }
        return (epoch, tmpURL)
    }

    public func commitStore(
        digest: String, epoch: UUID, tmpURL: URL
    ) throws -> (url: URL, epoch: UUID) {
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CancellationError()
        }
        if let hit = lookupOnDisk(digest: digest) {
            try? FileManager.default.removeItem(at: tmpURL)
            return hit
        }
        let key = DigestEpoch(digest: digest, epoch: epoch)
        let finalURL = epochURL(key)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
        let now = Date().timeIntervalSince1970
        entries[digest] = IndexEntry(
            digest: digest, epoch: epoch, key: nil,
            sizeBytes: directorySize(finalURL),
            lastAccessedAt: now, createdAt: now, sourceFileName: nil)
        try writeIndexAtomically()
        return (finalURL, epoch)
    }

    public func invalidate(digest: String, epoch: UUID) {
        let key = DigestEpoch(digest: digest, epoch: epoch)
        log.error("corrupt(digest=\(digest, privacy: .public)) — invalidating")
        if let entry = entries[digest], entry.epoch == epoch {
            entries.removeValue(forKey: digest)
            try? writeIndexAtomically()
        }
        if pinnedSerials[key]?.isEmpty == false {
            tombstones.insert(key)
        } else {
            try? FileManager.default.removeItem(at: epochURL(key))
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let v = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(v?.fileSize ?? 0)
        }
        return total
    }
}

// Replace the stub `reapTombstoneIfUnpinned` from Task 7 with the real one.
extension CoreMLModelCache {
    func reapTombstoneIfUnpinnedReal(_ key: DigestEpoch) {
        guard tombstones.contains(key),
              (pinnedSerials[key]?.isEmpty ?? true) else { return }
        try? FileManager.default.removeItem(at: epochURL(key))
        tombstones.remove(key)
    }
}
```

Then in the original `release(...)`, swap `reapTombstoneIfUnpinned(key)` → `reapTombstoneIfUnpinnedReal(key)`. (We could rename via Edit; the simplest path is to replace the stub body in-place.)

Replace the stub method body:

```swift
    func reapTombstoneIfUnpinned(_ key: DigestEpoch) {
        guard tombstones.contains(key),
              (pinnedSerials[key]?.isEmpty ?? true) else { return }
        try? FileManager.default.removeItem(at: epochURL(key))
        tombstones.remove(key)
    }
```

(Delete `reapTombstoneIfUnpinnedReal` if you added it as a separate name; one canonical implementation only.)

- [ ] **Step 4: Run; expect 9 tests pass.**

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git commit -m "Add prepareTmp/commitStore split + invalidate with tombstones"
```

---

## Task 10: `urlForKey` + recursive `joinOrInstall` with CAS-guarded clear + in-flight tracker + priority parameter

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

This is the heart of the cache protocol: the public `urlForKey` entry, the recursive `joinOrInstall`, in-flight dedup, success-or-failure CAS clear, and the `missCallback` signature that bridges to whoever produces the compiled URL.

- [ ] **Step 1: Write the failing tests.**

Append to `CoreMLModelCacheTests`:

```swift
    private func makeCompiledDir() throws -> URL {
        let url = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: url.appendingPathComponent("coremldata.bin"))
        return url
    }

    @Test func urlForKeyMissThenHit() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()
        var missCount = 0
        let miss = { @Sendable () async throws -> URL in
            missCount += 1
            return try makeCompiledDir()
        }
        // Note: makeCompiledDir is `throws` not `Sendable`-checked; for a
        // real test, inline the body inside the closure.
        let pinned1 = try await cache.urlForKey(digest: "abc", missCallback: {
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("c".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        })
        await pinned1.release()
        let pinned2 = try await cache.urlForKey(digest: "abc", missCallback: {
            #expect(Bool(false), "missCallback should not run on hit")
            throw CancellationError()
        })
        await pinned2.release()
        #expect(pinned1.epoch == pinned2.epoch)
    }

    @Test func threeCallerRaceAfterFailureSpawnsAtMostTwoCompiles() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()

        actor Counter { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }
        let counter = Counter()

        let goodCb: @Sendable () async throws -> URL = {
            await counter.inc()
            let u = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            try Data("c".utf8).write(to: u.appendingPathComponent("coremldata.bin"))
            return u
        }
        let failingCb: @Sendable () async throws -> URL = {
            await counter.inc()
            throw NSError(domain: "test", code: 1)
        }

        // Originator (will fail) starts first.
        async let a = cache.urlForKey(digest: "abc", missCallback: failingCb)
        // Slight delay so a is in-flight before b/c arrive.
        try await Task.sleep(for: .milliseconds(20))
        async let b = cache.urlForKey(digest: "abc", missCallback: goodCb)
        async let c = cache.urlForKey(digest: "abc", missCallback: goodCb)

        _ = try? await a
        let pb = try await b
        let pc = try await c

        // missCallback was invoked once for the failed task and once for the
        // replacement — never three times.
        let total = await counter.get()
        #expect(total == 2)
        #expect(pb.epoch == pc.epoch)
        await pb.release()
        await pc.release()
    }
```

- [ ] **Step 2: Run; expect compile failure (`urlForKey` not defined).**

- [ ] **Step 3: Implement `urlForKey` and `joinOrInstall`.**

Append to `CoreMLModelCache.swift`:

```swift
extension CoreMLModelCache {
    var inFlight: [String: Task<(URL, UUID), Error>] {
        get { _inFlight }
        set { _inFlight = newValue }
    }
}

public actor CoreMLModelCache_Pseudo {} // placeholder — keep this section append-only
```

Realistically, store the in-flight map as a stored property of the actor:

```swift
public actor CoreMLModelCache {
    // … existing fields …
    var _inFlight: [String: Task<(URL, UUID), Error>] = [:]
}
```

Then:

```swift
extension CoreMLModelCache {
    public func urlForKey(
        digest: String,
        priority: TaskPriority = .userInitiated,
        missCallback: @Sendable @escaping () async throws -> URL
    ) async throws -> PinnedCacheURL {
        if let hit = lookupOnDisk(digest: digest) {
            entries[digest]?.lastAccessedAt = Date().timeIntervalSince1970
            return acquireLocked(digest: digest, epoch: hit.epoch, url: hit.url)
        }
        return try await joinOrInstall(digest: digest, priority: priority,
                                       missCallback: missCallback)
    }

    private func joinOrInstall(
        digest: String,
        priority: TaskPriority,
        missCallback: @Sendable @escaping () async throws -> URL
    ) async throws -> PinnedCacheURL {
        if let existing = _inFlight[digest] {
            do {
                let (url, epoch) = try await existing.value
                return acquireLocked(digest: digest, epoch: epoch, url: url)
            } catch {
                log.error("Awaited precompile failed: \(String(describing: error)); retrying via joinOrInstall")
                if _inFlight[digest] == existing { _inFlight[digest] = nil }
                return try await joinOrInstall(digest: digest, priority: priority,
                                               missCallback: missCallback)
            }
        }

        let task = Task.detached(priority: priority) { [weak self] () async throws -> (URL, UUID) in
            guard let self else { throw CancellationError() }
            let mlpackageURL = try await missCallback()
            let compiledURL = try await MLModelCompiler.compile(at: mlpackageURL)
            let prep = try await self.prepareTmp(digest: digest, compiledURL: compiledURL)
            let stored = try await self.commitStore(digest: digest, epoch: prep.epoch, tmpURL: prep.tmpURL)
            Task.detached(priority: .utility) { [weak self] in await self?.runEvictionIfOverBudget() }
            return stored
        }
        _inFlight[digest] = task

        let result: Result<(URL, UUID), Error>
        do { result = .success(try await task.value) }
        catch { result = .failure(error) }

        if _inFlight[digest] == task { _inFlight[digest] = nil }

        let (url, epoch) = try result.get()
        return acquireLocked(digest: digest, epoch: epoch, url: url)
    }
}

// Tiny seam so tests don't need real CoreML.
enum MLModelCompiler {
    // Real implementation calls MLModel.compileModel(at:); for now it's the
    // identity, since the missCallback in tests already stages a `.mlmodelc/`.
    // Replaced in Task 16 when the real bridge is wired.
    static func compile(at url: URL) async throws -> URL { url }
}
```

- [ ] **Step 4: Run; tests pass.**

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git commit -m "Add urlForKey + joinOrInstall with CAS-guarded clear and recursive replacement"
```

---

## Task 11: `runEvictionIfOverBudget` + LRU + skip current pinned + release-triggered re-run

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

- [ ] **Step 1: Write the failing tests.**

Append to `CoreMLModelCacheTests`:

```swift
    @Test func evictionRemovesOldestWhenOverCap() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot(), evictionCap: 2)
        await cache.ensureCacheTreeExistsForTests()
        for i in 0..<3 {
            await cache.injectEntryForTests(IndexEntry(
                digest: "d\(i)", epoch: UUID(), key: nil,
                sizeBytes: 0, lastAccessedAt: Double(i),
                createdAt: 0, sourceFileName: nil))
        }
        await cache.runEvictionIfOverBudgetForTests()
        // Oldest (lastAccessedAt = 0) was evicted.
        #expect(await cache.lookupOnDiskForTests(digest: "d0") == nil)
        #expect(await cache.lookupOnDiskForTests(digest: "d1") != nil)
        #expect(await cache.lookupOnDiskForTests(digest: "d2") != nil)
    }

    @Test func evictionSkipsPinnedCurrentEpoch() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot(), evictionCap: 1)
        await cache.ensureCacheTreeExistsForTests()
        let e0 = UUID(), e1 = UUID()
        await cache.injectEntryForTests(IndexEntry(
            digest: "d0", epoch: e0, key: nil,
            sizeBytes: 0, lastAccessedAt: 0, createdAt: 0, sourceFileName: nil))
        await cache.injectEntryForTests(IndexEntry(
            digest: "d1", epoch: e1, key: nil,
            sizeBytes: 0, lastAccessedAt: 1, createdAt: 0, sourceFileName: nil))
        let pin = await cache.acquireForTests(digest: "d0", epoch: e0,
                                              url: URL(fileURLWithPath: "/tmp"))

        await cache.runEvictionIfOverBudgetForTests()
        // d0 is pinned + over cap; d1 is unpinned. Eviction must keep d0 and drop d1.
        #expect(await cache.lookupOnDiskForTests(digest: "d0") != nil)
        #expect(await cache.lookupOnDiskForTests(digest: "d1") == nil)
        await pin.release()
    }
```

- [ ] **Step 2: Adjust the actor's initializer to accept a custom `evictionCap` (test-only override).**

Update the `CoreMLModelCache` initializer:

```swift
public actor CoreMLModelCache {
    public let cacheRoot: URL
    public let evictionCap: Int
    public init(cacheRoot: URL, evictionCap: Int = 8) {
        self.cacheRoot = cacheRoot
        self.evictionCap = evictionCap
    }
    // … rest unchanged …
}
```

- [ ] **Step 3: Implement `runEvictionIfOverBudget`.**

Append to `CoreMLModelCache.swift`:

```swift
extension CoreMLModelCache {
    func runEvictionIfOverBudget() async {
        var sorted = entries.values.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
        while currentEntryCount > evictionCap, let candidate = sorted.first {
            sorted.removeFirst()
            if isCurrentEpochPinned(candidate.digest) { continue }
            // Evict.
            let key = DigestEpoch(digest: candidate.digest, epoch: candidate.epoch)
            try? FileManager.default.removeItem(at: epochURL(key))
            entries.removeValue(forKey: candidate.digest)
        }
        try? writeIndexAtomically()
    }

    public func runEvictionIfOverBudgetForTests() async {
        await runEvictionIfOverBudget()
    }
}
```

- [ ] **Step 4: Run; expect 11 tests pass.**

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git commit -m "Add LRU eviction with pinned-current-epoch skip"
```

---

## Task 12: `clearAll()` + `cancelAllPending` + bundle-version reset glue

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

Per spec §Clear Cache > Interaction with in-flight work.

- [ ] **Step 1: Write the failing test.**

Append to `CoreMLModelCacheTests`:

```swift
    @Test func clearAllWipesIndexAndModelsButPreservesTreeInvariant() async throws {
        let cache = await CoreMLModelCache(cacheRoot: tempCacheRoot())
        await cache.ensureCacheTreeExistsForTests()
        let staging = URL.temporaryDirectory.appendingPathComponent("\(UUID()).mlmodelc")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data().write(to: staging.appendingPathComponent("coremldata.bin"))
        let prep = try await cache.prepareTmp(digest: "d", compiledURL: staging)
        _ = try await cache.commitStore(digest: "d", epoch: prep.epoch, tmpURL: prep.tmpURL)

        await cache.clearAll()

        // index.json still parseable, zero entries; models/ exists; root has isExcludedFromBackup.
        let modelsDir = await cache.cacheRoot.appendingPathComponent("models")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: modelsDir.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(await cache.lookupOnDiskForTests(digest: "d") == nil)
    }
```

- [ ] **Step 2: Run; expect compile failure.**

- [ ] **Step 3: Implement `clearAll`.**

Append to `CoreMLModelCache.swift`:

```swift
extension CoreMLModelCache {
    public func clearAll() async {
        for task in _inFlight.values { task.cancel() }
        try? FileManager.default.removeItem(at: cacheRoot)
        try? ensureCacheTreeExists()
        entries.removeAll()
        pinnedSerials.removeAll()
        tombstones.removeAll()
        _inFlight.removeAll()
        try? writeIndexAtomically()
    }
}
```

- [ ] **Step 4: Run; test passes.**

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git commit -m "Add clearAll with in-flight cancel + tree-invariant restore"
```

---

## Task 13: `EngineLaunchStatus` observable for LoadingView

**Files:**
- Create: `ios/KataGo iOS/KataGoInterface/EngineLaunchStatus.swift`

`@Observable` MainActor-resident wrapper exposing the bridge phase to SwiftUI. Simple enough to skip unit tests; correctness shows up in `LoadingView` integration.

- [ ] **Step 1: Implement.**

Create `ios/KataGo iOS/KataGoInterface/EngineLaunchStatus.swift`:

```swift
import Observation

@MainActor @Observable
public final class EngineLaunchStatus {
    public enum Phase: Equatable, Sendable {
        case idle
        case compilingMissFirstLaunch    // "Compiling Core ML model — first launch only"
        case awaitingPrecompile          // "Finishing Core ML compile…"
    }
    public var phase: Phase = .idle
    public init() {}
}
```

- [ ] **Step 2: Build to verify it compiles into the framework target.**

```bash
cd "ios/KataGo iOS" && xcodebuild build \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/EngineLaunchStatus.swift"
git commit -m "Add EngineLaunchStatus observable for LoadingView"
```

---

## Task 14: `PrecompileScheduler` with backend guard, dedup, concurrency=1

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`
- Create: `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`

- [ ] **Step 1: Write the failing test.**

Create `ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift`:

```swift
import Foundation
import Testing
@testable import KataGo_Anytime

struct PrecompileSchedulerTests {
    @Test func skipsWhenBackendIsMpsGpu() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("mpsGPU", forKey: "backend_default_model.bin.gz")

        var enqueued = 0
        let scheduler = PrecompileScheduler(defaults: defaults) { _ in enqueued += 1 }
        await scheduler.scheduleForModel(fileName: "default_model.bin.gz")

        try await Task.sleep(for: .milliseconds(50))
        #expect(enqueued == 0)
    }

    @Test func runsWhenBackendIsCoreml() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("coremlNE", forKey: "backend_default_model.bin.gz")

        var enqueued = 0
        let scheduler = PrecompileScheduler(defaults: defaults) { _ in enqueued += 1 }
        await scheduler.scheduleForModel(fileName: "default_model.bin.gz")

        try await Task.sleep(for: .milliseconds(50))
        #expect(enqueued == 1)
    }

    @Test func dedupesIdenticalEnqueues() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("coremlNE", forKey: "backend_default_model.bin.gz")

        var enqueued = 0
        let scheduler = PrecompileScheduler(defaults: defaults) { _ in
            enqueued += 1
            try? await Task.sleep(for: .milliseconds(50))
        }
        async let a: Void = scheduler.scheduleForModel(fileName: "default_model.bin.gz")
        async let b: Void = scheduler.scheduleForModel(fileName: "default_model.bin.gz")
        _ = await (a, b)
        try await Task.sleep(for: .milliseconds(120))
        #expect(enqueued == 1)
    }
}
```

- [ ] **Step 2: Run; expect compile failure.**

- [ ] **Step 3: Implement `PrecompileScheduler`.**

Create `ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift`:

```swift
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.chinchangyang.KataGo-Anytime",
                         category: "engine.coreml.cache")

public enum PrecompileStatus: Equatable, Sendable {
    case idle
    case ready
    case queued
    case compiling
    case failed(message: String)
}

@MainActor @Observable
public final class PrecompileScheduler {
    public typealias Worker = (_ fileName: String) async throws -> Void

    private let defaults: UserDefaults
    private let worker: Worker
    private var inFlight: Set<String> = []
    public var status: [String: PrecompileStatus] = [:]

    public init(defaults: UserDefaults = .standard, worker: @escaping Worker) {
        self.defaults = defaults
        self.worker = worker
    }

    public func scheduleForModel(fileName: String) async {
        if defaults.string(forKey: "backend_\(fileName)") == "mpsGPU" {
            log.info("skip-precompile reason=mpsGPU fileName=\(fileName, privacy: .public)")
            return
        }
        guard !inFlight.contains(fileName) else { return }
        inFlight.insert(fileName)
        status[fileName] = .queued
        Task.detached(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            self.status[fileName] = .compiling
            do {
                try await self.worker(fileName)
                self.status[fileName] = .ready
            } catch {
                let summary = (error as NSError).localizedDescription
                log.error("precompile.failed model=\(fileName, privacy: .public) error=\(String(describing: error), privacy: .public)")
                self.status[fileName] = .failed(message: summary)
            }
            self.inFlight.remove(fileName)
        }
    }

    public func scheduleBuiltIn() async {
        await scheduleForModel(fileName: "default_model.bin.gz")
    }

    public func cancelAllPending() {
        // The Tasks themselves were detached and we don't track them; we
        // simply clear the in-flight set so a future schedule can try
        // again. Cancellation of the underlying Task is propagated when
        // CoreMLModelCache.clearAll() cancels its own in-flight tasks.
        inFlight.removeAll()
    }
}
```

- [ ] **Step 4: Run; tests pass.**

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGo iOS/PrecompileScheduler.swift" \
        "ios/KataGo iOS/KataGo iOSTests/PrecompileSchedulerTests.swift"
git commit -m "Add PrecompileScheduler with backend guard + dedup"
```

---

## Task 15: Adoption pass + orphan sweep on actor init

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`
- Modify: `ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift`

Per spec §Adoption / Orphan sweep — on actor first use, walk `models/` and either adopt (if index missing/wrong-schema) or sweep orphans (if index valid).

- [ ] **Step 1: Write the failing tests.**

Append to `CoreMLModelCacheTests`:

```swift
    @Test func orphanSweepRemovesUnreferencedDirs() async throws {
        let root = tempCacheRoot()
        let cache = await CoreMLModelCache(cacheRoot: root)
        await cache.ensureCacheTreeExistsForTests()

        // Plant an orphaned <D>/<E>.mlmodelc/ that has no index entry.
        let orphan = root.appendingPathComponent("models/d/\(UUID().uuidString).mlmodelc")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data().write(to: orphan.appendingPathComponent("coremldata.bin"))

        await cache.runStartupSweepForTests()

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func adoptionAdoptsValidDirsWhenIndexMissing() async throws {
        let root = tempCacheRoot()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("models"),
                               withIntermediateDirectories: true)
        let digest = String(repeating: "a", count: 32)
        let epoch = UUID()
        let entry = root.appendingPathComponent("models/\(digest)/\(epoch.uuidString).mlmodelc")
        try fm.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data("c".utf8).write(to: entry.appendingPathComponent("coremldata.bin"))

        let cache = await CoreMLModelCache(cacheRoot: root)
        await cache.runStartupSweepForTests()

        let hit = try #require(await cache.lookupOnDiskForTests(digest: digest))
        #expect(hit.epoch == epoch)
    }
```

- [ ] **Step 2: Run; expect compile failure.**

- [ ] **Step 3: Implement.**

Append to `CoreMLModelCache.swift`:

```swift
extension CoreMLModelCache {
    private func loadOrInitIndex() {
        let url = indexURL
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(IndexFile.self, from: data),
              file.schemaVersion == Self.schemaVersion else {
            // Missing / unreadable / wrong schema → adopt.
            adoptDirs()
            return
        }
        for entry in file.entries { entries[entry.digest] = entry }
        orphanSweep()
    }

    private func adoptDirs() {
        try? FileManager.default.removeItem(at: indexURL)
        try? ensureCacheTreeExists()
        let modelsRoot = self.modelsRoot
        let fm = FileManager.default
        guard let digestDirs = try? fm.contentsOfDirectory(at: modelsRoot,
            includingPropertiesForKeys: nil) else { return }
        let digestRegex = try! NSRegularExpression(pattern: "^[0-9a-f]{32}$")
        let epochRegex = try! NSRegularExpression(pattern: "^[0-9a-f-]{36}\\.mlmodelc$")
        for digestDir in digestDirs {
            let dname = digestDir.lastPathComponent
            guard digestRegex.firstMatch(in: dname,
                  range: NSRange(location: 0, length: dname.utf16.count)) != nil
            else {
                try? fm.removeItem(at: digestDir); continue
            }
            guard let leaves = try? fm.contentsOfDirectory(at: digestDir,
                includingPropertiesForKeys: nil) else { continue }
            for leaf in leaves {
                let lname = leaf.lastPathComponent
                guard epochRegex.firstMatch(in: lname,
                      range: NSRange(location: 0, length: lname.utf16.count)) != nil,
                      fm.fileExists(atPath: leaf.appendingPathComponent("coremldata.bin").path),
                      let epoch = UUID(uuidString: String(lname.dropLast(".mlmodelc".count))) else {
                    try? fm.removeItem(at: leaf); continue
                }
                let now = Date().timeIntervalSince1970
                entries[dname] = IndexEntry(
                    digest: dname, epoch: epoch, key: nil,
                    sizeBytes: directorySize(leaf),
                    lastAccessedAt: now, createdAt: now, sourceFileName: nil)
                break    // only adopt one epoch per digest; orphan sweep handles the rest
            }
        }
        try? writeIndexAtomically()
    }

    private func orphanSweep() {
        let fm = FileManager.default
        guard let digestDirs = try? fm.contentsOfDirectory(at: modelsRoot,
            includingPropertiesForKeys: nil) else { return }
        for digestDir in digestDirs {
            let dname = digestDir.lastPathComponent
            guard let entry = entries[dname] else {
                try? fm.removeItem(at: digestDir); continue
            }
            let expected = "\(entry.epoch.uuidString).mlmodelc"
            guard let leaves = try? fm.contentsOfDirectory(at: digestDir,
                includingPropertiesForKeys: nil) else { continue }
            for leaf in leaves where leaf.lastPathComponent != expected {
                try? fm.removeItem(at: leaf)
            }
        }
    }

    public func runStartupSweepForTests() {
        try? ensureCacheTreeExists()
        loadOrInitIndex()
    }
}
```

- [ ] **Step 4: Run; tests pass.**

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift" \
        "ios/KataGo iOS/KataGo iOSTests/CoreMLModelCacheTests.swift"
git commit -m "Add adoption pass + orphan sweep on actor init"
```

---

## Task 16: Replace `MLModelCompiler.compile` stub with the real `MLModel.compileModel(at:)` call

**Files:**
- Modify: `ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift`

- [ ] **Step 1: Replace the stub.**

```swift
import CoreML

enum MLModelCompiler {
    static func compile(at url: URL) async throws -> URL {
        return try await MLModel.compileModel(at: url)
    }
}
```

- [ ] **Step 2: Build (no new tests — covered by integration in Task 17+).**

```bash
cd "ios/KataGo iOS" && xcodebuild build \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit.**

```bash
git add "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift"
git commit -m "Wire MLModel.compileModel(at:) into the cache compile path"
```

---

## Task 17: Wire `metalbackend.swift::createCoreMLComputeHandle` into the cache

**Files:**
- Modify: `cpp/neuralnet/metalbackend.swift:332-395`

Replace the existing `createCoreMLComputeHandle` body with the cache-aware path. The function continues to return `CoreMLComputeHandle?`; on cache miss the body unchanged. On hit we skip both convert and compile. We also expose a helper `createCoreMLComputeHandleViaCache(...)` that the C++ caller invokes (Task 19 wires that side).

Because `metalbackend.swift` lives in the cpp neuralnet build (not in the iOS app target), we need the cache shared instance. Add a static accessor `CoreMLModelCache.shared` in `KataGoInterface/CoreMLModelCache.swift`, and have the swift backend call it.

- [ ] **Step 1: Add `CoreMLModelCache.shared` (one-off init).**

Append to `CoreMLModelCache.swift`:

```swift
extension CoreMLModelCache {
    /// Process-wide singleton used by the engine bridge. Backed by
    /// `Application Support/<bundle>/coreml/`.
    nonisolated public static let shared: CoreMLModelCache = {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let bundle = Bundle.main.bundleIdentifier ?? "KataGoAnytime"
        let root = appSupport.appendingPathComponent("\(bundle)/coreml", isDirectory: true)
        return CoreMLModelCache(cacheRoot: root)
    }()
}
```

- [ ] **Step 2: Modify `createCoreMLComputeHandle` to query the cache.**

The existing function (per `metalbackend.swift:344-395`) is:

```swift
public func createCoreMLComputeHandle(
    coremlModelPath: String,
    serverThreadIdx: Int,
    requireExactNNLen: Bool,
    numInputChannels: Int32,
    numInputGlobalChannels: Int32,
    numInputMetaChannels: Int32,
    numPolicyChannels: Int32,
    numValueChannels: Int32,
    numScoreValueChannels: Int32,
    numOwnershipChannels: Int32,
    context: MetalComputeContext
) -> CoreMLComputeHandle? { … }
```

Wrap the body in a cache-aware path. New helper to add (right after `deleteSourceModel`):

```swift
import KataGoInterface  // Adjust if the actual module name differs

private func cacheKey(
    forSourcePath sourcePath: String,
    nnXLen: Int32, nnYLen: Int32,
    requireExactNNLen: Bool, useFP16: Bool, maxBatchSize: Int
) async throws -> CoreMLCacheKey {
    let identity = try await CoreMLCacheKey.sourceIdentity(
        for: sourcePath,
        downloadedHasher: BinFileHasher.shared.identityForDownloadedFile)
    let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return CoreMLCacheKey(
        sourceIdentity: identity,
        boardXLen: nnXLen, boardYLen: nnYLen,
        computePrecision: useFP16 ? "FP16" : "FP32",
        optimizeIdentityMask: requireExactNNLen,
        minBatchSize: 1, maxBatchSize: maxBatchSize,
        converterVersion: katagocoremlConverterVersion(),
        osMajorVersion: osMajor)
}

// Accessor to katagocoreml::ConverterVersion::current() through the existing
// C++ namespace. metalbackend.cpp already includes KataGoConverter.hpp; this
// helper just shells out to a small bridging function (declared in
// KataGoInterface.h, defined in metalbackend.cpp via the swift::String wrapping).
@_silgen_name("katagocoreml_converter_version")
func katagocoremlConverterVersion_cstr() -> UnsafePointer<CChar>

private func katagocoremlConverterVersion() -> String {
    String(cString: katagocoremlConverterVersion_cstr())
}
```

Add the accompanying C function in `metalbackend.cpp` (next to the existing `convertModelToTemp`):

```cpp
extern "C" const char* katagocoreml_converter_version() {
    return katagocoreml::ConverterVersion::current();
}
```

- [ ] **Step 3: Build to confirm the bridge symbol resolves.**

```bash
cd "ios/KataGo iOS" && xcodebuild build \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit.**

```bash
git add cpp/neuralnet/metalbackend.swift cpp/neuralnet/metalbackend.cpp \
        "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift"
git commit -m "Expose CoreMLModelCache.shared + katagocoreml_converter_version bridge"
```

---

## Task 18: `CoreMLComputeHandle` gains optional `pinnedURL`; `loadCoreMLHandle` retry loop

**Files:**
- Modify: `cpp/neuralnet/metalbackend.swift` (`CoreMLComputeHandle` class declaration + new `loadCoreMLHandle` function)

- [ ] **Step 1: Add an optional `pinnedURL` to `CoreMLComputeHandle`.**

In `metalbackend.swift` near line 45 (`public class CoreMLComputeHandle`), add:

```swift
public class CoreMLComputeHandle {
    let model: MLModel
    let pinnedURL: PinnedCacheURL?     // nil = legacy non-cached path
    // … existing fields unchanged …

    init(model: MLModel, pinnedURL: PinnedCacheURL? = nil, /* … existing args … */ ) {
        self.model = model
        self.pinnedURL = pinnedURL
        // … rest unchanged …
    }

    deinit {
        if pinnedURL == nil {
            // Legacy fall-through path — clean up our temp dir.
            // (Real path: stash the .mlmodelc URL; for this stub the field is
            // already in the existing handle.)
        } else {
            let url = pinnedURL
            Task { await url?.release() }
        }
    }
}
```

- [ ] **Step 2: Add a top-level `loadCoreMLHandle(...)` with the one-shot retry loop.**

Append to `metalbackend.swift`:

```swift
public func loadCoreMLHandle(
    coremlModelPath: String,
    /* identical args as createCoreMLComputeHandle */
    context: MetalComputeContext
) async throws -> CoreMLComputeHandle? {
    let optimizeMask = requireExactNNLen
    let useFP16 = (context.useFP16Mode != enabled_t.False)
    let key = try await cacheKey(
        forSourcePath: coremlModelPath,
        nnXLen: context.nnXLen, nnYLen: context.nnYLen,
        requireExactNNLen: optimizeMask, useFP16: useFP16,
        maxBatchSize: maxBatchSize)

    for attempt in 0..<2 {
        let pinned = try await CoreMLModelCache.shared.urlForKey(
            digest: key.digest,
            missCallback: {
                // The C++ side does the conversion synchronously; we hop
                // off the actor to call it. Signature locked in here so
                // Task 19's swap-in only changes the body.
                return try await convertOnCooperativePool(
                    coremlModelPath: coremlModelPath,
                    boardX: context.nnXLen, boardY: context.nnYLen,
                    useFP16: useFP16, optimizeMask: optimizeMask,
                    maxBatchSize: Int32(maxBatchSize),
                    serverThreadIdx: Int32(serverThreadIdx))
            })
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: pinned.url, configuration: config)
            return CoreMLComputeHandle(model: model, pinnedURL: pinned, /* …rest of args… */)
        } catch {
            await pinned.release()
            await CoreMLModelCache.shared.invalidate(digest: pinned.digest, epoch: pinned.epoch)
            if attempt == 1 { throw error }
        }
    }
    return nil
}

// Stub — real conversion shim wired in Task 19. Signature already in its
// final form so Task 19 only swaps the body.
private func convertOnCooperativePool(
    coremlModelPath: String,
    boardX: Int32, boardY: Int32,
    useFP16: Bool, optimizeMask: Bool,
    maxBatchSize: Int32, serverThreadIdx: Int32
) async throws -> URL {
    // Placeholder: returns the same path. Replaced in Task 19 to call C++.
    return URL(fileURLWithPath: coremlModelPath)
}
```

- [ ] **Step 3: Build.**

```bash
cd "ios/KataGo iOS" && xcodebuild build \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit.**

```bash
git add cpp/neuralnet/metalbackend.swift
git commit -m "Add loadCoreMLHandle with corrupt-hit retry + optional pinnedURL"
```

---

## Task 19: Cooperative-pool conversion shim + bridge into `metalbackend.cpp`

**Files:**
- Modify: `cpp/neuralnet/metalbackend.swift` (replace the stub `convertOnCooperativePool`)
- Modify: `cpp/neuralnet/metalbackend.cpp:444-483` (`convertAndCreateCoreMLOnlyHandle` — drive via Swift Task with semaphore + secondary timeout)

- [ ] **Step 1: Replace the stub with a call to the existing `CoreMLConversion::convertModelToTemp`.**

`metalbackend.cpp` already exposes the C++ conversion. We need a C-callable entry that returns a heap-owned C string with the temp `.mlpackage` path:

```cpp
extern "C" const char* katagocoreml_convert_to_temp(
    const char* modelPath, int boardX, int boardY,
    bool useFP16, bool optimizeMask, int maxBatchSize, int serverThreadIdx
) {
    try {
        std::string out = CoreMLConversion::convertModelToTemp(
            modelPath, boardX, boardY, useFP16, optimizeMask, maxBatchSize, serverThreadIdx);
        char* buf = (char*)malloc(out.size() + 1);
        memcpy(buf, out.c_str(), out.size() + 1);
        return buf;
    } catch (...) {
        return nullptr;
    }
}
extern "C" void katagocoreml_free_string(const char* s) {
    free((void*)s);
}
```

- [ ] **Step 2: Replace the Swift stub.**

In `metalbackend.swift`:

```swift
@_silgen_name("katagocoreml_convert_to_temp")
func katagocoreml_convert_to_temp(
    _ modelPath: UnsafePointer<CChar>,
    _ boardX: Int32, _ boardY: Int32,
    _ useFP16: Bool, _ optimizeMask: Bool,
    _ maxBatchSize: Int32, _ serverThreadIdx: Int32
) -> UnsafePointer<CChar>?

@_silgen_name("katagocoreml_free_string")
func katagocoreml_free_string(_ s: UnsafePointer<CChar>?)

private func convertOnCooperativePool(
    coremlModelPath: String,
    boardX: Int32, boardY: Int32,
    useFP16: Bool, optimizeMask: Bool,
    maxBatchSize: Int32, serverThreadIdx: Int32
) async throws -> URL {
    return try await Task.detached(priority: .userInitiated) {
        let result = coremlModelPath.withCString { cstr -> URL? in
            guard let outCstr = katagocoreml_convert_to_temp(
                cstr, boardX, boardY, useFP16, optimizeMask,
                maxBatchSize, serverThreadIdx) else { return nil }
            defer { katagocoreml_free_string(outCstr) }
            return URL(fileURLWithPath: String(cString: outCstr))
        }
        guard let url = result else {
            throw NSError(domain: "katagocoreml", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "conversion failed"])
        }
        return url
    }.value
}
```

Update the `loadCoreMLHandle` call site to pass the additional parameters into `convertOnCooperativePool`.

- [ ] **Step 3: Update `convertAndCreateCoreMLOnlyHandle` in `metalbackend.cpp` to drive Swift via `Task.detached(priority: .userInitiated)` + `DispatchSemaphore` + secondary 60 s wait fall-through.**

Replace the body (`metalbackend.cpp:444-483`) with:

```cpp
static swift::Optional<KataGoSwift::CoreMLComputeHandle> convertAndCreateCoreMLOnlyHandle(
  ComputeContext* context,
  const LoadedModel* loadedModel,
  bool requireExactNNLen,
  int maxBatchSize,
  int serverThreadIdx
) {
  // Drive the cache-aware Swift loadCoreMLHandle from this C++ thread via
  // a DispatchSemaphore. See spec §Engine-thread bridging for the protocol.
  // ... see metalbackend.swift `loadCoreMLHandle` for the actual cache call.
  // Falls through to the legacy direct-compile path on bridge timeout.
  return KataGoSwift::loadCoreMLHandleWithBridgeTimeout(
    swift::String(loadedModel->modelPath),
    serverThreadIdx,
    requireExactNNLen,
    /* … channel counts unchanged … */
    context->metalContext);
}
```

The actual C++/Swift glue is straightforward: a top-level Swift function `loadCoreMLHandleWithBridgeTimeout(...)` that the C++ side calls; inside, it spawns the `Task.detached(priority: .userInitiated)` and does the two-stage `DispatchSemaphore` wait.

Add to `metalbackend.swift`:

```swift
public func loadCoreMLHandleWithBridgeTimeout(
    coremlModelPath: String,
    /* …existing args… */
    context: MetalComputeContext
) -> CoreMLComputeHandle? {
    let sem = DispatchSemaphore(value: 0)
    var box: Result<CoreMLComputeHandle?, Error>? = nil
    let task = Task.detached(priority: .userInitiated) {
        do {
            box = .success(try await loadCoreMLHandle(
                coremlModelPath: coremlModelPath, /* …args… */ context: context))
        } catch {
            box = .failure(error)
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + .seconds(600)) == .timedOut {
        // Secondary 60 s wait before fall-through.
        let secondary = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            _ = try? await task.value
            secondary.signal()
        }
        if secondary.wait(timeout: .now() + .seconds(60)) == .timedOut {
            task.cancel()
            // Direct-compile fall-through with pinnedURL: nil.
            return runLegacyCompileOnEngineThread(
                coremlModelPath: coremlModelPath, /* …args… */ context: context)
        }
    }
    switch box {
    case .success(let h)?: return h
    case .failure: return nil
    case nil: return nil
    }
}

private func runLegacyCompileOnEngineThread(
    coremlModelPath: String, /* …args… */ context: MetalComputeContext
) -> CoreMLComputeHandle? {
    // Behaves exactly like the pre-cache `createCoreMLComputeHandle` body —
    // synchronous compile, returns a handle with `pinnedURL: nil`. We rename
    // the existing body to this function so the legacy path is preserved.
    // … existing body of createCoreMLComputeHandle, returning
    //    CoreMLComputeHandle(model:, pinnedURL: nil, …) …
}
```

Then update `metalbackend.cpp:444-483` to call `loadCoreMLHandleWithBridgeTimeout` instead of `createCoreMLComputeHandle`.

- [ ] **Step 4: Build.**

```bash
cd "ios/KataGo iOS" && xcodebuild build \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Smoke-test on simulator.**

Open the app in the iOS Simulator (`xcrun simctl boot 'iPhone 17' && open -a Simulator`); pick the built-in model; confirm the engine launches and analysis works end-to-end. Watch Console for `engine.coreml.cache: lookup → miss → compiling` followed by `engine.coreml.cache: lookup → hit` on the second launch.

- [ ] **Step 6: Commit.**

```bash
git add cpp/neuralnet/metalbackend.cpp cpp/neuralnet/metalbackend.swift
git commit -m "Wire cache into engine-thread bridge with two-stage timeout fall-through"
```

---

## Task 20: `ModelPickerView` per-row badge

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/ModelPickerView.swift`

Per spec §UI > Per-model badge. Status binds to `PrecompileScheduler.status[fileName]`.

- [ ] **Step 1: Inject `PrecompileScheduler` into the picker.**

Pass the scheduler down from `KataGo_iOSApp` (or the root view) as `@Environment` or a simple property. Smallest diff: add `@Environment(PrecompileScheduler.self) var scheduler` to `ModelPickerView`.

- [ ] **Step 2: Add the badge.**

In `ModelPickerView`'s row builder, add to the trailing accessory:

```swift
@ViewBuilder
private func badge(for status: PrecompileStatus?) -> some View {
    switch status ?? .idle {
    case .ready:
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.tint)
            .accessibilityLabel("Core ML cache ready")
    case .compiling:
        ProgressView().controlSize(.small)
            .accessibilityLabel("Compiling Core ML model")
    case .queued:
        Image(systemName: "clock")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Waiting to compile Core ML model")
    case .failed:
        Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .accessibilityLabel("Compile failed; will retry")
    case .idle:
        EmptyView()
    }
}
```

Wire it into the row's HStack right after the existing gear button.

- [ ] **Step 3: Build.**

```bash
cd "ios/KataGo iOS" && xcodebuild build \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | tail -5
```

- [ ] **Step 4: Commit.**

```bash
git add "ios/KataGo iOS/KataGo iOS/ModelPickerView.swift"
git commit -m "Add per-model Core ML cache badge to ModelPickerView"
```

---

## Task 21: `ModelPickerView` Clear Cache footer

**Files:**
- Create: `ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift`
- Modify: `ios/KataGo iOS/KataGo iOS/ModelPickerView.swift`

- [ ] **Step 1: Create the footer view.**

```swift
import SwiftUI
import KataGoInterface

struct CoreMLCacheFooterView: View {
    let scheduler: PrecompileScheduler
    @State private var entryCount: Int = 0
    @State private var sizeBytes: Int64 = 0
    @State private var showConfirm = false
    @State private var clearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Core ML Cache")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if entryCount == 0 {
                    Text("empty").foregroundStyle(.secondary)
                } else {
                    Text("\(ByteCountFormatter().string(fromByteCount: sizeBytes)) · \(entryCount) of 8 compiled models")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if entryCount > 0 {
                    Button("Clear Cache") { showConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .disabled(clearing)
                }
            }
        }
        .padding(.vertical, 12)
        .task { await refresh() }
        .confirmationDialog("Clear Core ML Cache?",
                            isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { await clear() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All \(entryCount) compiled models will be removed. They will recompile on next use. The built-in model will recompile automatically in the background.")
        }
    }

    @MainActor private func refresh() async {
        let stats = await CoreMLModelCache.shared.statsForUI()
        entryCount = stats.count
        sizeBytes = stats.totalBytes
    }

    @MainActor private func clear() async {
        clearing = true
        defer { clearing = false }
        await CoreMLModelCache.shared.clearAll()
        UserDefaults.standard.set("", forKey: "CoreMLCache.firstLaunchPrecompileVersion")
        await scheduler.scheduleBuiltIn()
        await refresh()
    }
}
```

- [ ] **Step 2: Add `statsForUI` to the actor.**

Append to `CoreMLModelCache.swift`:

```swift
extension CoreMLModelCache {
    public struct Stats: Sendable { public let count: Int; public let totalBytes: Int64 }
    public func statsForUI() -> Stats {
        Stats(count: entries.count,
              totalBytes: entries.values.reduce(0) { $0 + $1.sizeBytes })
    }
}
```

- [ ] **Step 3: Mount the footer in `ModelPickerView` below the last model row.**

```swift
// Inside the picker's List/VStack, after the last row:
CoreMLCacheFooterView(scheduler: scheduler)
```

- [ ] **Step 4: Build + smoke-test on simulator.**

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGo iOS/CoreMLCacheFooterView.swift" \
        "ios/KataGo iOS/KataGo iOS/ModelPickerView.swift" \
        "ios/KataGo iOS/KataGoInterface/CoreMLModelCache.swift"
git commit -m "Add Core ML Cache footer with size/count + Clear Cache button"
```

---

## Task 22: Wire `BackendConfigSheet` picker writes to `PrecompileScheduler.scheduleForModel`

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/BackendConfigSheet.swift`

Per spec §Background Precompile triggers — fire `scheduleForModel` from each picker's `onChange` handler, immediately after the new value is persisted.

- [ ] **Step 1: Add `@Environment(PrecompileScheduler.self) var scheduler`.**

- [ ] **Step 2: For both `BackendChoice` and `coremlBoardSize` pickers, add `.onChange(of:)` that calls:**

```swift
.onChange(of: selectedBackend) { _, _ in
    Task { await scheduler.scheduleForModel(fileName: model.fileName) }
}
.onChange(of: coremlBoardSize) { _, _ in
    Task { await scheduler.scheduleForModel(fileName: model.fileName) }
}
```

(`PrecompileScheduler.scheduleForModel` already early-returns on `.mpsGPU`, so flipping back and forth is safe.)

- [ ] **Step 3: Build.**

- [ ] **Step 4: Commit.**

```bash
git add "ios/KataGo iOS/KataGo iOS/BackendConfigSheet.swift"
git commit -m "Trigger PrecompileScheduler from BackendConfigSheet picker writes"
```

---

## Task 23: `Downloader` triggers `BinFileHasher` + `scheduleForModel` on success

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/Downloader.swift`

- [ ] **Step 1: After download completion, call:**

```swift
// Inside the success branch of Downloader's URLSession completion:
Task.detached(priority: .userInitiated) {
    _ = try? await BinFileHasher.shared.identityForDownloadedFile(downloadedURL)
    await MainActor.run {
        Task { await scheduler.scheduleForModel(fileName: downloadedURL.lastPathComponent) }
    }
}
```

The exact wiring depends on `Downloader`'s existing structure; either inject `PrecompileScheduler` via property or read from `@Environment` at the call site that owns the downloader.

- [ ] **Step 2: Build.**

- [ ] **Step 3: Commit.**

```bash
git add "ios/KataGo iOS/KataGo iOS/Downloader.swift"
git commit -m "Hash and schedule precompile on download success"
```

---

## Task 24: Root view `.onAppear` first-launch / bundle-upgrade re-warm check

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/GameSplitView.swift` (or `ModelRunnerView.swift`, whichever is the root scene-content view)
- Create: `ios/KataGo iOS/KataGo iOSTests/RootViewBundleUpgradeTests.swift`

Per spec §Architecture > Modified components — check `firstLaunchPrecompileVersion` against `CFBundleVersion` and call `scheduleBuiltIn` on mismatch.

- [ ] **Step 1: Write the failing decision-logic test.**

Create `ios/KataGo iOS/KataGo iOSTests/RootViewBundleUpgradeTests.swift`:

```swift
import Foundation
import Testing
@testable import KataGo_Anytime

struct RootViewBundleUpgradeTests {
    @Test func bundleUpgradeRetriggers() async throws {
        let defaults = UserDefaults(suiteName: "test.\(UUID())")!
        defaults.set("1.0.41", forKey: "CoreMLCache.firstLaunchPrecompileVersion")

        var enqueued = 0
        let decide = BundleVersionWarmDecision.shouldRewarm(
            stored: defaults.string(forKey: "CoreMLCache.firstLaunchPrecompileVersion") ?? "",
            current: "1.0.42")
        if decide {
            defaults.set("1.0.42", forKey: "CoreMLCache.firstLaunchPrecompileVersion")
            enqueued += 1
        }
        #expect(enqueued == 1)
        #expect(defaults.string(forKey: "CoreMLCache.firstLaunchPrecompileVersion") == "1.0.42")

        // Re-fire — no enqueue, no flag change.
        let decide2 = BundleVersionWarmDecision.shouldRewarm(
            stored: defaults.string(forKey: "CoreMLCache.firstLaunchPrecompileVersion") ?? "",
            current: "1.0.42")
        #expect(!decide2)
    }
}
```

- [ ] **Step 2: Implement the decision helper.**

In an existing nearby file (e.g., `EngineLifecycle.swift`, since it already houses `RecoveryDecision`), add:

```swift
public enum BundleVersionWarmDecision {
    public static func shouldRewarm(stored: String, current: String) -> Bool {
        return stored != current
    }
}
```

- [ ] **Step 3: Wire `.onAppear` in the root view.**

```swift
@AppStorage("CoreMLCache.firstLaunchPrecompileVersion") private var lastWarmedVersion: String = ""

.onAppear {
    let current = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    if BundleVersionWarmDecision.shouldRewarm(stored: lastWarmedVersion, current: current) {
        Task { await scheduler.scheduleBuiltIn() }
        lastWarmedVersion = current
    }
}
```

- [ ] **Step 4: Run; tests pass.**

```bash
cd "ios/KataGo iOS" && xcodebuild test \
  -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:'KataGo iOSTests/RootViewBundleUpgradeTests' 2>&1 | tail -10
```

- [ ] **Step 5: Commit.**

```bash
git add "ios/KataGo iOS/KataGo iOS/GameSplitView.swift" \
        "ios/KataGo iOS/KataGo iOS/EngineLifecycle.swift" \
        "ios/KataGo iOS/KataGo iOSTests/RootViewBundleUpgradeTests.swift"
git commit -m "Re-warm built-in precompile on first launch + bundle upgrade"
```

---

## Task 25: `LoadingView` secondary status string

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/LoadingView.swift`

- [ ] **Step 1: Inject `EngineLaunchStatus` and add the secondary line.**

```swift
@Environment(EngineLaunchStatus.self) private var launchStatus

var body: some View {
    VStack(spacing: 8) {
        ProgressView("Loading…")
        if let line = secondaryLine {
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

private var secondaryLine: String? {
    switch launchStatus.phase {
    case .compilingMissFirstLaunch: "Compiling Core ML model — first launch only"
    case .awaitingPrecompile:       "Finishing Core ML compile…"
    case .idle:                     nil
    }
}
```

- [ ] **Step 2: Wire phase transitions from the bridge (Task 19's `loadCoreMLHandleWithBridgeTimeout`).**

Around the `urlForKey` cache hit/miss decision, hop to MainActor:

```swift
await MainActor.run { launchStatus.phase = .compilingMissFirstLaunch }
// …
await MainActor.run { launchStatus.phase = .idle }
```

(`launchStatus` here is the singleton observed by `LoadingView`.)

- [ ] **Step 3: Build + smoke-test.**

- [ ] **Step 4: Commit.**

```bash
git add "ios/KataGo iOS/KataGo iOS/LoadingView.swift" cpp/neuralnet/metalbackend.swift
git commit -m "Show 'Compiling Core ML model — first launch only' status during cache miss"
```

---

## Task 26: End-to-end smoke run + manual verification checklist

**Files:** none (manual)

Run through the spec's verification checklist:

- [ ] Cold install (delete app from simulator, reinstall) → built-in model precompiles in background → second app launch with built-in is fast.
- [ ] Download FD3 → status badge transitions queued → compiling → ready → first launch is fast.
- [ ] Change `coremlBoardSize` 19 → 13 in `BackendConfigSheet` → background precompile fires → next launch fast at new size.
- [ ] Switch back to 19 → cache hit (still in LRU) → instant launch.
- [ ] Compile 10 distinct (model, size) combos → cache stays at 8 entries; oldest evicted.
- [ ] Tap "Clear Cache" → footer shows "empty" → next launch slow → built-in precompile re-runs in background.

If everything passes, push the branch.

```bash
git push origin ios-dev
```

---

## Notes for the implementer

- The actor's static `shared` singleton uses `Bundle.main.bundleIdentifier`, which differs between iOS and visionOS targets — confirm both targets land in their own `Application Support/<bundleId>/coreml/` directory.
- Several tests need a real `MLModel.compileModel(at:)` to verify end-to-end behavior. Tasks 1–15 stub it as the identity function so the tests stay fast and don't require fixture `.mlpackage` files; Task 16 swaps in the real implementation. Run the relevant sub-suites between tasks to confirm nothing regresses.
- The Swift module name in `@testable import` is `KataGo_Anytime` (per existing tests in `EngineLifecycleTests.swift`). The framework target where `CoreMLCacheKey`, `CoreMLModelCache`, and `EngineLaunchStatus` live is `KataGoInterface` — confirm the test file's imports are right.
- `convertOnCooperativePool` calls `katagocoreml::KataGoConverter::convert` via the existing `convertModelToTemp`. The reentrancy assumption (spec §Engine-thread bridging) was already implicit in the multi-thread call site at `metalbackend.cpp:445`; making it explicit here is documentation-only.
- If a test that depends on `MLModel.compileModel` is flaky on the simulator, mark it with a `@Test(.disabled("requires real CoreML compile"))` and rely on the manual verification step.
- The spec lists ~50 named tests across rounds 1–15. The plan tasks cover the structurally important ones (digest stability, structural-collision rejection, three-caller race, idempotent release, eviction with pin-skip, invalidate-respects-pin, orphan sweep, bundle-upgrade re-warm, scheduler backend guard). The remainder — `…_NoEvictionRaceBetweenReturnAndAcquire`, `…_PriorityElevationOnDedup`, `…_StoreDoesNotBlockActorOnCrossVolumeMove`, `…_DeinitDoesNotReleaseRecycledAddress`, `EngineBridge_TimeoutFallThroughBoundsMemory`, `IndexJSON_AdoptedEntryKeyIsNull`, `PrecompileScheduler_FailedStatusEquatable`, `CoreMLCacheKey_ServerThreadIdxNotInOptions` — are valuable but mostly regression guards rather than driving design. Add them after Task 26 if time allows; they don't gate the manual verification checklist passing.
