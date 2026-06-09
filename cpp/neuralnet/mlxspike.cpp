#include "mlxspike.h"

#include <mlx/mlx.h>

namespace mx = mlx::core;

// Adds two 1-element arrays and reads back the result. Exercises header
// visibility, C++20 compile, mx:: link, and a JIT-compiled Metal kernel at
// runtime. Expect 5.0. The iOS/visionOS simulator's Metal incompatibilities
// are handled inside the vendored mlx-swift (ThirdParty/mlx-swift, see
// PATCHES.md), so no workaround is needed here.
extern "C" double mlxSpikeSelfTest() {
  mx::array a({2.0f});
  mx::array b({3.0f});
  mx::array c = mx::add(a, b);
  mx::eval(c);
  return static_cast<double>(c.item<float>());
}
