# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a fork of KataGo (a strong open-source Go AI engine) with native apps for iOS, macOS, and visionOS that wrap the C++ engine. iOS is a SwiftUI app; macOS is a native AppKit app that embeds SwiftUI panes via `NSHostingController`; visionOS is a volumetric RealityKit app (3D goban + stones, game-controller move input). The app compiles an MLX-based C++ backend that runs inference on Apple's Neural Engine (via CoreML) and GPU (via MLX), providing power-efficient Go analysis across Apple platforms.

## Source Code Layout

Quick map of where the **KataGo Anytime** source lives (the **Architecture** and **C++ Source Structure** sections below have the details):

- **`cpp/`** — the KataGo C++ engine (upstream tree plus the app's MLX backend).
- **`ios/KataGo iOS/`** — everything Apple: the Xcode project, all app targets, and the shared Swift package. This is the working directory for every build/test command in this file.

Inside `ios/KataGo iOS/`, the product is split across:

- **`KataGo Anytime.xcodeproj`** — the one Xcode project for all platforms (schemes `KataGo Anytime` for iOS, `KataGo Anytime Mac` for macOS, `KataGo Anytime Vision` for visionOS).
- **`KataGo iOS/`** — iOS app target source (entry point + SwiftUI views). Because this folder sits inside `ios/KataGo iOS/`, the full path is `ios/KataGo iOS/KataGo iOS/`.
- **`KataGo Anytime Mac/`** — macOS (AppKit) app target source.
- **`KataGo Anytime Vision/`** — visionOS app target source (volumetric RealityKit board, controller input, ornament) plus the committed 3D assets in `Resources/BoardAssets/` (36 geometry-only board USDZs for 2..37 with 4×4 placeholder tops + the two stones, ~2.3 MB, bundled as a folder reference; board-top textures are generated at runtime and placement is analytic — no manifest).
- **`KataGoUICore/`** — shared SwiftPM package (models, services, rendering, the C++ bridge, the `GameSession`/`KataGoEngineIO` seam); most cross-platform logic lives here.
- **`KataGoEngineIPC/`** + **`KataGoEngineHelper/`** — the macOS subprocess-engine package and the `katago-engine` helper executable.

**Naming traps:** the product is "KataGo Anytime", but the iOS source folder is named `KataGo iOS` (the macOS folder is `KataGo Anytime Mac`, the visionOS folder `KataGo Anytime Vision` with product name "KataGo Vision"), and the project directory `ios/KataGo iOS/` is nested one level above the identically named `KataGo iOS/` target folder. A `KataGo Anytime/` folder that appears locally is untracked cruft (a stray `.DS_Store` + an empty `View/`), not source — ignore it.

## Build Commands

### Building for All Platforms
The app must build for all supported platforms. There are **five app targets/schemes**: `KataGo Anytime` (iOS only), `KataGo Anytime Mac` (macOS, native AppKit), `KataGo Anytime Vision` (visionOS, volumetric RealityKit), `KataGo Anytime TV` (tvOS), and `KataGo Anytime Watch` (watchOS, companion live mirror + remote play). The `KataGo Anytime` scheme supports **neither macOS nor visionOS** — use `KataGo Anytime Mac` / `KataGo Anytime Vision`.
```bash
cd ios/KataGo\ iOS

# Build for iOS Simulator (scheme: KataGo Anytime)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug

# Build for visionOS Simulator (separate scheme: KataGo Anytime Vision)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug

# Build for macOS (separate scheme: KataGo Anytime Mac)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug

# Build for tvOS Simulator (scheme: KataGo Anytime TV)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV'

# Build for watchOS Simulator (scheme: KataGo Anytime Watch; watch app links ONLY KataGoGameStore — never the engine)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)'
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
- `KataGo iOS/` - iOS app target (SwiftUI entry point and views; scheme `KataGo Anytime`)
- `KataGo Anytime Mac/` - macOS app target (native AppKit; scheme `KataGo Anytime Mac`)
- `KataGo Anytime Vision/` - visionOS app target (volumetric RealityKit 3D goban; scheme `KataGo Anytime Vision`, product "KataGo Vision"): board input is game-controller-only (thumbstick/D-pad ghost stone, A play, B show/hide analysis, L1/R1 candidate cycle, X undo, Y pass — immediate, no confirmation; Undo is the safety net); a bottom-front ornament carries player chips (pinch to flip Human⇄AI via `ConfigEngineSync.set*MaxTime`), New Game (9/13/19 quick buttons, disabled above the engine cap, plus a Custom… card with width/height steppers 2..cap — any rectangle), a Games toggle (shows/hides a left-side game-list ornament of the newest iCloud-synced games; picking runs the same gated `switchGame` path as boot), the analysis sparkle (run/pause/off), a Settings gear (right-side card: Analysis information picker Winrate/Score/All/None — Vision default Winrate; Show ownership toggle; board orientation tabletop ⇄ standing — persisted via `VisionSettings.*` UserDefaults on `VisionGameShell`, mirrored into `GobanState`; a Max Board Size picker 9/13/19/37 — default 19, persisted per model — that quits and respawns the engine with the new NN buffer, the tvOS restart pattern ported into `VisionEngineController` with read-loop parking in `VisionRootView`), and a controller-mapping legend (auto-shown on first controller connect; Settings, the legend, and the New Game card share the right anchor, mutually exclusive). The root view owns the per-move engine driver: `.onChange(of: player.nextColorForPlayCommand)` mirrors BoardView's turn-change hook (asymmetric human-SL commands → `maybeRequestAnalysis` → clear) — without it the AI never auto-replies and analysis freezes after the first move. **Any board from 2×2 to 37×37 renders, square or rectangular**: the bundled USDZs are geometry-only squares (a rectangle reuses the width-matched square with its slab depth-stretched and legs repositioned), the board-top texture (procedural wood + grid + hoshi from the shared `BoardStarPoints` rule) is generated at load by `BoardTopTexture` and swapped over the 4×4 placeholder before mount, and placement is analytic (`BoardGeometryRules` — no manifest). A board over the launched NN buffer gates to a board-too-large state pointing at the Max Board Size setting; outside 2..37 gates to unsupported. The volume is 0.9×0.95×0.9 m (`VisionVolumeMetrics`, 1224×1292×1224 pt at 1360 pt/m) so a 37×37 fits both orientations at the native 22×23.7 mm pitch. Engine pinned CoreML/ANE-only `[100, 100]`; NN buffer defaults to 19. Platform-agnostic logic (BoardGeometryRules, BoardTopTexture, BoardSceneGeometry, GhostCursorModel, visionBoardIsSupported, VisionGamePickerItem) lives in `KataGoUICore/Sources/KataGoUICore/Vision/` so the iOS-simulator test target covers it.
- `KataGoEngineIPC/` - macOS-only package that spawns and drives the `katago-engine` subprocess over stdin/stdout pipes
- `KataGoEngineHelper/` - builds the `katago-engine` subprocess executable (linked against the C++ engine)

### Key Swift Files

| File | Purpose |
|------|---------|
| `KataGo_iOSApp.swift` | iOS app entry point, SwiftData container setup |
| `ContentView.swift` | iOS main view; drives `GameSession.run()`/`messaging()` |
| `VisionRootView.swift` | visionOS root: engine boot, run loop, controller events, ornament |
| `VisionBoardSceneModel.swift` | visionOS RealityKit entity graph; diffs stones/markers into the 3D scene |
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

**Locations:** `KataGo_iOSApp.swift`, `ContentView.swift`, `GameSplitView.swift`, and `GobanView.swift` are in the iOS app target (`KataGo iOS/`); `MainWindowController.swift` and `BoardViewController.swift` are in the macOS target (`KataGo Anytime Mac/`, alongside `SubprocessKataGoEngine.swift`); the `Vision*.swift` files are in the visionOS target (`KataGo Anytime Vision/`). The rest live in the shared `KataGoUICore` package: Bridge (`KataGoHelper.swift`, `KataGoEngineIO.swift`), Session (`GameSession.swift`), Model (`KataGoModel.swift`, `GameRecord.swift`, `GobanState.swift`, `NeuralNetworkModel.swift`), Services (`Commentator.swift`, `AudioModel.swift`), Rendering (`LinePlotView.swift`, `BoardLineView.swift`).

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

The compiled MLX backend multiplexes two inference paths — **CoreML/NE** (Apple's Neural Engine) and **MLX/GPU**. On **iOS** the Backend settings sheet offers three per-model choices — `MLX/GPU`, `CoreML/NE`, and a `GPU+ANE` mux that runs both in parallel — defaulting to single **CoreML/NE** (`BackendSettings.backend`). On **macOS** the per-model picker is removed: the engine always runs a fixed **1 GPU + 2 ANE** NN-server-thread mux (`MainWindowController.engineDeviceAssignments = [0, 100, 100]`). On **visionOS** there is no picker either: the engine is pinned CoreML/ANE-only `[100, 100]` (the GPU belongs to the 90 Hz compositor; see `VisionEngineController`).
- **CoreML/NE** (Neural Engine): default on iOS (best power/throughput, verified on an iPad A17 Pro); best power efficiency (~70 visits/s on iPhone 12); the only backend on visionOS.
- **MLX/GPU**: default on macOS.
- Search threads: on **iOS** they are user-configurable per model in the Backend settings sheet — a Stepper over `1...BackendChoice.maxSearchThreads` (**32**), defaulting to `KataGoHelper.mlxNumSearchThreads` (**2** on iOS/visionOS, verified on an iPad A17 Pro) and persisted per model. On **macOS** they are fixed at **16** (`mlxNumSearchThreads`, no picker); visionOS uses the shared default (2, no picker).
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
- watchOS 26+ (companion live mirror + remote play, paired iPhone only)
