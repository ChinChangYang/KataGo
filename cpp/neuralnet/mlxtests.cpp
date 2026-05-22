#ifdef USE_MLX_BACKEND

/**
 * MLX backend unit tests.
 *
 * Holds the runMLXWinogradTests() test entry point, extracted from
 * mlxbackend.cpp so the production backend translation unit stays focused on
 * inference code.
 *
 * These run once per process, on the first call to NeuralNet::testEvaluateConv
 * (see the ranMLXAuxTests guard in mlxbackend.cpp). The runnnlayertests
 * subcommand exercises that path.
 *
 * runMLXBatchNormFP16Test() / runMLXConvLayerFP16WinogradTest() remain defined
 * in mlxbackend.cpp because they construct the file-local BatchNormLayer /
 * ConvLayer classes; they are forward-declared here and called by
 * runMLXWinogradTests().
 */

#include "../neuralnet/mlxwinograd.h"
#include "../neuralnet/mlxwinotuner.h"
#include "../neuralnet/desc.h"
#include "../core/test.h"

#include <mlx/mlx.h>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <random>
#include <regex>
#include <string>
#include <vector>

using namespace std;
namespace mx = mlx::core;

// Defined in mlxbackend.cpp — they need the file-local BatchNormLayer /
// ConvLayer classes, so they cannot move here.
void runMLXBatchNormFP16Test();
void runMLXConvLayerFP16WinogradTest();

// runMLXWinogradTests() — moved from mlxbackend.cpp in Task 1.
// runMLXWinotunerTests() — moved from mlxwinotuner.cpp in Task 2.

