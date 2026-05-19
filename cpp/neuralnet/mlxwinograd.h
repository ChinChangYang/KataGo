#ifndef NEURALNET_MLXWINOGRAD_H_
#define NEURALNET_MLXWINOGRAD_H_

#ifdef USE_MLX_BACKEND

#include <vector>

namespace MLXWinograd {

// Tuned launch/layout config. SP1 bakes the known-tuned fp32 defaults;
// SP2's autotuner must rediscover these. axis=1 == channel-fast (load-bearing).
struct WinogradConfig {
  int tg0 = 32;
  int tg1 = 1;     // reserved for SP2 autotuner; kernel is 1-D, not yet wired in winogradConv2d
  int vec = 1;
  int axis = 1;
  int tileSize = 4; // input tile dim => F(2,3); F(4,3)=6 is a deferred SP2 dim
};

// F(2,3) 1D transform matrices.
inline constexpr float BT[4][4] = {
  {1.f, 0.f,-1.f, 0.f},
  {0.f, 1.f, 1.f, 0.f},
  {0.f,-1.f, 1.f, 0.f},
  {0.f, 1.f, 0.f,-1.f}
};
inline constexpr float G[4][3] = {
  {1.f, 0.f, 0.f},
  {0.5f,0.5f,0.5f},
  {0.5f,-0.5f,0.5f},
  {0.f, 0.f, 1.f}
};
inline constexpr float AT[2][4] = {
  {1.f, 1.f, 1.f, 0.f},
  {0.f, 1.f,-1.f,-1.f}
};

// Transform one 3x3 filter g -> 4x4 U = G g G^T.
inline void transformWeight(const float g[3][3], float U[4][4]) {
  float Gg[4][3];
  for(int i=0;i<4;i++) for(int j=0;j<3;j++) {
    float s=0.f; for(int k=0;k<3;k++) s += G[i][k]*g[k][j]; Gg[i][j]=s;
  }
  for(int i=0;i<4;i++) for(int j=0;j<4;j++) {
    float s=0.f; for(int k=0;k<3;k++) s += Gg[i][k]*G[j][k]; U[i][j]=s;
  }
}

// Transform one 4x4 input tile d -> 4x4 V = B^T d B.
inline void transformInput(const float d[4][4], float V[4][4]) {
  float Bd[4][4];
  for(int i=0;i<4;i++) for(int j=0;j<4;j++) {
    float s=0.f; for(int k=0;k<4;k++) s += BT[i][k]*d[k][j]; Bd[i][j]=s;
  }
  for(int i=0;i<4;i++) for(int j=0;j<4;j++) {
    float s=0.f; for(int k=0;k<4;k++) s += Bd[i][k]*BT[j][k]; V[i][j]=s;
  }
}

// Inverse transform 4x4 M -> 2x2 Y = A^T M A.
inline void transformOutput(const float M[4][4], float Y[2][2]) {
  float AM[2][4];
  for(int i=0;i<2;i++) for(int j=0;j<4;j++) {
    float s=0.f; for(int k=0;k<4;k++) s += AT[i][k]*M[k][j]; AM[i][j]=s;
  }
  for(int i=0;i<2;i++) for(int j=0;j<2;j++) {
    float s=0.f; for(int k=0;k<4;k++) s += AM[i][k]*AT[j][k]; Y[i][j]=s;
  }
}

// Full CPU reference NHWC Winograd F(2,3) "same" conv, stride 1.
// in: [N][H][W][Cin], weights OIHW flattened [Cout][Cin][3][3], out: [N][H][W][Cout].
inline std::vector<float> cpuConv2d3x3(
  const std::vector<float>& in, int N, int H, int W, int Cin,
  const std::vector<float>& wOIHW, int Cout
) {
  std::vector<float> out((size_t)N*H*W*Cout, 0.f);
  // Precompute U per (oc,ic).
  std::vector<float> U((size_t)Cout*Cin*16);
  for(int oc=0;oc<Cout;oc++) for(int ic=0;ic<Cin;ic++) {
    float g[3][3];
    for(int a=0;a<3;a++) for(int b=0;b<3;b++)
      g[a][b]=wOIHW[(((size_t)oc*Cin+ic)*3+a)*3+b];
    float Um[4][4]; transformWeight(g,Um);
    for(int a=0;a<4;a++) for(int b=0;b<4;b++)
      U[(((size_t)oc*Cin+ic)*4+a)*4+b]=Um[a][b];
  }
  // Tile over 2x2 output blocks; pad to "same" (pad=1 each side for 3x3).
  for(int n=0;n<N;n++)
  for(int ty=0; ty<H; ty+=2)
  for(int tx=0; tx<W; tx+=2) {
    for(int oc=0; oc<Cout; oc++) {
      float Macc[4][4] = {};
      for(int ic=0; ic<Cin; ic++) {
        float d[4][4];
        for(int a=0;a<4;a++) for(int b=0;b<4;b++) {
          int iy=ty+a-1, ix=tx+b-1; // pad=1
          d[a][b]=(iy>=0&&iy<H&&ix>=0&&ix<W)
            ? in[(((size_t)n*H+iy)*W+ix)*Cin+ic] : 0.f;
        }
        float V[4][4]; transformInput(d,V);
        for(int a=0;a<4;a++) for(int b=0;b<4;b++)
          Macc[a][b]+=U[(((size_t)oc*Cin+ic)*4+a)*4+b]*V[a][b];
      }
      float Y[2][2]; transformOutput(Macc,Y);
      for(int a=0;a<2;a++) for(int b=0;b<2;b++) {
        int oy=ty+a, ox=tx+b;
        if(oy<H&&ox<W) out[(((size_t)n*H+oy)*W+ox)*Cout+oc]=Y[a][b];
      }
    }
  }
  return out;
}

} // namespace MLXWinograd

