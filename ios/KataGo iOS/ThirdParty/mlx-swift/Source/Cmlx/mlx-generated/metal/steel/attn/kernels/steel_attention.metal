// Copyright © 2024-25 Apple Inc.

// KataGo: suppress benign C++17/20 "if constexpr is a C++17/20 extension"
// warnings emitted by the MLX steel attention kernels when compiled by the
// Metal compiler. Mirrors upstream mlx-swift's
// MTL_COMPILER_FLAGS (-Wno-c++17-extensions -Wno-c++20-extensions), which the
// SwiftPM build path used by this app does not apply (see
// ThirdParty/mlx-swift/xcode/xcconfig/Cmlx.xcconfig). Scoped to this TU.
#pragma clang diagnostic ignored "-Wc++17-extensions"
#pragma clang diagnostic ignored "-Wc++20-extensions"

// clang-format off
#include "../../../utils.h"

#include "../../../steel/attn/kernels/steel_attention.h"

#define instantiate_attn(tname, dtype, bq, bk, bd, wm, wn, mname, mtype) \
  instantiate_kernel(                                                    \
      "steel_attention_" #tname "_bq" #bq "_bk" #bk "_bd" #bd            \
      "_wm" #wm "_wn" #wn "_mask" #mname,                                \
  attention, dtype, bq, bk, bd, wm, wn, mtype, float)

#define instantiate_attn_shapes_helper(iname, itype, mname, mtype)  \
    instantiate_attn(iname, itype, 32, 16, 128, 4, 1, mname, mtype) \
    instantiate_attn(iname, itype, 32, 32,  80, 4, 1, mname, mtype) \
    instantiate_attn(iname, itype, 32, 32,  64, 4, 1, mname, mtype)

#define instantiate_attn_mask_helper(iname, itype) \
    instantiate_attn_shapes_helper(iname, itype, iname, itype) \
    instantiate_attn_shapes_helper(iname, itype, bool_, bool)

instantiate_attn_mask_helper(float16, half);
instantiate_attn_mask_helper(bfloat16, bfloat16_t);

instantiate_attn_mask_helper(float32, float);
// clang-format on