void runMLXWinogradTests() {
  cout << "Running MLX Winograd F(2,3) tests" << endl;
  // Naive direct 3x3 "same" conv NHWC, OIHW weights, as independent oracle.
  auto direct = [](const vector<float>& in,int N,int H,int W,int Cin,
                    const vector<float>& w,int Cout){
    vector<float> out((size_t)N*H*W*Cout,0.f);
    for(int n=0;n<N;n++)for(int oy=0;oy<H;oy++)for(int ox=0;ox<W;ox++)
    for(int oc=0;oc<Cout;oc++){ float s=0.f;
      for(int ic=0;ic<Cin;ic++)for(int a=0;a<3;a++)for(int b=0;b<3;b++){
        int iy=oy+a-1,ix=ox+b-1;
        if(iy>=0&&iy<H&&ix>=0&&ix<W)
          s+=in[(((size_t)n*H+iy)*W+ix)*Cin+ic]
             *w[(((size_t)oc*Cin+ic)*3+a)*3+b];
      }
      out[(((size_t)n*H+oy)*W+ox)*Cout+oc]=s;
    }
    return out;
  };
  // Scope `rng`/`dist` to this CPU-oracle loop so they don't shadow same-named
  // locals in the per-test blocks below.
  {
    std::mt19937 rng(12345);
    std::uniform_real_distribution<float> dist(-1.f,1.f);
    for(auto dims : vector<array<int,5>>{{1,5,5,3,4},{2,19,19,8,16},{1,7,13,4,4}}){
      int N=dims[0],H=dims[1],W=dims[2],Cin=dims[3],Cout=dims[4];
      vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=dist(rng);
      vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=dist(rng);
      auto ref = direct(in,N,H,W,Cin,w,Cout);
      auto got = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
      double maxErr=0.0;
      for(size_t i=0;i<ref.size();i++)
        maxErr=std::max(maxErr,(double)std::fabs(ref[i]-got[i]));
      cout<<"  dims "<<N<<"x"<<H<<"x"<<W<<"x"<<Cin<<"->"<<Cout
          <<" maxErr="<<maxErr<<endl;
      testAssert(maxErr < 1e-4);
    }
  }
  cout << "MLX Winograd F(2,3) CPU reference OK" << endl;

  // GPU Winograd metal_kernel validated against the CPU oracle.
  {
    namespace mxc = mlx::core;
    int N=2,H=19,W=19,Cin=8,Cout=16;
    std::mt19937 grng(777);
    std::uniform_real_distribution<float> gdist(-1.f,1.f);
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=gdist(grng);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=gdist(grng);
    auto refv = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
    mxc::array inArr(in.data(),{N,H,W,Cin},mxc::float32);
    auto Uw = MLXWinograd::makeWinogradWeights(w,Cout,Cin);
    MLXWinograd::InputTransform inCfg;
    MLXWinograd::OutputUntransform outCfg;
    mxc::array o = MLXWinograd::winogradConv2d(inArr,Uw,Cout,inCfg,outCfg);
    mxc::eval(o);
    const float* od = o.data<float>();
    double maxErr=0.0;
    for(size_t i=0;i<refv.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(refv[i]-od[i]));
    cout<<"  MLX-metal winograd maxErr="<<maxErr<<endl;
    testAssert(maxErr < 2e-3);
  }

  // FP16 Winograd: input/weights/output all fp16, compared against fp32 CPU oracle.
  // Tolerance ~5e-2 covers (a) fp16 input quantization, (b) fp16 weight quantization,
  // (c) fp16 transform/store rounding. The matmul itself accumulates in fp32 (MLX
  // steel gemm default), so the dominant error is the storage round-trip.
  {
    namespace mxc = mlx::core;
    int N=2,H=19,W=19,Cin=8,Cout=16;
    std::mt19937 grng(778);
    std::uniform_real_distribution<float> gdist(-1.f,1.f);
    vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=gdist(grng);
    vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=gdist(grng);
    auto refv = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);
    mxc::array inArrF32(in.data(),{N,H,W,Cin},mxc::float32);
    mxc::array inArr = mxc::astype(inArrF32, mxc::float16);
    auto Uw = MLXWinograd::makeWinogradWeights(w,Cout,Cin,/*useFP16=*/true);
    MLXWinograd::InputTransform inCfg;
    MLXWinograd::OutputUntransform outCfg;
    mxc::array o = MLXWinograd::winogradConv2d(inArr,Uw,Cout,inCfg,outCfg,/*useFP16=*/true);
    mxc::eval(o);
    testAssert(o.dtype() == mxc::float16);
    mxc::array oF32 = mxc::astype(o, mxc::float32);
    mxc::eval(oF32);
    const float* od = oF32.data<float>();
    double maxErr=0.0;
    for(size_t i=0;i<refv.size();i++)
      maxErr=std::max(maxErr,(double)std::fabs(refv[i]-od[i]));
    cout<<"  MLX-metal winograd FP16 maxErr="<<maxErr<<endl;
    testAssert(maxErr < 5e-2);
  }

  runMLXBatchNormFP16Test();
  runMLXConvLayerFP16WinogradTest();

  // Smoke test — verify Winograd plumbing.
  // Trivial 4x4x1 input, 1 output channel, all-ones filter.
  {
    namespace mxc = mlx::core;
    std::vector<float> in_data(16, 1.0f);
    mxc::array inp(in_data.data(), {1, 4, 4, 1}, mxc::float32);
    std::vector<float> w_data(9, 1.0f);
    auto Uw = MLXWinograd::makeWinogradWeights(w_data, /*Cout*/1, /*Cin*/1,
                                               /*useFP16*/false);
    MLXWinograd::InputTransform    inCfg;
    MLXWinograd::OutputUntransform outCfg;
    mxc::array out = MLXWinograd::winogradConv2d(inp, Uw, /*Cout*/1, inCfg, outCfg,
                                                 /*useFP16*/false);
    mxc::eval(out);
    testAssert(out.shape().size() == 4);
    testAssert(out.shape(0) == 1);
    testAssert(out.shape(1) == 4);
    testAssert(out.shape(2) == 4);
    testAssert(out.shape(3) == 1);
    // Verify expected values for all-ones input × all-ones 3x3 filter (same padding).
    // Uses cpuConv2d3x3 as the CPU reference to avoid hard-coding per-pixel expected values.
    auto ref = MLXWinograd::cpuConv2d3x3(in_data, /*N*/1, /*H*/4, /*W*/4, /*Cin*/1,
                                          w_data, /*Cout*/1);
    const float* op = out.data<float>();
    double smokeMaxErr = 0.0;
    for(int idx = 0; idx < 16; idx++)
      smokeMaxErr = std::max(smokeMaxErr, (double)std::fabs(op[idx] - ref[idx]));
    testAssert(smokeMaxErr < 1e-4);
    cout << "  MLX Winograd kernel-plumbing smoke test passed (value maxErr=" << smokeMaxErr << ")" << endl;
  }

  // WPT=1, 4, 8 must produce bit-identical output (fp32).
  // Realistic shape: N=2, H=W=19, C=64 -> Ntiles = 2*10*10 = 200.
  {
    using namespace MLXWinograd;
    namespace mx = mlx::core;
    std::vector<float> in_data((size_t)2*19*19*64);
    std::mt19937 rng(0x1234u);
    std::uniform_real_distribution<float> fdist(-1.0f, 1.0f);
    for(auto& x : in_data) x = fdist(rng);
    mx::array inp(in_data.data(), {2, 19, 19, 64}, mx::float32);

    std::vector<float> w_data((size_t)64*64*9, 1.0f);
    mx::array Uw = makeWinogradWeights(w_data, 64, 64, false);

    auto runWith = [&](int wpt_in, int wpt_out) {
      InputTransform    inCfg;  inCfg.wpt  = wpt_in;
      OutputUntransform outCfg; outCfg.wpt = wpt_out;
      mx::array out = winogradConv2d(inp, Uw, 64, inCfg, outCfg, false);
      mx::eval(out);
      return out;
    };

    // Vary input WPT, output stays at WPT=1.
    mx::array out_w1   = runWith(1, 1);
    mx::array out_w4   = runWith(4, 1);
    mx::array out_w8   = runWith(8, 1);
    // Vary output WPT, input stays at WPT=1.
    mx::array out_ow4  = runWith(1, 4);
    mx::array out_ow8  = runWith(1, 8);

    // Compare bit-for-bit (no FP-ordering change — only thread loop unroll differs).
    const float* p1   = out_w1.data<float>();
    const float* p4   = out_w4.data<float>();
    const float* p8   = out_w8.data<float>();
    const float* po4  = out_ow4.data<float>();
    const float* po8  = out_ow8.data<float>();
    size_t n = (size_t)2 * 19 * 19 * 64;
    for(size_t i = 0; i < n; i++) {
      testAssert(p1[i] == p4[i]);
      testAssert(p1[i] == p8[i]);
      testAssert(p1[i] == po4[i]);
      testAssert(p1[i] == po8[i]);
    }
    cout << "  MLX Winograd WPT bit-for-bit equivalence (1/4/8) passed" << endl;
  }

  // Tail-guard coverage: Ntiles=100 (N=1, H=W=19) is NOT
  // divisible by WPT=8, so the last thread along the slow axis has
  // tileIdx in {96..103}; iterations 100..103 must hit the break.
  {
    using namespace MLXWinograd;
    namespace mx = mlx::core;
    std::vector<float> in_data((size_t)1*19*19*64);
    std::mt19937 rng(0xBEEFu);
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
    for(auto& x : in_data) x = dist(rng);
    mx::array inp(in_data.data(), {1, 19, 19, 64}, mx::float32);

    std::vector<float> w_data((size_t)64*64*9, 1.0f);
    mx::array Uw = makeWinogradWeights(w_data, 64, 64, false);

    auto runWith = [&](int wpt_in, int wpt_out) {
      InputTransform    inCfg;  inCfg.wpt  = wpt_in;
      OutputUntransform outCfg; outCfg.wpt = wpt_out;
      mx::array out = winogradConv2d(inp, Uw, 64, inCfg, outCfg, false);
      mx::eval(out);
      return out;
    };

    mx::array out_w1   = runWith(1, 1);
    mx::array out_w8in  = runWith(8, 1);  // input WPT=8 with Ntiles%WPT != 0
    mx::array out_w8out = runWith(1, 8);  // output WPT=8 with Ntiles%WPT != 0

    const float* p1   = out_w1.data<float>();
    const float* p8i  = out_w8in.data<float>();
    const float* p8o  = out_w8out.data<float>();
    size_t n = (size_t)1 * 19 * 19 * 64;
    for(size_t i = 0; i < n; i++) {
      testAssert(p1[i] == p8i[i]);
      testAssert(p1[i] == p8o[i]);
    }
    cout << "  MLX Winograd WPT tail-guard coverage (Ntiles=100, WPT=8) passed" << endl;
  }

  // Input VW=1, 2, 4 must produce bit-identical fp16 output (Cfast). C=64
  // is divisible by 4 — VW=4 valid. Output VW is gone (kernel is VW=1
  // monomorphic).
  {
    using namespace MLXWinograd;
    namespace mx = mlx::core;
    std::vector<float> in_data((size_t)2*19*19*64);
    std::mt19937 rng(0x9ABCu);
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
    for(auto& x : in_data) x = dist(rng);
    mx::array inp = mx::astype(mx::array(in_data.data(), {2, 19, 19, 64}, mx::float32), mx::float16);

    std::vector<float> w_data((size_t)64*64*9, 0.5f);
    mx::array Uw = makeWinogradWeights(w_data, 64, 64, true);

    auto runWith = [&](int vw_in) {
      InputTransform    inCfg;  inCfg.vw  = vw_in;
      OutputUntransform outCfg;
      mx::array out = winogradConv2d(inp, Uw, 64, inCfg, outCfg, true);
      mx::eval(out);
      return out;
    };

    mx::array out_v1   = runWith(1);
    mx::array out_v2in = runWith(2);
    mx::array out_v4in = runWith(4);

    // Cast to fp32 and compare bit-for-bit (no FP-op reordering — only channel
    // sequencing differs across input VW, so equality must hold exactly).
    mx::array out_v1_fp32   = mx::astype(out_v1,   mx::float32);
    mx::array out_v2in_fp32 = mx::astype(out_v2in, mx::float32);
    mx::array out_v4in_fp32 = mx::astype(out_v4in, mx::float32);
    mx::eval(out_v1_fp32, out_v2in_fp32, out_v4in_fp32);
    const float* p1  = out_v1_fp32.data<float>();
    const float* p2i = out_v2in_fp32.data<float>();
    const float* p4i = out_v4in_fp32.data<float>();
    size_t n = (size_t)2 * 19 * 19 * 64;
    for(size_t i = 0; i < n; i++) {
      testAssert(p1[i] == p2i[i]);
      testAssert(p1[i] == p4i[i]);
    }
    cout << "  MLX Winograd input-VW bit-for-bit equivalence (1/2/4 fp16, Cfast) passed" << endl;
  }

  // Input-stage GridOrder::Cfast and GridOrder::Tfast must produce
  // bit-identical fp32 output. They differ only in which thread does which
  // (c, tileIdx) pair; the on-disk layout is unchanged. The output kernel
  // is Cfast-monomorphic, so only the input gridOrder is varied here.
  {
    using namespace MLXWinograd;
    namespace mx = mlx::core;
    std::vector<float> in_data((size_t)2*19*19*64);
    std::mt19937 rng(0xDEADu);
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
    for(auto& x : in_data) x = dist(rng);
    mx::array inp(in_data.data(), {2, 19, 19, 64}, mx::float32);

    std::vector<float> w_data((size_t)64*64*9);
    for(auto& x : w_data) x = dist(rng);
    mx::array Uw = makeWinogradWeights(w_data, 64, 64, false);

    auto runWith = [&](GridOrder go_in) {
      InputTransform    inC;  inC.gridOrder  = go_in;
      OutputUntransform outC;
      mx::array out = winogradConv2d(inp, Uw, 64, inC, outC, false);
      mx::eval(out);
      return out;
    };

    // Input Cfast (baseline).
    mx::array out_c = runWith(GridOrder::Cfast);
    // Input Tfast — kernel swaps thread mapping, output must match.
    mx::array out_t = runWith(GridOrder::Tfast);

    const float* pc = out_c.data<float>();
    const float* pt = out_t.data<float>();
    size_t n = (size_t)2 * 19 * 19 * 64;
    for(size_t i = 0; i < n; i++) {
      testAssert(pc[i] == pt[i]);
    }
    std::cout << "  MLX Winograd input-stage Cfast vs Tfast bit-for-bit equivalence passed" << std::endl;
  }

  // Tail-guard coverage: input Tfast with C=67 (not
  // divisible by WPT=8). Last thread group has only 3 channels (67 % 8 = 3);
  // the tail-guard `if (c >= C_k) break;` fires for the other 5 iterations.
  // We verify input Tfast still matches input Cfast for this shape.
  {
    using namespace MLXWinograd;
    namespace mx = mlx::core;
    std::vector<float> in_data((size_t)1*19*19*67);
    std::mt19937 rng(0xFEEDu);
    std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
    for(auto& x : in_data) x = dist(rng);
    mx::array inp(in_data.data(), {1, 19, 19, 67}, mx::float32);

    std::vector<float> w_data((size_t)67*67*9);
    for(auto& x : w_data) x = dist(rng);
    mx::array Uw = makeWinogradWeights(w_data, 67, 67, false);

    auto runWith = [&](GridOrder go, int wpt) {
      InputTransform    inC;  inC.gridOrder  = go;  inC.wpt  = wpt;
      OutputUntransform outC; outC.wpt = wpt;
      mx::array out = winogradConv2d(inp, Uw, 67, inC, outC, false);
      mx::eval(out);
      return out;
    };

    mx::array out_cfast = runWith(GridOrder::Cfast, 1);
    mx::array out_tfast = runWith(GridOrder::Tfast, 8);  // input Tfast with WPT=8, C=67 not divisible.

    const float* pc = out_cfast.data<float>();
    const float* pt = out_tfast.data<float>();
    size_t n = (size_t)1 * 19 * 19 * 67;
    for(size_t i = 0; i < n; i++) {
      testAssert(pc[i] == pt[i]);
    }
    std::cout << "  MLX Winograd input-stage Tfast tail-guard coverage (C=67, WPT=8) passed" << std::endl;
  }

  {
    // Output kernel is monomorphic on VW=1, GRID_ORDER=Cfast.
    // Run a full conv via winogradConv2d with a deterministic input and weight
    // tensor; assert the output is finite and matches a stable reference
    // checksum (sum of absolute values to 4 decimal places). This catches:
    //   - stale Tfast read paths in the output kernel
    //   - stale VW>1 vector-load paths
    //   - Std-only weight layout not consistent with kernel reads
    namespace mx = mlx::core;
    using namespace MLXWinograd;

    const int N = 1, H = 8, W = 8, Cin = 8, Cout = 8;

    // Deterministic input: i*0.01.
    std::vector<float> inData(N * H * W * Cin);
    for(size_t i = 0; i < inData.size(); i++) inData[i] = (float)i * 0.01f;
    mx::array input(inData.data(), {N, H, W, Cin}, mx::float32);

    // Deterministic 3x3 weights: (oc*Cin*9 + ic*9 + k)*0.001.
    std::vector<float> wData(Cout * Cin * 9);
    for(size_t i = 0; i < wData.size(); i++) wData[i] = (float)i * 0.001f;
    // makeWinogradWeights takes raw [Cout, Cin, 3, 3] flattened and produces
    // the transformed [16, Cin, Cout] tensor (Std-only).
    mx::array U = makeWinogradWeights(wData, Cout, Cin, /*useFP16=*/false);

    // Output config: Std OutputUntransform has tg0/tg1/wpt only.
    InputTransform inCfg{};
    inCfg.tg0 = 32; inCfg.tg1 = 1; inCfg.wpt = 1; inCfg.vw = 1;
    inCfg.gridOrder = GridOrder::Cfast;
    OutputUntransform outCfg{};
    outCfg.tg0 = 16; outCfg.tg1 = 4; outCfg.wpt = 1;

    mx::array out = winogradConv2d(input, U, Cout, inCfg, outCfg);
    mx::eval(out);

    // Output shape must be [N, H, W, Cout].
    testAssert(out.shape(0) == N);
    testAssert(out.shape(1) == H);
    testAssert(out.shape(2) == W);
    testAssert(out.shape(3) == Cout);

    // Pull data; assert all finite.
    std::vector<float> outData(out.size());
    out.eval();
    std::memcpy(outData.data(), out.data<float>(), outData.size() * sizeof(float));
    for(float v : outData) testAssert(std::isfinite(v));

    // Stable checksum: sum of absolute values. This is a regression check —
    // a change in numerics suggests a kernel-template mismatch (e.g., output
    // kernel reads channels via VW>1 path that no longer exists, producing
    // UB-flavored garbage).
    double sumAbs = 0.0;
    for(float v : outData) sumAbs += std::abs(v);
    // Recompute this expected value once after the test is first written —
    // it captures the deterministic conv result for the inputs above. The
    // test passes thereafter as a regression check, not a correctness check.
    // Tolerance: 0.5% to absorb minor reordering noise from MLX graph rewrites.
    constexpr double expectedSumAbs = 22788.156637847424;  // captured 2026-05-21
    testAssert(std::abs(sumAbs - expectedSumAbs) / expectedSumAbs < 0.005);
    std::cout << "  Output-kernel monomorphic smoke test OK" << std::endl;
  }
}

#endif // USE_MLX_BACKEND
