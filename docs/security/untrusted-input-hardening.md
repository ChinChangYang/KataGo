# Untrusted-input hardening: checklist and A/B verification

Scope: the three ways untrusted input reaches the engine — **network files**,
**SGF / board size / GTP**, and **config / network surface** — as found by the
October 2026 audit. A = the code before this change (`ios-dev` @ `f52e3ea`),
B = with this change. Reproduction scripts live in [`ab/`](ab/).

Legend: ✅ fixed and A/B-verified by running it · 🧪 fixed, A/B written as
tests that need Xcode (no Swift toolchain on the Linux box this was done on) ·
⏭ deliberately deferred.

## Checklist

### Network files (C++)

- [x] ✅ **M1 — gzip bomb.** `FileUtils::uncompressAndLoadFileIntoString` now
  stops at `max(64 MiB, 16 × compressed size)`. Real nets inflate ~1.08×.
  `cpp/core/fileutils.cpp`
- [x] ✅ **M2a — allocation before read.** `readFloats` and the conv / matmul /
  matbias readers no longer `resize` to the file's *declared* count before
  reading. They grow in 1 Mi-float chunks as bytes actually arrive. *(Found
  while fixing M2: a 116-byte file drove the engine to 12.5 GB.)*
  `cpp/neuralnet/desc.cpp`
- [x] ✅ **M2b — int overflow in weight counts.** The conv and matmul counts
  are computed in 64-bit and must fit an `int` (downstream indexing is
  `int`). `cpp/neuralnet/desc.cpp`
- [x] ✅ **M3 — input channel counts.** `ModelDesc` now throws unless
  `numInputChannels` / `numInputGlobalChannels` equal the model version's
  feature counts. Before, only an `assert` in `mlxbackend.cpp` guarded the
  buffer copy, and `NDEBUG` would turn a mismatch into a heap overflow.
  (Value, score, policy and ownership channels were already validated in
  `desc.cpp`; the audit overstated that part.) `cpp/neuralnet/desc.cpp`
- [x] ✅ **M4 — CoreML converter parser.** It now rejects non-positive or
  overflowing dimensions (matmul / matbias had no checks) and reads floats
  incrementally. `cpp/external/katagocoreml/src/parser/KataGoParser.cpp`
- [ ] ⏭ **M4b — converter failure on an NN server thread still calls
  `std::terminate`** (`nneval.cpp:362`, by upstream design). With M1–M4 the
  converter only sees files `desc.cpp` already accepted, so this is now
  hard to reach. Making it graceful needs an engine-lifecycle change and an
  Apple build to test, so it is out of scope here.

### SGF / board size / GTP (Swift)

- [x] 🧪 **S1 — `SZ` smuggled through a comment.** `SgfHeaderScan` now reads
  `SZ`/`KM`/`RU`/`PL` from the **root node's properties only**, with the
  C++ lexer's rules (letter keys, `\` escapes, repeated keys). It reports
  `boardSizeIsSupported`, and the dimensions are always clamped to 2…37.
  `SgfReplay` clamps, `GoBoard.init` bounds both edges, and
  `ForcePlay.resolve` returns `nil` past 37.
  `KataGoAnalysisKit/SgfHeaderScan.swift`, `GoRulesKit/{SgfReplay,GoBoard,ForcePlay,GoGame}.swift`
- [x] 🧪 **S2 — Safari decoy size.** Both Safari extensions and
  `ListeningPrepareDriver` also require `scan.boardSizeIsSupported` before
  their size gate. The scan now agrees with `loadsgf` on the size.
  `KataGoAnytimeSafariExt/AnalysisJobRunner.swift`,
  `KataGoAnytimeSafariExtIOS/IOSAnalysisService.swift`,
  `KataGoUICore/Listening/ListeningPrepareDriver.swift`
- [x] 🧪 **S3 — iMessage komi.** Decode rejects `k` outside ±2000 half points
  (the app-wide ±1000 komi clamp). Encoding goes through `halfPoints(_:)`,
  which cannot trap. `GoRulesKit/MessageGameCodec.swift`
- [x] 🧪 **sgfHash.** A `start` request must carry 64 lowercase hex digits.
  The hash names spool and cache files and rides a `loadsgf` line.
  `KataGoAnalysisKit/AnalysisWire.swift`

### Config / network / supply chain

- [x] ✅ **CI downloads pinned.** `ci_post_clone.sh` checks the SHA-256 of all
  three bundled nets. **The hashes are trust-on-first-use** (what GitHub
  served on 2026-10-04). Confirm them against your own copies:
  - default `9d7a6afe…a51f1d`
  - human `637746e4…d84ab5`
  - Safari `ec1ee64e…c711d33`
- [ ] ⏭ **In-app catalog downloads have no hash pin**
  (`NeuralNetworkModel.swift`; TLS + a fixed host today). Needs the catalog's
  hashes and a product decision about custom URLs.
- [ ] ⏭ **macOS helper inherits the full app sandbox** (`security.inherit`).
  That isolates crashes but does not limit privileges; fixing it is a design
  change.

## A/B results

