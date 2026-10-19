# PROTOTYPE: the stage 2 hookup for the Core AI gate (wayfinder #40)

Throwaway code. It is never merged and nothing in it ships.

Stage 2 of the gate runs Core AI inside the engine. The gate is defined in
[What does the Core AI go/no-go gate measure, and what passes it?](https://github.com/ChinChangYang/KataGo/issues/35);
the measurements are [What are stage 2's visits/s and testgpuerror results on an idle Mac and the iPad A17 Pro?](https://github.com/ChinChangYang/KataGo/issues/41).

## What the hookup is

- **Device id 200** (`MLX_MUX_COREAI` in `cpp/neuralnet/mlxbackend.cpp`), beside `0` (MLX/GPU) and `100` (CoreML/NE).
  It feeds the same NCHW rows and mask the CoreML/NE path feeds, and reads the outputs the same way.
- **`cpp/neuralnet/coreaibackend.swift`**, in KataGoSwift: `CoreAIComputeHandle`, with the same `apply` signature
  as `CoreMLComputeHandle`. It runs a pre-converted static batch-1 `.aimodel` with `.neuralEngine` preferred.
- **The calling pattern** is the one stage 1 found fastest on the iPad: concurrent batch-1 calls through async
  `run`, **one `AIModel` per concurrent slot**. Concurrent calls into one `AIModel` return wrong rows on the ANE (#37).
  A handle gets `nnMaxBatchSize` slots (cap them with `coreAISlots=<n>`). Row `r` of a batch runs on slot
  `r % slots`; rows on the same slot run one after another. The first slot specializes the model; the others load
  from Core AI's cache in about 10 ms each.
- **Config keys**:
  - `coreAIModelFile=<path>`: an `.aimodel`, or a directory holding `<nnXLen>x<nnYLen>.aimodel` for each NN buffer
    size used. `testgpuerror` needs 9x9, 13x13 and 19x19 (rectangle runs in a 19x19 buffer).
  - `coreAISlots=<n>`: optional, at most `nnMaxBatchSize`.
- The human SL net (meta input) is refused on device 200. `mlxUseFP16=false` is ignored there: the model is FP16.
- `-fno-char8_t` on the `katago` target: Homebrew's MLX 0.32 exports `cxx_std_20`, which broke `fileutils.cpp`
  in the CMake MLX build. This is unrelated to Core AI.

## Build the models

With the converter from #36 (`../mlpackage_cli.cpp`, `../mil_to_coreai.py`) and `../run.sh <workDir> setup`:

```bash
M=/path/to/default_model.bin.gz
for b in 9 13 19; do
  <workDir>/build-cli/mlpackage_cli "$M" <workDir>/models/b18_${b}_n1.mlpackage $b FLOAT16 1
  USE_OS_COREAI=1 <workDir>/venv/bin/python -I ../mil_to_coreai.py <workDir>/models/b18_${b}_n1.mlpackage <models>/${b}x${b}.aimodel
done
```

## The Mac command-line build

```bash
cmake -S cpp -B build-mlx -G Ninja -DUSE_BACKEND=MLX -DCMAKE_BUILD_TYPE=Release && ninja -C build-mlx katago
cmake -S cpp -B build-eigen -G Ninja -DUSE_BACKEND=EIGEN -DCMAKE_BUILD_TYPE=Release && ninja -C build-eigen katago

# The shared FP32 reference, once per dataset (Eigen, slow)
build-eigen/katago testgpuerror -config cpp/configs/gtp_example.cfg -model "$M" -boardsize 19 -reference-file ref_19.bin

# Core AI, and CoreML/NE, scored against it
build-mlx/katago testgpuerror -config cpp/configs/gtp_example.cfg -model "$M" -boardsize 19 -reference-file ref_19.bin \
  -override-config "numNNServerThreadsPerModel=1,mlxDeviceToUseThread0=200,coreAIModelFile=<models>,nnMaxBatchSize=8"
build-mlx/katago testgpuerror -config cpp/configs/gtp_example.cfg -model "$M" -boardsize 19 -reference-file ref_19.bin \
  -override-config "numNNServerThreadsPerModel=1,mlxDeviceToUseThread0=100,nnMaxBatchSize=8"

# GTP in the macOS mux: [0,100,100] against [0,200,200]
build-mlx/katago gtp -config cpp/configs/gtp_example.cfg -model "$M" -override-config \
  "numNNServerThreadsPerModel=3,mlxDeviceToUseThread0=0,mlxDeviceToUseThread1=200,mlxDeviceToUseThread2=200,coreAIModelFile=<models>,numSearchThreads=16,nnMaxBatchSize=8"
```

`testgpuerror` on device 200 also builds its "fp32" evaluator on Core AI's FP16 model. Without a reference file, its
lines compare Core AI with itself (all zeros). With one, the `fp32 error vs reference` lines are FP16 numbers held to
the FP32 thresholds (winrate p99 0.45%), and they can fail: at 19x19 the p99 was 0.457%, so the command exits 1.
Judge Core AI by the `current cfg` lines, not by the exit code. CoreML/NE's fp32 evaluator really is FP32 (Core ML on
the CPU).

## The iPad prototype app

The iOS app reads a hidden key, `prototype.coreAI.arm` (`AppEngineController.spawnEngineThread`):

- `coreai`: one NN server thread on device 200; `coreml`: one on device 100.
- Either way: the default 2 search threads, `nnMaxBatchSize` 3, a 19x19 buffer, `requireMaxBoardSize=false`, and
  the human SL net off, whatever the Backend sheet says. Pick the built-in network in the app.
- Core AI loads `Library/CoreAI/19x19.aimodel` from the app's data container.

```bash
xcodebuild build -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'id=<iPad UDID>' -configuration Release -derivedDataPath <dd>
xcrun devicectl device install app --device <iPad> <dd>/Build/Products/Release-iphoneos/KataGo\ Anytime.app
xcrun devicectl device copy to --device <iPad> --domain-type appDataContainer \
  --domain-identifier chinchangyang.KataGo-iOS.tw --source <models> --destination Library/CoreAI
xcrun devicectl device process launch --device <iPad> --console chinchangyang.KataGo-iOS.tw \
  -prototype.coreAI.arm coreai
```

Afterwards: delete the prototype build from the iPad (or reinstall from TestFlight), and trash
`~/Library/Caches/coreai-cache`.