#include "mlx/mlx.h"
#include "mlx/fast.h"

namespace MLXWinograd {
namespace mx = mlx::core;

// Host-side weight transform: OIHW [Cout][Cin][3][3] -> U array
// laid out [16, Cin, Cout] so the matmul Stage-2 sees [16,Ntiles,Cin] x [16,Cin,Cout] -> [16,Ntiles,Cout].
inline mx::array makeWinogradWeights(const std::vector<float>& wOIHW,
                                     int Cout, int Cin) {
  std::vector<float> U((size_t)16 * Cin * Cout, 0.0f);
  for(int oc = 0; oc < Cout; oc++) {
    for(int ic = 0; ic < Cin; ic++) {
      float g[3][3];
      for(int a = 0; a < 3; a++)
        for(int b = 0; b < 3; b++)
          g[a][b] = wOIHW[(((size_t)oc * Cin + ic) * 3 + a) * 3 + b];
      float Um[4][4]; transformWeight(g, Um);
      for(int a = 0; a < 4; a++)
        for(int b = 0; b < 4; b++)
          U[((size_t)(a * 4 + b) * Cin + ic) * Cout + oc] = Um[a][b];
    }
  }
  return mx::array(U.data(), {16, Cin, Cout}, mx::float32);
}

// F(2,3) input transform kernel: NHWC fp32 input -> [16, Ntiles, C] fp32.
// One thread per (channel, tile); axis=1 (channel-fast): grid=(C_groups, Ntiles, 1).
inline constexpr const char* kWinoInputSource = R"METAL(
    uint c_group  = thread_position_in_grid.x;
    uint tileIdx  = thread_position_in_grid.y;

    int N_k      = inp_shape[0];
    int H_k      = inp_shape[1];
    int W_k      = inp_shape[2];
    int C_k      = inp_shape[3];
    int tilesY_k = (H_k + 1) / 2;
    int tilesX_k = (W_k + 1) / 2;
    int Ntiles_k = N_k * tilesY_k * tilesX_k;

    if ((int)tileIdx >= Ntiles_k) return;

    int rem = (int)tileIdx;
    int n   = rem / (tilesY_k * tilesX_k); rem -= n * tilesY_k * tilesX_k;
    int ty  = rem / tilesX_k;
    int tx  = rem % tilesX_k;

    uint c = c_group;
    if ((int)c >= C_k) return;
    float d[4][4];
    for (int i = 0; i < 4; i++) {
      int iy = 2 * ty - 1 + i;
      for (int j = 0; j < 4; j++) {
        int ix = 2 * tx - 1 + j;
        if (iy < 0 || iy >= H_k || ix < 0 || ix >= W_k) {
          d[i][j] = 0.0f;
        } else {
          d[i][j] = inp[((n * H_k + iy) * W_k + ix) * C_k + c];
        }
      }
    }
    float tmp[4][4];
    for (int j = 0; j < 4; j++) {
      float v0 = d[0][j], v1 = d[1][j], v2 = d[2][j], v3 = d[3][j];
      tmp[0][j] = v0 - v2;
      tmp[1][j] = v1 + v2;
      tmp[2][j] = v2 - v1;
      tmp[3][j] = v1 - v3;
    }
    for (int r = 0; r < 4; r++) {
      float u0 = tmp[r][0], u1 = tmp[r][1], u2 = tmp[r][2], u3 = tmp[r][3];
      float V0 = u0 - u2;
      float V1 = u1 + u2;
      float V2 = u2 - u1;
      float V3 = u1 - u3;
      int base = ((r * 4 + 0) * Ntiles_k + (int)tileIdx) * C_k + (int)c;
      outp[base + 0 * Ntiles_k * C_k] = V0;
      outp[base + 1 * Ntiles_k * C_k] = V1;
      outp[base + 2 * Ntiles_k * C_k] = V2;
      outp[base + 3 * Ntiles_k * C_k] = V3;
    }
)METAL";

