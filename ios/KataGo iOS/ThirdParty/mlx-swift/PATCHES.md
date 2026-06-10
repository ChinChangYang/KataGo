# Local patches to mlx-swift

This is a **vendored copy of [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift)**
(tag `0.31.4`, MLX C++ ~0.31.1) consumed as a **local SwiftPM package** so we can
carry small fixes. They fall into two groups:

- **Patches 1–2** let MLX run on the **iOS/visionOS simulator**. Without them MLX
  crashes as soon as any `mx::array` is constructed on the simulator. They are
  simulator-only / null-guarded, so device and macOS behavior is byte-for-byte
  upstream.
- **Patch 3** fixes a real **macOS + device** crash that fires whenever MLX uses
  **JIT-compiled Metal kernels** (this build sets `MLX_METAL_JIT=ON`). It changes
  behavior on every platform — that is the point — but only relaxes a too-strict
  assertion, so it is safe where the assertion previously held.

All patches are upstreamable to ml-explore/mlx.

## Patch 1 — guard null GPU architecture name
`Source/Cmlx/mlx/mlx/backend/metal/device.cpp`, `Device::Device()`

The simulator's `MTLDevice.architecture.name.utf8String()` returns `nullptr`;
`std::string(nullptr)` aborts (libc++ hardening) / is UB. Guard the null and
fall back to a generic Apple-GPU arch string (`applegpu_g14g`) so the downstream
arch parsing stays valid. On real devices `utf8String()` is non-null, so the
fallback never runs.

## Patch 2 — skip the shared-storage Metal heap on the simulator
`Source/Cmlx/mlx/mlx/backend/metal/allocator.cpp`, `MetalAllocator::MetalAllocator()`

The MetalAllocator creates one `ResourceStorageModeShared` heap, but the
simulator's `MTLSimDevice` rejects it (`"MTLStorageModePrivate is required for
heaps"`). After the existing `if (is_vm) return;` (Apple Paravirtual) guard, add
an `#if TARGET_OS_SIMULATOR return; #endif` so the simulator skips the heap and
routes all allocations through `device_->newBuffer` (exactly the `is_vm` path).
Requires `#include <TargetConditionals.h>`.

## Patch 3 — size the threadgroup to the kernel's real max, don't assert 1024
Six files under `Source/Cmlx/mlx/mlx/backend/metal/`:
`copy.cpp`, `binary.cpp`, `ternary.cpp`, `unary.cpp`, `indexing.cpp`, `compiled.cpp`.

For the "general" (strided, up-to-3D) dispatch path, upstream MLX hard-codes a
1024-thread threadgroup and asserts the kernel's
`maxTotalThreadsPerThreadgroup()` is **exactly** 1024 before calling
`get_block_dims(dim0, dim1, rest)` (whose `pow2` arg defaults to 10 = log2(1024)):

```cpp
if (thread_group_size != 1024) {
  throw std::runtime_error("[Metal::copy] Must use 1024 sized block");
}
auto group_dims = get_block_dims(dim0, dim1, rest);
```

That assumption holds for the **prebuilt** metallib (Homebrew) but **not** for
**JIT-compiled** kernels (`MLX_METAL_JIT=ON`), which are register-/device-limited
and routinely report a max below 1024. The throw is uncaught → `std::terminate`
→ `Abort trap: 6`. We observed exactly `[Metal::copy] Must use 1024 sized block`
on macOS (Apple Silicon) the moment NN inference ran.

Each site is patched to derive `pow2` from the kernel's actual max threads and
size the block to that instead of asserting 1024:

```cpp
// KataGo patch: size the block to the kernel's actual max threads/threadgroup
// (JIT-compiled kernels can report < 1024) instead of asserting exactly 1024.
int tg_pow2 = 0;
while ((static_cast<size_t>(1) << (tg_pow2 + 1)) <= thread_group_size) { tg_pow2++; }
auto group_dims = get_block_dims(dim0, dim1, rest, tg_pow2);
```

Per-file notes:
- `copy.cpp`, `binary.cpp`, `ternary.cpp`, `unary.cpp` — the pattern above, on the
  General/strided path. (`unary.cpp` also divides `dim0` by `work_per_thread`
  first, unchanged.)
- `indexing.cpp` (Scatter, ~L435) — same idea, applied to
  `get_block_dims(upd_size, grid_y, 1, tg_pow2)`.
- `compiled.cpp` (~L457) — upstream computed `pow2` with an
  `if (==1024) 10 else if (>512) 9 else throw` ladder; replaced with the same
  floor-log2 loop so any sub-1024 max is accepted.

When the kernel does report 1024 (prebuilt metallib), the loop yields
`tg_pow2 == 10`, i.e. **identical** behavior to upstream — the patch only relaxes
the assertion, it does not change the happy path.

> Note: Patch 3 is necessary but **not sufficient** on its own. With multiple
> KataGo NN server threads, MLX's single global GPU stream also needs serializing
> — that fix lives in `cpp/neuralnet/mlxbackend.cpp` (`mlxGpuEvalMutex`), not here.

## Re-applying on an MLX version bump
Re-vendor the new mlx-swift tag (drop `.git`), then re-apply the hunks above:
- Patches 1–2: search for `applegpu_g14g` and `TARGET_OS_SIMULATOR`.
- Patch 3: search for `tg_pow2` (six sites) and for any remaining
  `!= 1024` / `Must use 1024 sized block` assertions to confirm none were missed.

Verify with (a) a simulator run of the app / MLX self-test (successful GPU
compute) and (b) a macOS run that performs NN inference for >60 s without an
`Abort trap: 6`.
