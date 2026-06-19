# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a fork of KataGo (a strong open-source Go AI engine) with native apps for iOS, macOS, and visionOS that wrap the C++ engine. iOS and visionOS are SwiftUI apps; macOS is a native AppKit app that embeds SwiftUI panes via `NSHostingController`. The app compiles an MLX-based C++ backend that runs inference on Apple's Neural Engine (via CoreML) and GPU (via MLX), providing power-efficient Go analysis across Apple platforms.

## Build Commands

### Building for All Platforms
The app must build for all three supported platforms. There are **two app targets/schemes**: `KataGo Anytime` (iOS + visionOS) and `KataGo Anytime Mac` (macOS, native AppKit). The `KataGo Anytime` scheme does **not** support macOS — use `KataGo Anytime Mac` for the Mac build.
```bash
cd ios/KataGo\ iOS

# Build for iOS Simulator (scheme: KataGo Anytime)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug

# Build for visionOS Simulator (scheme: KataGo Anytime)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug

# Build for macOS (separate scheme: KataGo Anytime Mac)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug
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
- CoreML model conversion, loading, and caching are handled Swift-side: `CoreMLComputeHandleLoader.swift` (in the iOS app target `KataGo iOS/` and the macOS app target `KataGo Anytime Mac/`) and `CoreMLModelCache.swift` (in the `CoreMLCacheKit` target of the `KataGoUICore` package) — there is no `coremlbackend.cpp`.
- `neuralnet/metalbackend.{cpp,swift}` - legacy Metal backend, superseded by MLX and not active in the app (the app defines `USE_MLX_BACKEND`, not `USE_METAL_BACKEND`).
- Standard upstream backends: CUDA, OpenCL, Eigen (CPU), TensorRT.

**Apps & shared package (`ios/KataGo iOS/`)**: Native iOS/macOS/visionOS interface:
- `KataGoUICore/` - Shared SwiftPM package for all platforms: the C++ bridge (`CKataGoBridge` target + `KataGoHelper.swift`, folded in from the former `KataGoInterface` framework) plus shared models, services, SwiftUI rendering, and the `GameSession`/`KataGoEngineIO` engine seam. Vends two products: `KataGoUICore` (UI + bridge) and `CoreMLCacheKit` (dependency-light CoreML cache reused by the subprocess engine).
- `KataGo iOS/` - iOS/visionOS app target (SwiftUI entry point and views; scheme `KataGo Anytime`)
- `KataGo Anytime Mac/` - macOS app target (native AppKit; scheme `KataGo Anytime Mac`)
- `KataGoEngineIPC/` - macOS-only package that spawns and drives the `katago-engine` subprocess over stdin/stdout pipes
- `KataGoEngineHelper/` - builds the `katago-engine` subprocess executable (linked against the C++ engine)

### Key Swift Files

| File | Purpose |
|------|---------|
| `KataGo_iOSApp.swift` | iOS/visionOS app entry point, SwiftData container setup |
| `ContentView.swift` | iOS/visionOS main view; drives `GameSession.run()`/`messaging()` |
| `GameSplitView.swift` | Navigation split view, game list sidebar |
| `MainWindowController.swift` | macOS AppKit window controller; owns the `GameSession`, engine lifecycle, and subprocess |
| `BoardViewController.swift` | macOS AppKit view controller; hosts the SwiftUI board via `NSHostingController` |
| `GameSession.swift` | Per-game engine driver; owns the GTP message loop (`messaging()`) |
| `KataGoEngineIO.swift` | Transport protocol + `InProcessKataGoEngine` (iOS/visionOS) |
| `SubprocessKataGoEngine.swift` | macOS subprocess GTP transport (wraps `KataGoEngineProcess` from `KataGoEngineIPC`) |
| `KataGoModel.swift` | Board state, stones, analysis data models |
| `GobanView.swift` | Go board rendering |
| `KataGoHelper.swift` | In-process C++ bridge (iOS/visionOS): `runGtp()`, `sendCommand()`, `getMessageLine()` |
| `GameRecord.swift` | SwiftData model for saved games |
| `GobanState.swift` | Game state management (editing, branching, SGF) |
| `Commentator.swift` | AI commentary using Apple FoundationModels |
| `AudioModel.swift` | Sound effects for stone placement/capture |
| `LinePlotView.swift` | Win rate/score chart with auto-play |
| `BoardLineView.swift` | Board grid lines rendering |

**Locations:** `KataGo_iOSApp.swift`, `ContentView.swift`, `GameSplitView.swift`, and `GobanView.swift` are in the iOS app target (`KataGo iOS/`); `MainWindowController.swift` and `BoardViewController.swift` are in the macOS target (`KataGo Anytime Mac/`, alongside `SubprocessKataGoEngine.swift`). The rest live in the shared `KataGoUICore` package: Bridge (`KataGoHelper.swift`, `KataGoEngineIO.swift`), Session (`GameSession.swift`), Model (`KataGoModel.swift`, `GameRecord.swift`, `GobanState.swift`, `NeuralNetworkModel.swift`), Services (`Commentator.swift`, `AudioModel.swift`), Rendering (`LinePlotView.swift`, `BoardLineView.swift`).

### Communication Pattern

The app communicates with the C++ engine via GTP (Go Text Protocol), abstracted by the `KataGoEngineIO` protocol so the transport differs by platform:
- **iOS/visionOS** run the engine **in-process** (`InProcessKataGoEngine`, delegating to `KataGoHelper`).
- **macOS** spawns a **`katago-engine` subprocess** and talks GTP over stdin/stdout (`SubprocessKataGoEngine` wrapping `KataGoEngineProcess` from `KataGoEngineIPC`; wired via `session.useEngine(_:)` in `MainWindowController`).

Because both conform to `KataGoEngineIO`, `GameSession` drives them identically:
1. Swift sends commands via `engine.sendCommand()`
2. The engine queues responses
3. Swift polls `engine.getMessageLine()` in an async loop
4. `GameSession.messaging()` parses responses to update UI state

### Neural Network Backends on Apple Silicon

The compiled MLX backend multiplexes two inference paths — **CoreML/NE** (Apple's Neural Engine) and **MLX/GPU**. On **iOS/visionOS** these are user-selectable per model in the Backend settings sheet. On **macOS** the per-model picker is removed: the engine always runs a fixed **1 GPU + 2 ANE** NN-server-thread mux (`MainWindowController.engineDeviceAssignments = [0, 100, 100]`).
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
