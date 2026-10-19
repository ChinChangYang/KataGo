# PROTOTYPE: the stage 1 harness for the Core AI gate (wayfinder #37)

Throwaway code. It is never merged.

Stage 1 of the gate builds no engine hookup. It compares Core AI with CoreML/NE on b18c384nbt, on a Mac and on the
iPad A17 Pro. Stage 1 can only fail the gate. The gate is defined in
[What does the Core AI go/no-go gate measure, and what passes it?](https://github.com/ChinChangYang/KataGo/issues/35).

The models come from #36's converter (`../mlpackage_cli.cpp`, `../mil_to_coreai.py`), which this branch carries.

## What it measures

The same Swift sources build a Mac command-line tool and an iPad app.

| mode | what | judged |
|---|---|---|
| `speed` | Sustained throughput of K concurrent batch-1 evaluations. CoreML/NE runs exactly as the app runs it (`CoreMLApp.swift` copies `CoreMLComputeHandle.apply`). Core AI runs four arms: K concurrent batch-1 calls and one static batch-K call, each through `encode` and through `run`. | iPad, K=2: the fastest Core AI arm needs at least 98% of CoreML/NE's median |
| `parity` | Core AI against Core ML, element by element, on this device's ANE. It uses #36's positions at 19x19 and 37x37, and the FP32 reference from the Mac. | 37x37: every head's error is at most 1.10x CoreML/NE's at p50, p99, p99.9, max and RMS; no Core AI-only overflow |
| `mish` | The FP16 Mish sweep (research note section 3.6) on the CPU, GPU and ANE, for both frameworks. A PyTorch-decomposed positive control must fail on the ANE. | Core AI on the ANE: no catastrophic error, max error at most 3e-3, `y == x` for x >= 12 |
| `residency` | Core AI's per-kernel debug records with `.neuralEngine` preferred, and Core ML's compute plans beside them. | No CPU (bnns) kernels, every MPSGraph-level residency is ANE, and at most one top-level op per function lacks one |
| `power` | Each K=2 arm runs alone for 20 s; the readable energy counters give W and mJ per evaluation. | recorded only |
| `load` | One load per process: `coreai-cold`, `coreai-warm`, `coreai-aot` (uncached), `coreml-first`, `coreml-cached`. | recorded only |
| `agree` | Diagnostic: how often each Core AI arm returns rows that differ from Core ML's. | none |

The measurement method is enforced by the tool, not left to whoever runs it:

- **Idle gate.** Before every speed repetition, the tool reads three things over 1 s:
  - GPU "Device Utilization %" from IOAccelerator, the value `ioreg -r -c IOAccelerator` prints;
  - busy CPU cores outside the harness, and on the Mac the top processes;
  - the thermal state and Low Power Mode.

  It waits up to `--idle-wait` (300 s) for the machine to be idle. If the machine never gets there, the tool refuses
  to measure.
- **Sampling.** Each repetition first warms every arm. It then alternates the arms in blocks (100 rounds by default)
  within one process, rotating their order every cycle and discarding the first 5 rounds of each block. It keeps
  going until every arm has at least 500 timed rounds.
- **Spread.** The reported figure is the median of at least 3 repetitions. The spread is (max - min) / median. A
  spread of 2% or more voids the arm.
- **Recordable runs.** A run with fewer samples or repetitions, or with `--allow-busy`, prints
  `SMOKE RUN, NOT FOR THE RECORD` and gives no verdict.
- **Correctness first.** Before timing, every Core AI arm must return Core ML's rows on fresh positions, within FP16
  noise. An arm that returns a wrong row is disqualified and never timed.

## Run

```bash
KATAGO_MODEL=/path/to/default_model.bin.gz ./prepare.sh <workDir>    # models, positions, Mish sweep (about 5 min)
./stage1.sh mac  <workDir>                                         # the Mac, for the record
SUDO_POWER=1 ./stage1.sh mac <workDir>                             # the same, with ANE power (asks for sudo)
./stage1.sh ipad <workDir>                                         # the iPad, connected by USB and unlocked
```

`stage1.sh` writes one JSON per mode, `run.log` and `summary.txt` into `<workDir>/stage1-<platform>-<time>/`.

For single modes, call the tool directly:

```bash
./build.sh mac <workDir> && <workDir>/bin/coreai-gate --mode parity --assets <workDir>/assets --out <dir>
```

On the iPad, the same arguments go after `--` in `xcrun devicectl device process launch --console ...`, followed by
`--exit`. Launched by hand, the app offers the modes as buttons.

### Requirements

- macOS 27 with Xcode 27, Homebrew `protobuf` and `abseil`, and `uv` (as `../run.sh` needs).
- The iPad needs iOS 27, Developer Mode, and the screen unlocked with Auto-Lock off.
- The iPad app is built with plain `swiftc` and signed with the team's wildcard development profile
  ("iOS Team Provisioning Profile: *"). It needs no Xcode project and registers nothing with the developer account.
  Its bundle is about 320 MB.

Afterwards:

- trash `~/Library/Caches/coreai-cache`;
- delete the Core AI Gate app from the iPad;
- set Auto-Lock back.

## Things this harness found while being built (M3 Max on macOS 27.0.1; iPad A17 Pro on iOS 27.0.1)

- **Concurrent Core AI calls into one AIModel return wrong rows on the ANE.**
  - What failed: K threads calling one `InferenceFunction`, or one `InferenceFunction` each from the same `AIModel`.
    This happened with both `encode` and the public async `run`.
  - How often, on the M3 Max: 1 to 2 of 80 rows at K=2, and 30 to 72 of 320 at K=8. On the iPad A17 Pro at K=2:
    6 of 100 through `encode`, 0 of 100 through `run`. The wrong rows are off by up to 22 in the policy logits, and
    they are mostly not another row's answer.
  - What works: one `AIModel` per thread, loaded from the cached specialization, gave 0 wrong rows in 320 at K=8. One
    call to a static batch-K function was always right.
  - What the harness does: the concurrent arms use one `AIModel` per slot (`--functions per-model`). `--mode agree
    --functions shared` reproduces the failure.
- **A cached specialization written by an earlier build of this tool fails in `loadFunction`** (seen on the Mac).
  - What fails: the tool is ad hoc signed, so every build has a new identity. After a rebuild, `AIModel(contentsOf:)`
    succeeds from the cache, then `loadFunction` throws Foundation's `nilError`.
  - What fixes it: deleting the entry and specializing again. Core ML's first load after a rebuild also took about
    4 s instead of 50 ms.
  - What the harness does: it recovers automatically and records each recovery as `cacheRecoveries` in the JSON.
- **Core ML keeps a small elementwise graph on the CPU, whatever compute units it is given.**
  - At 1x40x32x32, the Mish sweep stayed on the CPU. At 1x256x64x64, it was placed on each requested unit.
  - So the sweep tiles its 40,960 inputs 25 times. The Core ML rows report where `MLComputePlan` placed the ops.
- **Unprivileged IOReport reads 0 for ANE, CPU and DRAM energy on macOS 27.** Only GPU energy is readable without root,
  so ANE power on the Mac needs `SUDO_POWER=1`. That path is untested.