// F(2,3) output untransform kernel: [16, Ntiles, outC] fp32 -> NHWC fp32.
// One thread per (out-channel, tile); axis=1: grid=(outC_groups, Ntiles, 1).
// nhwc input array carries the [N,H,W,outC] dims because metal_kernel only
// exposes *_shape for inputs, not outputs.
inline constexpr const char* kWinoOutputSource = R"METAL(
    uint oc_group = thread_position_in_grid.x;
    uint tileIdx  = thread_position_in_grid.y;

    int Ntiles_k = m_shape[1];
    int outC_k   = m_shape[2];
    int H_k      = nhwc[1];
    int W_k      = nhwc[2];
    int tilesY_k = (H_k + 1) / 2;
    int tilesX_k = (W_k + 1) / 2;

    if ((int)tileIdx >= Ntiles_k) return;

    int rem = (int)tileIdx;
    int n   = rem / (tilesY_k * tilesX_k); rem -= n * tilesY_k * tilesX_k;
    int ty  = rem / tilesX_k;
    int tx  = rem % tilesX_k;

    uint oc = oc_group;
    if ((int)oc >= outC_k) return;
    float mm[4][4];
    for (int r = 0; r < 4; r++) {
      for (int c2 = 0; c2 < 4; c2++) {
        int p = r * 4 + c2;
        mm[r][c2] = m[(p * Ntiles_k + (int)tileIdx) * outC_k + (int)oc];
      }
    }
    float tmp[2][4];
    for (int c2 = 0; c2 < 4; c2++) {
      float v0 = mm[0][c2], v1 = mm[1][c2], v2 = mm[2][c2], v3 = mm[3][c2];
      tmp[0][c2] = v0 + v1 + v2;
      tmp[1][c2] = v1 - v2 - v3;
    }
    for (int a = 0; a < 2; a++) {
      float u0 = tmp[a][0], u1 = tmp[a][1], u2 = tmp[a][2], u3 = tmp[a][3];
      float Y0 = u0 + u1 + u2;
      float Y1 = u1 - u2 - u3;
      int oy0 = 2 * ty + a;
      if (oy0 < H_k) {
        int ox0 = 2 * tx + 0;
        if (ox0 < W_k)
          outp[((n * H_k + oy0) * W_k + ox0) * outC_k + (int)oc] = Y0;
        int ox1 = 2 * tx + 1;
        if (ox1 < W_k)
          outp[((n * H_k + oy0) * W_k + ox1) * outC_k + (int)oc] = Y1;
      }
    }
)METAL";

// Three-stage Winograd F(2,3) conv: input transform (Metal) -> mx::matmul -> output untransform (Metal).
// Signature unchanged from prior implementation so ConvLayer needs no changes.
// Uw layout is [16, Cin, Cout] (matmul rhs); cfg.tg0,cfg.tg1 set threadgroup; vec/axis hardcoded to (1,1)
// for SP1 minimum — the SP2 autotuner will reintroduce parameterization.
inline mx::array winogradConv2d(const mx::array& input,
                                const mx::array& Uw,
                                int Cout,
                                const WinogradConfig& cfg) {
  int N = input.shape(0);
  int H = input.shape(1);
  int W = input.shape(2);
  int C = input.shape(3);
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  // Stage 1: input transform -> [16, Ntiles, C]
  auto inFn = mx::fast::metal_kernel(
      "wino_input_transform_f32",
      /*input_names=*/{"inp"},
      /*output_names=*/{"outp"},
      /*source=*/kWinoInputSource);
  auto inOuts = inFn(
      /*inputs=*/{input},
      /*output_shapes=*/{ mx::Shape{16, Ntiles, C} },
      /*output_dtypes=*/{ mx::float32 },
      /*grid=*/std::make_tuple(C, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/{},
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  mx::array t = inOuts[0];

  // Stage 2: batched matmul [16,Ntiles,C] @ [16,C,Cout] -> [16,Ntiles,Cout]
  mx::array m = mx::matmul(t, Uw);

  // Stage 3: output untransform -> [N, H, W, Cout]
  int nhwc_arr[4] = {N, H, W, Cout};
  mx::array nhwcArr(nhwc_arr, {4}, mx::int32);
  auto outFn = mx::fast::metal_kernel(
      "wino_output_untransform_f32",
      /*input_names=*/{"m", "nhwc"},
      /*output_names=*/{"outp"},
      /*source=*/kWinoOutputSource);
  auto outOuts = outFn(
      /*inputs=*/{m, nhwcArr},
      /*output_shapes=*/{ mx::Shape{N, H, W, Cout} },
      /*output_dtypes=*/{ mx::float32 },
      /*grid=*/std::make_tuple(Cout, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/{},
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  return outOuts[0];
}

} // namespace MLXWinograd

#endif // USE_MLX_BACKEND
#endif // NEURALNET_MLXWINOGRAD_H_
