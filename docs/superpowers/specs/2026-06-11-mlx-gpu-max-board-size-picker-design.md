# MLX/GPU Max Board Size Picker — Design

**Date:** 2026-06-11
**Status:** Approved
**Branch:** feature/mlx-app-migration

## Goal

Give the MLX/GPU backend a user-selectable max board size (9/13/19/37), mirroring
the existing CoreML/NE "Compiled Board Size" picker, defaulting to **19×19**. The
Winograd autotuner and NN buffers then optimize for the board the user actually
plays instead of the hardwired full `nnLen` (37).

## Scope

Swift-only, two files. No C++, tuner, or bridge changes:

- `effectiveMaxBoardLength` already flows app → `KataGoHelper.runGtp(maxBoardSizeForNNBuffer:)`
  → `KataGoCpp` → `-override-config maxBoardSizeForNNBuffer=…` → `setup.cpp` sets
  `nnXLen`/`nnYLen` → MLX `createComputeContext` → `loadOrAutoTune`.
- The MLX tuner cache filename is already keyed by `x{X}_y{Y}`
  (`mlxwinotuner.cpp::defaultFileName`), so per-size tunes coexist without collision.

The only reason MLX/GPU currently tunes at 37 is that
`BackendSettings.effectiveMaxBoardLength` returns `model.nnLen` for `.mpsGPU`.

## Changes

### `BackendChoice.swift`

1. **Rename** `CoreMLBoardSize` → `BoardSizeChoice` (shared enum; identical values
   `{9,13,19,37}` and `"WxW"` label). Both backends pick from the same set, so one
   enum, not two near-duplicates. Stored rawValues and the `coremlBoardSize_<file>`
   key are unchanged → no persistence break. (App is unreleased regardless.)
2. Retype the existing `coremlBoardSize` accessor to `BoardSizeChoice` (key/default
   unchanged: default `.nineteen`).
3. **Add** `mlxBoardSize` accessor: `UserDefaults` key `mlxBoardSize_<file>`,
   default `.nineteen`, same get/set shape as `coremlBoardSize`.
4. `effectiveMaxBoardLength` `.mpsGPU` case: `model.nnLen`
   → `min(mlxBoardSize.rawValue, model.nnLen)`.

### `BackendConfigSheet.swift`

1. Add `@State private var mlxBoardSize: BoardSizeChoice`, initialized from
   `settings.mlxBoardSize`; retype the existing CoreML `@State` to `BoardSizeChoice`.
2. In the `backend == .mpsGPU` branch, add a **"Max Board Size"** section (segmented
   picker over `BoardSizeChoice.allCases`) **above** the existing "Performance Tuning"
   section. Footer: the chosen size is the largest board MLX/GPU can play and the size
   the tuner optimizes for; larger boards aren't available until raised. Label is
   "Max Board Size", not CoreML's "Compiled Board Size", because MLX compiles nothing.
3. Add `.onChange(of: mlxBoardSize)` to persist, mirroring the `coremlBoardSize`
   handler.

## Behavior consequence (explicit)

At the default 19, MLX/GPU tunes for 19×19 and caps the playable board at 19×19
until the user raises it — identical to how CoreML/NE's compiled size behaves today.

## Testing

UI/settings plumbing. No existing unit-test target covers `BackendSettings` (the
CoreML picker has none); mirroring it means no new test target. Verification:

- iOS Simulator, macOS, and visionOS Simulator all build green.
- The "Max Board Size" picker renders only for MLX/GPU, persists across reopen, and
  changes `effectiveMaxBoardLength` (hence the `x{X}_y{Y}` tuner-cache file selected).
