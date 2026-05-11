# Core ML Cache for KataGo Anytime

## Problem

When a user launches KataGo Anytime with a selected model, the app pays two costs every time:

1. C++ `katagocoreml::KataGoConverter::convert()` writes a `.mlpackage` to a temp directory (`cpp/neuralnet/metalbackend.cpp:50`).
2. Swift `MLModel.compileModel(at:)` compiles it to `.mlmodelc` (`cpp/neuralnet/metalbackend.swift:371`).

Step 2 dominates the wait — it runs on every launch even though the compiled output is a pure function of `(model bytes, board size, FP16/FP32, optimizeIdentityMask, batch sizes)`. Users have no way to amortize that cost across launches.

The existing backend-selection feature (`docs/superpowers/specs/2026-04-16-backend-selection-design.md`) already calls out this compile cost as a known UX issue; this spec resolves it.

## Goals

- On the second launch with a given (model, settings) tuple, skip both the C++ conversion and the Core ML compile entirely.
- On a cold install, prefer to do the compile *before* the user picks the built-in model — i.e., warm the cache opportunistically.
- Make the user-visible state of the cache discoverable and clearable from the model picker.
- Stay within the existing engine-launch flow; no signature changes to `KataGoHelper.runGtp`.

## Non-Goals

- Caching for non-iOS targets (desktop KataGo CLI, CI builds). The cache is owned by the iOS/macOS/visionOS app target.
- Persistent telemetry or analytics. OSLog is sufficient for diagnostics.
- Caching anything other than the compiled `.mlmodelc`. Intermediate `.mlpackage` files remain in temp and are deleted on use.

## Solution Overview

A new Swift actor `CoreMLModelCache` owns `Application Support/<bundleid>/coreml/`. The C++ Core ML handle creation path queries this cache before doing any work. On a hit, the cached `.mlmodelc` loads directly. On a miss, the existing convert + compile pipeline runs and the result is stored atomically.

A `PrecompileScheduler` warms the cache opportunistically on first app launch (built-in model), on download success (newly downloaded models), and on settings change (so a new (model, settings) tuple is ready before the next launch).

LRU eviction caps the cache at 8 entries. The model picker shows per-row badges for cache state and a footer for "Clear Core ML Cache".

## Architecture

### New components

| Component | Layer | Purpose |
|---|---|---|
| `CoreMLModelCache` (Swift actor) | iOS app + KataGoInterface | Owns `Application Support/coreml/`; performs lookup/store/evict atomically; tracks in-flight compiles |
| `CoreMLCacheKey` (Swift struct) | KataGoInterface | Captures all fields that affect the compiled `.mlmodelc`; stable hex digest used as on-disk filename |
| `BinFileHasher` (Swift) | iOS app | Computes (and memoizes via `@AppStorage`) SHA-256 of downloaded `.bin.gz` files |
| `PrecompileScheduler` (Swift `@Observable`) | iOS app | Background task glue — fires precompile on download success, settings change, and first-app-launch (built-in) |
| `katagocoreml::ConverterVersion` (C++) | katagocoreml | Exposes a `current()` string used in the cache key; bumped when the converter changes its output for the same inputs |

### Modified components

| Component | Change |
|---|---|
| `metalbackend.cpp::convertAndCreateCoreMLOnlyHandle` | Computes cache key first; calls Swift `CoreMLModelCache.urlForKey(...)`; runs `convertModelToTemp` only via the miss-callback |
| `metalbackend.swift::createCoreMLComputeHandle` | Becomes the cache-miss compile path. New `loadCachedCoreMLHandle(...)` handles the cache-hit path (open `.mlmodelc` and wrap in handle) |
| `KataGoHelper.runGtp` | No signature change; cache lookup is internal |
| `Downloader.swift` | After successful download: `BinFileHasher.computeAndStore(...)`, then `PrecompileScheduler.scheduleForModel(...)` |
| `BackendConfigSheet` | Wherever the sheet writes `backend_<fileName>` or `coremlBoardSize_<fileName>` (the AppStorage-bound `Picker` actions), call `PrecompileScheduler.scheduleForModel(...)` immediately after the new value is persisted. The "Done" button only dismisses; it does not re-trigger scheduling, since a duplicate enqueue would no-op anyway |
| Root view `.onAppear` (`GameSplitView` or `ModelRunnerView`) | Read `@AppStorage("CoreMLCache.firstLaunchPrecompileVersion")` (default `""`). If it differs from the current `CFBundleVersion`, call `PrecompileScheduler.scheduleBuiltIn()` and write the current version into the AppStorage key. The string-versus-bool design ensures the precompile re-fires after an app upgrade that ships a different `default_model.bin.gz`, where the cached `(size, mtime)`-based `sourceIdentity` no longer matches |
| `ModelPickerView` | Per-row status badge bound to `PrecompileScheduler.status`; footer with cache size + "Clear Core ML Cache" button |
| `LoadingView` | Optional secondary status string driven by an `EngineLaunchStatus` `@Observable` |

### Engine-launch data flow

```
ModelRunnerView.startKataGoThread
  → KataGoHelper.runGtp (C++)
    → setup loads NN graph from .bin.gz
    → metalbackend convertAndCreateCoreMLOnlyHandle
      → pass raw key fields (board, fp16, mask, batch, source-identity, converter-ver) to Swift
      → Swift CoreMLModelCache.urlForKey(rawFields, missCallback) → PinnedCacheURL
        ├── HIT  → pin digest, return PinnedCacheURL(url, digest, cache)
        └── MISS → await any in-flight precompile for this key
                 → if still miss: invoke missCallback → C++ convertModelToTemp
                 → await MLModel.compileModel(at: tempPackage)
                 → atomic rename .mlmodelc into cache dir
                 → pin digest, return PinnedCacheURL(url, digest, cache)
                 → kick LRU eviction asynchronously (skips pinned digests)
      → outside the actor: MLModel(contentsOf: pinned.url, configuration: cpuAndNE) → handle
      → on engine teardown: await pinned.release()
```

The C++↔Swift seam is one new Swift function exposed to C++ via the existing `KataGoSwift` bridge. C++ provides a callback object that knows how to do conversion-on-demand; Swift only invokes it on miss.

**Why `MLModel(contentsOf:)` is outside the actor:** loading a compiled model takes hundreds of ms of I/O. If we did it inside the actor, every cache hit would serialize behind every other cache operation. By returning a URL and letting the (already off-MainActor) caller construct the `MLModel`, the actor's critical section stays short and other lookups, eviction, and store operations don't block. **By the same rationale, the cross-volume `compiledURL → <epoch>.tmp/` move runs off-actor (`prepareTmp`); only the same-volume rename into `<epoch>.mlmodelc/` and the `index.json` update happen inside the actor (`commitStore`).** See *Atomic write protocol on store* below.

**Digest construction owner:** Swift is the sole owner. C++ passes raw fields across the bridge; Swift's `CoreMLCacheKey` initializer canonicalizes and SHA-256s them. There is no SHA-256 implementation on the C++ side and no canonical-encoding implementation on either. This avoids the trap of two implementations drifting into different digests for the same logical inputs.

## Cache Key

`CoreMLCacheKey` is a Swift struct of `let` fields:

| Field | Type | Source |
|---|---|---|
| `sourceIdentity` | `String` | Built-in: `"builtin:<CFBundleVersion>:<bundleFileSize>:<bundleFileMtime>"`. Downloaded: `"sha256:" + hex(SHA256(.bin.gz))` |
| `boardXLen`, `boardYLen` | `Int32` | from `MetalComputeContext` |
| `computePrecision` | `String` | `"FP16"` or `"FP32"`. **Note:** these spellings are deliberately distinct from the on-the-wire `"FLOAT16"` / `"FLOAT32"` strings used by `katagocoreml::ConversionOptions::compute_precision` (`metalbackend.cpp:69`). The cache key uses the shorter form so the digest input is independent of any future converter-side rename; harmonizing them would invalidate every user's cache. The mapping `"FP16" ↔ "FLOAT16"` is one line in `convertModelToTemp`'s caller. |
| `optimizeIdentityMask` | `Bool` | mirrors `requireExactNNLen` |
| `minBatchSize`, `maxBatchSize` | `Int` | both `1` and `cfg.nnMaxBatchSize` |
| `converterVersion` | `String` | from new `katagocoreml::ConverterVersion::current()` |
| `osMajorVersion` | `Int` | `ProcessInfo.processInfo.operatingSystemVersion.majorVersion` |

**Digest:** SHA-256 of the canonical encoding of those fields, taking the first 16 bytes (32 hex chars). Used as both the on-disk directory name and the in-memory dedup key.

**Canonical encoding** is a hand-rolled `key=value\n` format — *not* `JSONEncoder`. `JSONEncoder` defaults to non-deterministic key ordering for `Codable`-synthesized encoding, and its number / bool serialization has shifted across Foundation versions; relying on it would silently invalidate user caches on an OS upgrade. Spec rules:

- **Ordering:** fields are encoded in the fixed order listed in the table above. The implementation is a hand-written `canonicalBytes` accessor — never `Codable` auto-synthesis.
- **Encoding:** UTF-8 bytes of `key=value` pairs joined by `\n`, with one trailing `\n`. Integers as base-10 with no leading zeros and no sign for non-negative values. Booleans as the literal strings `true` / `false`.
- **String validation:** any string field that flows into `canonicalBytes` (`computePrecision`, `converterVersion`, `sourceIdentity`) is validated at the construction site against `^[\x21-\x3C\x3E-\x7E]+$` — printable ASCII excluding `=` (0x3D), `\n` (0x0A), space (0x20), and all other control characters. Excluding `=` and `\n` is **structural**: those two bytes are the field separators of the canonical encoding, and admitting them would let a future field value silently collide with a logically distinct key. Excluding space and other whitespace is defensive — it keeps `canonicalBytes` byte-for-byte equal to the human-readable `"key=value\n..."` form, so frozen-digest mismatches are debuggable by eye.
- **Validation traps with `preconditionFailure`** rather than throws — a string field that fails this check is a programming error, not a runtime input. Conversion sites:
    - `sourceIdentity` — built-in form `"builtin:<version>:<size>:<mtimeMs>"` is constructed from `Int64`/`String` numerics that are already in-range. The `version` segment (CFBundleVersion) is **sanitized** by replacing any disallowed byte with `_` *before* assembly, since CFBundleVersion isn't constrained by Apple to printable ASCII. Downloaded form `"sha256:<hex>"` is hex by construction.
    - `computePrecision` — string literal `"FP16"` or `"FP32"`, never user-derived.
    - `converterVersion` — set in C++ source; CI lint asserts the chosen literal matches the regex.

```swift
extension CoreMLCacheKey {
    var canonicalBytes: Data {
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

    var digest: String {
        let hash = SHA256.hash(data: canonicalBytes)
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
```

**Frozen-digest test:** `CoreMLCacheKey_DigestPinnedConstant` asserts that **two** fixed sample keys produce known 32-hex constants — one for each source-identity flavor:

1. **Built-in sample** with `sourceIdentity = "builtin:1.0.42:104857600:1735689600000"` (CFBundleVersion `1.0.42`, 100 MiB, mtime `2025-01-01T00:00:00Z` quantized to milliseconds).
2. **Downloaded sample** with `sourceIdentity = "sha256:0000…0000"` (32 zero bytes, hex).

Both constants are computed once during implementation and frozen in source. Any future change to canonicalization — including the mtime quantization rule, bundle-version concatenation, or the `key=value\n` ordering — fails this test rather than silently invalidating user caches.

**Built-in source identity (hybrid, mirrors downloaded):** combines `CFBundleVersion` with the bundled `default_model.bin.gz`'s `(size, mtime)`. We deliberately do not hash the bundle bytes (that's a fixed ~100 MB read at every launch), but the `(size, mtime)` pair catches the realistic dev-rebuild case where the same `CFBundleVersion` ships with a swapped model. The `(size, mtime)` read is a single `stat(2)` — negligible. The "Clear Cache" footer button remains a manual escape hatch for any case this still misses.

**Downloaded source identity:** SHA-256 of `.bin.gz` bytes, computed once at download time and memoized in `UserDefaults`. The hybrid `(path, size, mtime)` check from Q3=C decides whether to reuse the memo or recompute.

**Dispatch — how Swift picks built-in vs downloaded:** `CoreMLCacheKey.sourceIdentity(for modelPath:)` decides as follows:

```swift
static func sourceIdentity(for modelPath: String) async throws -> String {
    let candidate = URL(fileURLWithPath: modelPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    let bundleURL = Bundle.main
        .url(forResource: "default_model", withExtension: "bin.gz")?
        .resolvingSymlinksInPath()
        .standardizedFileURL

    if let bundleURL, candidate == bundleURL {
        // Built-in: read CFBundleVersion + stat the bundled file.
        let attrs = try FileManager.default.attributesOfItem(atPath: bundleURL.path)
        let size = (attrs[.size] as? Int64) ?? 0

        // Quantize mtime to whole milliseconds and serialize as Int64
        // base-10. Rationale: `\(Double)` interpolation is not pinned
        // across Swift / Foundation versions and would silently
        // invalidate caches on OS upgrades — the same trap that ruled
        // out JSONEncoder for the canonical key encoding.
        // Millisecond resolution is finer than any filesystem records
        // for .bin.gz on iOS/macOS in practice, so this loses no real
        // signal while pinning the encoding deterministically.
        let mtimeRaw = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mtimeMs = Int64((mtimeRaw * 1000).rounded())

        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return "builtin:\(version):\(size):\(mtimeMs)"
    }

    // Downloaded: prefer memoized hash, recompute on miss/mismatch.
    return try await BinFileHasher.shared.identityForDownloadedFile(URL(fileURLWithPath: modelPath))
        // returns "sha256:<hex>"
}
```

