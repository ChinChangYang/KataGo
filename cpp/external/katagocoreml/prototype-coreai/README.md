# PROTOTYPE: Core AI conversion parity (wayfinder #36)

Throwaway code. It answers one question and is never merged:
does a Core AI translation of b18c384nbt match the Core ML model `MILBuilder` builds, element by element, on the CPU
and the Neural Engine, at 19x19 and 37x37?

## Approach

A **MIL translator**, not a second builder:

1. `mlpackage_cli` (C++, links this directory's parent `katagocoreml`) writes the `.mlpackage` that the app's
   converter builds from a `.bin.gz`, with the app's options: FP16 compute, FP32 I/O, mask on, batch 1.
2. `mil_to_coreai.py` loads that MIL program with `coremltools` and re-emits it op for op through
   `coreai.authoring`. Mish therefore arrives in `MILBuilder`'s branch-free form `x / (1 + 2/(e(e+2)))`, and the
   script asserts the program holds no `log` and no `tanh`.
3. `parity.py` runs both frameworks from Python on the OS runtime (`USE_OS_COREAI=1`): `.cpuOnly` and preferred
   `.neuralEngine` for Core AI, `CPU_ONLY` and `CPU_AND_NE` (the app's setting) for Core ML. FP32 builds of both on
   the CPU are the reference; they agree with each other to about 3e-5.

Positions come from `python/katago/game`: the empty board, a real 19x19 game (`cpp/tests/data/humanslbigdiff.sgf`),
random legal play, and games the FP32 network plays against itself with its policy sampled.

## Run

```bash
KATAGO_MODEL=/path/to/default_model.bin.gz ./run.sh <workDir>          # all stages
./run.sh <workDir> compare                                              # tables only
```

Needs macOS 27 with Xcode 27, Homebrew `protobuf` and `abseil`, and `uv`. Afterwards, trash
`~/Library/Caches/coreai-cache`.
