# Core AI as a third inference backend: framework, performance, and Mish numerics

Research notes, 2026-10-18. Scope: Apple's Core AI framework (27 SDKs) as a candidate third backend next to
CoreML/Neural Engine and MLX/GPU, plus the FP16 numerics of softplus and Mish under it.

Every claim carries a source tag. The tags are defined under [Sources](#6-sources). Three tags mean the claim
rests on something other than a published Apple page:

- **[SDK]**: read from the Xcode 27.1 SDK (`.swiftinterface`, `.swiftdoc`, `.tbd`, headers), not from documentation.
- **[Probe]**: measured on this Mac (Apple M3 Max, `Mac15,9`, 48 GB, macOS 27.0.1 build 26A434, Xcode 27.1 build
  27A9275, Swift 6.4, `coreai-core` 1.0.0b3, `coremltools` 9.0). [Section 4](#4-probe-results) gives the commands.
- **[Repo]**: read from this repository.
- **[Verify]**: confirmed, corrected or refuted by an independent adversarial pass on the same Mac, with its own
  builders and harnesses ([Section 4.6](#46-independent-verification)).

---

## 1. TL;DR

1. **What it is.** Core AI is Apple's new framework for running neural networks on device, in all five 27 OSes
   [D-CoreAI][SDK]. Apple calls it "the inference framework powering on-device Apple Intelligence" [W324] and says
   that for a custom model "Core AI is the right technology to use" [W102]. **Core ML is not deprecated**: its 27 SDK
   has no deprecation marks and no new API (the newest availability tag is 26.0) [SDK]. Apple now points
   neural-network work to Core AI and keeps Core ML for other model types such as trees and tabular feature
   engineering [D-CoreML][D-CoreAI].
2. **Simulators.** **Core AI is missing from every Simulator SDK** (iOS, tvOS, watchOS, visionOS) [SDK]. Code that
   uses it needs `#if canImport(CoreAI)`, and the simulator-only test target can never exercise it.
3. **How a model gets in.** The only way is a `.aimodel` file: a directory holding MLIR bytecode of a private
   `coreai` dialect, a SHA-256 of it, and `metadata.json` [Probe][CT]. **There is no public on-device graph-building
   API, and nothing reads `.mlpackage`/MIL** [SDK][Probe]. `.aimodel` files are written by Python (`coreai-core`
   `coreai.authoring`, or `coreai-torch` from `torch.export`) on a Mac or Linux [CT][PyPI].
   - The runtime rejects textual MLIR. A malformed program **aborts the process** (`LLVM ERROR`, exit 134); it does
     not throw a Swift error [Probe].
   - So today's runtime conversion of `.bin.gz` into MIL (`MILBuilder.cpp`) has no Core AI equivalent on device.
4. **Compute units.** `SpecializationOptions` gives `.default` (minimum latency), `.cpuOnly`, or a *preferred*
   `ComputeUnitKind` (`.cpu`, `.gpu`, `.neuralEngine`) [SDK][D-Spec].
   - Placement goes through delegates. Debug info shows the MPSGraph delegate placing kernels on GPU *and* ANE, and
     a BNNS delegate for the CPU [Probe][CT-src].
   - There is no per-op precision switch. Precision is the tensor dtypes baked into the graph. The ANE runs FP16
     (and int8/int16) only; FP32 ops fall back off the ANE [CM-skills].
5. **Speed.** For identical KataGo-like FP16 conv towers, **Core AI was slower than Core ML on the ANE at both
   batch sizes measured**: 7 to 10% slower at batch 8, and 20 to 35% slower in latency at batch 1 in long
   (500 to 1000 sample) runs [Probe][Verify]. An earlier 30-sample run that showed Core AI faster at batch 1 did not
   reproduce: it was dominated by power-state swings (Section 4.6). A GPU-heavy unrelated job ran on this Mac during
   every measurement, so an idle-machine and an on-device rerun are still owed. Outputs were bit-identical across
   the two frameworks on the CPU and element-wise identical on the ANE [Probe][Verify]. The big difference is
   **first-load specialization for the ANE**:
   - From a source `.aimodel`, Core AI took **0.8 s to 41 s** for correct towers, and **722 s** for a naive-softplus
     tower. Core ML compiled the same towers for the ANE in 0.3 to 1.7 s [Probe].
   - Ahead-of-time compiling with `xcrun coreai-build compile` (on a Mac; not supported for tvOS or watchOS) cut the
     on-device load to **0.5 to 0.6 s after an idle gap**. Back-to-back cold loads, however, stalled about **10.5 s**
     in 13 of 23 runs, blocked in a synchronous XPC wait on `aned` with no CPU work [Probe][Verify][D-AOT].
6. **Board sizes.** The ANE needs fully static shapes [CM-skills]:
   - One static function per board size, built with `AIProgram.set_static_shape_config`, works: 4 sizes, 1.4 s
     specialization, static-speed inference [Probe][CT].
   - Dynamic H×W specializes in 30 ms, but runs at GPU-like speed and reports no ANE residency [Probe].
   - Weights fed as runtime inputs ran **13× slower** on ANE [Probe].
7. **Mish has no native op.** The `coreai` dialect has no `softplus`, `mish`, `log1p`, `expm1`, or `logaddexp` op;
   `coreai-torch` lowers `log1p(t)` as `log(t + 1)` [Probe][CT-src].
   - PyTorch decomposes `torch.nn.Mish` to `x * tanh(where(x > 20, x, log1p(exp(x))))` [PT]. That is what KataGo's
     PyTorch model would emit through the default `coreai-torch` pipeline [Repo].
8. **The ANE breaks naive softplus.** The pattern `log(exp(x) + 1)` returns **0** for every x ≥ 10.3984, which is
   where exp(x) + 1 ≥ 2^15. It does so even though `exp(x)` is still finite. Separately, `log(+inf)` returns 0
   [Probe].
   - So naive Mish and PyTorch-decomposed Mish output **0 instead of x on the ANE for x in [10.3984, 20]**.
   - This reproduces exactly the 10.39 threshold this repo found under Core ML in 2022 (commit 312876854) [Repo].
   - Core ML's ANE path still does the same today: a naive-Mish tower gave identical wrong outputs under both
     frameworks [Probe].
9. **Recommended lowering.** Keep the branch-free form already in `MILBuilder::addMishOps`:
   `x / (1 + 2 / (e*(e+2)))` with `e = exp(x)`, all constants FP16. For `ACTIVATION_MISH_SCALE8`, use `e = exp(8x)`.
   - It has no `log`, and each overflow lands on the correct limit on every unit.
   - It was the most accurate formulation on CPU and ANE, cost the least ANE throughput of the correct forms
     (−22% vs ReLU), and specialized fastest [Probe].
10. **Validation.** Before anything else, do three things:
    - Make an exhaustive FP16 sweep per compute unit a unit test (40,705 values in [-30, 30]).
    - Assert ANE residency through debug info.
    - Run `testgpuerror` against the Eigen FP32 reference at 9/13/19/rectangle sizes and at 37×37.

---

## 2. Part 1: Core AI, framework and performance

### 2.1 What Core AI is

- **The framework.** "Run AI models in your app on Apple silicon." Core AI "allows your app to use the latest model
  architectures and inference techniques across the CPU, GPU, and Neural Engine", with a Swift API [D-CoreAI].
  - It comes with Python tools: Core AI Optimization (`coreai-opt`) and Core AI PyTorch Extensions (`coreai-torch`).
  - The rest of the toolchain is a Core AI Debugger app, an Xcode debug gauge, a Core AI Instruments template, and
    the `coreai-build` CLI [D-CoreAI][W324].
- **Its scope.**
  - Apple says it "is the inference framework powering on-device Apple Intelligence. And now, it's available for
    you to use" [W324].
  - The Keynote says it is "available on all our platforms" [W101].
  - The Platforms State of the Union says: "If you're using a custom model to power a feature within your app, Core
    AI is the right technology to use" [W102].
- **Is Core ML deprecated or superseded?** Superseded in Apple's guidance for neural networks, but not deprecated.
  - The Core ML page now says "If your app integrates AI models using the latest architectures and inference
    techniques, see Core AI" [D-CoreML].
  - The Core AI page says "If your app uses model types other than neural networks, such as decision trees or
    tabular feature engineering, see Core ML" [D-CoreAI].
  - In the 27 SDKs, Core ML headers and Swift interface carry no 27.0 deprecations and no 27.0 API. The newest
    availability is `macos(26.0)` [SDK].
- **Relation to MPSGraph and BNNS.** Core AI hands work to delegates. MPSGraph and BNNS are clients of the Core AI
  compiler and runtime [SDK].
  - `CoreAICompiler.tbd` lists `allowable-clients: BNNSCoreAIDelegate, BNNSOdieDelegate, CoreAI, CoreAIAsset,
    CoreAIDelegates, MetalPerformanceShadersGraph`. `CoreAIRuntime.tbd` lists `BNNSCoreAIDelegate, BNNSOdieDelegate,
    CoreAI, CoreAICommonTests, CoreAIDelegates, CoreAIRuntimeTests, MetalPerformanceShadersGraph` [SDK][Verify].
  - The MPSGraph Swift interface imports `CoreAICompiler` and `CoreAIRuntime`. Its `.tbd` exports
    `Compiler_coreAI`, `Segmenter_coreAI`, `MPSGraphDelegate.resolveCoreAI` and
    `MPSGraphDelegateKernel.coreAI_*` [SDK].
  - A private `ODIEDelegates.framework` exports an `AneDelegate`, and a private `CoreMLOdie.framework` has
    `AllowedDelegates.E5MLOptions`/`MPSGraphOptions` symbols [SDK]. Whether Core ML 27 runs on the same compiler
    stack is undocumented. It fits two probe results: for the same graph, Core ML and Core AI gave bit-identical
    CPU outputs, and ANE outputs with identical error statistics on 4 of 5 towers [Probe].
  - MPSGraph builds graphs on device, but its only public placement lever is all-or-nothing:
    `MPSGraphCompilationDescriptor.optimizationLevel` `.level1` (the default) lets its placement pass decide whether
    to use the ANE or the CPU, and `.level0` turns that pass off. No public API requests, forces or pins ANE
    placement, and none reports where ops ran. The ANE session and device-descriptor classes are private symbols
    only [SDK][Verify].
  - At runtime, Apple's own debugging code names the delegates `bnns`, `mps` and the `odix` fallback. It reads ANE
    placement from MPS-delegate kernels whose `residency` is `ANE` [CT-src]. My debug dumps match: with
    `.neuralEngine` preferred, every probe op sat in the `MPSGraph_optimized` delegate record, and every compute op
    had an `ANE` residency [Probe].
- **Relation to MLX.** None, technically. Core AI links neither MLX nor anything under it [SDK][Probe]. Apple
  presents them side by side: "High-level frameworks like Core AI and MLX make it easy to deploy your models"
  [W330].
- **Platforms.** `CoreAI.framework` (an umbrella that re-exports `CoreAIDelegates`, which re-exports CoreAIAsset,
  CoreAICache, CoreAICommon, CoreAICompiler and CoreAIRuntime) is in the iOS 27.1, macOS 27, tvOS 27, watchOS 27 and
  visionOS 27 device SDKs. **It is in none of the Simulator SDKs** [SDK].
  - All public API is `@available(macOS 27.0, iOS 27.0, watchOS 27.0, tvOS 27.0, visionOS 27.0, *)` [SDK].
  - The online symbol pages leave macOS out of some per-symbol platform lists, but the framework page and the SDK
    both list macOS 27.0 [D-CoreAI][SDK].
  - Per-platform differences [SDK]:
    - tvOS marks `AIModelCache.Policy.persistent` as `@available(tvOS, unavailable)`.
    - watchOS has no `MTLBuffer`- or `IOSurface`-backed `NDArray` initializers and no
      `ComputeStream(commandQueue:)`.
  - Ahead-of-time compilation "is not supported on tvOS and watchOS" and "only compiles for devices that support
    Apple Intelligence" [D-AOT]. `coreai-build list-architectures` prints nothing for tvOS and watchOS [Probe].

### 2.2 How a model gets in

- **The only input formats are `.aimodel` (source) and `.aimodelc` (ahead-of-time compiled)** [D-Integrate][D-AOT][SDK].
  - `AIModel(contentsOf:options:)` "Creates an AIModel from a `.aimodel` or `.aimodelc` file" [SDK]. The other public
    entry points, `AIModel.specialize(contentsOf:options:cache:cachePolicy:)`, `AIModelCache.model(for:options:)`
    (synchronous; returns a cached specialization) and `AIModel(resolvingBookmark:)`, all start from an existing
    `.aimodel`/`.aimodelc` or its cache entry too [SDK][Verify].
  - `AIModelAsset` can inspect and edit metadata but cannot create a program [D-AIModelAsset][SDK].
  - The public `CoreAICompiler`, `CoreAICommon` and `CoreAICache` modules export **no** public declarations; their
    `.swiftinterface` files contain only imports [SDK].
  - The compiler entry points (`Compiler.compile`, `AIModelAsset.updateProgramBytecode(to:)`,
    `AIModel.init(contentsOf:delegates:options:)`) exist only as SPI behind the allowable-clients lists above [SDK].
  - **So an app cannot build a graph in code on device.**
- **What an `.aimodel` is.** "An .aimodel is a directory", holding "the program bytecode plus a metadata.json file"
  [CT]. On disk it is [Probe]:
  - `main.mlirb`: MLIR bytecode, magic `ML\xefR`, producer `MLIR22.0.0git`.
  - `main.hash`: the raw 32-byte SHA-256 of `main.mlirb`.
  - `metadata.json`: `assetVersion` 2.0.
  - The ops come from a private `coreai` dialect (`coreai.conv2d`, `coreai.pad`, `coreai.exp` and so on) [Probe].
  - Apple's Python docs say the raw MLIR bindings "carry no stability guarantee and are unversioned: they track the
    LLVM pin and may change with any bump" [CT].
- **Textual MLIR does not load.** I replaced the bytecode with the equivalent textual MLIR and recomputed the hash.
  Loading failed with `bytecode version 265389 is newer than the current version 6` /
  `input buffer is not an MLIR bytecode file`, then **`LLVM ERROR: cannot unwrap empty odiec_module_t` aborted the
  process** (exit 134) [Probe]. Writing the program on device would mean emitting MLIR bytecode (version 6) for an
  unversioned private dialect.
- **Core ML MIL and `.mlpackage` are not accepted.**
  - `coreai-build` takes `.aimodel`/`.aimodelc` and, for `package`, "bare MLIR (.mlir) or bytecode (.mlirb,
    .mlir.bc)" [Probe, strings and help of `coreai-build` 3600.83.1].
  - Neither the `coreai` Python package nor `coreai-torch` has a Core ML importer. `coremltools` appears only as a
    test dependency of `coreai-torch` [CT-src][Probe].
  - `coremltools` 9.0 (2025-11-10) is still the latest stable release [PyPI]. The successor toolchain is
    `coreai-core` plus `coreai-torch`, not a new `coremltools`.
- **The conversion toolchain is Python, off device.**
  - `coreai-core` (`pip install coreai-core`, 1.0.0b3, Python 3.11 to 3.14) contains `coreai.authoring`, to "Build
    an AI Model in Python and save it as a `.aimodel` file", and `coreai.runtime`, to run one [CT][PyPI].
  - Its wheels are macOS arm64 and manylinux x86_64 [PyPI], so authoring can also run on Linux CI.
  - `coreai-torch` converts a `torch.export.ExportedProgram` "by traversing the FX graph and mapping ATen operators
    to Core AI operations" [CT].
  - Custom ops go through `register_torch_lowering` and are "written against authoring APIs from coreai-core (such
    as `coreai._compiler.dialects`)", which "may move or change without notice" [CT].
  - Custom Metal 4 kernels can be embedded (`TorchMetalKernel`, op `coreai.metal4_kernel`) [CT][W325][Probe].
  - I built every probe model with the public `coreai.authoring` facade (`conv2d`, `pad`, `exp`, `divide`, and so
    on) [Probe].
- **Ahead-of-time compile (Mac only).**
  - `xcrun coreai-build compile Model.aimodel --platform iOS --min-deployment-version 27.0 [--architecture …]
    [--preferred-compute gpu|neural-engine|none] [--expect-frequent-reshapes]` writes one `.aimodelc` per device
    architecture, and `AIModel.deviceArchitectureName` picks the right one at runtime [D-AOT][SDK].
  - The tool ships in the downloadable **Metal Toolchain** component (`xcodebuild -downloadComponent MetalToolchain`),
    not in Xcode itself [D-AOT][D-Integrate]. Here it resolved to a cryptex-mounted `Metal.xctoolchain` [Probe].
  - Architectures reported here [Probe]:
    - macOS: 22, `h13c` … `h18g`.
    - iOS: `h13g h14g h15g h16g h16p h17g h17p h18p h19p`.
    - visionOS: `h14g.n301 h17g.n301a`.
    - tvOS and watchOS: none.
    - This Mac reports `h15c`.

### 2.3 API shape

- **Model and functions.**
  - `AIModel` is a lightweight `Sendable` struct. It specializes on `init` (async) and returns
    `InferenceFunction`s via `loadFunction(named:)`, which is synchronous and throwing [SDK][D-Integrate].
  - `InferenceFunction` "owns the resources needed for inference, including model weights and intermediate
    buffers", is `Sendable`, and "automatically allocates additional intermediate buffers as needed to support
    concurrency" [D-InferenceFunction].
- **`run` is async, but `encode` is synchronous.**
  - `run(inputs:states:outputViews:) async throws` comes in an `[String: NDArray]` overload and a non-escapable
    `InferenceFunction.Inputs` overload [SDK].
  - The lower level is `encode(inputs:states:outputViews:to: ComputeStream)`, which returns `AsyncValue` futures
    that can be chained into further `encode` calls without a CPU round trip [D-encode]. **`encode` itself is a
    synchronous `throws` call**, not `async` [SDK][Verify].
  - `ComputeStream(commandQueue:)` encodes onto an app's `MTLCommandQueue` (not on watchOS) [D-ComputeStream][SDK].
    `ComputeStream` is not `Sendable`, so each thread needs its own.
  - **A synchronous thread can therefore run inference with no Swift concurrency**: `encode` onto an app-owned
    queue with outputs in app `MTLBuffer`s (`AsyncMutableValue(unsafeBuffer:)`), then commit an empty marker command
    buffer on the same queue and `waitUntilCompleted()`. Verified bit-exact against `run` on GPU, ANE and CPU, from
    a plain `Thread`, and it typechecks against iPhoneOS 27.1 [Verify]. On the ANE and CPU `encode` happened to block
    until done; the docs say compute "may still be running" on return, so the marker wait is the robust pattern.
  - KataGo's NN server threads are synchronous C++ threads; today they call Core ML's synchronous
    `model.prediction(from:)` (`cpp/neuralnet/metalbackend.swift:304`) [Repo]. Loading can be synchronous too once
    a specialization is cached (`AIModelCache.model(for:options:)`, `loadFunction(named:)`).
- **Tensors.**
  - `NDArray` takes any `ScalarType` (FP16/FP32/BF16/FP8/int sizes) and can be backed by bytes, `MTLBuffer` or
    `IOSurface`. Access is through typed non-escapable `View` and `MutableView` [SDK].
  - `NDArrayDescriptor.preferredStrides` gives "the strides that avoid data layout transformations"; plain
    contiguous arrays still work but "may incur a copy" [D-NDArrayDescriptor].
  - `outputViews` lets you pre-allocate outputs [D-encode][W324].
  - In the probes, Core ML returned ANE outputs with padded strides (`[155648, 608, 32, 1]` for N×256×19×19, so
    W = 19 padded to 32). Core AI returned contiguous outputs, probably after a copy [Probe].
- **C and C++.** **Core AI is Swift-only**: no headers, no module map, no `@objc` API. The interfaces are built
  with `-formal-cxx-interoperability-mode=off` and use `~Copyable`/`~Escapable` types [SDK]. C++ would have to call
  a Swift shim with a C ABI, the same way the repo already reaches Core ML through `@_silgen_name` entry points
  [Repo].
- **Compute units and options.**
  - `SpecializationOptions` [SDK][D-Spec]:
    - `.default`, which "selects the combination of compute units that minimizes inference latency".
    - `.cpuOnly`.
    - `init(preferredComputeUnitKind:)`: "Fallback to other kinds … may still occur for operations or operation
      patterns that are incompatible with the preferred kind".
    - `allowedComputeUnitKinds` is read-only. A *preferred* unit still allows all three.
    - `expectFrequentReshapes: Bool`.
    - `ComputeUnitKind.availableKinds` returned `{cpu, gpu, neuralEngine}` here [Probe].
  - **There is no "ANE only" option**, so placement has to be checked (see 2.6).
  - On this Mac `.default` picked the GPU for every probe [Probe]. On iOS the app's current default is CoreML/NE for
    power [Repo], and Core AI's `.default` optimizes latency, not power [D-Spec].
- **Precision.**
  - No runtime precision setting exists. Precision is the dtype of each tensor in the program [SDK][CT].
  - Apple's guidance: the ANE supports "fp16, int8, int16. fp32 falls back to GPU/CPU", and "Any Python float
    literal or fp32 op creates an f32 buffer that Neural Engine cannot execute" [CM-skills]. On GPU, "fp16 weights,
    fp32 intermediates OK" [CM-skills].
  - Measured: GPU kernels kept **FP32 intermediates inside fused elementwise chains** of an FP16 graph. For example,
    `log(exp(30))` came out as 30 on GPU, but as `inf` on CPU and 0 on ANE [Probe].
  - Mixed precision (the `MILBuilder` FP32 tiers for transformers) is possible by emitting FP32 tensors and casts,
    and such ops then leave the ANE.
- **Shapes and batching.**
  - Dimensions can be dynamic (`?`). By default Core AI "optimizes the inference function for each new input shape
    it encounters"; `expectFrequentReshapes` skips that and "runs the generic dynamic version" [D-Spec].
  - The ANE wants "Fully static shapes: Export one function per static shape config" [CM-skills].
  - `AIProgram.set_static_shape_config(entrypoint, {key: {input: shape}})` clones a dynamic graph into one static
    function per key, named `<entrypoint>_<key>` [CT].
  - Batch is just a dimension, so a static batch means one function per batch size.
- **Specialization and caching.**
  - Specialization produces "executable code tied to that device's hardware and OS version" and is cached in
    `AIModelCache.default` [D-Spec].
  - Cache entries are keyed by the source file and the `SpecializationOptions` [D-Spec].
  - Policy:
    - `.default` is purgeable under storage pressure or when the source changes.
    - `.persistent` survives until the next OS update; not on tvOS.
    - Everything is "always" purged on OS update [D-Spec][SDK].
  - `AIModelCache(appGroup:)` shares a cache across apps and extensions [D-Spec].
  - `bookmarkData` lets the source be deleted afterwards [D-Spec].
  - On-disk layout [SDK, swiftdoc]:
    - Not sandboxed: `~/Library/<Caches|Application Support>/coreai-cache/<BUILD_VERSION>/<BUNDLE_ID>/<MODEL_HASH>/<SPECIALIZATION>/Asset`.
    - App group: `<GROUP-CONTAINER>/Library/<STORE_ROOT>/coreai-cache/<GROUP_NAME>/…`.
    - Observed for the unsandboxed probe tools: `~/Library/Caches/coreai-cache/26A434/<tool name>/…`, where 26A434
      is the macOS build. Each executable gets its own scope, which matters for the macOS `katago-engine` helper
      [Probe].
- **Background.** The `com.apple.developer.background-tasks.continued-processing.inference` entitlement "lets a
  background task run inference on the Neural Engine". The system also "requires the entitlement for any Neural
  Engine access while your app is in the background", whether through Core AI, Core ML or MPSGraph [D-BGInference].

### 2.4 Apple's performance claims and guidance

- **Claims.** Apple claims "blazing fast inference across the CPU, GPU, and Neural Engine" and "uncompromising
  performance" [W324][W102].
  - **I found no published number comparing Core AI with Core ML**, in docs, session transcripts (324, 325, 326,
    330, 102, 101), or on Apple Machine Learning Research, which had no Core AI post on the date of this note.
  - The only concrete figure is app-level: splitting SAM3 into three functions made a re-prompt "76% faster" [W325].
- **What Apple says limits ANE throughput** [CM-skills]:
  - "Switching between accelerators (Neural Engine <-> GPU <-> CPU) introduces overhead that dominates small-model
    inference". Keep the whole model on the ANE.
  - "The last axis must be contiguous and aligned to 64 bytes". Unaligned widths are padded. KataGo's W = 19 FP16
    (38 B) pads to 64 B, as the Core ML output strides showed [Probe].
  - Reshapes and transposes that "touch the width (innermost) dimension are especially expensive".
  - Prefer high-level ops. Use 1×1 Conv2d instead of Linear, channels-first layouts and static shapes [W325].
  - Compression helps only "for layers where weight transfer time dominates computation time".
  - "Neural Engine hardware does not handle IEEE `-inf` correctly in softmax"; use -40000.
- **Latency hygiene** [W324][D-NDArrayDescriptor]:
  - Allocate I/O with `preferredStrides`.
  - Pre-allocate `outputViews`.
  - Pipeline with `encode`/`AsyncValue`.
  - Keep specialization out of interactive flows (check `AIModelCache.model(for:options:)`; call
    `AIModel.specialize(...)` early), or compile ahead of time [D-Spec][D-AOT].

### 2.5 Measured performance (M3 Max, details in Section 4)

The workload is a KataGo-like pre-activation residual tower: 10 blocks × 2 3×3 convs, 256 channels, 19×19 board,
batch 8, FP16 throughout, BN folded into the conv bias, Mish between convs. The same weights went into a Core AI
`.aimodel` and a Core ML `.mlpackage` (`coremltools` 9.0, `mlprogram`, FP16). Median single-stream latency is shown
as positions per second; "k=4" runs four concurrent requests [Probe].

| Tower (b10c256, N=8) | Core AI ANE | Core ML ANE | Core AI GPU | Core ML GPU | Core AI ANE first specialization | Core ML ANE first load |
|---|---|---|---|---|---|---|
| ReLU | 1095 pos/s (k=4: 1283) | 1234 (1342) | 965 | 1076 | 1.48 s | 0.30 s |
| Mish, branch-free (MILBuilder form) | 854 (984) | 924 (964) | 1060 | 1174 | 8.39 s | 1.18 s |
| Mish, sigmoid form | 795 (897) | 820 (886) | 930 | 873 | 36.06 s | 1.11 s |
| Mish, logaddexp/stable form | 775 (864) | 822 (859) | 860 | 904 | 40.98 s | 1.31 s |
| Mish, naive (**wrong on ANE**) | 901 (1037) | 897 (946) | 765 | 895 | **721.92 s** | 0.64 s |
| branch-free, N=1 | 652 (1.53 ms) **did not reproduce**; 2.02 to 2.45 ms in long runs | 404 (2.47 ms); 1.23 to 1.66 ms in long runs | 452 | 520 | 0.84 s | 0.49 s |
| branch-free, b10c384, N=8 | 463 | 497 | 445 | 462 | 11.95 s | 1.73 s |

Before every Core AI load, its cache entry was deleted (`AIModelCache.default.deleteEntries(for:)`). The Core ML
column is the first `MLModel(contentsOf:)` load on the ANE in that run. Every Core ML ANE load was the first ever
for its weights except the branch-free N=8 row, which an earlier debugging run had already compiled once. That
row's figure may therefore be a warm load.

- **Same backends.** On the ANE, Core AI and Core ML outputs had identical max abs and RMS deviation from the CPU
  reference on four of five towers; the sigmoid tower differed slightly. An element-wise diff of the branch-free
  tower at N=1 found them **identical on the ANE** (100% of elements) [Verify]. On the CPU the two frameworks matched
  exactly (max difference 0). GPU and ANE were 0.02 to 0.03 RMS from the FP16 CPU reference on outputs up to about
  13.5 [Probe].
- **The naive-Mish tower is broken on the ANE.** Under both frameworks its maximum error was the full output
  magnitude (13.45) [Probe]. See Part 2.
- **Specialization is the outlier.** Core AI's first ANE specialization from a source `.aimodel` grew with batch
  (0.84 s at N=1, 8.4 s at N=8) and swung wildly with the activation formulation (1.5 s to 722 s). Warm reloads
  from the cache took 2 to 3 ms. GPU specialization was 0.05 to 0.13 s [Probe].
- **Ahead-of-time compilation removed it.** For a fresh-weight stable-Mish tower [Probe]:
  - `coreai-build compile --platform macOS --architecture h15c --preferred-compute neural-engine` took 1.3 s on the
    host.
  - Loading the `.aimodelc` with `.neuralEngine` preferred took 0.55 s, and it ran at ANE speed (10.85 ms median).
  - A same-shape tower with different weights loaded from `.aimodel` took 40.6 s.
  - **AOT loads are bimodal** [Verify]: 0.5 to 0.6 s after about 45 s of idle, but back-to-back cold loads (a new
    process within seconds) stalled about 10.5 s in 13 of 23 runs. `sample` shows the loader blocked in
    `-[_ANEClient compileModel:options:qos:error:]`, a synchronous XPC wait on `aned`, while `aned` and
    `ANECompilerService` used about 0.01 s of CPU: a fixed stall, not compilation work.
  - An earlier note here blamed a 10.6 s `.default`-options load on options that did not match the compile-time
    compute units. That was the same stall: after an idle gap, `.default` loaded in 0.5 to 0.6 s and still ran on
    the ANE [Verify]. Apple still says to "specify options that match the compute units you used at compile time"
    [D-AOT].
  - `coreai-build` names this Mac's architecture `h15c`; an `h15g` asset is rejected with
    `incompatibleCompiledAssetArchitecture`, even though IORegistry reports the ANE architecture string `h15g`
    [Verify].
  - Compiling for all 9 iOS architectures took 10.4 s and wrote 9 × 23 MB [Probe].
- **Mish cost on the ANE**, relative to ReLU: branch-free −22%, sigmoid −27%, stable −29% [Probe].
- **Residency.** With `.neuralEngine` preferred, the branch-free tower placed 176 of 177 MPSGraph kernels on the ANE
  and 1 on the GPU, apparently the output boundary [Probe].
- **Caveat.** On this M3 Max the GPU beat the ANE at batch 8. Only an iPhone or iPad measurement can settle what to
  use on iOS, where the app chose CoreML/NE for power [Repo]. An unrelated PyTorch/MPS training job ran during every
  measurement in this note (117 to 164% CPU, 57 to 80% GPU device utilization, no ANE frameworks loaded). It
  affects the GPU and CPU rows, and Core AI's ANE plan carries one graph-level GPU entry, so it may penalise Core AI's
  ANE figures too [Verify].

### 2.6 Board sizes (2..37, `requireExactNNLen=false`)

The probe was a 4-block, 128-channel branch-free tower at N=1 [Probe]:

| Variant | `.neuralEngine` specialization | Median latency | Notes |
|---|---|---|---|
| Static 19×19 function | 0.27 s | 0.86 ms (GPU: 1.03 ms) | 60 of 61 kernels on ANE |
| 4 enumerated static functions (9/13/19/37, `set_static_shape_config`) | 1.42 s for all 4 | 9: 0.44, 13: 0.53, 19: 0.87, 37: 1.79 ms | 240 of 244 kernels on ANE; weights stored once (asset 2.34 MB vs 2.32 MB) |
| One dynamic H×W function | 0.03 s | 19: 1.26, 9: 0.76, 37: 2.21 ms | ~31 ms first call per new shape; no residency reported at load; timings match GPU |
| Dynamic + `expectFrequentReshapes` | 0.05 s | similar | no per-shape first-call cost |
| Conv weights as runtime inputs | 0.27 s | **11.2 ms** (GPU: 5.95 ms) | 52 of 61 kernels on ANE, but 13× slower than constants |

The ANE path therefore needs one static function per board-size configuration (or per batch size). Feeding weights
at runtime is not a way around on-device authoring.

### 2.7 Profiling tools

- **The Core AI Instruments template** has Core AI, Neural Engine, GPU and Time Profiler tracks. It shows
  Specialization, Load, Setup and Inference events per model and per function [D-Instr].
- **The Xcode debug gauge** streams load, specialization and inference events [D-Debug].
- **Core AI Debugger (a standalone macOS app)** [D-Debugger][D-Validate]:
  - Visualizes a graph, runs it on a chosen device and compute unit, and dumps every op's output.
  - Compares against a PyTorch reference (`.aimodelintermediates`) or a second configuration, using
    PSNR/MAE/MSE/max-abs/relative metrics per "sync point".
- **Debug info, scriptable.** `coreai.runtime.SpecializationOptions…with_debug(enabled=True)` with `USE_OS_COREAI=1`
  on macOS exposes per-kernel delegate and `residency` JSON (`AIModel._debug_infos`). `coreai_torch.debugging`'s
  `ComputePlan` uses it [CT-src]. Every residency figure in this note comes from it [Probe].

---

## 3. Part 2: softplus and Mish numerics

### 3.1 Native ops

- **There are none.** The `coreai` dialect bundled with `coreai-core` 1.0.0b3 has no `softplus`, `mish`, `log1p`,
  `expm1` or `logaddexp` op. It does have `exp`, `log`, `tanh`, `sigmoid`, `silu`, `gelu`, `relu`, `divide`, `where`
  and the comparisons [Probe, `_coreai_ops_gen.py`]. Apple documents no precision or ANE lowering for activations.
- **`coreai-torch` lowerings** [CT-src `_aten_to_core.py`]:
  - `log1p(x)` becomes `coreai.log(x + 1)`.
  - `expm1(x)` becomes `exp(x) - 1`.
  - `get_decomp_table()` keeps `silu`, `hardswish` and `hardsigmoid` and lets `mish` and `softplus` decompose
    [CT-src `_decomp.py`].
- **What PyTorch produces.** PyTorch's reference decompositions (registered in the core ATen decomposition table)
  are [PT]:
  - `mish(a) = a * tanh(softplus(a))`.
  - `softplus(a) = where(a > 20, a, log1p(exp(a)))`.
  - KataGo's PyTorch model uses `torch.nn.Mish` (`python/katago/train/model_pytorch.py:64`) [Repo].
  - **Exported through the default `coreai-torch` pipeline, KataGo Mish becomes
    `x * tanh(where(x > 20, x, log(exp(x) + 1)))`.** Below, that is formulation `mish_torch`.
- **A side note on SiLU.** Apple's own skill notes that `silu()` "lowers to `mps.cast(→f32) + mps.swish(f32) +
  mps.cast(→f16)`", which is invalid on the ANE, and suggests `x * sigmoid(x)`. It also suggests replacing
  `torch.tanh` with `2*sigmoid(2x) - 1` in some ANE contexts [CM-skills]. This matters for SiLU-trunk networks.

### 3.2 FP16 landmarks

| Quantity | Value |
|---|---|
| Largest finite FP16 | 65504; exp(x) becomes `inf` for x ≥ 11.0938 (first FP16 input above ln 65504 = 11.0898) |
| 2^15 | 32768; ln 2^15 = 10.3972, first FP16 input above it is 10.3984 |
| Smallest normal | 2^-14 = 6.10e-5; ln = −9.704 |
| Smallest subnormal | 2^-24 = 5.96e-8; exp(x) rounds to 0 below x ≈ −17.33 |
| 1 + t rounds to 1 | t ≤ 2^-11 = 4.88e-4, that is t = exp(x) with x ≤ −7.6246 |
| Spacing just below 1 | 2^-11, so the largest FP16 below 1 is 0.99951 |

### 3.3 Per-unit behaviour of the elementary ops (FP16 graph, Core AI) [Probe]

| Op or pattern | CPU (BNNS) | GPU (MPSGraph) | ANE (MPSGraph → ANE) |
|---|---|---|---|
| `exp(x)`, x ≥ 11.09 | `inf` | `inf` (as a graph output) | `inf` |
| `log(+inf)` | `inf` | n/a (FP32 intermediates) | **0** |
| `log(0)` | `-inf` | `-inf` | −45440 (finite) |
| `log(exp(x) + c)` once exp(x) + c ≥ 2^15 | correct up to `inf` | correct | **0 from x = 10.3984**, even with c = 1.00098, with constant-first order, with `exp(x-1)*e`, and with `exp(x)` also exported as an output |
| `log(2048·|x| + 1)` above 2^15 | correct | correct | correct |
| `log(exp(x) · 1.00098)` above 2^15 | correct | correct | correct |
| `x · 4096` overflow | `±inf` | `±inf` | `±inf` (IEEE, no saturation) |
| `tanh(x)` for large \|x\| | **0.999023** (= 1 − 2^-10, never 1) | 1 | 1 |
| `sigmoid(x)`, x ≤ −9.7 | correct subnormals | correct | 0 (flushed) |

The ANE failure is specific to the `exp` → `+c` → `log` chain. A plain `log` of values in [2^15, 65504] is correct.
The likely explanation is a pattern-matched internal softplus with a 2^15 range limit. That is my inference, not
something Apple documents. Either way it reproduces this repo's 2022 Core ML experience, where threshold 11 still
overflowed and 10.39 did not (commits 9a61cf6f3, 312876854) [Repo], and Core ML's ANE path still behaves the same
[Probe]. The CPU `tanh` cap gives `x·tanh(…)` forms a systematic −0.1% bias for large x on `.cpuOnly`.

### 3.4 The formulations, analyzed and measured

The sweep covered every distinct FP16 value in [−30, 30] (40,705 inputs), in an N×C×H×W = 1×40×32×32 FP16 tensor,
on `.cpuOnly`, preferred `.gpu` and preferred `.neuralEngine`. The reference is float64 `x·tanh(softplus(x))` with
softplus computed stably. "wRMS" weights the error by an N(0, 3²) density over the grid. "Catastrophic" counts
errors above 10% of max(1, |ref|). The floor row is correctly rounded FP16 [Probe].

| Formulation | Unit | max abs err | max rel err (x ≥ 0.25) | wRMS | catastrophic |
|---|---|---|---|---|---|
| Floor: fp16(ref) | – | 1.95e-3 | 4.75e-4 | 3.66e-4 | 0 |
| **naive** `x·tanh(log(1+exp(x)))` | CPU | 3.12e-2 | 1.30e-3 | 1.58e-3 | 0 |
|  | GPU | 1.95e-3 | 4.75e-4 | 3.66e-4 | 0 |
|  | ANE | **30.0** | **1.0** | 0.18 | **1614** |
| **torch decomposition** `x·tanh(where(x>20, x, log(exp(x)+1)))` | CPU | 3.12e-2 | 1.30e-3 | 1.58e-3 | 0 |
|  | GPU | 1.95e-3 | 4.75e-4 | 3.66e-4 | 0 |
|  | ANE | **20.0** | **1.0** | 0.18 | **974** |
| **old repo threshold** `where(x<10.39, log(1+exp(min(x,10.39))), x)` | CPU | 3.12e-2 | 1.30e-3 | 1.58e-3 | 0 |
|  | ANE | 4.08e-3 | 2.11e-3 | 8.73e-4 | 0 |
| **logaddexp / stable** `x·tanh(max(x,0)+log(1+exp(-\|x\|)))` | CPU | 3.12e-2 | 1.30e-3 | 1.58e-3 | 0 |
|  | GPU | 1.95e-3 | 4.75e-4 | 3.66e-4 | 0 |
|  | ANE | 4.03e-3 | 2.17e-3 | 8.74e-4 | 0 |
| stable + `tanh` via `2σ(2z)−1` | CPU | 5.11e-3 | 2.44e-3 | 1.25e-3 | 0 |
|  | ANE | 4.03e-3 | 2.17e-3 | 8.89e-4 | 0 |
| **sigmoid form** `x·(1−s²)/(1+s²)`, s = σ(−x) | CPU | 3.72e-3 | 1.35e-3 | 8.70e-4 | 0 |
|  | GPU | 1.95e-3 | 4.75e-4 | 3.66e-4 | 0 |
|  | ANE | 2.99e-3 | 2.01e-3 | 7.68e-4 | 0 |
| **branch-free** (MILBuilder) `x / (1 + 2/(e(e+2)))`, e = exp(x) | CPU | **2.57e-3** | 1.06e-3 | **5.11e-4** | 0 |
|  | GPU | 1.95e-3 | 4.75e-4 | 3.66e-4 | 0 |
|  | ANE | **2.62e-3** | 1.35e-3 | **5.96e-4** | 0 |

Analysis of each formulation in FP16:

- **Naive softplus, `log(1 + exp(x))`.**
  - *Overflow.* exp(x) reaches `inf` at x ≥ 11.09, so on IEEE units softplus becomes `inf`. That is wrong as a
    value, but Mish recovers it: `tanh(inf) = 1` and `x·1 = x`. On the CPU, `tanh` saturates at 0.99902 instead,
    hence the 3.1e-2 error at x = 24.
  - *Underflow.* Below x ≈ −7.62, `1 + e` rounds to 1, so softplus is 0 and Mish is 0. The true |Mish| there is at
    most 7.62 × 4.9e-4 = 3.7e-3, exactly the CPU maximum measured at x = −7.625. That is 100% relative error but
    negligible in absolute terms.
  - *On the ANE it is catastrophic.* The pattern returns 0 from x = 10.3984, so Mish returns **0 instead of x** for
    every x ≥ 10.3984.
  - *On the GPU it is correct.* FP32 intermediates inside the fused chain avoid both problems.
- **PyTorch decomposition (the default `coreai-torch` result).**
  - The 20 threshold was chosen for FP32. In FP16, x in (11.09, 20] still overflows; IEEE units recover through
    `tanh`.
  - On the ANE, x in [10.3984, 20] gives 0. This is exactly what a KataGo checkpoint converted with stock
    `coreai-torch` would do.
  - Fixing it means registering a lowering for `aten.mish` (`register_torch_lowering(..., allow_override=True)`)
    and keeping it out of the decomposition table [CT].
- **Repo threshold 10.39 (`coremlmish.mish_torch_ne`).** Clamping exp's input below ln 2^15 keeps it off the ANE
  failure. The cost is `minimum` plus `where` plus `log` plus `tanh`, and it keeps the underflow tail loss and the
  CPU `tanh` bias. Commit eb8c3930d recorded that `select` stopped running on the ANE in a later macOS [Repo]. In
  Core AI, `where` was ANE-resident in this probe [Probe].
- **logaddexp / stable softplus**, `max(x,0) + log(1 + exp(−|x|))`. MLX uses this form (`logaddexp(0, x)`)
  [Repo `mlxbackend.cpp`][MLX].
  - It never overflows, because exp's argument is at most 0.
  - Without a native `log1p` it still loses the tail: for |x| > 7.62, `1 + t` rounds to 1.
  - It needs `tanh`, so it inherits the CPU bias.
  - MLX's Metal `log1p` computes in float with the Goldberg correction (`ThirdParty/mlx-swift/.../metal/kernels/utils.h`)
    [Repo].
  - Core AI cannot express that `log1p` without a custom Metal kernel, which would only cover the GPU.
  - Note that this repo's MLX backend actually evaluates the BN-plus-Mish chain in **FP32**: `mergedScale` and
    `mergedBias` are FP32, type promotion lifts the chain, and the result is cast back to FP16
    (`mlxbackend.cpp:420-485`) [Repo]. Its "overflow-free in FP16" comment is therefore not what protects it.
- **Sigmoid form**, `x(1 − s²)/(1 + s²)` with s = σ(−x). This is exact algebra: with u = 1 + e^x,
  tanh(ln u) = (u² − 1)/(u² + 1).
  - It is overflow-free, since s is in [0, 1].
  - For x > 9.7 the ANE flushes s to 0, and the result is x, which is correct.
  - For x < −7.6, s rounds to 1, so the tail is lost the same way.
  - It costs a `sigmoid` and a `divide`.
- **Branch-free (current `MILBuilder::addMishOps`, from `coremlmish.mish_torch_branch_free`)**, using
  tanh(softplus(x)) = 1/(1 + 2/(e(e + 2))).
  - *Upper range.* For x > 5.54, `e(e+2)` overflows to `inf`. Then `2/inf = 0` and the result is `x/1 = x`. The
    term it drops is below 3.05e-5 relative, under half an FP16 ULP, so nothing is lost. At x ≥ 11.09, e = `inf`
    takes the same path.
  - *Lower range.* For x < −11.09, `2/(e(e+2)) ≈ 1/e` overflows, and `x/inf = −0`. The true magnitude there is at
    most 1.7e-4, which matches the measured 1.68e-4.
  - *Between.* For −11.09 < x < −9.7, e is subnormal: reduced precision, but bounded absolute error.
  - *Robustness.* It contains no `log`, so the ANE's `log(inf) = 0` and the 2^15 softplus pattern cannot occur, and
    no `tanh`, so the CPU cap does not apply. Every overflow lands on the correct limit under IEEE `inf` and would
    under saturation too.
  - Edge cases differ by unit [Verify]. On CPU and GPU: x = +inf gives `inf`, x = −inf gives `NaN` (a finite
    activation never hits it), and NaN propagates. On the ANE: −inf gives 0, +NaN gives +inf and −NaN gives 0,
    because the ANE's `exp` maps NaN to inf or 0 by sign.
  - Measured independently [Verify]: max abs error 2.57e-3 (CPU) and 2.62e-3 (ANE) over all 40,705 FP16 inputs in
    [−30, 30]; y == x bit-exactly for every FP16 x ≥ 12 on all three units (in fact from x > 4.14 on CPU and
    x > 4.16 on ANE).
- **`ACTIVATION_MISH_SCALE8`** is defined as `x·tanh(softplus(8x))` (`desc.cpp:446`) [Repo]. The same identity gives
  `x / (1 + 2/(E(E+2)))` with E = exp(8x), with the same overflow and underflow behaviour at x/8 thresholds.
  Multiplying by 8 is exact in FP16.
- **The other backends in this repo** [Repo]:
  - **CUDA** computes Mish in FP32 per element, converting half to float and back, with thresholds 20 and 2.5 for
    scale8 (`cudahelpers.cu:50-65`). No FP16 issue.
  - **TensorRT** uses `kSOFTPLUS` (`alpha·log(exp(beta·x)+1)` [TRT]), then `kTANH`, then a product, with an FP32
    precision override when `forceFP32` is set (`trtbackend.cpp:876-909`).
  - **ONNX** emits `Softplus` (`y = ln(exp(x)+1)` [ONNX]), then `Tanh`, then `Mul`, scaling the input by 8 for
    SCALE8 (`onnxmodelbuilder.cpp:241-255`).
  - For TensorRT and ONNX the internal precision belongs to the execution provider. On IEEE GPUs the `inf` overflow
    recovers through `tanh` the same way as above. None of these is a risk on Apple hardware; they only show that
    the ANE's non-IEEE `log` is what makes the naive form unsafe.
- **What scale8 is for.** It protects the *residual stream and the accumulators*, not softplus internals. It divides
  trunk activations by 8 and multiplies `outputScaleMultiplier` by 8 (`desc.cpp:2745-2763`) [Repo]. The ONNX
  maintainers measured a b28c512 convnet at 50×50 with peak activations of 29,284, 44.7% of the FP16 maximum, and
  NaNs on GPU FP16 without scale8 (commit c2e555277) [Repo].
  - `MILBuilder` keeps plain convnets pure FP16 on the ANE without scale8, and passes `testgpuerror` for b18c384nbt
    and b28c512nbt (`MILBuilder.cpp:76-97`) [Repo].
  - The app's boards go up to 37×37 [Repo]. The ANE accumulates in FP16 and cannot escalate [CM-skills][Repo].
    Whether a Core AI graph needs scale8 at 37×37 is a test result to obtain, not an assumption.

### 3.5 Recommended Core AI lowering

1. **Mish** (for SCALE8, use E = exp(8x)):
   ```
   e   = exp(x)
   y   = x / (1 + 2 / (e * (e + 2)))
   ```
   - Every constant is an FP16 tensor; FP32 literals knock ops off the ANE [CM-skills].
   - Use no `where`, `log` or `tanh`.
   - It is the most accurate tested form on CPU and ANE, the cheapest correct form on the ANE (854 vs 795 and
     775 pos/s), the fastest correct form to specialize on the ANE (8.4 s vs 36 to 41 s), and fully ANE-resident
     [Probe].
2. **Never emit `log(exp(x) + c)`** anywhere an ANE might run it, including any future SiLU or softplus head inside
   the graph. If a stable softplus is needed in-graph, use `max(x, 0) + log(1 + exp(−|x|))`, which is ANE-safe in
   the probe and has an absolute error of at most 4.9e-4.
3. **If `coreai-torch` is the converter,** override `aten.mish` with the form above and keep it from decomposing.
   Otherwise the stock pipeline emits the ANE-broken pattern (Section 3.1).
4. **Post-processing softplus is out of scope.** `nneval.cpp:753-759` computes `softPlus` in `double` on the CPU
   (`x > 40 ? x : log(1 + exp(x))`). It acts on raw head outputs times `outputScaleMultiplier`, after inference.
   The backend's only job is to return those raw outputs, either in FP32 or in FP16 with a known rounding error; it
   does not lower this softplus [Repo].

### 3.6 Validation plan

1. **Op level (unit test, offline, macOS).**
   - Sweep all 40,705 FP16 inputs in [−30, 30], plus ±65504, ±inf and NaN, through the exact lowering the backend
     emits, on `.cpuOnly`, preferred `.gpu` and preferred `.neuralEngine`. Expect per-unit behaviour for ±inf and
     NaN (Section 3.4), not NaN propagation everywhere.
   - Gate on: no catastrophic errors; max abs error ≤ 3e-3 (the measured CPU and ANE values are 2.6e-3); and exact
     identity `y == x` for x ≥ 12.
   - Pin regression points at 10.3906/10.3984 (the ANE's 2^15 boundary) and at 11.0859/11.0938 (the FP16 `exp`
     overflow).
   - The harness in Section 4 is about 60 lines of Swift plus a Python builder.
2. **Residency.** Assert that the Mish and conv ops are ANE-resident under `.neuralEngine`, using the debug
   `residency` records (Python `with_debug`) or the Core AI Instruments template. A silent fallback to GPU changes
   both speed and numerics.
3. **Network level.**
   - Run `testgpuerror` against the Eigen FP32 reference files (`rungpuerrortest.sh` already has gpu and ane modes;
     add a Core AI mode with its own `deviceToUseThread*` id).
   - Cover 9/13/19/10x14/rectangle and add 37×37, for b18c384nbt, b28c512nbt, the human SL net and the official
     b40 download.
   - Compare against the CoreML/NE numbers; given the shared ANE backend they should be nearly bit-identical.
4. **Per-op divergence.** When a network-level check fails, use the Core AI Debugger comparison (PSNR per sync
   point) against a PyTorch `.aimodelintermediates` run, or against a second compute unit [D-Validate].

---

## 4. Probe results

**Setup.** Everything ran in a temporary scratch directory (`<scratchpad>` below), which no longer exists. The
essential scripts are reproduced in the appendix. No project build was run.

```bash
cd <scratchpad>
uv venv -p 3.12 venv
VIRTUAL_ENV=$PWD/venv uv pip install coreai-core==1.0.0b3 numpy coremltools==9.0
cd probe
```

### 4.1 The model format and the textual MLIR test

```bash
../venv/bin/python -I hello.py                       # x + x, saves hello.aimodel
xcrun coreai-build inspect hello.aimodel --storage --compute --ops
shasum -a 256 hello.aimodel/main.mlirb; xxd hello.aimodel/main.hash   # identical: hash = SHA-256(bytecode)
swiftc -parse-as-library -O hello.swift -o hello && ./hello hello.aimodel
#   availableKinds: [cpu, neuralEngine, gpu]  arch: h15c  y = [2,4,6,8,10,12]
# textual MLIR + recomputed hash -> "input buffer is not an MLIR bytecode file",
#   "LLVM ERROR: cannot unwrap empty `odiec_module_t`", process exit 134
```

### 4.2 The Mish/softplus sweep

```bash
../venv/bin/python -I make_input.py x_all.f16        # 40705 distinct FP16 values in [-30,30], padded to 40960
../venv/bin/python -I build_mish.py                  # mish_probe.aimodel, one FP16 function per formulation
swiftc -parse-as-library -O mish_probe.swift -o mish_probe
./mish_probe mish_probe.aimodel x_all.f16 out        # cpu, gpu (preferred), ane (preferred), default
../venv/bin/python -I analyze.py && ../venv/bin/python -I table.py
../venv/bin/python -I build_elem.py   && ./mish_probe elem_probe.aimodel   x_all.f16 out_elem   cpu,gpu,ane
../venv/bin/python -I build_fuse.py   && ./mish_probe fuse_probe.aimodel   x_all.f16 out_fuse   cpu,gpu,ane
../venv/bin/python -I build_addlog.py && ./mish_probe addlog_probe.aimodel x_all.f16 out_addlog cpu,gpu,ane
../venv/bin/python -I build_single.py mish_branchfree   # then residency:
USE_OS_COREAI=1 ../venv/bin/python -I plan.py single_mish_branchfree.aimodel ane
```

Selected raw values, ANE on the left and CPU in parentheses where it differs [Probe]:

| x | ref softplus | naive softplus | ref Mish | naive Mish | torch-decomp Mish | branch-free Mish |
|---|---|---|---|---|---|---|
| 10.3828 | 10.383 | 10.383 | 10.383 | 10.383 (CPU 10.375) | 10.383 | 10.383 |
| 10.3984 | 10.398 | **0** | 10.398 | **0** (CPU 10.391) | **0** | 10.398 |
| 11.0938 | 11.094 | **0** (CPU `inf`) | 11.094 | **0** | **0** | 11.094 |
| 20.0 | 20 | **0** (CPU `inf`) | 20 | **0** (CPU 19.984) | **0** | 20 |
| 20.0156 | 20.016 | **0** | 20.016 | **0** | 20.016 | 20.016 |
| −8.0 | 3.35e-4 | 0 | −2.68e-3 | 0 | 0 | −2.69e-3 |
| −10.0 | 4.54e-5 | 0 | −4.54e-4 | 0 | 0 | −4.57e-4 |

Residency with `.neuralEngine` preferred, from single-function models: every compute op was on the ANE, plus one
GPU kernel per function (naive 5 + 1, torch 7 + 1, stable 9 + 1, branch-free 6 + 1, sigmoid 7 + 1). With `.gpu` or
`.default` everything was GPU; with `.cpuOnly`, the BNNS delegate [Probe].

### 4.3 The throughput benchmark

```bash
../venv/bin/python -I build_tower.py branchfree 8 256 10 --coreml   # also relu|sigmoid|stable|naive, N=1, C=384
swiftc -parse-as-library -O bench.swift -o bench
./bench tower_branchfree_n8_c256_b10_s19 cpu,gpu,ane,default 30 1,2,4
```

`bench.swift` does the following for each unit:
- `AIModelCache.default.deleteEntries(for:)`, then times `AIModel(contentsOf:options:)` and `loadFunction`, plus a
  warm reload.
- Times 3 warm-up runs and then 30 sequential `run` calls (median), then k = 1, 2, 4 concurrent tasks × 30 runs.
- Does the same through Core ML: `MLModel.compileModel`, then `MLModel(contentsOf:configuration:)` with
  `.cpuOnly/.cpuAndGPU/.cpuAndNeuralEngine/.all` and async `prediction(from:)`.
- Compares outputs for a fixed input, reading MLMultiArray strides.

The results are in Section 2.5.

### 4.4 Board sizes and ahead-of-time compilation

```bash
for w in static19 enumerated dynamic weights_as_inputs; do ../venv/bin/python -I build_shapes.py $w; done
swiftc -parse-as-library -O shapes.swift -o shapes
./shapes shapes_static19.aimodel gpu,ane static
./shapes shapes_enumerated.aimodel gpu,ane enumerated
./shapes shapes_dynamic.aimodel gpu,ane dynamic            # add a 5th arg for expectFrequentReshapes
./shapes shapes_weights_as_inputs.aimodel gpu,ane weights
xcrun coreai-build list-architectures --platform iOS
../venv/bin/python -I build_tower.py stable 8 256 10 seed=1 && ../venv/bin/python -I build_tower.py stable 8 256 10 seed=2
xcrun coreai-build compile tower_stable_n8_c256_b10_s19_seed1.aimodel --platform macOS --architecture h15c \
      --preferred-compute neural-engine --output aot2/        # 1.3 s
swiftc -parse-as-library -O loadtime.swift -o loadtime
./loadtime aot2/tower_stable_n8_c256_b10_s19_seed1.h15c.aimodelc ane   # 0.55 s, 10.85 ms/run
./loadtime tower_stable_n8_c256_b10_s19_seed2.aimodel ane              # 40.62 s
```

The results are in Sections 2.5 and 2.6.

### 4.5 What I could not measure

- iPhone, iPad, Vision Pro and Apple TV numbers: no device was available. Every timing is from an M3 Max.
- Power and energy.
- Whether tvOS routes anything to the ANE through Core AI. Core ML never did in this app (`TVCoreMLBenchmark`,
  0 ANE ops) [Repo].
- Behaviour inside the macOS `katago-engine` helper, which has its own bundle identity and therefore its own
  `AIModelCache.default` scope [SDK, cache layout].
- Whether the 722 s or 40 s on-device ANE specializations are an early-release regression. `coreai-build` did the
  same graphs in 1 to 2 s on the host.
- Any timing on an idle machine: an unrelated GPU-heavy training job ran throughout (Section 2.5, Caveat).

### 4.6 Independent verification

A second pass tried to refute the load-bearing claims, with its own builders and harnesses (scripts in the
scratchpad's `verify/` folder) [Verify]:

| Claim | Verdict |
|---|---|
| No public on-device way to create a Core AI program | Confirmed; three more public load entry points exist, all from an existing `.aimodel`/`.aimodelc` |
| Inference is async-only | **Refuted**: `encode` is synchronous and works from a plain thread (Section 2.3) |
| Core AI is absent from every Simulator SDK | Confirmed, including the installed iOS 27.0 simulator runtime |
| ANE `log(exp(x)+1)` returns 0 for x ≥ 10.3984; `log(+inf)` = 0 | Confirmed over all 65,536 FP16 bit patterns; the last correct input is 10.390625 |
| PyTorch-decomposed Mish outputs 0 on [10.3984, 20] on the ANE | Confirmed: exactly 974 inputs |
| Branch-free Mish max abs error ≤ 3e-3; y == x for x ≥ 12 | Confirmed (2.57e-3 CPU, 2.62e-3 ANE) |
| Ops are ANE-resident under `.neuralEngine` | Confirmed; the one GPU record per function is a graph-level entry, not proven to be a compute kernel |
| Core AI faster than Core ML at N=1 on the ANE | **Refuted**: Core ML was 20 to 35% faster in 500 to 1000 sample runs; 30-sample medians swing 1.3 to 2.6 ms with the power state |
| Core AI about 7% slower at N=8 on the ANE | Confirmed: 7.1 to 10.4% slower |
| Cold ANE specialization 0.84 s (N=1), 8.4 s (N=8); Core ML 0.3 to 1.2 s | Confirmed; Core ML 0.51 to 0.56 s and 1.16 to 1.20 s, truly cold |
| AOT `.aimodelc` loads in about 0.55 s | Partly: bimodal, 0.5 to 0.6 s after idle, about 10.5 s stall back-to-back |
| `.default` options cause a 10.6 s AOT load | **Refuted**: the same `aned` stall |
| Identical weights and functions across frameworks | Confirmed byte-for-byte; ANE outputs element-wise identical |

---

## 5. Implications for a KataGo Core AI backend: open decisions

1. **Conversion path.** Converting `.bin.gz` into a program on device has no supported Core AI equivalent: no
   public builder, bytecode only, and a private, unversioned dialect. Which of these is it?
   - Offline only: a Python converter, mirroring `MILBuilder` with `coreai.authoring` or translating the MIL it
     emits, runs on a Mac or Linux; the app downloads `.aimodel`/`.aimodelc` next to `.bin.gz`. Then custom and
     user-imported networks stay on Core ML.
   - A C++ MLIR-bytecode writer that tracks a dialect Apple may change in any OS release.
   - Is a PyTorch-checkpoint path (`coreai-torch` plus a Mish override) worth having alongside `.bin.gz`, given that
     the app distributes `.bin.gz`?
2. **Where conversion runs, and who signs off.** Python on Linux or a Mac for authoring (`coreai-core` has
   manylinux wheels), `coreai-build` (Metal Toolchain) for AOT. Can Xcode Cloud run the Metal Toolchain step
   reliably, given the repo's earlier Cloud Metal Toolchain trouble? Or does a separate CI job publish the assets?
3. **Shipping AOT artifacts.** Cold ANE specialization from `.aimodel` took 8 to 41 s on an M3 Max, and an iPhone
   could well be slower. AOT brought it to about 0.5 s.
   - Ship one `.aimodelc` per architecture (9 iOS, 22 macOS, 2 visionOS, each about the size of the network), hosted
     and fetched by `deviceArchitectureName`?
   - What happens on tvOS, where AOT is not supported? Accept the on-device specialization there, or keep tvOS on
     Core ML?
4. **Board-size and batch matrix.** One static function per board size (`set_static_shape_config`) inside one
   `.aimodel`, or one asset per size? Which sizes are compiled ahead of time: just 19, the menu sizes, or all 36?
   Which batch sizes? Every static function adds ANE specialization time, and ANE time grew roughly in proportion
   with batch. Do non-precompiled sizes fall back to a dynamic GPU function or to Core ML?
5. **Platform gating.** `#if canImport(CoreAI)` everywhere, because no Simulator SDK has it. How is the backend
   tested, given the test target runs only on the simulator? A macOS-hosted package test, as the probes here did?
   On iOS, macOS and visionOS, does Core AI replace Core ML on 27 (`if #available(iOS 27, …)`) or sit beside it as a
   user choice? What is the device-assignment id (today's MLX mux uses 100 for CoreML/NE)?
6. **The C++ seam.** Core AI is Swift-only. `run` is async, but the synchronous `encode` onto a per-thread
   `ComputeStream` plus a Metal marker wait works from a plain thread (Section 2.3). Does the shim use that pattern
   behind `@_cdecl` entry points, rather than blocking on a `Task`? And does it allocate inputs with
   `preferredStrides` and pre-allocated `outputViews` to avoid the ANE layout copies seen here (W = 19 padded to 32)?
7. **Coexisting with CoreMLCacheKit.** Core AI manages its own specialization cache, keyed by the source file and
   options, purged on OS updates and under storage pressure. Does CoreMLCacheKit shrink to managing `.aimodel` and
   `.aimodelc` files (download, integrity, deletion, `bookmarkData`), with `AIModelCache.Policy.persistent` on iOS,
   macOS and visionOS? And on macOS, does the `katago-engine` helper share specializations with the app through
   `AIModelCache(appGroup:)`, or keep its own?
8. **The Mish lowering.** Adopt the branch-free form (Section 3.5) everywhere, including SCALE8 (E = exp(8x))? Ban
   `log(exp(·)+c)` in the converter with a lint, so that no future head or activation brings back the 2^15 failure?
9. **Scale8 on the ANE.** The ANE is FP16-only with FP16 accumulation, and boards go to 37×37. Does the Core AI graph
   apply `applyScale8ToReduceActivations()` for convnets? Or does `testgpuerror` at 37×37 show enough headroom for
   pure FP16, as `MILBuilder` assumes today? Transformers will need the same FP32 tiers as `MILBuilder`, which means
   leaving the ANE.
10. **Unit choice.** `.default` picks for latency (GPU on this Mac); the iOS app picks the ANE for power. Does the
    backend always pass `preferredComputeUnitKind: .neuralEngine` on iOS and visionOS, and assert residency at load?
    Is a Core AI GPU path worth having at all, next to MLX/GPU?
11. **Validation gate.** What is the acceptance bar? The op-level FP16 sweep per unit, residency assertions, and
    `testgpuerror` matching or beating CoreML/NE on b18c384nbt, b28c512nbt, the human SL net and b40 at all board
    datasets plus 37×37 (Section 3.6)?
12. **Failure isolation.** A malformed `.aimodel` aborts the process instead of throwing. Should the app validate
    downloaded assets (SHA-256 of the whole bundle, `AIModelAsset.isValid(at:)`, a signature) before
    `AIModel(contentsOf:)` ever sees them? On macOS, does the subprocess engine contain the blast radius anyway?

---

## 6. Sources

**Apple documentation (developer.apple.com, fetched as DocC JSON on 2026-10-18)**

- [D-CoreAI] Core AI: https://developer.apple.com/documentation/coreai
- [D-Integrate] Integrating on-device AI models in your app with Core AI: https://developer.apple.com/documentation/coreai/integrating-on-device-ai-models-in-your-app-with-core-ai
- [D-Spec] Managing model specialization and caching: https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching
- [D-AOT] Compiling Core AI models ahead of time: https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time
- [D-Debug] Inspecting, debugging, and profiling Core AI models: https://developer.apple.com/documentation/coreai/inspecting-debugging-and-profiling-core-ai-models
- [D-Instr] Analyzing model runtime performance with Instruments: https://developer.apple.com/documentation/coreai/analyzing-model-runtime-performance-with-instruments
- [D-Debugger] Inspecting Core AI models with Core AI Debugger: https://developer.apple.com/documentation/coreai/inspecting-core-ai-models-with-core-ai-debugger
- [D-Validate] Validating inference correctness against a reference run: https://developer.apple.com/documentation/coreai/validating-inference-correctness-against-a-reference-run
- [D-InferenceFunction] https://developer.apple.com/documentation/coreai/inferencefunction
- [D-encode] https://developer.apple.com/documentation/coreai/inferencefunction/encode(inputs:states:outputviews:to:)
- [D-ComputeStream] https://developer.apple.com/documentation/coreai/computestream
- [D-NDArrayDescriptor] https://developer.apple.com/documentation/coreai/ndarraydescriptor and https://developer.apple.com/documentation/coreai/ndarraydescriptor/preferredstrides
- [D-AIModelAsset] https://developer.apple.com/documentation/coreai/aimodelasset
- [D-BGInference] Background Inference entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference
- [D-CoreML] Core ML: https://developer.apple.com/documentation/coreml

**WWDC 2026 sessions (developer.apple.com/videos, transcripts)**

- [W324] Meet Core AI: https://developer.apple.com/videos/play/wwdc2026/324/
- [W325] Dive into Core AI model authoring and optimization: https://developer.apple.com/videos/play/wwdc2026/325/
- [W326] Integrate on-device AI models into your app using Core AI: https://developer.apple.com/videos/play/wwdc2026/326/
- [W330] Optimize custom machine learning operations with Metal tensors: https://developer.apple.com/videos/play/wwdc2026/330/
- [W102] Platforms State of the Union: https://developer.apple.com/videos/play/wwdc2026/102/
- [W101] Keynote: https://developer.apple.com/videos/play/wwdc2026/101/

**Apple open source**

- [CT] coreai-torch and coreai-core documentation: https://apple.github.io/coreai-torch/main/. Pages used: `index`,
  `getting-started/installation`, `coreai-core/index`, `coreai-core/tutorials/construct-a-graph`,
  `coreai-core/tutorials/run-an-aimodel`, `coreai-core/api/coreai`, `api/supported-aten-ops`, `api/TorchConverter`.
- [CT-src] https://github.com/apple/coreai-torch (main, pushed 2026-10-14). Files used:
  `coreai_torch/_aten_to_core.py` (`replace_log1p`, `replace_expm1`), `coreai_torch/_decomp.py`,
  `coreai_torch/debugging/compute_plan.py`, `coreai_torch/debugging/debug_info.py`, `pyproject.toml`.
- [CM-skills] https://github.com/apple/coreai-models (main). Files used:
  `skills/skills/model-authoring/SKILL.md`, `references/neural_engine_rules.md`, `references/common_issues.md`.
- [PyPI] https://pypi.org/project/coreai-core/ (1.0.0b3, wheels) and https://pypi.org/project/coremltools/
  (9.0, 2025-11-10; 9.1.dev1, 2026-08-03).

**Third-party primary sources**

- [PT] PyTorch reference decompositions, `torch/_refs/nn/functional/__init__.py` (`mish`, `softplus`) and
  `torch/_decomp/__init__.py` (core ATen decomposition list): https://github.com/pytorch/pytorch (main)
- [ONNX] Softplus operator: https://onnx.ai/onnx/operators/onnx__Softplus.html
- [TRT] TensorRT `nvinfer1::ActivationType`: https://docs.nvidia.com/deeplearning/tensorrt/latest/_static/c-api/namespacenvinfer1.html
- [MLX] `mlx.core.logaddexp`: https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.logaddexp.html

**Local**

- [SDK] `/Applications/Xcode.app/Contents/Developer/Platforms/*/Developer/SDKs/*.sdk/System/Library/{Frameworks/CoreAI.framework,SubFrameworks/CoreAI*.framework,Frameworks/CoreML.framework,Frameworks/MetalPerformanceShadersGraph.framework,PrivateFrameworks/{BNNSCoreAIDelegate,ODIE,ODIEDelegates,CoreMLOdie}.framework}`.
  Also the `coreai-build` 3600.83.1 binary and `--help`, from the Metal Toolchain cryptex.
- [Repo] This repository:
  - Mish history: commits 9a61cf6f3, 312876854, 46809d78d, eb8c3930d (and e1b11ef6a); `python/coremlmish.py`.
  - Lowerings and precision: `cpp/external/katagocoreml/src/builder/MILBuilder.cpp`, `cpp/neuralnet/mlxbackend.cpp`,
    `cpp/neuralnet/trtbackend.cpp`, `cpp/neuralnet/onnxmodelbuilder.cpp`, `cpp/neuralnet/cudahelpers.cu`,
    `cpp/neuralnet/desc.cpp`, `cpp/neuralnet/nneval.cpp`.
  - Scale8: commits 05ad7e187 and c2e555277.
  - Apple-side integration: `cpp/neuralnet/metalbackend.swift`, `ios/KataGo iOS/KataGo iOS/CoreMLComputeHandleLoader.swift`,
    `ios/KataGo iOS/KataGoUICore/Sources/CoreMLCacheKit/CoreMLModelCache.swift`.
  - Other: `cpp/rungpuerrortest.sh`, `python/katago/train/model_pytorch.py`,
    `ios/KataGo iOS/ThirdParty/mlx-swift/Source/Cmlx/mlx/mlx/backend/{cpu,metal/kernels}/binary_ops.h`.
- [Probe] Experiments described in Section 4.

---

## Appendix: probe sources (abridged)

<details>
<summary><code>build_mish.py</code>: the formulations exactly as tested</summary>

```python
import shutil, sys
from pathlib import Path
from typing import Annotated
import numpy as np
import coreai                                    # import before coreai._compiler (circular-import quirk)
from coreai import authoring as A
from coreai.authoring import AIProgram, Module, TensorSpec, Value
SHAPE = [1, 40, 32, 32]; H = np.float16
def c(v): return np.array(v, dtype=H)            # FP16 scalar constants only
def sp_naive(x):  return A.log(A.broadcasting_add(A.exp(x), c(1.0)))
def sp_torch(x):  return A.where(A.broadcasting_greater(x, c(20.0)), x, A.log(A.broadcasting_add(A.exp(x), c(1.0))))
def sp_stable(x): return A.broadcasting_add(A.broadcasting_maximum(x, c(0.0)),
                         A.log(A.broadcasting_add(A.exp(A.broadcasting_mul(A.abs_(x), c(-1.0))), c(1.0))))
def sp_thr(x):
    t = c(10.39); inner = A.log(A.broadcasting_add(A.exp(A.broadcasting_minimum(x, t)), c(1.0)))
    return A.where(A.broadcasting_greater(t, x), inner, x)
def mish_branchfree(x):
    e = A.exp(x); emep2 = A.mul(e, A.broadcasting_add(e, c(2.0)))
    return A.divide(x, A.broadcasting_add(A.broadcasting_divide(c(2.0), emep2), c(1.0)))
def mish_sigmoid(x):
    s = A.sigmoid(A.broadcasting_mul(x, c(-1.0))); s2 = A.mul(s, s)
    return A.mul(x, A.divide(A.broadcasting_sub(c(1.0), s2), A.broadcasting_add(s2, c(1.0))))
FORMS = {"sp_naive": sp_naive, "sp_torch": sp_torch, "sp_stable": sp_stable, "sp_thr": sp_thr,
         "mish_naive":  lambda x: A.mul(x, A.tanh(sp_naive(x))),
         "mish_torch":  lambda x: A.mul(x, A.tanh(sp_torch(x))),
         "mish_stable": lambda x: A.mul(x, A.tanh(sp_stable(x))),
         "mish_thr":    lambda x: A.mul(x, A.tanh(sp_thr(x))),
         "mish_branchfree": mish_branchfree, "mish_sigmoid": mish_sigmoid}
module = Module.create()
with module:
    for name, f in FORMS.items():
        def fn(x: Annotated[Value, TensorSpec(shape=SHAPE, dtype=H)]) -> Annotated[Value, TensorSpec(shape=SHAPE, dtype=H, name="y")]:
            return f(x)                           # graph body is traced at decoration time
        A.graph(fn, provided_name=name)
module.verify()
p = Path("mish_probe.aimodel"); shutil.rmtree(p, ignore_errors=True)
AIProgram(module).save_asset(p)
```
</details>

<details>
<summary><code>mish_probe.swift</code>: runs each function per compute unit and dumps FP16 outputs</summary>

```swift
import CoreAI
import Foundation

func options(_ name: String) -> SpecializationOptions {
    switch name {
    case "cpu": return .cpuOnly
    case "gpu": return SpecializationOptions(preferredComputeUnitKind: .gpu)
    case "ane": return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    default:    return .default
    }
}

@main struct MishProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        let modelURL = URL(fileURLWithPath: args[1])
        let input = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let outDir = URL(fileURLWithPath: args[3])
        let units = args.count > 4 ? args[4].split(separator: ",").map(String.init) : ["cpu", "gpu", "ane", "default"]
        let count = input.count / 2
        for unit in units {
            let model = try await AIModel(contentsOf: modelURL, options: options(unit))
            let dir = outDir.appendingPathComponent(unit)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in model.functionNames {
                guard let fn = try model.loadFunction(named: name),
                      case .ndArray(let desc)? = fn.descriptor.inputDescriptor(of: "x") else { continue }
                var x = NDArray(shape: desc.shape, scalarType: .float16)
                do {
                    var mv = x.mutableView(as: Float16.self)
                    guard var dst = mv.contiguousElements else { fatalError("non-contiguous input") }
                    input.withUnsafeBytes { raw in
                        let src = raw.bindMemory(to: Float16.self)
                        for i in 0..<count { dst[i] = src[i] }
                    }
                }
                _ = try await fn.run(inputs: ["x": x])            // warm-up
                var outs = try await fn.run(inputs: ["x": x])
                guard let y = outs.remove("y")?.ndArray,
                      let src = y.view(as: Float16.self).contiguousElements else { continue }
                var v = [Float16](repeating: 0, count: count)
                for i in 0..<count { v[i] = src[i] }
                try v.withUnsafeBytes { try Data($0).write(to: dir.appendingPathComponent("\(name).f16")) }
            }
        }
    }
}
```
</details>

<details>
<summary><code>plan.py</code>: per-kernel residency from Core AI debug info (macOS, <code>USE_OS_COREAI=1</code>)</summary>

```python
import asyncio, json, sys, os
from coreai.runtime import AIModel, SpecializationOptions, ComputeUnitKind
async def main(path, unit):
    if unit == "cpu":       o = SpecializationOptions.cpu_only()
    elif unit == "default": o = SpecializationOptions.default()
    else: o = SpecializationOptions.from_preferred_compute_unit_kind(
              {"gpu": ComputeUnitKind.gpu(), "ane": ComputeUnitKind.neural_engine()}[unit])
    m = await AIModel.load(path, o.with_debug(enabled=True))
    records = json.loads(m._debug_infos)   # [{identifier: "MPSGraph_optimized_op_id"|"bnns_op_id"|"odix_op_id", operations: [...]}]
    for rec in records:                    # each operation's metadatas carry "residency": "ANE"|"GPU"
        print(rec["identifier"], len(rec["operations"]))
    open(f"debug_{os.path.basename(path)}_{unit}.json", "wb").write(m._debug_infos)
asyncio.run(main(sys.argv[1], sys.argv[2]))
```
</details>

The tower builder (`build_tower.py`) emits the same random FP16 weights in two forms. The Core AI form uses
`A.pad` (`uint32` padding [0,0,0,0,1,1,1,1]) and `A.conv2d` (`uint32` stride, dilation and groups; bias added by
broadcasting). The Core ML form uses `coremltools` MIL `mb.conv(pad_type="same")`, `compute_precision=FLOAT16`,
`minimum_deployment_target=macOS15`. The benchmark (`bench.swift`), board-size runner (`shapes.swift`) and AOT load
timer (`loadtime.swift`) follow Section 4.