Notes:
- `.resolvingSymlinksInPath().standardizedFileURL` resolves symlinks (including macOS/iOS firmlinks like `/private/var` ↔ `/var`), `..`, and trailing slashes, so path comparisons work across APIs that return the same file under different prefixes. **`URL.standardized` alone is not sufficient** — it canonicalizes `..` and trailing slashes only and does not follow symlinks, so on macOS the bundle URL may surface as `/var/...` while a path passed through `URL(fileURLWithPath:)` surfaces as `/private/var/...` and `==` would not equate them.
- A user who installs the app for the first time after this PR has no `UserDefaults` memo for previously-downloaded files. The first launch with such a file pays the **slow path** — `BinFileHasher` streams-and-hashes the .bin.gz (a few seconds for 270 MB). The hash is memoized and subsequent launches are instant. This is the only legacy migration cost; we don't need a separate migration step.
- If `default_model.bin.gz` is missing from the bundle (mis-built app), the bundle URL lookup returns nil; the function falls through to the downloaded path and treats the model as content-addressed. This degrades gracefully rather than throwing.

**Why `osMajorVersion` is in the key:** not because we know `.mlmodelc` will silently miscompute (we don't), but as a conservative invalidation. Apple's Core ML format is tied to OS-level codegen; a major-version upgrade can plausibly change the optimal compiled output even when an older `.mlmodelc` still loads. Recompiling on the first launch after an OS upgrade is cheap insurance and matches Apple's general guidance to recompile after platform updates. Minor versions are excluded — they're frequent and Apple's intra-major compatibility is strong.

**Why device model is NOT in the key:** `.mlmodelc` files are portable across devices that share an OS major version. Including device model (e.g., `iPhone15,3` vs `iPhone16,1`) would over-invalidate the cache for users with multiple devices syncing app data, and would not improve correctness. Cross-device portability of `.mlmodelc` is an explicit Apple guarantee within an OS major version.

**Why `serverThreadIdx` is NOT in the key (audit):** `serverThreadIdx` is passed to `convertModelToTemp` (`cpp/neuralnet/metalbackend.cpp:50`) but only flows into `generateTempPath(...)` (line 41) and a few `cerr` log lines (64, 83, 85, 88). It is **not** a member of `katagocoreml::ConversionOptions` (lines 66–74) and is **not** passed to `katagocoreml::KataGoConverter::convert(...)` (line 77). Two threads converting the same `(modelPath, boardX, boardY, useFP16, optimizeMask, maxBatchSize)` tuple produce byte-identical `.mlpackage` outputs at distinct temp paths — the index is purely a temp-file-disambiguation handle. **If a future change moves `serverThreadIdx` (or any per-thread state) into `ConversionOptions`, this exclusion regresses and the field must be added to `CoreMLCacheKey`.** The test `CoreMLCacheKey_ServerThreadIdxNotInOptions` (below) catches the regression at PR-review time rather than at runtime cache-correctness time.

**Why `cacheFormatVersion` is NOT in the digest:** if we change the on-disk layout, we change the directory structure and recovery rules — so the right invalidation primitive is a top-level `index.json.schemaVersion` check, not a per-entry digest field. The cache code refuses to load an `index.json` whose `schemaVersion` differs from the compiled-in constant, wipes the cache root, and starts fresh. This keeps the digest fields purely about *what was compiled*, not *how we store it*.

### Hash memoization in `UserDefaults`

`@AppStorage` cannot take a runtime-interpolated key (the wrapper attribute is a compile-time constant), so `BinFileHasher` reads/writes `UserDefaults.standard` directly with dynamic keys:

| Key pattern | Type | Purpose |
|---|---|---|
| `binFileSha256_<fileName>` | `String` | Memoized SHA-256 hex, set by `Downloader` on completion |
| `binFileSize_<fileName>` | `Int64` | File size at hash time — invalidates memo if size differs |
| `binFileMtime_<fileName>` | `Double` (TimeInterval) | mtime at hash time — invalidates memo if mtime differs |

**`Double` mtime in the memo is never in `canonicalBytes`.** The downloaded `sourceIdentity` is `"sha256:<hex>"` — a content hash, not an mtime — so the canonical-encoding stability guarantees are unaffected by the `Double` representation here. The `Double` is purely for the equality short-circuit on the memoization side, and `UserDefaults`'s `Double` round-trip is bit-stable for that purpose.

`BinFileHasher` is a non-SwiftUI service class with all hashing methods marked `async` and explicitly off-MainActor. Hashing 270 MB takes order-of seconds on iPhone; running this on the main thread would hitch the UI. Concretely:

- `func identityForDownloadedFile(_ url: URL) async throws -> String` — returns `"sha256:<hex>"`. If a memo exists for the same `(size, mtime)`, returns instantly; otherwise streams the file in 1 MB chunks through `CryptoKit.SHA256` on a `Task.detached(priority: .userInitiated)` so the work runs on the cooperative thread pool, never the main actor.
- `UserDefaults` writes for the memo itself happen at the end of the same detached task; `UserDefaults` is thread-safe.
- Callers (the `Downloader`, the `PrecompileScheduler`) `await` the result. SwiftUI views never call this directly.

## On-Disk Layout

Root: `Application Support/<bundleid>/coreml/`. The root directory has `isExcludedFromBackup = true` set at creation.

```
coreml/
  index.json              # {schemaVersion, entries: [{digest, epoch, key?, sizeBytes, lastAccessedAt, createdAt, sourceFileName}]}
  models/
    <digest>/
      <epoch-A>.mlmodelc/ # tombstoned from a previous compile — lingering until pins drain
      <epoch-B>.mlmodelc/ # current — index points here
      <epoch-C>.tmp/      # only present mid-write — atomically renamed on success
```

**Why an epoch UUID per entry:** `<digest>` is the cache identity (a function of source bytes + conversion options) but cannot also be the on-disk identity. If a tombstoned-but-undeleted `<digest>.mlmodelc/` (waiting for pins to drain after `invalidate`) shared a name with the recompile target, step 3 of the atomic-write protocol — `rename(<digest>.tmp, <digest>.mlmodelc)` — would fail because the destination already exists. Adding a fresh `epoch: UUID` per `storeAtomically` call gives each compile its own collision-free namespace, so the tombstoned and recompiled entries can coexist on disk until the tombstoned one's pins drain. UUIDs sidestep the "next-gen counter" bookkeeping that a monotonic alternative would require, the directory name remains human-readable for debugging, and the `(digest, epoch)` pair is unforgeable across recompiles.

**`entries[].key` is diagnostic-only.** It holds a human-readable rendering of the canonicalized `CoreMLCacheKey` fields (board size, FP precision, optimizeMask, batch sizes, source-identity prefix, etc.) for log inspection and tooling. **No read path may branch on its contents or even on its presence.** The field is nullable: adopted entries (recovered from disk when `index.json` is missing — see *Adoption pass*) write `key: null` because the original key fields cannot be reconstructed from the on-disk `.mlmodelc/`. Readers MUST tolerate `null`; the only correctness-critical fields are `digest`, `epoch`, and `lastAccessedAt`. Any future "let's actually use `key` for X" change requires either populating it in the adoption pass or rejecting adopted-without-key entries — both are out of scope for v1.

**No file lock.** All cache mutation goes through the single `CoreMLModelCache` actor; the actor's serial executor *is* the lock. The app does not have extension targets that share `Application Support`, so cross-process contention is not in scope. (If extensions are added later, an advisory `flock(2)` can be added — it would have a real defined mechanism then. Adding one now without a contention model would be cargo-cult.)

### Atomic write protocol on store

The store path is split into a slow off-actor preparation and a fast on-actor commit. **The cross-volume `compiledURL → <epoch>.tmp/` move runs off-actor** — `FileManager.moveItem` falls back to copy + remove on `EXDEV`, and the compiled directory can be hundreds of MB. Holding the actor's serial executor through that copy would stall every concurrent `urlForKey` / `release` / `invalidate`. Only the same-volume rename and the `index.json` update happen inside the actor.

#### Phase A — `prepareTmp` (off-actor, `nonisolated`)

A0. **Cancellation checkpoint.** `try Task.checkCancellation()`. (`MLModel.compileModel` itself is assumed to run to completion regardless of cancellation; this is the first place the cache observes cancellation.)
A1. **Mint a fresh `epoch = UUID()`.** Build `tmpURL = models/<digest>/<epoch>.tmp`.
A2. `try FileManager.default.createDirectory(at: models/<digest>/, withIntermediateDirectories: true)` — `ensureCacheTreeExists()` guarantees `models/`, the per-digest subdir is created on demand here.
A3. `try FileManager.default.moveItem(at: compiledURL, to: tmpURL)`. Handles the cross-volume case (`EXDEV`) by falling back to copy + remove; same-volume calls are a fast atomic rename. **Slow path; off-actor by design.** The cross-volume copy is *uncancellable* — `FileManager.moveItem` does not honor `Task.cancel()` mid-copy, so a `clearAll()` issued during a hundreds-of-MB cross-volume copy will see the copy run to completion before A4's cancellation re-check fires. The orphan `<epoch>.tmp/` is then cleaned by either A4 itself (if cancellation was observed) or the next-startup orphan sweep. Acceptable: the alternative would be reimplementing `moveItem` as a chunked, cancellable copy loop, which is out of scope for v1.
A4. **Cancellation re-check.** If `Task.isCancelled`, delete `<epoch>.tmp/` and throw `CancellationError`. The race with `clearAll()` (which `cancel`s the in-flight task and wipes `coreml/`) is bounded by this re-check; any orphaned `<epoch>.tmp/` left after a wipe is cleaned by the next-startup orphan sweep.

The `<epoch>.tmp/` path is invisible to `lookupOnDisk` (index-only) and excluded from the adoption-pass "complete" predicate (rule 5: no `.tmp` suffix), so concurrent lookups cannot see partial state.

#### Phase B — `commitStore` (on-actor)

B0. **Cancellation re-check inside the actor.** If `Task.isCancelled`, delete `<epoch>.tmp/` and throw `CancellationError`.
B1. Re-check `lookupOnDisk(digest)`. If non-nil (another precompile finished while we compiled), delete our `<epoch>.tmp/` and return the existing `(url, epoch)` so the caller pins the already-stored entry.
B2. `rename(<digest>/<epoch>.tmp, <digest>/<epoch>.mlmodelc)` via `FileManager.moveItem`. Both endpoints are inside `coreml/models/<digest>/` (same volume by construction), so this rename is the atomic POSIX `rename(2)` underneath. The fresh-UUID destination cannot collide with a tombstoned-but-undeleted older epoch.
B3. Update the in-memory index (add entry with `digest` AND `epoch`). Write `index.json` atomically: write to `index.json.tmp`, `fsync`, then `rename` over `index.json`.

This is the ONLY phase that holds the actor; everything in it is bounded I/O (a same-volume rename and a small JSON write).

### `lookupOnDisk` semantics

**`lookupOnDisk(digest: String) -> (url: URL, epoch: UUID)?` is index-only.** It returns the URL of `models/<digest>/<epoch>.mlmodelc/` paired with the entry's `epoch`, if and only if `index.json` has an entry for `digest` whose `epoch` is not in `tombstones`. Filesystem state is never consulted. Specifically:

- A `<digest>/<epoch>.mlmodelc/` directory whose entry has been removed from `index.json` (by `invalidate` or `clearAll`) is invisible to lookup.
- A `<digest>/<epoch>.tmp/` directory is invisible regardless of index state.
- The only code path that walks the filesystem is the **adoption pass**, which runs at actor init when `index.json` is missing or unreadable.

### Cache tree invariant

The cache tree has one invariant maintained by every code path that creates or destroys it:

- `coreml/` exists, has `isExcludedFromBackup = true`.
- `coreml/models/` exists.
- `coreml/index.json` exists and is a schema-versioned JSON document (possibly with zero entries).

The single helper `ensureCacheTreeExists()` is responsible:

```swift
private func ensureCacheTreeExists() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    var rootURL = cacheRoot
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try rootURL.setResourceValues(values)
    try fm.createDirectory(at: cacheRoot.appendingPathComponent("models"),
                           withIntermediateDirectories: true)
}
```

It is called from: actor init, `clearAll()`, and the index-recovery path. After it returns, callers may freely write to `coreml/models/<digest>.tmp/` without `ENOENT` on the parent.

### Index recovery on app start

If `index.json` is missing, unreadable, or has a `schemaVersion` other than the compiled-in constant, the cache deletes the cache root, calls `ensureCacheTreeExists()` to re-establish the invariant tree, and writes a fresh empty `index.json`. (The `schemaVersion` mismatch case can only arise after a downgrade or a manual edit — neither is a hot path.)

**Adoption (index missing / unreadable / wrong-schema):** walk `models/` and adopt complete `<digest>/<epoch>.mlmodelc/` pairs.

A path under `models/` is **complete** (eligible for adoption) iff:

1. The first level matches `^[0-9a-f]{32}$` (canonical digest format).
2. The second level matches `^[0-9a-f-]{36}\.mlmodelc$` (canonical UUID epoch with the `.mlmodelc` suffix).
3. Both levels are directories (not regular files or symlinks).
4. The leaf contains a non-empty `coremldata.bin` — Core ML's mandatory weights file.
5. Neither level has a `.tmp` suffix.

Anything else under `models/` (malformed names, `.tmp/` directories, leaves missing `coremldata.bin`) is deleted as orphaned. Adopted entries take `epoch` from the on-disk UUID; `createdAt = now`, `lastAccessedAt = now`, and the on-disk directory size as `sizeBytes`. We do not reconstruct the original key fields from disk — the entry is treated as opaque except for digest-based lookup.

**Orphan sweep (valid-index branch):** at actor init, *also* on the happy path, walk `models/` once and delete any `<digest>/` that has no `index.json` entry, plus any `<digest>/<epoch>.mlmodelc/` whose `(digest, epoch)` is not in the index, plus any `<epoch>.tmp/`. This cleans up tombstoned-but-not-reaped epochs left over from a prior-process crash (the in-memory `tombstones` set didn't survive). Both the adoption pass and the orphan sweep hold the actor's serial executor for their duration; subsequent operations see a coherent on-disk state.

## LRU Eviction

- **Cap:** 8 most-recently-accessed entries (Q5=B). **v1 limitation:** there is no size-on-disk cap. Eight 28-block-at-37×37-FP16 entries can reach multi-GB total — if user reports surface this, a follow-up can add a byte-budget cap *in addition to* the count cap (the eviction loop already iterates by `lastAccessedAt`; adding a size predicate is a few lines). Documented here so a future contributor knows the choice was deliberate.
- **`lastAccessedAt`:** updated on every cache hit. Persistence is debounced to once per ~60 s of activity to avoid hammering disk.
- **Trigger:** runs after every successful cache-store. If `entries.count > 8`, evict by oldest `lastAccessedAt` until ≤ 8. The eviction pass observes the just-stored entry's pin count of ≥ 1 (`urlForKey` calls `acquireLocked` before returning) and skips it; eviction can only target the new entry after every caller has called `release()`.
- **Action:** delete `<digest>.mlmodelc/` recursively; remove from `index.json`. Runs in a detached `Task` after the handle is returned to the engine — never blocks launch.
- **Pinning:** in-use entries are explicitly pinned against eviction. Apple does not document `MLModel(contentsOf:)` as eagerly loading all weights; it may memory-map or lazy-load from `coremldata.bin` after construction. Deleting a `<digest>.mlmodelc/` directory under a live model would race with that lazy load. To be safe rather than rely on undocumented behavior, the actor maintains a refcount-keyed pin set, and the pin is acquired **atomically inside the actor turn that returns the URL**. Splitting "return URL" and "acquire pin" across two `await` boundaries would re-open the eviction race the pin set exists to close.

  `urlForKey` returns a `PinnedCacheURL` reference type instead of a bare `URL`. The pin happens before the actor function returns, on every successful return path; the caller releases via the token's `release()` method.

  **Why a class with a serial nonce, not a struct, and not `ObjectIdentifier`:** the actor needs a stable per-token identity so `release()` is **idempotent** — a struct's copy semantics would let a stale duplicate's `release()` decrement a count that now belongs to a different legitimate caller. Promoting to a class is necessary but **not sufficient**: `ObjectIdentifier(self)` is the object's address, and the allocator can reuse a freed slot for a new instance with the same `ObjectIdentifier`. Concrete hazard: caller A's explicit `release()` empties the pin set; A is deallocated; the allocator reuses A's slot for a fresh acquire B (so `OI(B) == OI(A)`); A's `deinit`-spawned deferred release finally runs and `set.remove(OI(A))` removes B's pin — eviction can then delete the directory under B's still-mmap'd `MLModel`, exactly the use-after-free the pin set exists to prevent. Fix: each token carries a `UInt64` serial minted by the actor at acquire time. Identity is independent of memory address; allocator reuse cannot collide.

  ```swift
  /// Pin set is keyed by (digest, epoch) so a tombstoned epoch's pin
  /// is independent of a freshly-recompiled epoch's pin.
  struct DigestEpoch: Hashable, Sendable {
      let digest: String
      let epoch: UUID
  }

  final class PinnedCacheURL: @unchecked Sendable {
      let url: URL
      let digest: String
      let epoch: UUID                           // ← which compile this token pins
      let serial: UInt64                        // ← stable across address reuse
      private weak var cache: CoreMLModelCache?

      init(url: URL, digest: String, epoch: UUID, serial: UInt64, cache: CoreMLModelCache) {
          self.url = url; self.digest = digest; self.epoch = epoch
          self.serial = serial; self.cache = cache
      }

      /// Idempotent. Safe to call from any actor.
      func release() async {
          guard let cache else { return }
          await cache.release(digest: digest, epoch: epoch, serial: serial)
      }

      deinit {
          // Safety net for callers that forget to call release().
          // Capture by value — self is dying.
          guard let cache else { return }
          let d = digest, e = epoch, s = serial
          Task.detached { await cache.release(digest: d, epoch: e, serial: s) }
      }
  }

  // Inside actor CoreMLModelCache:
  private var nextTokenSerial: UInt64 = 0
  private var pinnedSerials: [DigestEpoch: Set<UInt64>] = [:]
  private var tombstones: Set<DigestEpoch> = []

  /// Mints a new serial, inserts it into the pin set, and returns the token.
  /// Called on the same actor turn that produced `url`.
  private func acquireLocked(digest: String, epoch: UUID, url: URL) -> PinnedCacheURL {
      let serial = nextTokenSerial
      nextTokenSerial &+= 1                     // wraps at 2^64; ~58k years at 10^7/s
      let key = DigestEpoch(digest: digest, epoch: epoch)
      pinnedSerials[key, default: []].insert(serial)
      return PinnedCacheURL(url: url, digest: digest, epoch: epoch,
                            serial: serial, cache: self)
  }

  func release(digest: String, epoch: UUID, serial: UInt64) {
      let key = DigestEpoch(digest: digest, epoch: epoch)
      guard var set = pinnedSerials[key] else { return }
      set.remove(serial)
      if set.isEmpty { pinnedSerials.removeValue(forKey: key) }
      else            { pinnedSerials[key] = set }
      reapTombstoneIfUnpinned(key)              // see Invalidate below

      // If a previous eviction pass skipped a current epoch because it was
      // pinned, this release may have unblocked it. Cheap when under cap
      // (no detached task spawned). The over-budget guard makes this a
      // no-op in steady state.
      if currentEntryCount > evictionCap {
          Task.detached(priority: .utility) { [weak self] in
              await self?.runEvictionIfOverBudget()
          }
      }
  }

  /// True iff any pin is held against the *current* epoch of `digest`
  /// (i.e. the one currently in `index.json`). Eviction uses this.
  func isCurrentEpochPinned(_ digest: String) -> Bool {
      guard let entry = currentEntry(digest: digest) else { return false }
      let key = DigestEpoch(digest: digest, epoch: entry.epoch)
      return !(pinnedSerials[key]?.isEmpty ?? true)
  }
  ```

  `@unchecked Sendable` is honest: `weak var cache` forces `var` on the storage but is set once at init and never reassigned; everything else is `let`. The class is otherwise only mutated through actor calls.

  Every return path of `urlForKey` (cache hit, dedup wait, fresh compile) calls `acquireLocked(digest:epoch:url:)` and returns the resulting `PinnedCacheURL` on the same actor turn that produced the URL. Eviction filters out the *current epoch* of any digest with pins via `isCurrentEpochPinned(digest)`; if the cache is over budget but every current epoch is pinned, eviction is a no-op for this pass and re-runs after the next `release`. **Tombstoned epochs are not eligible for eviction at all** — they're already on the reap path and will be deleted as soon as their pins drain. The cache may stay temporarily over budget during heavy concurrent use — acceptable, since the alternative is a use-after-free against `MLModel`.

## Concurrency

`CoreMLModelCache` is an actor; all `index.json` reads/writes serialize naturally.

In-flight tracker:

```swift
private var inFlight: [String /* digest */: Task<(URL, UUID), Error>]   // task returns (url, epoch)
```

Lookup-or-compile flow (Q9=A — engine-launch waits for in-flight precompile). **The actor returns a URL only.** The caller (off-actor) constructs the `MLModel` from that URL, keeping the heavy load out of the actor's serial executor.

The single non-obvious invariant: **every clear of `inFlight[digest]` is CAS-guarded by `inFlight[digest] == task`.** With that guard in place, both success and failure paths can safely clear the slot — the comparison rejects the case where a fall-through caller has already replaced our task. Re-entry after a failure happens via recursion through `joinOrInstall`; the head-check and the assignment in `joinOrInstall` are on the same actor turn (no `await` between them), which is what serializes the install.

```swift
// Inside actor CoreMLModelCache:
func urlForKey(
    _ key: CoreMLCacheKey,
    priority: TaskPriority = .userInitiated,
    missCallback: @Sendable () async throws -> URL
) async throws -> PinnedCacheURL {
    let digest = key.digest

    if let hit = lookupOnDisk(digest) {                  // cache hit
        touch(digest)
        return acquireLocked(digest: digest, epoch: hit.epoch, url: hit.url)
    }

    return try await joinOrInstall(digest: digest,
                                   priority: priority,
                                   missCallback: missCallback)
}

private func joinOrInstall(
    digest: String,
    priority: TaskPriority,
    missCallback: @Sendable () async throws -> URL
) async throws -> PinnedCacheURL {
    // Head-check is synchronous — no actor yield between observing
    // the slot and writing to it below. This is what serializes
    // installs across concurrent callers.
    if let existing = inFlight[digest] {
        // Priority escalation: when our caller runs at a higher priority
        // than `existing` was created with (e.g., engine-launch
        // .userInitiated dedup'ing onto a precompile's .utility), Swift's
        // runtime elevates `existing`'s effective priority for the duration
        // of this await. No extra detached awaiter task needed — the
        // natural `try await existing.value` is the trigger. (Pre-condition:
        // the bridge `Task.detached` is spawned at the elevated priority,
        // not the default .medium; see Engine-thread bridging below.)
        do {
            let (url, epoch) = try await existing.value
            return acquireLocked(digest: digest, epoch: epoch, url: url)
        } catch {
            log.error("Awaited precompile failed (\(error)); retrying via joinOrInstall")
            // CAS-clear: only retract the slot if it still holds the task
            // whose failure we observed. If a concurrent fall-through caller
            // already replaced it, leave that replacement for the recursion
            // to find via the head-check above. `Task` is a struct; `==`
            // is identity-based ("two task values are equal iff they refer
            // to the same task instance"). `===` is for AnyObject and
            // would not compile.
            if inFlight[digest] == existing { inFlight[digest] = nil }
            return try await joinOrInstall(digest: digest,
                                           priority: priority,
                                           missCallback: missCallback)
        }
    }

    // The compile task returns (url, epoch). prepareTmp is nonisolated so the
    // cross-volume move runs off-actor; commitStore re-enters the actor only
    // for the fast same-volume rename + index update. A fresh UUID epoch is
    // minted in prepareTmp so a tombstoned older epoch's still-on-disk dir
    // cannot collide with the recompile target.
    let task = Task.detached(priority: priority) { [self] in
        let mlpackageURL = try await missCallback()
        let compiledURL  = try await MLModel.compileModel(at: mlpackageURL)
        let prep         = try await self.prepareTmp(digest: digest,
                                                     compiledURL: compiledURL)
        let stored       = try await self.commitStore(digest: digest,
                                                      epoch: prep.epoch,
                                                      tmpURL: prep.tmpURL)
        Task.detached(priority: .utility) { [self] in await self.runEvictionIfOverBudget() }
        return stored                                    // (URL, UUID)
    }
    inFlight[digest] = task

    let result: Result<(URL, UUID), Error>
    do { result = .success(try await task.value) }
    catch { result = .failure(error) }

    // CAS-clear on either path — safe because the identity check rejects
    // the case where a fall-through caller already replaced us.
    if inFlight[digest] == task { inFlight[digest] = nil }

    let (url, epoch) = try result.get()
    return acquireLocked(digest: digest, epoch: epoch, url: url)
}

// Public actor method — called by the off-actor caller when MLModel(contentsOf:)
// throws on what should have been a valid cache entry.
//
// Index removal is immediate (so retries miss). On-disk delete of the SPECIFIC
// (digest, epoch) directory is DEFERRED until that epoch's pin set drains —
// a concurrent caller whose MLModel(contentsOf:) succeeded may still be
// lazy-loading from coremldata.bin, so deleting under it would race with that
// load (the same rationale that motivates the pin set). Tombstoning on the
// (digest, epoch) tuple — not just digest — means a fresh recompile mints a
// different UUID and lands at a non-colliding directory.
//
// The caller's pin is intentionally NOT released here — release is the
// caller's responsibility (deferred via PinnedCacheURL).

// Caller passes the SPECIFIC epoch they failed on (from pinned.epoch). If the
// index has already moved on to a different epoch — because a concurrent
// caller already invalidated and recompiled — this is a no-op so we don't
// spuriously evict a freshly-good entry.
func invalidate(digest: String, epoch: UUID) async {
    log.error("corrupt(digest=\(digest), epoch=\(epoch)) — invalidating")
    let key = DigestEpoch(digest: digest, epoch: epoch)
    if let entry = currentEntry(digest: digest), entry.epoch == epoch {
        removeFromIndex(digest)                        // future lookups miss now
    }
    // Tombstone-or-delete is keyed on (digest, epoch), not on whether we just
    // touched the index — the caller's failed pin is what matters.
    if pinnedSerials[key]?.isEmpty == false {
        tombstones.insert(key)                         // disk delete deferred
    } else {
        try? FileManager.default.removeItem(at: epochURL(key))
    }
}

private func reapTombstoneIfUnpinned(_ key: DigestEpoch) {
    guard tombstones.contains(key),
          (pinnedSerials[key]?.isEmpty ?? true) else { return }
    try? FileManager.default.removeItem(at: epochURL(key))
    tombstones.remove(key)
}

private func epochURL(_ key: DigestEpoch) -> URL {
    cacheRoot.appendingPathComponent("models/\(key.digest)/\(key.epoch.uuidString).mlmodelc")
}

// ─────────────────────────────────────────────────────────────────────
// Internal actor helpers referenced above. Declared here for completeness;
// each is straightforward and elided from the design pseudocode.
// ─────────────────────────────────────────────────────────────────────
//
//   nonisolated let cacheRoot: URL                    // Application Support/<bundle>/coreml/
//   let evictionCap: Int = 8                          // Q5=B
//
//   private var entries: [String: IndexEntry]         // in-memory mirror of index.json
//   private var currentEntryCount: Int { entries.count }
//
//   private func currentEntry(digest: String) -> IndexEntry?
//   private func touch(_ digest: String)              // updates lastAccessedAt with 60s debounce
//   private func addEntry(digest:, epoch:, sizeBytes:, sourceFileName:)
//   private func removeFromIndex(_ digest: String)
//   private func writeIndexAtomically() throws        // .tmp + fsync + rename
//
//   private func runEvictionIfOverBudget() async      // skips entries with isCurrentEpochPinned()
//
// The PrecompileScheduler side has one helper used by clearAll():
//   func cancelAllPending() — drops queued tuples that haven't started.

// Off-actor caller (in the C++/Swift bridge function). The MLModel load
// is wrapped in a one-shot retry to handle corrupt-hit fall-through.
//
// CoreMLComputeHandle has an OPTIONAL pinnedURL because the bridge-timeout
// fall-through path (see Engine-thread bridging > Semaphore timeout) returns
// a handle whose .mlmodelc/ lives in temp directly, not in the cache. The
// handle's teardown deletes the temp dir if pinnedURL is nil.
struct CoreMLComputeHandle {
    let model: MLModel
    let pinnedURL: PinnedCacheURL?    // nil = legacy non-cached path
    // ... other Metal-context fields ...
}

func loadCoreMLHandle(key: CoreMLCacheKey, missCallback: ...) async throws -> CoreMLComputeHandle {
    // Up to one corruption-recovery retry. A second corrupt hit is a real bug
    // and should propagate to the engine launch (existing recovery banner).
    for attempt in 0..<2 {
        let pinned = try await cache.urlForKey(key, missCallback: missCallback)
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: pinned.url, configuration: config)
            // Success — the handle owns `model` AND `pinned` so the pin is
            // released when the engine tears the handle down.
            return CoreMLComputeHandle(model: model, pinnedURL: pinned, ...)
        } catch {
            // Release this pin and tell the cache to evict the entry. urlForKey
            // on the next iteration is guaranteed to miss → invokes missCallback
            // → recompiles. We invalidate BEFORE checking the attempt counter so
            // the next launch attempt doesn't re-hit the broken entry even when
            // we propagate (the retry counter resets between launches).
            await pinned.release()
            await cache.invalidate(digest: pinned.digest, epoch: pinned.epoch)
            log.error("MLModel(contentsOf:) failed digest=\(pinned.digest) attempt=\(attempt) error=\(error)")
            if attempt == 1 { throw error }
        }
    }
    fatalError("unreachable")  // for-loop bound is fixed at 2
}
```

**Why invalidate before the attempt-counter check:** even when we give up and throw, the broken entry is removed from disk. Otherwise the next launch attempt would re-hit the same corrupt cache entry — and the per-call retry counter wouldn't help, since it resets between launches.

The `MLModel(contentsOf:)` call is wrapped by the existing engine-thread-bridging Task (see *Engine-thread bridging* below); the actor never blocks on it.

### Engine-thread bridging

The engine thread (started in `ModelRunnerView.startKataGoThread`) is a non-MainActor `Thread` with no Swift async runtime. To cross into the actor, the C++ bridge spawns a `Task.detached { ... }` that performs the actor call and signals completion via a `DispatchSemaphore`. The engine thread waits on the semaphore. This is consistent with the existing C++/Swift interop patterns in `metalbackend.cpp`.

```
Engine thread (C++):
  let sem = DispatchSemaphore(value: 0)
  let resultBox = Box<Result<PinnedCacheURL, Error>>()
  Task.detached(priority: .userInitiated) {
      do {
          let pinned = try await cache.urlForKey(
              key,
              priority: .userInitiated,
              missCallback: { try await convertOnCooperativePool() })
          resultBox.value = .success(pinned)
      } catch {
          resultBox.value = .failure(error)
      }
      sem.signal()
  }
  // Bounded wait — see "semaphore timeout" below.
  if sem.wait(timeout: .now() + .seconds(600)) == .timedOut { … }
  return resultBox.value
```

**The bridge spawns at `.userInitiated` explicitly** because the engine thread is a POSIX `Thread`, not a `Task`, so there is no ambient priority for `Task.detached { ... }` to inherit. Without an explicit priority, the bridge `Task` starts at `.medium` and the priority-escalation mechanism (see *missCallback execution context* below) silently no-ops because the awaiter is not above the precompile's `.utility`.

#### `missCallback` execution context

`missCallback` runs INSIDE the detached compile task created by `joinOrInstall`, which means it executes on Swift's cooperative thread pool — never on the engine thread that called `urlForKey`. The engine thread is parked on the bridge semaphore and **MUST NOT** be re-entered while that wait is in progress. `convertOnCooperativePool()` is a thin Swift wrapper around `KataGoSwift::convertCoreMLToTemp(...)`, a synchronous C++ entry point that internally calls the existing `CoreMLConversion::convertModelToTemp`. Because this runs on the cooperative pool (not the engine thread), the engine thread remains free to be parked on the semaphore without deadlock.

#### Reentrancy assumption

`katagocoreml::KataGoConverter::convert` must be safe to call from any thread and to be called concurrently with itself for distinct outputs. The existing per-server-thread call site at `metalbackend.cpp:445` already relies on this implicitly when multiple Metal mux-ANE threads boot in parallel; the cache makes the assumption explicit. Same-digest concurrent calls are deduped by the actor's in-flight tracker, so the converter only ever sees ONE in-flight invocation per digest.

#### Semaphore timeout

`sem.wait(timeout: .now() + .seconds(600))`. On timeout the bridge logs `engine.coreml.cache: bridge timeout digest=…`. Ten minutes is well above the worst observed compile (~30 s on a cold M3 Max) but bounds the failure mode if a future Core ML release stalls indefinitely. This is defensive — it covers hung compiles, not protocol deadlocks (which the `missCallback` thread-context pin above already prevents).

**Two-stage fall-through (bounds peak memory).** Naively cancelling the cooperative-pool task and immediately starting a direct compile on the engine thread would briefly run *two* `compileModel` invocations concurrently — each holding a `.mlpackage` open and a `.mlmodelc/` working set in RSS. Peak memory is ~2× a single compile, and on a 4 GB iPhone that risks OOM. Instead, on bridge-semaphore timeout the bridge does a **secondary bounded await** of 60 s on the same task before falling through:

```
if sem.wait(timeout: .now() + .seconds(600)) == .timedOut {
    log("engine.coreml.cache: bridge primary timeout — secondary 60s wait")
    let secondary = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        _ = try? await outstandingTask.value
        secondary.signal()
    }
    if secondary.wait(timeout: .now() + .seconds(60)) == .timedOut {
        log("engine.coreml.cache: bridge secondary timeout — direct compile")
        outstandingTask.cancel()
        return runLegacyCompileOnEngineThread()    // pinnedURL: nil
    }
    return resultBox.value                         // cooperative compile finished
}
```

60 s is long enough that a compile that's *just slow* (rather than truly hung) wins, and short enough that a real deadlock still falls through. In the slow-but-eventually-finishes case, only one compile runs and the cache benefits. In the truly-hung case, we still pay the 2× compile RSS, but only after 11 minutes of patience — at that point the user is going to retry anyway.

## Background Precompile

`PrecompileScheduler` is a single Swift `@Observable` class owned by the app, with three triggers (Q7=C):

| Trigger | Where | When |
|---|---|---|
| First app launch (and bundle upgrades) | Root view `.onAppear` | If `firstLaunchPrecompileVersion != CFBundleVersion`, enqueue built-in with default `BackendSettings`, then write the current `CFBundleVersion` into the AppStorage key. Re-fires after an upgrade that ships a different bundled `.bin.gz` |
| Download success | `Downloader` completion handler | After `BinFileHasher.computeAndStore`, enqueue the just-downloaded model with its current `BackendSettings` |
| Settings change | At the picker-write site inside `BackendConfigSheet` (each `Picker`'s `onChange`/binding setter) | Enqueue the new (model, settings) tuple as soon as the new value is written. Dedup by digest means rapid back-and-forth picker changes coalesce |

### Enqueue semantics

- **Backend guard.** Both entry points (`scheduleForModel(fileName:)` and `scheduleBuiltIn()`) read the per-model `@AppStorage("backend_\(fileName)")` value and **return early if the configured backend is `.mpsGPU`** — that backend doesn't run Core ML compile, so warming the cache for it is wasted work. On macOS where `.mpsGPU` is the default, this guard is what prevents every cold launch from precompiling for nothing. Skipped enqueues log `engine.coreml.cache: skip-precompile reason=mpsGPU fileName=…`. When the user later flips `.mpsGPU → .coreml` in `BackendConfigSheet`, the existing `onChange`-triggered `scheduleForModel` fires unconditionally because the guard re-reads the just-written backend value — so the guard is a one-way no-op and never strands users on the slow path.
- Each enqueue produces a `(digest, sourcePath, options)` tuple. Deduplicates by `digest` — already enqueued or in-flight → no-op.
- Internal queue concurrency = **1**. Compiling two models in parallel spikes memory; serializing keeps the working set predictable.
- Each task ends up calling `CoreMLModelCache.urlForKey(...)` — exactly the same method the engine calls. So precompile and engine-launch share the in-flight tracker, and Q9=A behavior emerges naturally.

### Lifecycle

- `PrecompileScheduler` enqueues at `.utility` (`Task.detached(priority: .utility)`) so background warming doesn't block UI. The actual compile work inside `urlForKey` runs at the priority the caller passes — `PrecompileScheduler` passes `priority: .utility`, and the engine bridge passes the default `.userInitiated`. If an engine-launch caller awaits a precompile-created `.utility` task via the dedup branch, **Swift's priority-escalation mechanism** elevates the awaitee's effective priority for the duration of the await — the natural `try await existing.value` is the trigger; no extra detached awaiter task is needed. (Pre-condition: the awaiter must itself be running at the elevated priority. The engine-bridge `Task.detached` is spawned at `.userInitiated` explicitly because the engine thread is a POSIX `Thread` and has no ambient priority for `Task.detached` to inherit; without that explicit priority, the bridge runs at `.medium` and escalation silently no-ops.) This keeps engine launch from being gated on `.utility` priority while still avoiding redundant work.
- On `scenePhase` transition to `.background`, the OS suspends naturally. We don't force-cancel. iOS may grant ~30 s of background execution before suspending; the atomic-write protocol prevents poisoned cache if suspension happens mid-write. On the next foregrounding the unfinished task starts over.
- No `BGTaskScheduler` integration in v1 — keeps things foreground-only and avoids entitlement surface.
- No battery / WiFi guards in v1. Compile is local, modest energy.

### Status reporting

`PrecompileScheduler` exposes `@Observable var status: [String /* fileName */: PrecompileStatus]`:

```swift
enum PrecompileStatus: Equatable, Sendable {
    case idle                       // no entry, not enqueued
    case ready                      // cache hit exists for current settings
    case queued                     // enqueued, waiting for slot
    case compiling                  // actively running
    case failed(message: String)    // human-readable; full Error logged to OSLog
}
```

`Equatable` lets `@Observable` dictionary diffing dedupe identical failure states (no view-update storms on a flapping retry). `Sendable` makes the cross-actor write from the detached precompile task into MainActor-isolated `@Observable` state compile-time-checked. The full `Error` still goes to OSLog with category `engine.coreml.cache` for diagnostics; the UI only needs the short string. Producer side:

```swift
} catch {
    let summary = (error as NSError).localizedDescription
    log.error("precompile.failed model=\(fileName) error=\(error)")
    await MainActor.run {
        self.status[fileName] = .failed(message: summary)
    }
}
```

The map is **reconciled** (not blindly rebuilt) on `ModelPickerView` appear by checking `CoreMLModelCache.contains(digest:)` for each model's current-settings digest. The reconciliation only writes `.idle ↔ .ready` transitions; it explicitly does NOT clobber any in-flight `.queued`, `.compiling`, or `.failed` value that the scheduler may have written between the user backgrounding and re-foregrounding the app. Otherwise a brief picker reappear during a long compile would visually reset the badge to `.idle`. Pruning: when a model is removed from `ModelPickerView` (e.g., user deletes a downloaded model), the corresponding `status[fileName]` key is removed in the same code path that frees the model file. There is no automatic GC; orphan keys (model deleted while app was backgrounded by a different process) are removed by the next reconciliation pass when the corresponding model is no longer in `NeuralNetworkModel.allCases.filter { $0.downloadedURL != nil }`.

## UI

### Per-model badge in `ModelPickerView`

A small status indicator on each row, to the right of the existing gear icon, bound to `PrecompileScheduler.status[model.fileName]`:

| Status | Visual | Accessibility label |
|---|---|---|
| `.ready` | `checkmark.circle.fill`, accent color | "Core ML cache ready" |
| `.compiling` | small `ProgressView()` (spinner) | "Compiling Core ML model" |
| `.queued` | `clock`, secondary color | "Waiting to compile Core ML model" |
| `.failed` | `exclamationmark.triangle`, orange | "Compile failed; will retry" |
| `.idle` | nothing (no badge) | — |

The badge does not replace any existing UI; it is purely additive. No tap gesture on the badge itself.

### `LoadingView` status string

In `LoadingView` (the spinner shown during engine launch), add a small status line below the existing label:

- Default: existing label.
- Cache miss in flight: `"Compiling Core ML model — first launch only"`.
- Awaiting in-flight precompile: `"Finishing Core ML compile…"`.
- Cache hit: nothing extra.

The status is wired through a new `EngineLaunchStatus` `@Observable` class. The C++/Swift bridge gets one new callback `reportLaunchStatus(_:)` that maps to enum cases. **All writes to `EngineLaunchStatus` published properties hop to MainActor** — the calls originate on the engine thread (a non-MainActor `Thread`) and on the cache actor, but SwiftUI requires `@Observable` mutations to be observed on the main actor. The implementation is `await MainActor.run { status.phase = … }` (or `Task { @MainActor in … }` for fire-and-forget transitions). Observers in `LoadingView` see consistent updates without thread-safety asserts.

### Cache footer in `ModelPickerView`

A footer section at the bottom of the model list, below the last row, separated by a subtle divider.

```
┌─────────────────────────────────────────────────────┐
│  Strong Igo Hatsuyoron 120 Net    [⚙]  [↓]          │
│  ─────────────────────────────────────────────────  │
│                                                     │
│  Core ML Cache                                      │
│  287 MB · 3 of 8 compiled models                    │
│                                  [ Clear Cache ]    │
└─────────────────────────────────────────────────────┘
```

- **Header:** `"Core ML Cache"` (`.font(.subheadline)`, `.foregroundStyle(.secondary)`).
- **Status line:** `"<formatted size> · <N> of 8 compiled models"`. Uses `ByteCountFormatter` for size. Updates reactively from `CoreMLModelCache`.
- **Clear button:** `Button("Clear Cache")`, `.bordered`, `.tint(.secondary)`.
- **Empty state:** entire footer collapses to a single line `"Core ML Cache · empty"` with no button.

### Clear Cache behavior

1. Tap → `.confirmationDialog` titled `"Clear Core ML Cache?"`. Body: `"All <N> compiled models will be removed. They will recompile on next use. The built-in model will recompile automatically in the background."` Destructive button `"Clear"`.
2. On confirm:
    - `CoreMLModelCache.clearAll()` removes everything under `coreml/`, recreates the invariant tree, writes a fresh empty `index.json`, and resets `inFlight = [:]`.
    - Reset `firstLaunchPrecompileVersion = ""` as a belt-and-suspenders guard for the cold-launch path (so a future cold launch re-warms even if the foreground re-warm below is interrupted).
    - **Directly call `PrecompileScheduler.scheduleBuiltIn()` from the confirm handler.** Do NOT rely on `.onAppear` to re-fire — `ModelPickerView` is the active view at this moment and the root view never disappeared, so its `.onAppear` will not run until the next backgrounding/foregrounding cycle. Direct enqueue means the user sees the built-in's status badge transition `.idle → .queued → .compiling → .ready` immediately, in the same picker session that initiated the clear.
    - Brief toast / status: `"Core ML cache cleared"`.
3. While clearing (rare; near-instant): button shows `ProgressView()` and is disabled.
4. The footer's stats update reactively as the cache is `@Observable`.

### Interaction with in-flight work

`clearAll()` runs while a `PrecompileScheduler` task may be queued or running, and while a `urlForKey` call from the engine bridge may be mid-flight. The protocol:

1. `PrecompileScheduler.cancelAllPending()` first — drops queued tuples that haven't started.
2. `CoreMLModelCache.clearAll()` then runs inside the actor. For each `task` in `inFlight.values`, call `task.cancel()`. **Do not await them.** Apple does not document `MLModel.compileModel` as cancellation-aware, so we assume it runs to completion regardless. The cancellation-checkpoint is `storeAtomically` (see below): it inspects `Task.isCancelled` *after* `compileModel` returns, deletes the Core ML temp output, and throws `CancellationError` without writing anything to `coreml/`. The wipe step below therefore races only against the brief window between `compileModel` returning and `storeAtomically` reading `Task.isCancelled` — a window the actor's serial executor closes naturally, since `clearAll()` and `storeAtomically` both run on the same actor.
3. Within the same actor critical section: delete the cache root, call `ensureCacheTreeExists()` to re-establish the invariant tree (so any post-wipe `storeAtomically` lands on a writable `coreml/models/`), write a fresh empty `index.json`, set `inFlight = [:]`. Cancelled tasks may still finish later; their `defer` slot-clearing becomes a no-op against the now-empty dictionary, and the round-3 identity guard (`inFlight[digest] == task`) handles the race naturally.
4. Set `firstLaunchPrecompileVersion = ""` last.
5. Foreground re-warm via `.onAppear` runs after `clearAll()` returns; it enqueues the built-in fresh. Any in-flight task that completes after the wipe will write its `<digest>.mlmodelc/` to a now-empty `coreml/models/` and add one entry to `index.json`. That's correct behavior — the user wanted the cache cleared, but a model they were actively launching getting cached is fine; a subsequent Clear Cache catches it.

**Engine-launch interaction:** if a `urlForKey` call is mid-flight when `clearAll()` runs, its detached compile task sees `Task.isCancelled` and throws `CancellationError`. The engine bridge maps this to "treat as compile failure" → engine launch fails cleanly with the existing recovery banner. Acceptable trade-off: the user just asked to clear the cache; a launch in flight at that exact instant being interrupted is rare and self-explanatory.

**`clearAll()` does not auto-schedule a re-warm.** It has no opinion on which model is currently selected, so re-warm scheduling is the caller's responsibility. The Clear Cache button calls both `clearAll()` and `PrecompileScheduler.scheduleBuiltIn()`; any future programmatic `clearAll()` entry point (debug menu, remote config kill-switch) is responsible for the same pairing. Centralizing the pairing in the call site keeps the actor narrow.

### Accessibility

- All badges have explicit `accessibilityLabel`.
- The `LoadingView` status string container uses `accessibilityAddTraits(.updatesFrequently)` so VoiceOver picks up the transition without spamming.

## Error Handling

| Failure | Response |
|---|---|
| Source `.bin.gz` missing at conversion time | Surface as today's "Failed to load model" — engine launch returns nil; `selectedModel` resets; recovery banner shows. No cache state mutated. |
| `katagocoreml` conversion throws | Same as today: temp `.mlpackage` cleaned up, error propagated, `selectedModel` resets. Cache state unchanged. |
| `MLModel.compileModel` throws | Delete the partial `.tmp` directory, propagate error, leave cache index untouched. |
| Cache hit but `MLModel(contentsOf:)` throws (corruption / unexpected format mismatch) | Q10=A: caller releases the pin, calls `cache.invalidate(digest:epoch:)` for the *specific epoch* it failed on, retries `urlForKey` once. The retry is a guaranteed miss → invokes `missCallback` → recompiles into a *fresh epoch UUID* (cannot collide with the tombstoned entry). A second `MLModel(contentsOf:)` failure on the freshly-compiled entry propagates to engine launch (existing recovery banner). The retry is bounded at one attempt to prevent infinite loops. `invalidate` runs before the attempt-counter check so even a propagated failure does not leave the broken `index.json` entry. **`invalidate` removes the `index.json` entry synchronously (only if the index still points at the failed epoch — a concurrent invalidate may have already moved on) but defers the on-disk directory delete until that `(digest, epoch)`'s pin set drains.** Reaped by `release(digest:epoch:serial:)` via `reapTombstoneIfUnpinned`. |
| Awaited in-flight precompile throws | Engine launch swallows the error, logs it, and starts a fresh owned compile (does NOT propagate the precompile failure to the engine). The CAS-guarded clear inside `joinOrInstall` retracts the failed task's slot only if it still holds that task; recursion through `joinOrInstall` re-checks the slot synchronously before installing a replacement. |
| Engine-bridge semaphore times out (>10 min) | Log `engine.coreml.cache: bridge timeout`, cancel the outstanding `Task`, fall through to the legacy direct-convert+compile path on the engine thread (today's behavior pre-cache). The fallback returns a `CoreMLComputeHandle(model:, pinnedURL: nil, …)` — `pinnedURL` is optional precisely so the cache's contract doesn't bleed into the timeout path. The handle's teardown deletes the temp `.mlmodelc/` since the cache doesn't own it. User sees a slow launch but no failure. Defensive bound for a hypothetical hung Core ML compile. |
| OS major-version upgrade after a cache was warmed | Key now includes `osMajorVersion`; the post-upgrade lookup is a clean miss, recompile runs normally. The pre-upgrade entries linger until natural LRU eviction; not a correctness issue, just transient disk use. |
| Atomic rename fails (disk full / permission) | Drop the in-memory result; do NOT update `index.json`; propagate error; engine launch fails cleanly. |
| `index.json` missing/unreadable on start | Treat as empty cache. Walk `models/` and adopt well-formed `<digest>.mlmodelc/` dirs; discard `<digest>.tmp/`. Log warning. |
| Hash memo mismatch (size/mtime changed) | Recompute hash, update memo, treat as different source identity (new digest, full miss). |
| LRU eviction can't delete a directory | Log; leave entry in `index.json`; next eviction pass retries. Doesn't block engine. |
| `Application Support` not writable | Cache disabled this session; engine falls through to existing convert+compile-every-time path. Single log line. |

## Observability

OSLog: `subsystem = bundleId, category = "engine.coreml.cache"`.

- `info`: `lookup(digest=…) → hit`, `miss → compiling`, `evicted(digest=…, reason=lru, freed=… MB)`
- `info`: `precompile.scheduled(model=…, trigger=download|settings|firstLaunch)`, `precompile.completed(model=…, duration=…s)`
- `error`: `corrupt(digest=…)`, `compile.failed(model=…, error=…)`
- One Signpost interval `coreml.compile` from miss-detected to handle-returned, so Instruments shows compile duration directly.

## Testing

In `KataGo iOSTests` (iOS Simulator only). Mirror the existing `RecoveryDecision` pattern for pure-logic tests.

| Test | What it covers |
|---|---|
| `CoreMLCacheKey_DigestStability` | Same fields → same digest; single field flip → different digest; JSON canonicalization is stable |
| `CoreMLCacheKey_BuiltInVsDownloaded` | Built-in identity uses bundle version; downloaded uses sha256 prefix |
| `CoreMLModelCache_HitMiss` | Pre-populate `<digest>.mlmodelc/` in temp `Application Support`; lookup hits; missing digest invokes miss callback exactly once |
| `CoreMLModelCache_LRUEviction` | Insert 9 entries; oldest is evicted; access updates `lastAccessedAt` |
| `CoreMLModelCache_AtomicWrite` | Simulate crash mid-write (only `<digest>.tmp/` present); next startup discards it |
| `CoreMLModelCache_CorruptHit` | Place a bogus directory at a digest name; lookup throws → entry deleted → miss callback invoked |
| `CoreMLModelCache_InFlightDedup` | Two concurrent `urlForKey` for same digest → miss callback invoked once; both return same URL |
| `CoreMLModelCache_PrecompileFailureFallthrough` | Precompile task throws; concurrent engine-launch caller catches the error, runs its own miss callback, returns a working handle |
| `CoreMLModelCache_FailedPrecompileFallthroughDoesNotPoisonInFlight` | After a fallthrough caller installs a replacement task in `inFlight[digest]`, the original creator's `defer` runs and must NOT clear the slot (identity guard). A third concurrent caller sees the replacement task, awaits it, and does not spawn a redundant compile |
| `CoreMLCacheKey_OSMajorVersionInKey` | Same fields with different `osMajorVersion` → different digest |
| `CoreMLCacheKey_BuiltInDispatchByPath` | A path equal to `Bundle.main.url(forResource: "default_model", ...)` resolves to `builtin:` identity; any other path resolves to `sha256:` identity |
| `CoreMLCacheKey_LegacyDownloadedFileHashOnDemand` | Downloaded file with no `UserDefaults` memo → `sourceIdentity(for:)` triggers `BinFileHasher` and writes the memo |
| `CoreMLModelCache_StoreCrossVolumeMove` | Stub a `compiledURL` on a different temporary volume; verify `prepareTmp` (off-actor) succeeds via `FileManager.moveItem` fallback (no EXDEV propagated). The subsequent `commitStore` (on-actor) sees a same-volume tmp and renames atomically |
| `CoreMLCacheKey_DigestPinnedConstant` | Frozen-digest test: a fixed sample key produces a known 32-hex constant. Any change to canonicalization fails this test rather than silently invalidating user caches |
| `CoreMLModelCache_ClearDuringInFlightCompile` | Start a compile that blocks in `missCallback`; call `clearAll()`; assert (a) cache is empty, (b) in-flight task receives cancellation, (c) `inFlight` is empty after wipe, (d) subsequent `urlForKey` for same digest succeeds (fresh compile path) |
| `PrecompileScheduler_FailedStatusEquatable` | Two `.failed(message: "x")` values compare equal; consecutive identical failure writes do not trigger redundant `objectWillChange` notifications (verify via `withObservationTracking` count) |
| `CoreMLCacheKey_BuiltInIdentity_MtimeIsQuantizedToMs` | Two `Date`s differing only in sub-millisecond precision (e.g., `1735689600.0001` vs `1735689600.0004`) produce identical `sourceIdentity` strings — protects against Foundation `Double`-formatting drift |
| `CoreMLCacheKey_BuiltInIdentity_NoDoubleInterpolation` | Built-in identity string's mtime segment contains no `.` — a literal dot would mean a regression to `\(Double)` interpolation |
| `CoreMLModelCache_TaskEquatableComparesByIdentity` | Compile-time documentation: declares `let _: (Task<URL, Error>, Task<URL, Error>) -> Bool = (==)` so a future contributor cannot "fix" `==` back to `===` (the latter would not compile, but this assertion makes the intent visible) |
| `CoreMLModelCache_ClearAll_PreservesModelsSubdir` | After `clearAll()`, `coreml/models/` exists and is writable. A subsequent `storeAtomically` does not throw `ENOENT` |
| `CoreMLModelCache_PinPreventsEviction` | An entry whose digest has a non-zero refcount is never selected by LRU eviction even when the cache is over budget; release decrements and a subsequent eviction can target the entry |
| `CoreMLModelCache_ThreeCallerRaceAfterFailure` | Force the ordering: creator's task fails → creator resumes first and exits → 3rd caller enters → 2nd caller's catch fires. Assert miss callback is invoked exactly twice (once for the failed task, once for the replacement) — never three times |
| `CoreMLModelCache_PriorityElevationOnDedup` | Inside a controllable `missCallback`, sample `Task.currentPriority` at two moments: (a) before any engine-launch caller arrives — must be `.utility`; (b) after a `.userInitiated` engine-launch caller starts awaiting via the dedup branch — must transition to `.userInitiated`. The transition is what proves Swift's priority-escalation mechanism is active, not just the ending state |
| `CoreMLModelCache_CompileCompletesAfterCancel_DoesNotPoisonCache` | A `missCallback` returns a (real or stub) compiled URL; cancel the task before `storeAtomically` reads `Task.isCancelled`; assert (a) cache stays empty, (b) temp output is deleted, (c) `inFlight[digest]` ends up clear |
| `CoreMLCacheKey_RejectsStructuralCollisionBytes` | For each string field flowing into `canonicalBytes`, attempt construction with `"x=y"`, `"x\ny"`, `"x y"` and assert `preconditionFailure`. Input-side guard the frozen-digest test cannot provide |
| `CoreMLCacheKey_BundleVersionSanitization` | A CFBundleVersion containing disallowed bytes (e.g., `"1.0 dev=42"`) is sanitized to `"1.0_dev_42"` *before* assembly into `sourceIdentity`; the resulting string passes the structural-collision regex |
| `CoreMLModelCache_UrlReturnImpliesPin` | Immediately after `urlForKey` returns, the corresponding digest has `pinnedDigests[digest] ≥ 1`. Verify via a test-only `peekPinCount(digest:)` actor method |
| `CoreMLModelCache_NoEvictionRaceBetweenReturnAndAcquire` | Cap = 1; store entry A (pinned by caller_a); trigger a store of entry B inside caller_a's `MLModel(contentsOf:)` window; assert A's directory still exists when caller_a constructs its model |
| `ModelPicker_ClearCacheRewarmsBuiltInDirectly` | Wire the picker; tap Clear; confirm. Assert `PrecompileScheduler.scheduleBuiltIn()` is called exactly once before any view-lifecycle event fires (no background→foreground cycle in this test) |
| `RootView_BundleUpgradeRetriggersBuiltInPrecompile` | Set `firstLaunchPrecompileVersion = "1.0.41"`; simulate `CFBundleVersion = "1.0.42"`; fire `.onAppear`; assert `scheduleBuiltIn()` invoked exactly once and the AppStorage key is now `"1.0.42"`. Re-fire `.onAppear`; assert `scheduleBuiltIn()` is NOT invoked again |
| `CoreMLModelCache_CorruptHit_RetriesOnce` | Pre-populate `<digest>.mlmodelc/` with garbage that fails `MLModel(contentsOf:)`. Run caller flow with stub `missCallback` producing a valid compiled directory. Assert (a) `invalidate(digest:)` called exactly once, (b) `missCallback` invoked exactly once, (c) second `MLModel(contentsOf:)` returns successfully, (d) `index.json` ends with one entry, (e) the on-disk entry is the freshly-compiled one |
| `CoreMLModelCache_CorruptHit_PersistentCorruptionPropagates` | `missCallback` returns a directory that also fails `MLModel(contentsOf:)`. Assert second failure throws out of caller flow (no third attempt), and `invalidate(digest:)` was called exactly twice (the entry doesn't linger after the second failure) |
| `CoreMLModelCache_ThreeCallerRaceAfterFailure_AnyOrder` | Force the resume order parametrically (originator-first, B-first, C-first). For each ordering: assert `missCallback` is invoked exactly twice (originator's task + replacement), `inFlight[digest]` ends pointing at the live replacement (or nil if it succeeded and was cleared), and all callers receive the replacement's result |
| `EngineBridge_MissCallbackOffEngineThread` | Capture `Thread.current` inside a stub `missCallback`; assert it is NOT the engine thread that initiated the bridge call. Guards against an implementer accidentally hopping the C++ converter back to the parked engine thread (which would deadlock) |
| `EngineBridge_SemaphoreTimeoutFallsThrough` | Stub the actor to never signal; assert the engine thread returns from `sem.wait(timeout:)` after the configured deadline, the outstanding `Task` is cancelled, and the bridge falls through to the legacy direct-convert+compile path |
| `CoreMLCacheKey_ServerThreadIdxNotInOptions` | Build-time / lint-time check that `katagocoreml::ConversionOptions` declares no field whose name contains `thread`, `idx`, `tid`, `server`, or `worker`. Implemented as a CI grep against the `ConversionOptions` declaration site if reflection isn't available, or as a static `static_assert` over a sentinel field-list. The exact form depends on how `ConversionOptions` is exposed; the goal is to convert "if a future change moves per-thread state into options, the cache silently corrupts" into a build failure |
| `PinnedCacheURL_ReleaseIsIdempotent` | Call `release()` twice on the same token; assertions reference `serial`. Pin set for that digest is empty afterward; an *independently-acquired* second token (different `serial`) on the same digest still holds the pin |
| `PinnedCacheURL_DeinitReleasesIfNotExplicit` | Drop a `PinnedCacheURL` reference without calling `release()`; after `await Task.yield()`, assert the actor's pin set for that digest is empty (the `deinit`-spawned `Task.detached` ran `release(digest:serial:)` with the captured serial) |
| `PinnedCacheURL_DeinitDoesNotReleaseRecycledAddress` | Acquire token A; `release()` it; drop A's reference; force enough allocator activity that A's slot is plausibly reused; acquire token B for the same digest (optionally assert `ObjectIdentifier(B) == ObjectIdentifier(A)` to prove the hazard would have triggered under the old design — skip on flaky simulator versions); drain the cooperative thread pool; assert `peekPinCount(digest:epoch:)` is exactly 1 for B's epoch, proving A's deferred deinit-release stripped the *correct* serial and did NOT remove B's pin. Regression guard against the `ObjectIdentifier`-as-identity hazard |
| `CoreMLModelCache_InvalidateThenRecompile_NoCollision` | Invalidate digest D (epoch E1) while caller B still pinned at E1; immediately call `urlForKey(D)`. Assert (a) recompile lands at a fresh epoch E2 ≠ E1, (b) both `<D>/<E1>.mlmodelc/` and `<D>/<E2>.mlmodelc/` coexist on disk, (c) B's `MLModel` continues to work, (d) after B releases, E1's directory is reaped and E2's remains |
| `CoreMLModelCache_ReapTargetsCorrectEpoch` | Two epochs of the same digest pinned concurrently; release the older epoch's last pin; assert only that epoch's `<digest>/<epoch>.mlmodelc/` is reaped; the newer epoch's directory and pin set are untouched |
| `CoreMLModelCache_OrphanSweepCleansCrashedTombstones` | Pre-populate `models/<D>/<E_orphan>.mlmodelc/` with no matching `index.json` entry (simulating a tombstoned epoch left by a prior-process crash). Boot the actor; assert orphan sweep deletes `<E_orphan>.mlmodelc/`, leaves index entries intact, and does not affect any current epoch's directory |
| `CoreMLModelCache_LookupOnDisk_IndexOnly` | Place a well-formed `<D>/<E>.mlmodelc/` on disk with no matching `index.json` entry; assert `lookupOnDisk(D)` returns nil. Then add the index entry; assert it returns `(url, E)`. Then add `D` to tombstones (simulating mid-flight invalidate); assert it returns nil again |
| `EngineBridge_SemaphoreTimeoutHandleHasNilPinnedURL` | Force the bridge to time out; assert the returned `CoreMLComputeHandle.pinnedURL == nil`; on handle teardown the temp `.mlmodelc/` is deleted; cache `index.json` and `models/` are unchanged |
| `CoreMLModelCache_ReleaseRetriesBlockedEviction` | Cap = 1. Store entry A; pin via `pinnedA = urlForKey(keyA, …)`. Store entry B (count = 2, over budget). Run `runEvictionIfOverBudget()` — no-op because A is pinned. Assert count = 2. `await pinnedA.release()`. `await Task.yield()` to let the detached eviction run. Assert count = 1 and the surviving entry is B. (Replaces or supersedes `…_PinPreventsEviction`.) |
| `CoreMLModelCache_StoreDoesNotBlockActorOnCrossVolumeMove` | Stub a `compiledURL` whose move to `<epoch>.tmp/` blocks for ≥ 200 ms (e.g., a fault-injecting `FileManager` wrapper). Call `urlForKey(keyA, …)` on a detached task; do not await yet. From a second task call `cache.contains(digest:)` — an actor method that returns immediately under normal load. Assert the second call's wall time is small (or simply that it returns *during* the long move, by ordering); then await the first task and assert success. Locks in the invariant that the actor isn't blocked on the slow move |
| `PrecompileScheduler_SkipsWhenBackendIsMPSGPU` | Stub `@AppStorage("backend_<fileName>") = .mpsGPU`. Call both `scheduleForModel(fileName:)` and `scheduleBuiltIn()`. Assert neither enqueues a task and both log the skip. Then flip backend to `.coreml` and call again; assert both now enqueue |
| `EngineBridge_TimeoutFallThroughBoundsMemory` | Stub the actor to never signal but the cooperative compile to finish at the 90s mark. Assert the bridge's primary 600s wait times out, the secondary 60s wait *also* times out (since 90s > 60s), the bridge falls through to the engine-thread compile, and at no point are two `compileModel` invocations in flight simultaneously after the secondary wait expires. (Also test the converse: cooperative compile finishes at the 30s mark of the secondary wait → bridge returns the cached result; no engine-thread compile fires.) |
| `IndexJSON_AdoptedEntryKeyIsNull` | Boot the actor with `index.json` missing but a complete `<digest>/<epoch>.mlmodelc/` on disk. After adoption, assert the in-memory `entries[digest].key == nil` and the on-disk `index.json` reflects the same — locks the diagnostic-only contract |
| `CoreMLModelCache_InvalidateRespectsPin` | Caller B holds a pin on digest D; caller A invalidates D. Assert (a) `index.json` no longer references D, (b) `<digest>.mlmodelc/` still exists on disk, (c) after B's `release()`, the directory is gone (reap fired) |
| `CoreMLModelCache_InvalidateRemovesIndexImmediately` | Invalidate a digest; immediately call `urlForKey` for the same key with a stub `missCallback`. Assert `missCallback` was invoked (the lookup missed because the index entry was already gone, even if the on-disk dir is still tombstoned) |
| `CoreMLCacheKey_BuiltInDispatchByPath_FirmlinkAware` | On macOS, construct a candidate URL by prefixing `/private` to the bundle URL's `/var/...` form (or the inverse, depending on what `Bundle.main.url` returns at test time). Assert `sourceIdentity(for:)` returns the `builtin:` form. Use `XCTSkipUnless` to skip on filesystems without firmlinks |
| `BinFileHasher_Memoization` | First call computes; second call same `(size, mtime)` reuses memo; size change forces recompute |
| `PrecompileScheduler_Dedup` | Enqueue same (model, settings) twice → only one compile runs |
| `RecoveryDecision_FirstLaunchFlag` | Existing recovery decision works alongside new `firstLaunchPrecompileVersion` AppStorage key |

### Not unit-tested (and why)

- Real `MLModel.compileModel` calls — slow, need `.mlpackage` fixtures. Covered by manual smoke test.
- Background scenePhase suspension — fragile; correctness rests on Q4=B (`Application Support` not auto-purged) and the atomic-write protocol.
- C++↔Swift bridge wiring — covered by an integration test that boots the engine on simulator with a tiny dummy model and asserts the second boot is faster than the first.

### Manual verification checklist

1. Cold install → built-in model precompiles in background → second app launch with built-in is fast.
2. Download FD3 → status badge transitions queued → compiling → ready → first launch is fast.
3. Change `coremlBoardSize` from 19 → 13 in BackendConfigSheet → background precompile fires → next launch fast at new size.
4. Switch back to 19 → cache hit (still in LRU) → instant launch.
5. Compile 10 distinct (model, size) combos → cache stays at 8 entries; oldest evicted.
6. Tap "Clear Cache" → footer shows "empty" → next launch slow → built-in precompile re-runs in background.

## Decisions Recorded

Linked back to clarifying-question answers so reviewers can find context:

- **Q1 = B** — cache target is the `MLModel.compileModel` step.
- **Q2 = C** — many entries with LRU eviction.
- **Q3 = C** — hybrid cache key: hash for downloaded, app-build-version for built-in, with `(size, mtime)` short-circuit for the memoized hash.
- **Q4 = B** — cache lives in `Application Support/`, marked `isExcludedFromBackup`.
- **Q5 = B** — count-based cap, 8 entries.
- **Q6 = D**, **Q7 = C** — surface "Compiling Core ML model" status during cache miss; precompile in background on download success, settings change, and first app launch (built-in).
- **Q8 = OK** — cache key composition as proposed; built-in does not hash bytes.
- **Q9 = A** — engine launch waits for in-flight precompile.
- **Q10 = A** — silently delete corrupt entry, fall through to recompile, log; atomic-write on store prevents poisoning.
- **Q11 = C** — Clear Core ML Cache button + per-model status badges, placed in the model picker (footer for the global Clear button, inline badge per row).

### Post-review fixes (round 1)

1. **Failed precompile dooming engine launch** — fixed by catching the `try await task.value` error in the in-flight branch and falling through to a fresh owned compile.
2. **OS major version omitted from key** — fixed by adding `osMajorVersion` field. Rationale reframed in the Cache Key section: this is conservative invalidation around platform-level codegen changes, not a claim of silent miscompute.
3. **`@AppStorage` cannot take dynamic key** — fixed by replacing with direct `UserDefaults.standard` reads/writes inside `BinFileHasher`, encapsulated behind `identityForDownloadedFile(_:)`.

### Post-review fixes (round 2)

1. **`MLModel(contentsOf:)` was inside the actor** — actor now returns a `URL` only; the off-actor caller constructs the `MLModel`. The actor's serial executor is no longer held during the (slow) compiled-model load.
2. **Digest construction owner was ambiguous** — Swift is now the explicit sole owner. C++ passes raw fields; Swift's `CoreMLCacheKey` initializer canonicalizes and SHA-256s. No second SHA-256 implementation on the C++ side.
3. **Built-in source identity was hash-free** — now hybrid `(CFBundleVersion, bundle-file-size, bundle-file-mtime)`, mirroring downloaded. Catches dev-rebuild-with-swapped-model at zero hashing cost.
4. **`BinFileHasher` thread context was unspecified** — now explicitly `async`, runs on `Task.detached(priority: .userInitiated)`, never on MainActor.
5. **`cacheFormatVersion` in the digest** — moved out of the per-entry digest into `index.json.schemaVersion` as a top-level guard. Schema mismatch wipes the cache root.
6. **`osMajorVersion` rationale overclaimed miscompute risk** — reframed as conservative invalidation; new sentence explicitly excludes device model from the key with rationale.
7. **`index.json.lock` had no defined mechanism** — dropped. The actor's serial executor is the authoritative serialization primitive; cross-process contention is not in scope.
8. **"Complete" was undefined for adopted directories** — now defined as a four-rule predicate (digest-format name, is a directory, contains non-empty `coremldata.bin`, no `.tmp` suffix).
9. **`BackendConfigSheet` trigger was tied to `onDismiss`** — moved to the picker-write site (each `Picker`'s binding setter), so settings changes are scheduled immediately and dedup naturally absorbs rapid toggling.
10. **`EngineLaunchStatus` MainActor handling was implicit** — now explicit: writes from engine thread / cache actor hop to MainActor via `MainActor.run` / `Task { @MainActor in … }`.

### Post-review fixes (round 3)

1. **In-flight tracker race after failure fall-through** — original creator's `defer` could clear a slot that a fall-through caller had already overwritten with a replacement task, causing a third caller to spawn a redundant compile. Fixed with an identity guard: `defer { if inFlight[digest] === task { inFlight[digest] = nil } }`. New test `…_FailedPrecompileFallthroughDoesNotPoisonInFlight`.
2. **`sourceIdentity` dispatch was unspecified** — no rule for built-in vs downloaded selection, no path for legacy downloaded files lacking a `UserDefaults` memo, no statement about path-comparison semantics. Added concrete `sourceIdentity(for:)` Swift sketch using `URL.standardized` against the bundle resource URL, with explicit on-demand hash for legacy memos and graceful degradation if the bundle resource is missing. New tests `…_BuiltInDispatchByPath` and `…_LegacyDownloadedFileHashOnDemand`.
3. **Cross-filesystem rename (EXDEV)** — `MLModel.compileModel` may write to a different volume than `Application Support` on macOS, so the first move could fail with `EXDEV`. Atomic-write protocol now uses `FileManager.moveItem` for the compile-output → `<digest>.tmp/` step (handles cross-volume via copy+remove), and explicitly notes that step 3's rename remains atomic because both endpoints are inside `coreml/models/`. New test `…_StoreCrossVolumeMove`.

### Post-review fixes (round 4)

1. **Digest canonical encoding was unpinned** — original spec said "stable canonical JSON encoding" but `JSONEncoder` defaults to non-deterministic key ordering, and number/bool encoding has shifted across Foundation versions. Replaced with a hand-rolled `key=value\n` format with explicit field ordering, integer/bool serialization rules, and a `canonicalBytes` Swift sketch. New `CoreMLCacheKey_DigestPinnedConstant` freezes the digest of a sample key to a known constant; any future canonicalization change fails this test loudly rather than silently invalidating user caches on OS upgrades.
2. **`clearAll()` semantics against in-flight work were unspecified** — added explicit protocol: cancel pending `PrecompileScheduler` tuples first, then enter the cache actor, cancel each `inFlight` task (without awaiting), wipe `coreml/`, reset `inFlight = [:]`, reset `firstLaunchPrecompileDone`. The round-3 identity guard naturally handles the race where a cancelled task's defer fires after the wipe. Engine launches in flight at the moment of clear see `CancellationError` → existing recovery banner. New test `…_ClearDuringInFlightCompile`.
3. **`PrecompileStatus` was not view-friendly** — `case failed(Error)` couldn't conform to `Equatable` (breaks `@Observable` dictionary diffing) or strict `Sendable` (cross-actor writes would fail compile-time checks). Changed to `case failed(message: String)`; full `Error` still logged to OSLog. Enum now `Equatable, Sendable`. New test `PrecompileScheduler_FailedStatusEquatable` verifies dedup behavior under `withObservationTracking`.

### Post-review fixes (round 5)

1. **`===` on `Task` would not compile** — `Task<URL, Error>` is a struct, not a class. `===` is the identity operator for `AnyObject`. Fixed to `==`, which is `Task`'s identity-based `Equatable` conformance ("two task values are equal iff they refer to the same task instance"). Updated the cross-reference in the `clearAll()` section. Added a compile-time documentation test `CoreMLModelCache_TaskEquatableComparesByIdentity` that declares `let _: (Task<URL, Error>, Task<URL, Error>) -> Bool = (==)` so a future contributor cannot regress to `===` (it would not compile, but the assertion makes the intent visible at the right spot in the test file).
2. **`Double` mtime in built-in `sourceIdentity` undermined the digest-stability guarantee** — `\(Double)` interpolation is exactly the trap that ruled out `JSONEncoder` for canonical encoding (formatting has shifted across Swift / Foundation versions). Quantize mtime to whole milliseconds and serialize as `Int64` base-10 instead. Added a note clarifying that `binFileMtime_<fileName>` (a `Double` `UserDefaults` value) is purely for the memoization equality short-circuit and never feeds into `canonicalBytes`. Extended the frozen-digest test to two samples (one built-in, one downloaded) so any drift in either canonicalization path fails CI. New tests `CoreMLCacheKey_BuiltInIdentity_MtimeIsQuantizedToMs` and `…_NoDoubleInterpolation`.

### Post-review fixes (round 6)

1. **`clearAll()` did not recreate `models/`** — wipe deleted `coreml/` but didn't re-establish the cache tree, so any post-wipe `storeAtomically` would fail at `moveItem` with `ENOENT` on the parent. Centralized the tree invariant in a new `ensureCacheTreeExists()` helper called from actor init, `clearAll()`, and the index-recovery path. New test `…_ClearAll_PreservesModelsSubdir`.
2. **LRU eviction could delete in-use entries** — the original "implicitly safe" claim relied on undocumented Apple behavior around `MLModel(contentsOf:)`'s lazy load from `coremldata.bin`. Replaced with explicit refcount-based pinning (`acquire(digest:)` / `release(digest:)`), and the eviction pass skips pinned digests. The cache may stay temporarily over-budget under heavy concurrent use; that's acceptable since the alternative is a use-after-free against a live `MLModel`. New test `…_PinPreventsEviction`.
3. **Three-caller race after precompile failure** — even with the round-3 identity guard, a brief actor-yield window between the failed creator's `defer`-clear and the second caller's catch fired could let a third caller spawn redundant work. Restructured: failed tasks no longer clear `inFlight[digest]` at all; the slot-clear is moved to the success path. The catch block in the dedup branch installs a replacement task synchronously via a new `installFreshCompileTask(...)` actor helper — no `await` between observation and assignment. New test `…_ThreeCallerRaceAfterFailure`.
4. **Inner compile-task priority was hardcoded `.userInitiated`** — contradicted `PrecompileScheduler`'s `.utility` outer task (the inner compile, which is the heavy work, would still run at `.userInitiated`). Threaded `priority` through `urlForKey`, defaulting to `.userInitiated` for engine launch. `PrecompileScheduler` passes `.utility`. On dedup, the awaiter's higher priority triggers Swift's priority-escalation mechanism — engine launch isn't gated on `.utility`. New test `…_PriorityElevationOnDedup`.
5. **`MLModel.compileModel` cancellation was overclaimed** — Apple does not document `compileModel` as cancellation-aware. Dropped the (a) cooperative-cancel branch entirely; spec now states `compileModel` runs to completion. The cancellation checkpoint is `storeAtomically`, which inspects `Task.isCancelled` after `compileModel` returns, deletes the Core ML temp output, and throws `CancellationError` without writing anything to `coreml/`. New test `…_CompileCompletesAfterCancel_DoesNotPoisonCache`.

### Post-review fixes (round 7)

1. **Canonical encoding admitted structural-collision bytes** — original spec just said strings are "validated ASCII-only at the call site." That left `=` and `\n` admissible, even though they're the canonical encoding's field separators; a future field value containing either could silently collide with a logically distinct key. Added an explicit regex `^[\x21-\x3C\x3E-\x7E]+$` (printable ASCII excluding `=`, `\n`, space, controls), `preconditionFailure` on violation, and a CFBundleVersion sanitizer that replaces disallowed bytes with `_` *before* assembly into `sourceIdentity`. New tests `…_RejectsStructuralCollisionBytes` and `…_BundleVersionSanitization`.
2. **Pin acquire was not atomic with URL return** — original spec had the off-actor caller call `await cache.acquire(digest:)` *after* `urlForKey` returned. The actor yield between return and acquire reopened the eviction race the pin set existed to close. `urlForKey` now returns a `PinnedCacheURL` token and pins on every return path before yielding control back. Caller releases via `pinned.release()`. The bare `acquire(...)` is no longer in the public surface. New tests `…_UrlReturnImpliesPin` and `…_NoEvictionRaceBetweenReturnAndAcquire`.
3. **Clear Cache re-warm relied on a `.onAppear` that never fires** — `ModelPickerView` is the active view at the moment of Clear; the root view never disappeared, so its `.onAppear` will not re-fire until the next background→foreground cycle. The Clear confirm handler now calls `PrecompileScheduler.scheduleBuiltIn()` directly. The `firstLaunchPrecompileVersion` reset is retained as a belt-and-suspenders guard for the cold-launch path, but is no longer load-bearing. Added a note that `clearAll()` itself does not auto-schedule — re-warm scheduling is the caller's responsibility, since `clearAll()` has no opinion on which model is currently selected. New test `ModelPicker_ClearCacheRewarmsBuiltInDirectly`.

### Post-review fixes (round 8)

1. **Bundle upgrade silently missed first-launch precompile** — the original `firstLaunchPrecompileDone` bool didn't observe bundle changes. After an app upgrade shipping a different `default_model.bin.gz`, the bool was still `true`, `.onAppear` skipped the precompile, but the new bundle's `(size, mtime)` produced a different `sourceIdentity` so the cache missed and the user paid full convert+compile on first foreground launch — exactly what spec goal #2 promises to avoid. Replaced the bool with a string `firstLaunchPrecompileVersion` holding the last bundle version that fired the precompile. `.onAppear` re-fires precompile whenever this differs from `CFBundleVersion`. New test `RootView_BundleUpgradeRetriggersBuiltInPrecompile`. Downgrade case (rare but possible via TestFlight or Xcode) is handled correctly by the same comparison — version mismatch re-fires; the older bundled model's `(size, mtime)` differs anyway so the cache would miss regardless.
2. **Corrupt-hit retry path was described in the error table but not pseudocoded** — the off-actor caller pseudocode had no `do/catch` around `MLModel(contentsOf:)`, so an implementer following the spec literally would propagate the throw and skip the recompile path. Added a public `cache.invalidate(digest:)` actor method that removes the on-disk entry and the `index.json` record (without touching the pin set — release stays the caller's responsibility). Replaced the off-actor pseudocode with a one-shot retry loop (`for attempt in 0..<2`). On `MLModel` failure the caller releases the pin, invalidates the digest, logs, and either retries (attempt 0) or throws (attempt 1). `invalidate` runs *before* the attempt-counter check so the broken entry doesn't linger across launches even when the caller ultimately propagates. New tests `…_CorruptHit_RetriesOnce` and `…_CorruptHit_PersistentCorruptionPropagates`.

### Post-review fixes (round 9)

1. **Round-6's "success-only-clear" pattern was a workaround that didn't actually serialize installs** — `installFreshCompileTask` lacked a head-check on `inFlight[digest]`, so when multiple fall-through callers raced their second-iteration installs could each spawn a redundant compile. Replaced with a single recursive helper `joinOrInstall` whose head-check and assignment occur on the same actor turn (no `await` between them). The new invariant is that **every clear of `inFlight[digest]` is CAS-guarded by `inFlight[digest] == task`** — both success and failure paths can safely clear, because the identity check rejects the case where a fall-through caller already replaced our task. The three-caller failure walk now lands on exactly 2 compiles regardless of resume order. The round-6 `installFreshCompileTask` helper is gone; the round-6 "no-await between catch and assignment" invariant is replaced by the `joinOrInstall` head-check invariant. New parametric test `…_ThreeCallerRaceAfterFailure_AnyOrder` (the original `…_ThreeCallerRaceAfterFailure` is subsumed; in the test list the `_AnyOrder` variant supersedes it).
2. **`missCallback` thread context, `convertModelToTemp` reentrancy, and bridge-semaphore timeout were unstated** — the engine-thread bridging section now explicitly pins the `missCallback` to the cooperative thread pool (NEVER the engine thread, which is parked on the bridge semaphore), states the reentrancy contract for `katagocoreml::KataGoConverter::convert` (already implicit at the per-server-thread call site, now explicit), and bounds the bridge wait at 10 minutes with a fall-through to the legacy direct-compile path on timeout. New tests `EngineBridge_MissCallbackOffEngineThread` and `EngineBridge_SemaphoreTimeoutFallsThrough`. Error-handling table gains a row for the timeout case.

### Post-review fixes (round 10)

1. **"Structured priority inheritance" was the wrong term, and the bridge spawn missed an explicit priority** — Apple's mechanism here is **priority escalation** (a higher-priority awaiter elevates the awaitee's effective priority for the duration of the wait), not the parent-child priority inheritance used by `async let`/`TaskGroup`. The natural `try await existing.value` already triggers escalation; the round-9 redundant `Task.detached(priority: priority) { _ = try? await existing.value }` was unnecessary and obscured which mechanism does the work. Removed it. Pre-condition added explicitly: escalation only fires if the awaiter is itself running at the elevated priority. The engine thread is a POSIX `Thread` with no ambient priority for `Task.detached` to inherit, so the bridge `Task.detached` is now spawned at `.userInitiated` explicitly — without that, the bridge runs at default `.medium` and escalation silently no-ops. Strengthened `…_PriorityElevationOnDedup` to assert the pre-arrival (`.utility`) → post-arrival (`.userInitiated`) **transition** inside `missCallback`, not just the ending state.
2. **`serverThreadIdx` exclusion from the key was unstated** — verified against `cpp/neuralnet/metalbackend.cpp`: `serverThreadIdx` is passed to `convertModelToTemp` but only feeds `generateTempPath(...)` and `cerr` lines; it is not a member of `ConversionOptions` and never reaches `katagocoreml::KataGoConverter::convert`. Two threads converting the same options produce byte-identical `.mlpackage` output. Added an explicit "Why `serverThreadIdx` is NOT in the key (audit)" paragraph documenting the audit and the regression risk. New test `CoreMLCacheKey_ServerThreadIdxNotInOptions` enforces the contract at build/CI time, since the digest is pinned by `…_DigestPinnedConstant` and a silent options-field change would corrupt user caches before the digest test caught it.

### Post-review fixes (round 11)

1. **`PinnedCacheURL.release()` was not idempotent** — token was a struct, copies share the same digest, and the `Int` refcount couldn't tell which token released. A stale duplicate's `release()` would decrement a count that now belonged to a different legitimate caller, evicting an entry whose `MLModel` was still mmap'd to it (use-after-free, the exact failure mode the pin set existed to prevent). Promoted `PinnedCacheURL` to `final class @unchecked Sendable` so each acquire has stable identity. Replaced `pinnedDigests: [String: Int]` with `pinnedTokens: [String: Set<ObjectIdentifier>]` so set-remove is naturally idempotent. Added `deinit` as a safety net for callers that forget to release. Threaded the `token: ObjectIdentifier` parameter through every `acquireLocked` call site. New tests `PinnedCacheURL_ReleaseIsIdempotent` and `PinnedCacheURL_DeinitReleasesIfNotExplicit`.
2. **`cache.invalidate(digest:)` ignored pins** — eviction filtered pinned digests but `invalidate` deleted on-disk unconditionally. If caller A's `MLModel(contentsOf:)` failed on a digest while caller B's load on the same digest succeeded, A's invalidate would delete the directory under B (same use-after-free as above). Split `invalidate` into two effects: index removal is immediate (so retries miss), on-disk delete is deferred via a `tombstones: Set<String>` reaped from `release(digest:serial:)` once `isPinned(digest)` returns false. Error-handling table updated. New tests `CoreMLModelCache_InvalidateRespectsPin` and `…_InvalidateRemovesIndexImmediately`.
3. **`URL.standardized` does not resolve symlinks** — round-3 prose claimed it did. It only canonicalizes `..` and trailing slashes. On macOS the bundle URL surfaces as `/var/...` while `URL(fileURLWithPath:)` surfaces as `/private/var/...` (firmlink), and `==` doesn't equate them. Result: built-in dispatch falls through to the downloaded path, `BinFileHasher` hashes the 100 MB bundle file, first-launch ergonomics regress to the slow path. Replaced both sides with `.resolvingSymlinksInPath().standardizedFileURL`, which does collapse firmlinks. Updated the prose claim. New test `CoreMLCacheKey_BuiltInDispatchByPath_FirmlinkAware`.

### Post-review fixes (round 12)

1. **`ObjectIdentifier` as the per-token identity was unsafe across deallocation** — round 11 promoted `PinnedCacheURL` to a class so each acquire would have a unique identity, but `ObjectIdentifier(self)` is the object's address, and the allocator can reuse a freed slot for a new instance with the same `ObjectIdentifier`. Concrete hazard: caller A's explicit `release()` empties the pin set; A is deallocated; the allocator reuses A's slot for a fresh acquire B (so `OI(B) == OI(A)`); A's `deinit`-spawned deferred release runs and `set.remove(OI(A))` strips B's pin — eviction can then delete the directory under B's still-mmap'd `MLModel`, exactly the use-after-free the round-11 class promotion was supposed to prevent. Fix: each token carries a `UInt64 serial` minted by the actor at acquire time. Identity is independent of memory address; allocator reuse cannot collide. Replaced `pinnedTokens: [String: Set<ObjectIdentifier>]` with `pinnedSerials: [String: Set<UInt64>]`. `acquireLocked(digest:url:) -> PinnedCacheURL` now mints the serial inside the actor and returns the token; `release(digest:serial:)` and `reapTombstoneIfUnpinned` updated. Three call sites in `urlForKey` / `joinOrInstall` collapsed (the actor mints the token internally now). Wraparound is unreachable in practice (~58k years at 10^7 acquires/s). Updated `…_ReleaseIsIdempotent` and `…_DeinitReleasesIfNotExplicit` to assert on `serial`. Added `PinnedCacheURL_DeinitDoesNotReleaseRecycledAddress` as a regression guard against the address-reuse hazard.

### Post-review fixes (round 13)

1. **Tombstoned `<digest>.mlmodelc/` collided with the recompile path** — `invalidate(digest:)` deferred the on-disk delete (round 11) but kept the same directory name. The corrupt-hit retry's `storeAtomically` then tried `rename(<digest>.tmp, <digest>.mlmodelc)`, which failed because the tombstoned directory was still on disk. The promised retry path was broken. Fix: per-entry `epoch: UUID` in the on-disk path. The new layout is `coreml/models/<digest>/<epoch>.mlmodelc/`. `index.json` entries gain `epoch`. Pin set keyed on `DigestEpoch` so a tombstoned epoch's pins are independent of a freshly-recompiled epoch's pins. `invalidate(digest:epoch:)` accepts the specific epoch the caller failed on (no-op if the index already moved on). `release(digest:epoch:serial:)` and `reapTombstoneIfUnpinned(_ key: DigestEpoch)` updated. The fresh-UUID destination cannot collide with a tombstoned older epoch, so step 4 of the atomic-write protocol is collision-free by construction. New tests `…_InvalidateThenRecompile_NoCollision` and `…_ReapTargetsCorrectEpoch`.

2. **`lookupOnDisk` semantics were undefined** — the function was referenced four times but never defined. With round-11 tombstones, the distinction between filesystem-based and index-based lookup became load-bearing — a filesystem-based lookup would be fooled by a tombstoned-but-undeleted directory. Defined explicitly as **index-only**: returns `(url, epoch)` iff `index.json` has an entry whose `epoch` is not in `tombstones`; filesystem state is never consulted. Atomic-write step 3's "if `<digest>.mlmodelc/` already exists" prose tightened to "if `lookupOnDisk(digest)` returns non-nil." Added an **orphan sweep** at actor init (the valid-index branch, alongside the existing adoption pass on the missing-index branch) that walks `models/` once and deletes any directory not referenced by `index.json` — closes the gap of tombstoned epochs left over from a prior-process crash where the in-memory `tombstones` set didn't survive. New tests `…_LookupOnDisk_IndexOnly` and `…_OrphanSweepCleansCrashedTombstones`.

3. **Bridge timeout fall-through handle shape was undefined** — round-9's error-table row promised "fall through to the legacy direct-convert+compile path on the engine thread" but the cache-aware `loadCoreMLHandle` path returns `CoreMLComputeHandle(model:, pinnedURL:, …)`, leaving the legacy path's handle shape ambiguous. Fix (cleanly composed with the epoch redesign): `CoreMLComputeHandle.pinnedURL` is **optional**. The legacy fallback returns `pinnedURL: nil` and owns its `.mlmodelc/` in temp directly; handle teardown deletes the temp dir if `pinnedURL` was nil. Two callers downstream see this — handle teardown (conditional cleanup) and any diagnostic that prints a digest. Both are one-liners. New test `EngineBridge_SemaphoreTimeoutHandleHasNilPinnedURL`.

### Post-review fixes (round 14)

1. **`release()` did not retry blocked eviction** — the spec promised "if the cache is over budget but every current epoch is pinned, eviction is a no-op for this pass and re-runs after the next `release`," but the round-13 pseudocode only triggered eviction from `storeAtomically`'s detached follow-up, never from `release`. Consequence: an over-budget cache whose only pin-protected entries finally drained stayed over budget until the *next* store. Added a guarded eviction kick from `release(digest:epoch:serial:)` — only when `currentEntryCount > evictionCap`, so steady state under cap doesn't spawn detached tasks per release. New test `CoreMLModelCache_ReleaseRetriesBlockedEviction` (extends the round-6 `…_PinPreventsEviction` semantics).
2. **`storeAtomically` ran the slow cross-volume move inside the actor** — `FileManager.moveItem` falls back to copy + remove on `EXDEV` (the macOS cross-volume case the spec explicitly handles), and a `.mlmodelc/` directory can be hundreds of MB. Holding the actor's serial executor through that copy stalled every concurrent `urlForKey` / `release` / `invalidate`, defeating the same critical-section-stays-short rationale that motivates returning a URL (not an `MLModel`) from the actor. Split into off-actor `prepareTmp(digest:compiledURL:) -> (epoch, tmpURL)` (slow move + cancellation re-check) and on-actor `commitStore(digest:epoch:tmpURL:) -> (url, epoch)` (cancellation re-check, dedup re-check, same-volume rename, index update). The `<epoch>.tmp/` path is invisible to `lookupOnDisk` (index-only) and to the adoption-pass "complete" predicate (rule 5 excludes `.tmp` suffix), so concurrent lookups cannot see partial state. The race with `clearAll()` is bounded by the cancellation re-checks; orphan `.tmp/` directories are cleaned by the next-startup orphan sweep. Round-3's `…_StoreCrossVolumeMove` now exercises `prepareTmp` directly. New test `CoreMLModelCache_StoreDoesNotBlockActorOnCrossVolumeMove`.

### Post-review fixes (round 15)

1. **`PrecompileScheduler` enqueued unconditionally regardless of backend** — `.mpsGPU` does not run Core ML compile, so on macOS (where `.mpsGPU` is the default) every cold launch precompiled for nothing, every download triggered a wasted compile, and every settings flip toward MPS spawned a no-op task. Added a `.mpsGPU` early-return guard at both entry points (`scheduleForModel(fileName:)` and `scheduleBuiltIn()`) keyed off the same `@AppStorage("backend_\(fileName)")` value `BackendConfigSheet` writes. The guard is one-way — flipping back to `.coreml` re-fires the unconditional `onChange` enqueue, so users are never stranded on the slow path. New test `PrecompileScheduler_SkipsWhenBackendIsMPSGPU`.
2. **Bridge-timeout fall-through could run two `compileModel` invocations concurrently** — naively cancelling the cooperative-pool task and immediately starting a direct compile on the engine thread briefly held two `.mlpackage` opens and two `.mlmodelc/` working sets in RSS. On a 4 GB iPhone that risks OOM. Added a **secondary bounded await** (60 s) on the same task before falling through. In the slow-but-eventually-finishes case, only one compile runs and the cache benefits; in the truly-hung case, we still pay the 2× compile RSS, but only after 11 minutes of patience. New test `EngineBridge_TimeoutFallThroughBoundsMemory`.
3. **`index.json entries[].key` field was undefined** — listed in the schema but no section said what's in it, who reads it, or what adopted entries put there. Spec'd as **diagnostic-only and nullable**: holds a human-readable rendering of the canonicalized cache-key fields for log inspection; no read path may branch on its contents or even on its presence; adopted entries write `key: null` because the original key fields cannot be reconstructed from disk. New test `IndexJSON_AdoptedEntryKeyIsNull`.

#### Non-blocking notes incorporated this round (deferred suggestions from the review):

- Documented that `computePrecision="FP16/FP32"` (cache key) deliberately differs from on-the-wire `"FLOAT16/FLOAT32"` (`metalbackend.cpp:69`) so a future "harmonization" doesn't invalidate every user's cache.
- Documented that EXDEV cross-volume copy in `prepareTmp` is uncancellable (`FileManager.moveItem` does not honor `Task.cancel()` mid-copy); the orphan `<epoch>.tmp/` is cleaned by the post-copy cancellation re-check or the next-startup orphan sweep.
- Added an internal-helpers block (`cacheRoot`, `evictionCap`, `entries`, `currentEntryCount`, `currentEntry`, `touch`, `addEntry`, `removeFromIndex`, `writeIndexAtomically`, `runEvictionIfOverBudget`, `cancelAllPending`) so previously-undeclared references have a stable home in the spec.
- `PrecompileScheduler.status` is now **reconciled, not rebuilt**, on `ModelPickerView` appear — only `.idle ↔ .ready` transitions; in-flight `.queued/.compiling/.failed` is preserved. Documented status-map pruning when a model is deleted.
- Documented the v1 limitation: 8-entry cap with no size-on-disk cap; a byte-budget can be added later without reworking eviction.
