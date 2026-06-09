# Local patches to mlx-swift

This is a **vendored copy of [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift)**
(tag `0.31.4`, MLX C++ ~0.31.1) consumed as a **local SwiftPM package** so we can
carry small fixes that let MLX run on the **iOS/visionOS simulator**. Without
them MLX crashes as soon as any `mx::array` is constructed on the simulator
(real iOS/visionOS devices and macOS are unaffected and unchanged).

Both patches are simulator-only / null-guarded, so device and macOS behavior is
byte-for-byte upstream. They are upstreamable to ml-explore/mlx.

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

## Re-applying on an MLX version bump
Re-vendor the new mlx-swift tag (drop `.git`), then re-apply both hunks above
(search for `applegpu_g14g` and `TARGET_OS_SIMULATOR` to confirm). Verify with a
simulator run of the app / the MLX self-test (expect a successful GPU compute).
