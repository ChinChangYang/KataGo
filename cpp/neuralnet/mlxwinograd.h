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
// laid out [4*4][Cout][Cin] (xi*4+nu outer => channel-fast inner: axis=1).
inline mx::array makeWinogradWeights(const std::vector<float>& wOIHW,
                                     int Cout, int Cin) {
  std::vector<float> U((size_t)16*Cout*Cin);
  for(int oc=0;oc<Cout;oc++) for(int ic=0;ic<Cin;ic++) {
    float g[3][3];
    for(int a=0;a<3;a++) for(int b=0;b<3;b++)
      g[a][b]=wOIHW[(((size_t)oc*Cin+ic)*3+a)*3+b];
    float Um[4][4]; transformWeight(g,Um);
    for(int a=0;a<4;a++) for(int b=0;b<4;b++)
      U[((size_t)(a*4+b)*Cout+oc)*Cin+ic]=Um[a][b];
  }
  return mx::array(U.data(), {16, Cout, Cin}, mx::float32);
}

// N,H,W,Cin,Cout are supplied as template_args -> substituted by MLX as
// compile-time constants of the same name in the generated kernel.
inline constexpr const char* kWinogradSource = R"METAL(
  uint gid = thread_position_in_grid.x;
  int Wt = (W + 1) / 2;
  int Ht = (H + 1) / 2;
  int tilesPerN = Ht * Wt;
  int total = N * tilesPerN * Cout;
  if((int)gid >= total) return;
  int oc = gid % Cout;
  int t  = (gid / Cout) % tilesPerN;
  int n  = gid / (Cout * tilesPerN);
  int ty = (t / Wt) * 2;
  int tx = (t % Wt) * 2;

  float Macc[4][4];
  for(int a=0;a<4;a++) for(int b=0;b<4;b++) Macc[a][b]=0.0f;

  for(int ic=0; ic<Cin; ic++) {
    float d[4][4];
    for(int a=0;a<4;a++) for(int b=0;b<4;b++) {
      int iy=ty+a-1, ix=tx+b-1;
      bool inb = (iy>=0 && iy<H && ix>=0 && ix<W);
      d[a][b] = inb ? inp[(((n*H+iy)*W+ix)*Cin)+ic] : 0.0f;
    }
    const float BT[4][4]={{1,0,-1,0},{0,1,1,0},{0,-1,1,0},{0,1,0,-1}};
    float Bd[4][4], V[4][4];
    for(int i=0;i<4;i++) for(int j=0;j<4;j++){
      float s=0; for(int k=0;k<4;k++) s+=BT[i][k]*d[k][j]; Bd[i][j]=s; }
    for(int i=0;i<4;i++) for(int j=0;j<4;j++){
      float s=0; for(int k=0;k<4;k++) s+=Bd[i][k]*BT[j][k]; V[i][j]=s; }
    for(int a=0;a<4;a++) for(int b=0;b<4;b++) {
      float u = Uw[(((a*4+b)*Cout)+oc)*Cin + ic];
      Macc[a][b] += u * V[a][b];
    }
  }
  const float AT[2][4]={{1,1,1,0},{0,1,-1,-1}};
  float AM[2][4], Y[2][2];
  for(int i=0;i<2;i++) for(int j=0;j<4;j++){
    float s=0; for(int k=0;k<4;k++) s+=AT[i][k]*Macc[k][j]; AM[i][j]=s; }
  for(int i=0;i<2;i++) for(int j=0;j<2;j++){
    float s=0; for(int k=0;k<4;k++) s+=AM[i][k]*AT[j][k]; Y[i][j]=s; }
  for(int a=0;a<2;a++) for(int b=0;b<2;b++) {
    int oy=ty+a, ox=tx+b;
    if(oy<H && ox<W) out[(((n*H+oy)*W+ox)*Cout)+oc]=Y[a][b];
  }
)METAL";

inline mx::array winogradConv2d(const mx::array& input,
                                const mx::array& Uw,
                                int Cout,
                                const WinogradConfig& cfg) {
  int N = input.shape(0), H = input.shape(1);
  int W = input.shape(2), Cin = input.shape(3);
  int Wt=(W+1)/2, Ht=(H+1)/2;
  int total = N*Ht*Wt*Cout;

  auto kernel = mx::fast::metal_kernel(
    "katago_winograd_f23",
    /*input_names=*/{"inp","Uw"},
    /*output_names=*/{"out"},
    /*source=*/kWinogradSource);

  std::vector<mx::array> inputs = { input, Uw };
  std::vector<std::pair<std::string, mx::fast::TemplateArg>> templateArgs = {
    {"N", N}, {"H", H}, {"W", W}, {"Cin", Cin}, {"Cout", Cout}
  };
  // Round grid up to a multiple of the threadgroup x-dim; the kernel's
  // `if((int)gid >= total) return;` masks the surplus threads.
  int tg = cfg.tg0 > 0 ? cfg.tg0 : 1;
  int gridX = ((total + tg - 1) / tg) * tg;
  auto outs = kernel(
    inputs,
    /*output_shapes=*/{{N,H,W,Cout}},
    /*output_dtypes=*/{mx::float32},
    /*grid=*/std::make_tuple(gridX,1,1),
    // 1-D kernel: only tg0 is used; cfg.tg1/vec/axis are SP2 autotuner seams.
    /*threadgroup=*/std::make_tuple(tg,1,1),
    /*template_args=*/templateArgs,
    /*init_value=*/std::nullopt,
    /*verbose=*/false,
    /*stream=*/{});
  return outs[0];
}

} // namespace MLXWinograd

#endif // USE_MLX_BACKEND
#endif // NEURALNET_MLXWINOGRAD_H_
