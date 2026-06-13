# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a fork of KataGo (a strong open-source Go AI engine) with a SwiftUI app (iOS/macOS/visionOS) that wraps the C++ engine. The app compiles an MLX-based C++ backend that runs inference on Apple's Neural Engine (via CoreML) and GPU (via MLX), providing power-efficient Go analysis across Apple platforms.

## Build Commands

### Building for All Platforms
The app must build for all three supported platforms: iOS, macOS, and visionOS.
```bash
cd ios/KataGo\ iOS

# Build for iOS Simulator
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug

# Build for macOS
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug

# Build for visionOS Simulator
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
```

### Running Tests
Tests only run on iOS Simulator (the test target does not support macOS or visionOS).
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Required Resources
The app loads its networks from `ios/KataGo iOS/Resources/`. The `.bin.gz` networks are gitignored and must be supplied before building:
- `default_model.bin.gz` - built-in KataGo network (18-block `b18c384nbt`)
- `b18c384nbt-humanv0.bin.gz` - human-style (human SL) network for human-like profiles
- `default_gtp.cfg` - GTP configuration (committed)

There is **no** `.mlpackage` to download: the CoreML model is generated on the fly at runtime by converting the `.bin.gz` network, then compiled and cached. Additional networks (e.g. the 40-block "Official KataGo Network") are downloaded in-app via the model picker.

## Architecture

### Two-Component Design

**C++ Engine (`cpp/`)**: The core KataGo engine. The Apple app compiles the **MLX** backend (`USE_MLX_BACKEND`):
- `neuralnet/mlxbackend.cpp` - the backend the app compiles; dispatches each eval to either Apple's Neural Engine (CoreML) or the GPU (MLX) based on the selected device. Winograd autotuning lives in `mlxwinotuner.{cpp,h}` / `mlxwinograd.h`.
- CoreML model conversion, loading, and caching are handled Swift-side in `KataGoInterface/` (`CoreMLComputeHandleLoader.swift`, `CoreMLModelCache.swift`) — there is no `coremlbackend.cpp`.
- `neuralnet/metalbackend.{cpp,swift}` - legacy Metal backend, superseded by MLX and not active in the app (the app defines `USE_MLX_BACKEND`, not `USE_METAL_BACKEND`).
- Standard upstream backends: CUDA, OpenCL, Eigen (CPU), TensorRT.

**SwiftUI App (`ios/KataGo iOS/`)**: Native iOS/macOS/visionOS interface:
- `KataGoInterface/` - Framework bridging Swift to C++ via `KataGoHelper.swift`
- `KataGo iOS/` - Main app with SwiftUI views and models

### Key Swift Files

| File | Purpose |
|------|---------|
| `KataGo_iOSApp.swift` | App entry point, SwiftData container setup |
| `ContentView.swift` | Main view, GTP message processing loop |
| `GameSplitView.swift` | Navigation split view, game list sidebar |
| `KataGoModel.swift` | Board state, stones, analysis data models |
| `GobanView.swift` | Go board rendering |
| `KataGoHelper.swift` | C++ interface: `runGtp()`, `sendCommand()`, `getMessageLine()` |
| `GameRecord.swift` | SwiftData model for saved games |
| `GobanState.swift` | Game state management (editing, branching, SGF) |
| `Commentator.swift` | AI commentary using Apple FoundationModels |
| `AudioModel.swift` | Sound effects for stone placement/capture |
| `LinePlotView.swift` | Win rate/score chart with auto-play |
| `BoardLineView.swift` | Board grid lines rendering |

### Communication Pattern

The app communicates with the C++ engine via GTP (Go Text Protocol):
1. Swift sends commands via `KataGoHelper.sendCommand()`
2. C++ engine processes and queues responses
3. Swift polls `KataGoHelper.getMessageLine()` in async loop
4. `ContentView.messaging()` parses responses to update UI state

### Neural Network Backends on Apple Silicon

The compiled MLX backend multiplexes two user-selectable inference paths (chosen per model in the Backend settings sheet):
- **CoreML/NE** (Neural Engine): default on iOS and visionOS; best power efficiency (~70 visits/s on iPhone 12).
- **MLX/GPU**: default on macOS.
- Search threads are set per platform: **2** on iOS/visionOS (power efficiency), **16** on macOS.
- On the iOS/visionOS Simulator the backend is always pinned to CoreML/NE (MLX GPU inference crashes in the simulator's Metal layer).

## C++ Source Structure

Key directories (in dependency order):
- `core/` - Low-level utilities, hashing, threading
- `game/` - Board representation (`board.cpp`), rules, history
- `neuralnet/` - NN backends and interface (`nneval.cpp` for batching)
- `search/` - MCTS implementation (`search.cpp`), time controls
- `dataio/` - SGF parsing (`sgf.cpp`), model loading
- `command/` - User commands: `gtp.cpp`, `analysis.cpp`, `benchmark.cpp`

## SwiftData Models

- `GameRecord` - Persisted game with SGF, configuration, timestamps
- `Config` - Game settings (board size, komi, rules, commentary tone, temperature)
- Uses CloudKit for iCloud sync (container: `iCloud.chinchangyang.KataGo-iOS.tw`)

## On-Device AI Commentary

The `Commentator` class uses Apple's FoundationModels framework to generate natural language commentary for moves. Features:
- Configurable tones: technical, educational, encouraging, enthusiastic, poetic
- Analyzes win rate changes, score differences, captured/dead/endangered stones
- Uses `@Generable` struct with `LanguageModelSession` for on-device inference

## Global Settings

App-wide display/behavior preferences are stored via `@AppStorage` (keys prefixed `GlobalSettings.`) and synced into `GobanState` by `GlobalPreferenceSync` in `GameSplitView`. They include: `soundEffect`, `hapticFeedback`, `showVisitsPerSecond`, `showCoordinate`, `showPass`, `verticalFlip`, `showOwnership`, `showWinrateBar`, `showCharts`, `showComments`, `stoneStyle`, `analysisStyle`, `analysisInformation`, and `moveNumberStyle` (the move-number display picker: last-3 / last / all / marker).

## GTP Commands Used

The app uses KataGo's GTP extensions including:
- `kata-analyze` - Continuous analysis with ownership, winrate
- `showboard` - Get current board state
- `printsgf` - Export game as SGF
- `play <color> <move>` - Make moves
- `kata-set-rule` - Configure rules

## Platform Support

- iOS 26+
- macOS 26+ (native, not Catalyst)
- visionOS 26+
