# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a fork of KataGo (a strong open-source Go AI engine) with native apps for iOS, macOS, and visionOS that wrap the C++ engine. iOS is a SwiftUI app; macOS is a native AppKit app that embeds SwiftUI panes via `NSHostingController`; visionOS is a volumetric RealityKit app (3D goban + stones, game-controller move input). The app compiles an MLX-based C++ backend that runs inference on Apple's Neural Engine (via CoreML) and GPU (via MLX), providing power-efficient Go analysis across Apple platforms.

## Source Code Layout

Quick map of where the **KataGo Anytime** source lives (the **Architecture** section below has the details):

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
The app must build for all supported platforms. There are **five app targets/schemes**: `KataGo Anytime` (iOS only), `KataGo Anytime Mac` (macOS, native AppKit), `KataGo Anytime Vision` (visionOS, volumetric RealityKit), `KataGo Anytime TV` (tvOS), and `KataGo Anytime Watch` (watchOS, a **standalone read-only game library** — it does not use WatchConnectivity and never talks to the iPhone). The watch links `KataGoGameStore` **and** `GoRulesKit` (both bridge-free) and opens `SharedModelContainer.shared` through the CloudKit-only ladder it shares with tvOS — a plain non-App-Group store over the private CloudKit database that degrades to local-only, then in-memory, and never crashes. Board positions on the watch come from replaying `GameRecord.sgf` via `SgfHeaderScan` + `GoRulesKit.SgfReplay`, never from the per-move `blackStones`/`whiteStones` dictionaries, which only cover indices the phone visited. The watch also embeds the **`KataGoAnytimeWatchWidget`** complication (`kind: "ScoreLeadWidget"` — a legacy identifier kept deliberately: renaming it orphans every existing placement; see `WatchWidgetDefaults.widgetKind`). That appex links **only** `KataGoAnalysisKit` (Foundation-only, zero package dependencies) and reads the App-Group key `watchWidget.records`; it must never link `KataGoGameStore` or touch SwiftData, because on watchOS `SharedModelContainer.shared` takes the CloudKit-only branch with no `groupContainer`, so an appex opening it would get a second, permanently empty store. **App Group containers are per-device**: `group.chinchangyang.KataGo-iOS.tw` is entitled on both the iPhone and the watch, but nothing the phone writes there is visible to the watch widget — the App Group is a watch-LOCAL channel between the watch app and its complication, and the watch app is its only writer. Because nothing wakes the watch app in the background any more, the complication refreshes only while that app runs. The `KataGo Anytime` scheme supports **neither macOS nor visionOS** — use `KataGo Anytime Mac` / `KataGo Anytime Vision`. The iOS app also embeds the **`KataGoAnytimeMessages`** iMessage extension (engine-free human-vs-human Go in a Messages thread; builds with the iOS scheme, no scheme of its own). Like the widget/watch, the Messages extension links ONLY bridge-free products: `KataGoGameStore` + `GoRulesKit` (a pure-Swift port of the engine's board rules + scoring in `KataGoUICore/Sources/GoRulesKit/`, differential-tested against the C++ board in `GoRulesKitDifferentialTests`) — never `KataGoUICore`/`GobanRecogKit`.
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
Tests only run on iOS Simulator (the test target does not support macOS or visionOS). Run them through the script, not a bare `xcodebuild test`: it tests on a simulator of its own ("KataGo iPhone 17", created on first use) because other projects on this Mac test on the stock "iPhone 17", and two test runs on one simulator fail each other with 0 tests run. It also boots and smoke-tests that simulator first, retries simulator-launch failures, and judges the run by the `** TEST … **` line.
```bash
# Unit tests (FastTestPlan, the scheme default)
ios/KataGo\ iOS/scripts/run_tests.sh

# Unit + UI tests
ios/KataGo\ iOS/scripts/run_tests.sh -p FullTestPlan

# One class; anything after -- goes to xcodebuild
ios/KataGo\ iOS/scripts/run_tests.sh -p FullTestPlan -- -only-testing:"KataGo AnytimeUITests/BackendConfigSheetUITests"
```
Exit status: 0 passed, 1 tests failed, 2 no verdict (an infrastructure failure after the retries, a simulator that will not boot, or xcodebuild ending without a `** TEST … **` line, which is not retried), 3 could not start (another xcodebuild is using this project, or a bad option). The counts it prints come from the `.xcresult`, which counts the UI launch test once where the log shows it once per launch configuration. The log and `.xcresult` land in `$TMPDIR/katago-tests/<timestamp>` unless `-o` says otherwise; `-h` lists every option.

### Required Resources
The app loads its networks from `ios/KataGo iOS/Resources/`. The `.bin.gz` networks are gitignored and must be supplied before building:
- `default_model.bin.gz` - built-in KataGo network (18-block `b18c384nbt`)
- `b18c384nbt-humanv0.bin.gz` - human-style (human SL) network for human-like profiles; also bundled by the **tvOS** target, which uses it for its own "Play KataGo" ranked play
- `lionffen_b24c64_3x3_v3_12300.bin.gz` - the 4.8 MB net bundled by the **iOS Safari extension** appex, which runs the engine in-process on a tight memory budget. Missing it fails the iOS build (and only the iOS build) at Copy Bundle Resources.
- `default_gtp.cfg` - GTP configuration (committed)

`ci_scripts/ci_post_clone.sh` downloads all three networks; it is the authoritative list, so a new bundled net has to be added there or Xcode Cloud breaks on the next fresh clone.

There is **no** `.mlpackage` to download: the CoreML model is generated on the fly at runtime by converting the `.bin.gz` network, then compiled and cached. Additional networks (e.g. the 40-block "Official KataGo Network") are downloaded in-app via the model picker.

## Architecture

### Two-Component Design

**C++ Engine (`cpp/`)**: The core KataGo engine. The Apple app compiles the **MLX** backend (`USE_MLX_BACKEND`):
- `neuralnet/mlxbackend.cpp` - the backend the app compiles; dispatches each eval to either Apple's Neural Engine (CoreML) or the GPU (MLX) based on the selected device. Winograd autotuning lives in `mlxwinotuner.{cpp,h}` / `mlxwinograd.h`.
- CoreML conversion is C++ (`cpp/external/katagocoreml/`): `src/builder/MILBuilder.cpp` builds the MIL program from a `.bin.gz` (Mish is lowered in `addMishOps`). Swift drives it and loads the result in `CoreMLComputeHandleLoader.swift` (in the iOS app target `KataGo iOS/` and the macOS app target `KataGo Anytime Mac/`), and `CoreMLModelCache.swift` (in the `CoreMLCacheKit` target of the `KataGoUICore` package) caches compiled models — there is no `coremlbackend.cpp`.
- `neuralnet/metalbackend.{cpp,swift}` - legacy Metal backend, superseded by MLX and not active in the app (the app defines `USE_MLX_BACKEND`, not `USE_METAL_BACKEND`).
- Standard upstream backends: CUDA, OpenCL, Eigen (CPU), TensorRT.

**Apps & shared package (`ios/KataGo iOS/`)**: Native iOS/macOS/visionOS interface:
- `KataGoUICore/` - Shared SwiftPM package for all platforms: the C++ bridge (`CKataGoBridge` target + `KataGoHelper.swift`, folded in from the former `KataGoInterface` framework) plus shared models, services, SwiftUI rendering, and the `GameSession`/`KataGoEngineIO` engine seam. Vends two products: `KataGoUICore` (UI + bridge) and `CoreMLCacheKit` (dependency-light CoreML cache reused by the subprocess engine).
- `KataGo iOS/` - iOS app target (SwiftUI entry point and views; scheme `KataGo Anytime`)
- `KataGo Anytime Mac/` - macOS app target (native AppKit; scheme `KataGo Anytime Mac`)
- `KataGo Anytime Vision/` - visionOS app target (volumetric RealityKit 3D goban; scheme `KataGo Anytime Vision`, product "KataGo Vision"); its controller mapping, ornament, engine-restart, and board-geometry contracts are in `KataGo Anytime Vision/CLAUDE.md` — read it before touching visionOS code or `KataGoUICore/Sources/KataGoUICore/Vision/`.
- `KataGoEngineIPC/` - macOS-only package that spawns and drives the `katago-engine` subprocess over stdin/stdout pipes
- `KataGoEngineHelper/` - builds the `katago-engine` subprocess executable (linked against the C++ engine)

### Communication Pattern

The app communicates with the C++ engine via GTP (Go Text Protocol), abstracted by the `KataGoEngineIO` protocol so the transport differs by platform:
- **iOS/visionOS** run the engine **in-process** (`InProcessKataGoEngine`, delegating to `KataGoHelper`).
- **macOS** spawns a **`katago-engine` subprocess** and talks GTP over stdin/stdout (`SubprocessKataGoEngine` wrapping `KataGoEngineProcess` from `KataGoEngineIPC`; wired via `session.useEngine(_:)` in `MainWindowController`).

Because both conform to `KataGoEngineIO`, `GameSession` drives them identically:
1. Swift sends commands via `engine.sendCommand()`
2. The engine queues responses
3. Swift polls `engine.getMessageLine()` in an async loop
4. `GameSession.messaging()` parses responses to update UI state

**The board never waits for this.** Stones come from the game record, not from the engine (ADR 0008): `RecordPositionProjector` replays the record's SGF and is the only writer of the board's stones, so every platform mounts its board on the first frame and shows engine availability as an inline `EngineStatusView` line instead of a loading screen. Commands are gated on a **handshake**: `GameSession.handshake()` sends `version` (a *lifecycle* command — `version`/`stop`/`quit` bypass the gate) and reads with a bounded, cancellation-aware timed read until a `= `/`? ` reply, EOF or the 660 s budget. Until it succeeds `MessageList.isAcceptingCommands` is `false` and `appendAndSend` **drops and logs** every other command; the feed that was dropped is recorded on `GobanState.engineSyncGate` and replayed against the *live* selection once the engine answers.

### Neural Network Backends on Apple Silicon

The compiled MLX backend multiplexes two inference paths — **CoreML/NE** (Apple's Neural Engine) and **MLX/GPU**. On **iOS** the Backend settings sheet offers three per-model choices — `MLX/GPU`, `CoreML/NE`, and a `GPU+ANE` mux that runs both in parallel — defaulting to single **CoreML/NE** (`BackendSettings.backend`). On **macOS** the per-model picker is removed: the engine always runs a fixed **1 GPU + 2 ANE** NN-server-thread mux (`MainWindowController.engineDeviceAssignments = [0, 100, 100]`). On **visionOS** there is no picker either: the engine is pinned CoreML/ANE-only `[100, 100]` (the GPU belongs to the 90 Hz compositor; see `VisionEngineController`).
- **CoreML/NE** (Neural Engine): default on iOS (best power/throughput, verified on an iPad A17 Pro); best power efficiency (~70 visits/s on iPhone 12); the only backend on visionOS.
- **MLX/GPU**: default on macOS.
- Search threads: on **iOS** they are user-configurable per model in the Backend settings sheet — a Stepper over `1...BackendChoice.maxSearchThreads` (**32**), defaulting to `KataGoHelper.mlxNumSearchThreads` (**2** on iOS/visionOS, verified on an iPad A17 Pro) and persisted per model. On **macOS** they are fixed at **16** (`mlxNumSearchThreads`, no picker); visionOS uses the shared default (2, no picker).
- On the iOS/visionOS Simulator the backend is always pinned to CoreML/NE (MLX GPU inference crashes in the simulator's Metal layer).

## Global Settings

App-wide display/behavior preferences are stored via `@AppStorage` (keys prefixed `GlobalSettings.`) and synced into `GobanState` by `GlobalPreferenceSync` in `GameSplitView`. They include: `soundEffect`, `hapticFeedback`, `showVisitsPerSecond`, `showCoordinate`, `showPass`, `verticalFlip`, `showOwnership`, `showWinrateBar`, `showCharts`, `showComments`, `stoneStyle`, `analysisStyle`, `analysisInformation`, `moveNumberStyle` (the move-number display picker: last-3 / last / all / marker), and `thumbnailSize` (the game-list thumbnail picker: Off / Small / Large — Off draws no board AND resolves none, so the row's `square.grid.3x3` unreadable-record signal goes with it; migrated once from the retired `isLargeThumbnail` bool in `App.init()`).

## GTP Commands Used

The app uses KataGo's GTP extensions including:
- `kata-analyze` - Continuous analysis with ownership, winrate
- `showboard` - The **sync acknowledgement**: its `= MoveNum` reply is what marks the engine in sync with the record position (it no longer supplies the board's stones)
- `printsgf` - Export game as SGF
- `clear_board` - Starts every open/switch, before the setup stones
- `set_free_handicap <vertices>` - Setup stones when every one is Black (leaves White to move, applies the handicap bonus); requires an empty board
- `set_position <color> <vertex> …` - Setup stones for any other AB/AW combination (leaves Black to move)
- `kata-set-initial-player <color>` - **Fork-local.** Sets the side to move of a position with no moves, after the setup, when the record's side (its first move's colour, else `PL[]`, else the all-Black rule) is not the one the setup command left; `undo` and rules changes keep it, and `printsgf` writes it back as `PL[]`
- `play <color> <move>` - Make moves; also how the engine is fed, one recorded move at a time
- `undo` - Backward navigation, refusal-aware (a move the replay refused was never played, so it is never undone)
- `kata-set-rule` - Configure rules

**`loadsgf` is no longer used by the apps** (ADR 0008): a game is fed move by move so that a single illegal move cannot discard the whole record. The two Safari extension appexes keep their own `loadsgf`-based flow.

## Platform Support

- iOS 26+
- macOS 26+ (native, not Catalyst)
- visionOS 26+
- tvOS 26+ — **never a bare multi-option `Picker`**: the default style squeezes every option into one horizontal segment row and truncates the labels (11 rulesets clipped to 3 characters, 259 ranks illegible); use drill-down rows instead. Nothing on a tvOS screen may truncate or wrap — if explanatory prose does not fit one line, cut it.
- watchOS 26+ (standalone read-only game library, synced over iCloud; no connection to the iPhone)

## Agent skills

### Branches

**Never merge `ios-dev` into `master`.** Merges flow one way, `origin/master` → `ios-dev`. App work targets `ios-dev`: PR bases, `/code-review` and `/pr` fixed points, and `/implement-spec` integration branches. This applies even where a tool or skill defaults to `master`.

### Guardrails

Run `scripts/git-hooks/install.sh` once per clone, and again after changing `scripts/git-hooks/` (then run its `selftest.sh`). `pre-push` is the authoritative hook: it refuses ios-dev history on `master` and scans every commit you publish for CJK. `pre-commit` and `commit-msg` only warn early.

### Issue tracker

GitHub Issues on the fork `ChinChangYang/KataGo` (never upstream `lightvector/KataGo`), via `gh`. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default role labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context. The glossary is `CONTEXT.md` at the repo root: read and write it wherever a skill says `GLOSSARY.md`, and never create a `GLOSSARY.md`. ADRs are in `docs/adr/`. See `docs/agents/domain.md`.
