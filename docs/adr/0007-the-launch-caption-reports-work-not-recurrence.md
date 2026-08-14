# 0007 — The launch caption reports work, it never predicts recurrence

Date: 2026-08-14
Status: Accepted

## Context

The launch screen carried a secondary caption, **"Compiling Core ML model —
first launch only"** (`LoadingView.swift:111`, and for macOS/tvOS/visionOS the
shared `EngineLoadingView.swift:124`). Both halves of it were false.

**"first launch only".** A compiled model is identified by a nine-field key:
`sourceIdentity`, `boardXLen`, `boardYLen`, `computePrecision`,
`optimizeIdentityMask`, `minBatchSize`, `maxBatchSize`, `converterVersion`,
`osMajorVersion` (`CoreMLCacheKey.swift:20-28`). For the built-in network
`sourceIdentity` is `builtin:<CFBundleVersion>:<size>:<mtime>` (`:130-135`), so
**every app update** invalidates it; `converterVersion` and `osMajorVersion` are
folded in at `CoreMLModelCache.swift:786-795`, so **every OS major upgrade**
does too. On top of the key, the cache evicts LRU at 10 main / 4 auxiliary
entries (`:863-867`), and the user can wipe it outright — at which point the app
told them, correctly, that the models "will recompile on next use"
(`CoreMLCacheFooterView.swift:68`). The two screens contradicted each other.

**"Compiling".** The phase was raised at
`CoreMLComputeHandleLoader.swift:61`, *before* `cache.urlForKey` (`:65`)
branches hit-versus-miss, and cleared by a fire-and-forget
`defer { Task { … } }` at `:62`. On a cache hit — the overwhelmingly common
case — the caption appeared anyway. A launch loads two networks
(`gtp.cpp:500-509`), so a warm launch flashed "Compiling…" twice while
compiling nothing at all.

The clear was also unordered against the *next* load's raise, and `phase` was a
plain last-writer-wins field, so a stale clear could blank a caption that had
just become true.

## Decision

**The caption states what is happening right now, and makes no claim about
whether it will happen again.**

1. **Reported only from a genuine compile, at both call sites.** The report
   moves inside the miss callbacks — the loader's
   (`CoreMLComputeHandleLoader.swift:70-77`) *and* the routing probe's
   (`CoreMLRoutingProbe.swift:119-127`). A cache hit never enters either, so a
   warm launch is silent. Wrapping the probe is not optional: `run()` is
   deliberately not cancelled when the sheet is dismissed, because "the user's
   very next action is usually Play" (`CoreMLRoutingProbe.swift:32-36`) — so an
   engine launch *joining* a probe-installed compile is a designed common case,
   and gating on the loader alone would leave the app silent through it.
2. **The span is miss-gated but load-scoped.** The raise happens inside the
   miss callback; the release happens in a function-scope `defer`, counted
   rather than flagged (the corrupt-hit retry at `:65-115` can run the callback
   twice, and a Bool would leak a raise). The callback returns well before the
   user's wait ends — `prepareTmp`'s whole-tree move (`:330-349`),
   `commitStore`'s `directorySize` walk and index rewrite (`:353-378`), and
   `MLModel(contentsOf:)` building the ANE program (`:94`) all follow it. A
   strictly callback-scoped caption would go dark two-thirds of the way through
   a three-minute wait.
3. **The string is "Compiling Core ML model…"** — no recurrence claim, no
   duration, no board number.
4. **`EngineLaunchStatus.Phase` is retired.** With the never-assigned
   `.awaitingPrecompile` deleted, the enum was a two-case Bool wearing a
   costume. `EngineLaunchStatus` now holds `activeCompiles: Int` and exposes
   `isCompiling: Bool`; the registered seam carries `compileBegan()` /
   `compileEnded()` events. A counter is the right shape because increments and
   decrements **commute** — a late-landing release cannot blank a live caption,
   which no amount of care with a single assignable field achieves. The type
   keeps its name: it is the launch screen's status object, and a compile being
   its only content today is a property of the feature set, not of the role.
5. **Nothing special happens at the launch timeout.** The 600 s + 60 s fallback
   branch (`CoreMLComputeHandleLoader.swift:207-231`) does **not** clear or
   reset the counter, because at that moment a compile genuinely *is* running:
   the abandoned one cannot be cancelled (it lives in a detached task inside the
   cache actor whose only cancellation checks are post-compile), and the legacy
   direct-compile path the branch falls through to re-converts and recompiles
   from scratch (`EngineCoreMLBridge.swift:9-10`). Clearing there would make the
   caption go dark *during* a compile — the very defect this ADR removes.
   `compileEnded()` clamps at `max(0, n - 1)` so a stray release can never drive
   the count negative and silence the next real compile.