### Model files: `cpp/` built with Eigen, Release (`NDEBUG`), Linux x86-64

`ab/craft.py` derives each hostile file from the repo's
`g170-b6c96-…bin.gz`. `ab/run_models.sh` starts `katago gtp` on each one.

| Input (size on disk) | A: peak RSS · outcome | B: peak RSS · outcome |
|---|---|---|
| g170 control | 70 MB · plays `R16` | 71 MB · plays `R16` |
| M1 bomb (1.5 MB → 1.5 GB) | **2.13 GB** · parse error | 161 MB · "decompressed size exceeds the limit" |
| M2a conv 1×1×40000×40000 (**116 B**) | **12.5 GB** · parse error | 33 MB · "did not find the expected number of floats" |
| M2b conv 1×1×65536×65537 (122 B) | `std::bad_alloc`, no message | 30 MB · "layer has too many weights" |
| M3 1 global channel, v8 (3.8 MB) | Eigen `testAssert` FATAL (MLX: assert only → overflow under `NDEBUG`) | "numInputGlobalChannels (1) does not match … (19)" |

The same runs under **AddressSanitizer** show the same pattern: A on the
overflow file dies with "AddressSanitizer: out of memory, trying to allocate
0x400040000 bytes". B produces **no ASan reports** on any hostile file or any
of the 10 repo models.

**CoreML converter parser** (`ab/parsedrv.cpp`, ASan):

| Input | A | B |
|---|---|---|
| control | parses, 19 MB | parses, 19 MB |
| M2a huge conv | rejects only after **6.26 GB** | rejects at 14 MB |
| M2b overflow | **ASan OOM crash** | "layer has too many weights" |
| M4 matmul in = −1 | `std::length_error` ("vector larger than max_size") | "layer dimensions must be positive" |

**No regression:**
- `kata-raw-nn 0` output is **byte-identical A vs B** for all 10 repo
  models (5 binary incl. transformer nets, 5 text-format) and for the three
  shipped nets (default 18b, human SL, Safari 24b).
  - The human net showed one DIFF on the first pass. Three reruns (A vs A,
    A vs B) were identical, so it was a one-off.
- `katago runtests` on B: *All tests passed*.

### SGF: real C++ `loadsgf` as ground truth

The engine was built with `COMPILE_MAX_BOARD_LEN=37` (as the app is) and run
with a 19×19 NN buffer (as the Safari extensions are).

| SGF | C++ `loadsgf` | A scan (old regex) | B scan (root node) |
|---|---|---|---|
| `C[x\]SZ[100000:100000]SZ[19];B[dd]` | 19×19, plays | **100000×100000** (10¹⁰-cell board) | 19×19 ✓ |
| `C[x\]SZ[9]SZ[37];B[aa]` (S2 decoy) | 37×37 → **process terminates** on first eval | **9×9 → passes the ≤19 gate** | 37×37 → refused ✓ |
| `C[a\]SZ[3]SZ[13]` | 13×13 | 3×3 | 13×13 ✓ |
| `SZ[9]SZ[13]` | rejected, "not a singleton" | 9×9 | unsupported → refused ✓ |
| `;GM[1];SZ[9]B[aa]` (SZ not in root) | 19×19 | 9×9 | 19×19 ✓ |
| `SZ[4000000000:4000000000]` | rejected (> MAX_LEN) | 4·10⁹ squared (trap) | clamped 37, unsupported ✓ |

The A and B scan columns come from `ab/scan_port.py`, a line-for-line Python
port of the old regex and the new scanner. It checks the algorithm, not the
compiled Swift.

### Swift unit tests (run on a Mac)

These tests encode the A/B. Each one fails on A and passes on B.
- `SgfHeaderScanTests`: smuggled size, decoy, escape, non-root `SZ`, root-only
  `KM`/`RU`/`PL`, 12 unsupported sizes, exact supported sizes.
- `SgfReplayTests`: comment-smuggled size, hostile geometry clamp,
  out-of-range root size, `ForcePlay` over 37.
- `GoRulesKitTests` (iMessage): komi `Int.max` / `Int.min` / ±2001 rejected,
  edge values round-trip, `halfPoints` never traps.
- `KataGoAnalysisKitTests`: `sgfHash` path traversal, uppercase, 63 chars,
  embedded newline and `/` rejected; valid hash accepted. Existing tests
  moved from `"h"` / `"abc"` to real hashes.

```bash
cd "ios/KataGo iOS/KataGoUICore" && swift test     # package tests (GoRulesKit, KataGoAnalysisKit)
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Also build all five schemes. The C++ changes compile into every app target
that links the engine.

## Still to do on a Mac (could not be done here)

- [ ] Run the Swift tests above. **None of the Swift has been compiled yet.**
- [ ] Build all five schemes (MLX backend; `katagocoreml` with the hardened
  parser).
- [ ] Safari extension end to end: a page serving the S2 decoy should get
  "boards larger than 19×19 are not supported" instead of the extension dying.
- [ ] Import the S1 SGF on iPhone and let it sync. Watch, widget and Listen
  must show 19×19.