6. **Every surface that made the same promise is corrected in the same
   change**: the Backend picker footer (`BackendConfigSheet.swift:53`), the
   Core ML Routing footer's reuse promise (`:233`), the six tvOS sites
   asserting the Neural Engine on a target the loader pins to
   `.cpuAndGPU` (`TVSettingsScreen.swift:5-6, 243`, `TVEngineController.swift:7`,
   `TVRootView.swift:352`, `TVSettingsStore.swift:6`, `README.md:210`), and the
   macOS Safari extension's `warmingUp` message
   (`KataGoAnytimeSafariExt/Resources/content.js:673`), which adopts the honest
   string its iOS sibling already ships
   (`KataGoAnytimeSafariExtIOS/Resources/content.js:1216`).

## Alternatives rejected

- **Qualify the promise rather than delete it** — "first launch for a board
  size". The board dimensions are 2 of the 9 key fields; this is the same
  falsehood with a narrower blast radius, and it is the phrasing
  `BackendConfigSheet.swift:53` already shipped.
- **Name the board — "Compiling for 19×19".** `nnXLen`/`nnYLen` is the *NN
  buffer size* (the Max Board Size setting), not the game's board. A 9×9 game
  on a 19×19 engine compiles nothing, so this would have been a fresh lie
  rather than a repaired one.
- **State a duration.** No iOS or tvOS compile has ever been measured in this
  repository. The single committed figure is macOS, "~30 s on a cold M3 Max"
  (`docs/superpowers/specs/2026-05-09-coreml-cache-design.md:651`), which says
  nothing about a phone.
- **Clear the caption on the launch-timeout branch.** Intuitive, and wrong: it
  would blank the caption at the exact moment two compiles are in flight. See
  decision 5.
- **Keep `Phase` and let assignment mean a delta** (`.compiling` = +1,
  `.idle` = −1). Zero call-site churn, but a setter that secretly increments is
  precisely the class of implicit contract that produced this bug.
- **A generation stamp instead of a counter.** Equivalent correctness, but it
  has to *reason* about ordering where a counter is order-insensitive by
  construction.
- **Gate inside `CoreMLModelCache.urlForKey`** so that a caller *joining* an
  in-flight compile is also captioned. `mlxbackend.cpp:62-68` holds a
  process-wide `computeHandleMutex` across `new ComputeHandle` (`:2418-2421`),
  so engine handle loads never overlap; the join case that does exist comes
  from the routing probe, and decision 1 covers it in the app target without
  touching the dependency-light package the macOS helper also links.

## Consequences

- **The caption now has gaps, and they are honest.** A cold launch compiles two
  networks in sequence, so the caption rises, falls, and rises again. During
  the gap nothing is compiling. The ticking "Loading…" headline continues to
  answer the user's actual question, which is whether the app is stuck.
- **Genuine first-launch work before the caption stays silent.** The human-SL
  network's `sourceIdentity` needs a full-file SHA-256 that runs before the
  compile begins (`CoreMLCacheKey.swift:132-138`). Accepted: it is not
  compiling, and after this ADR the caption may not say it is.
- **The counter is process-wide, not per-launch.** A compile orphaned by a
  launch the user backed out of is still real work, still counted, and can
  therefore light the caption on a later launch that has nothing of its own to
  compile. Accepted: "some compile is running" is true, and strictly better
  than the unconditional claim it replaces.
- **The clamp trades exactness for safety.** It guarantees the property that
  matters — a stray release can never suppress a future caption — and gives up
  exact accounting under *concurrent* begins, which `computeHandleMutex` makes
  near-impossible on the engine path.
- **A throwing converter must not pin the caption on.**
  `convertOnCooperativePool` throws on failure (`:140-143`) and that failure
  signals the semaphore promptly, so the release has to be a `defer`, not a
  trailing statement. This is load-bearing, not stylistic.
- **The launch-timeout path is not covered by tests.** Pinning it needs a
  660-second wait or a parameterised timeout. Stated here rather than faked.
  What *is* pinned is the reporting helper itself, with an injected recorder —
  the process-wide updater global (`:291-301`) has no unregister, so tests must
  never touch it.
- **macOS shows nothing, and the Safari string it gains is dead code.** The Mac
  engine is a subprocess and the helper is the same loader "minus the
  `EngineLaunchStatus` UI reporting" (`EngineCoreMLBridge.swift:14`), so
  `MacBoardHostView`'s status view stays blank; no macOS producer emits
  `.warmingUp` either, so `content.js:673` is corrected for parity with its iOS
  sibling and for nothing else. A missing caption is a different defect from a
  false one; wiring it needs a status channel in `KataGoEngineIPC` and is
  deliberately out of scope.
