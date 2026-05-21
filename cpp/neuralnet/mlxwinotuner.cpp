#ifdef USE_MLX_BACKEND

#include "../neuralnet/mlxwinotuner.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <limits>
#include <optional>
#include <sstream>
#include <map>
#include <string>
#include <vector>

#include "../core/fileutils.h"
#include "../core/global.h"
#include "../core/logger.h"
#include "../core/makedir.h"
#include "../core/test.h"
#include "../dataio/homedata.h"

#include "mlx/mlx.h"
#include "mlx/fast.h"
#include <chrono>
#include <random>

using namespace std;

static const int MLX_WINO_TUNER_VERSION = 3;
static const std::string MLX_WINO_TUNEPARAMS_VERSION_LINE =
    "VERSION=" + std::to_string(MLX_WINO_TUNER_VERSION);

// Mirrors OpenCLTuner's readDescKeyValues: parse "KEY=VALUE KEY=VALUE ..." line into a map.
static map<string,int> parseKeyValueLine(const string& fileName, const string& line) {
  map<string,int> kvs;
  vector<string> tokens = Global::split(line);
  for(const string& tok : tokens) {
    size_t eq = tok.find('=');
    if(eq == string::npos)
      throw IOError("MLXWinogradTuneParams: token without '=' in " + fileName + " line: " + line);
    string k = tok.substr(0, eq);
    string v = tok.substr(eq + 1);
    if(k.empty())
      throw IOError("MLXWinogradTuneParams: key-value pair without key in " + fileName + " line: " + line);
    if(v.empty())
      throw IOError("MLXWinogradTuneParams: key-value pair without value for key '" + k + "' in " + fileName + " line: " + line);
    if(kvs.count(k) > 0)
      throw IOError("MLXWinogradTuneParams: duplicate key " + k + " in " + fileName);
    try {
      kvs[k] = Global::stringToInt(v);
    } catch(const StringError&) {
      throw IOError("MLXWinogradTuneParams: could not parse value for key " + k + " in " + fileName);
    }
  }
  return kvs;
}

static int requireKey(const map<string,int>& kvs, const string& key, const string& fileName) {
  auto it = kvs.find(key);
  if(it == kvs.end())
    throw IOError("MLXWinogradTuneParams: missing key " + key + " in " + fileName);
  return it->second;
}

bool MLXWinogradTuneParams::isValid() const {
  if(inputTransform.tg0 <= 0 || inputTransform.tg1 <= 0) return false;
  if(outputUntransform.tg0 <= 0 || outputUntransform.tg1 <= 0) return false;
  if(inputTransform.tg0 * inputTransform.tg1 > 1024) return false;
  if(outputUntransform.tg0 * outputUntransform.tg1 > 1024) return false;
  if(inputTransform.wpt < 1 || outputUntransform.wpt < 1) return false;
  if(inputTransform.vw  < 1) return false;
  // SP4: Tfast (GRID_ORDER=1) requires VW=1 in the kernels. Reject any
  // input candidate that violates this — surfaces the constraint earlier
  // than the Metal JIT static_assert. (SP5 Task 3: output VW is gone.
  // SP5 Task 6: global gridOrder is gone; input gridOrder stands alone.)
  if(inputTransform.gridOrder == MLXWinograd::GridOrder::Tfast
     && inputTransform.vw != 1) return false;
  return true;
}

void MLXWinogradTuneParams::save(const string& filename, const MLXWinogradTuneParams& params) {
  ofstream out;
  FileUtils::open(out, filename);
  out << MLX_WINO_TUNEPARAMS_VERSION_LINE << "\n";
  out << "#inputTransform\n";
  out << "tg0=" << params.inputTransform.tg0
      << " tg1=" << params.inputTransform.tg1
      << " wpt=" << params.inputTransform.wpt
      << " vw="  << params.inputTransform.vw
      << " gridOrder=" << (int)params.inputTransform.gridOrder << "\n";
  out << "#outputUntransform\n";
  out << "tg0=" << params.outputUntransform.tg0
      << " tg1=" << params.outputUntransform.tg1
      << " wpt=" << params.outputUntransform.wpt << "\n";
  out.flush();
  out.close();
}

MLXWinogradTuneParams MLXWinogradTuneParams::load(const string& filename) {
  vector<string> raw = FileUtils::readFileLines(filename, '\n');
  vector<string> lines;
  for(const string& r : raw) {
    string s = Global::stripComments(r);
    s = Global::trim(s);
    if(!s.empty()) lines.push_back(s);
  }
  if(lines.empty())
    throw IOError("MLXWinogradTuneParams::load: no content in " + filename);
  if(lines[0] != MLX_WINO_TUNEPARAMS_VERSION_LINE)
    throw IOError("MLXWinogradTuneParams::load: expected first line to be "
                  + MLX_WINO_TUNEPARAMS_VERSION_LINE + " in " + filename);
  if(lines.size() != 3)
    throw IOError("MLXWinogradTuneParams::load: expected 3 non-comment lines in " + filename);

  MLXWinogradTuneParams params;
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[1]);
    params.inputTransform.tg0 = requireKey(kvs, "tg0", filename);
    params.inputTransform.tg1 = requireKey(kvs, "tg1", filename);
    params.inputTransform.wpt = requireKey(kvs, "wpt", filename);
    params.inputTransform.vw  = requireKey(kvs, "vw",  filename);
    params.inputTransform.gridOrder = (MLXWinograd::GridOrder)requireKey(kvs, "gridOrder", filename);
  }
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[2]);
    params.outputUntransform.tg0 = requireKey(kvs, "tg0", filename);
    params.outputUntransform.tg1 = requireKey(kvs, "tg1", filename);
    params.outputUntransform.wpt = requireKey(kvs, "wpt", filename);
  }
  return params;
}

string MLXWinogradTuner::defaultDirectory(bool makeDir, const string& homeDataDirOverride) {
  string dir = HomeData::getHomeDataDir(makeDir, homeDataDirOverride);
  dir += "/mlxwinotuning";
  if(makeDir) MakeDir::make(dir);
  return dir;
}

string MLXWinogradTuner::defaultFileName(const string& gpuName,
                                         int nnXLen, int nnYLen,
                                         int trunkNumChannels, int modelVersion,
                                         bool useFP16) {
  string clean;
  for(char c : gpuName) {
    if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
      clean += c;
  }
  const char* dtypeSuffix = useFP16 ? "_fp16" : "_fp32";
  return Global::strprintf("tunemlxwino%d_gpu%s_x%d_y%d_c%d_mv%d%s.txt",
                           MLX_WINO_TUNER_VERSION, clean.c_str(),
                           nnXLen, nnYLen, trunkNumChannels, modelVersion,
                           dtypeSuffix);
}

namespace mx = mlx::core;

namespace {

// One stage-1 (input transform) timed run on a synthetic [N,H,W,C] tensor.
// Mirrors the inner-loop shape of winogradConv2d's stage 1, but issues only
// the input-transform kernel so we can score it in isolation. Returns wall ms.
// SP5 Task 5: matmulOrient axis removed — input kernel always writes Std layout.
static double timeOneInputTransform(
    const MLXWinograd::InputTransform& cfg,
    const mx::array& input, int channels,
    bool useFP16) {
  int N = input.shape(0);
  int H = input.shape(1);
  int W = input.shape(2);
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  const mx::Dtype dtype = useFP16 ? mx::float16 : mx::float32;

  // Kernel name encodes the still-live axes so the Metal JIT cache sees a
  // unique entry per (dtype, wpt, vw, gridOrder) combination.
  std::string kernelName =
      std::string(useFP16 ? "wino_input_transform_f16" : "wino_input_transform_f32")
      + "_w" + std::to_string(cfg.wpt)
      + "_v" + std::to_string(cfg.vw)
      + "_g" + std::to_string((int)cfg.gridOrder)
      + "_tune";

  auto fn = mx::fast::metal_kernel(
      kernelName.c_str(),
      /*input_names=*/{"inp"},
      /*output_names=*/{"outp"},
      /*source=*/MLXWinograd::kWinoInputSource);

  // Output shape: [16, Ntiles, C] (SP5 Task 5: Std only.)
  mx::Shape outShape = {16, Ntiles, channels};

  // Grid depends on gridOrder: Cfast → (ceil(C/vw), ceil(Ntiles/wpt), 1),
  //                             Tfast → (Ntiles, ceil(C/wpt), 1).
  int gridX = (cfg.gridOrder == MLXWinograd::GridOrder::Cfast)
      ? ((channels + cfg.vw - 1) / cfg.vw)
      : Ntiles;
  int gridY = (cfg.gridOrder == MLXWinograd::GridOrder::Cfast)
      ? ((Ntiles + cfg.wpt - 1) / cfg.wpt)
      : ((channels + cfg.wpt - 1) / cfg.wpt);

  std::vector<std::pair<std::string, mx::fast::TemplateArg>> tmplArgs = {
    {"T",             dtype},
    {"WPT",           cfg.wpt},
    {"VW",            cfg.vw},
    {"GRID_ORDER",    (int)cfg.gridOrder}
  };

  // Untimed warmup: ensures pipeline-state + lazy-graph caches are hot for THIS
  // config before the timed eval.
  {
    auto warmOuts = fn(
        /*inputs=*/{input},
        /*output_shapes=*/{ outShape },
        /*output_dtypes=*/{ dtype },
        /*grid=*/std::make_tuple(gridX, gridY, 1),
        /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
        /*template_args=*/tmplArgs,
        /*init_value=*/std::nullopt,
        /*verbose=*/false,
        /*stream=*/mx::StreamOrDevice{});
    mx::eval(warmOuts[0]);
  }

  // Timed pass — build fresh lazy node and eval it.
  auto outs = fn(
      /*inputs=*/{input},
      /*output_shapes=*/{ outShape },
      /*output_dtypes=*/{ dtype },
      /*grid=*/std::make_tuple(gridX, gridY, 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/tmplArgs,
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  auto t0 = std::chrono::steady_clock::now();
  mx::eval(outs[0]);
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// Same shape for output untransform: synthetic [16, Ntiles, outC] -> [N,H,W,outC].
// SP5 Task 5: matmulOrient axis removed — m is always Std-layout ([16, Ntiles, outC]).
static double timeOneOutputUntransform(
    const MLXWinograd::OutputUntransform& cfg,
    const mx::array& m, int N, int H, int W, int outC,
    bool useFP16) {
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  int nhwc_arr[4] = {N, H, W, outC};
  mx::array nhwcArr(nhwc_arr, {4}, mx::int32);

  const mx::Dtype dtype = useFP16 ? mx::float16 : mx::float32;

  // Kernel name encodes the still-live axes so the Metal JIT cache sees a
  // unique entry per (dtype, wpt) combination. (SP5 Task 3: VW dropped.
  // SP5 Task 4: GRID_ORDER dropped — output kernel is Cfast-only.
  // SP5 Task 5: MATMUL_ORIENT dropped — output kernel is Std-only.)
  std::string kernelName =
      std::string(useFP16 ? "wino_output_untransform_f16" : "wino_output_untransform_f32")
      + "_w" + std::to_string(cfg.wpt)
      + "_tune";

  auto fn = mx::fast::metal_kernel(
      kernelName.c_str(),
      /*input_names=*/{"m", "nhwc"},
      /*output_names=*/{"outp"},
      /*source=*/MLXWinograd::kWinoOutputSource);

  // Cfast-only grid: (outC, ceil(Ntiles/wpt), 1).
  int gridX = outC;
  int gridY = (Ntiles + cfg.wpt - 1) / cfg.wpt;

  std::vector<std::pair<std::string, mx::fast::TemplateArg>> tmplArgs = {
    {"T",             dtype},
    {"WPT",           cfg.wpt}
  };

  // Untimed warmup: ensures pipeline-state + lazy-graph caches are hot for THIS
  // config before the timed eval.
  {
    auto warmOuts = fn(
        /*inputs=*/{m, nhwcArr},
        /*output_shapes=*/{ mx::Shape{N, H, W, outC} },
        /*output_dtypes=*/{ dtype },
        /*grid=*/std::make_tuple(gridX, gridY, 1),
        /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
        /*template_args=*/tmplArgs,
        /*init_value=*/std::nullopt,
        /*verbose=*/false,
        /*stream=*/mx::StreamOrDevice{});
    mx::eval(warmOuts[0]);
  }

  // Timed pass — build fresh lazy node and eval it.
  auto outs = fn(
      /*inputs=*/{m, nhwcArr},
      /*output_shapes=*/{ mx::Shape{N, H, W, outC} },
      /*output_dtypes=*/{ dtype },
      /*grid=*/std::make_tuple(gridX, gridY, 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/tmplArgs,
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  auto t0 = std::chrono::steady_clock::now();
  mx::eval(outs[0]);
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// Random NHWC input tensor for the input-transform timing harness.
// When useFP16, astype the fp32 source to fp16 so the timed kernel measures
// the active precision.
static mx::array makeRandomInput(int N, int H, int W, int C, uint32_t seed, bool useFP16) {
  std::vector<float> v((size_t)N * H * W * C);
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  for(auto& x : v) x = dist(rng);
  mx::array arr(v.data(), {N, H, W, C}, mx::float32);
  if(useFP16) return mx::astype(arr, mx::float16);
  return arr;
}

// Random [16, Ntiles, outC] tensor for the output-untransform timing harness.
// When useFP16, astype the fp32 source to fp16 so the timed kernel measures
// the active precision.
static mx::array makeRandomMatmulOut(int Ntiles, int outC, uint32_t seed, bool useFP16) {
  std::vector<float> v((size_t)16 * Ntiles * outC);
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  for(auto& x : v) x = dist(rng);
  mx::array arr(v.data(), {16, Ntiles, outC}, mx::float32);
  if(useFP16) return mx::astype(arr, mx::float16);
  return arr;
}

// Score one input-transform candidate. Mirrors OpenCL line 2172-2206:
// 20 reps rotating across {trunk, mid, max} channel counts; rep 0 is warmup
// with weight 0; remaining 19 reps weighted into a mean wall-clock time.
static double scoreInputTransform(const MLXWinograd::InputTransform& cfg,
                                  int N, int H, int W,
                                  const MLXWinogradTuner::ModelInfoForTuning& mi,
                                  bool useFP16) {
  mx::array inTrunk = makeRandomInput(N, H, W, mi.trunkNumChannels, 0xA1A1A1A1u, useFP16);
  mx::array inMid   = makeRandomInput(N, H, W, mi.midNumChannels,   0xB2B2B2B2u, useFP16);
  mx::array inMax   = makeRandomInput(N, H, W, mi.maxConvChannels3x3, 0xC3C3C3C3u, useFP16);
  mx::eval(inTrunk); mx::eval(inMid); mx::eval(inMax);

  const int reps = 20;
  double totalMs = 0.0;
  double totalWeight = 0.0;
  for(int i = 0; i < reps; i++) {
    int slot;
    double weight;
    switch(i % 10) {
      case 0: slot = 0; weight = 0; break;
      case 1: slot = 0; weight = 1; break;
      case 2: slot = 1; weight = 1; break;
      case 3: slot = 2; weight = 1; break;
      case 4: slot = 0; weight = 1; break;
      case 5: slot = 1; weight = 1; break;
      case 6: slot = 2; weight = 1; break;
      case 7: slot = 0; weight = 1; break;
      case 8: slot = 1; weight = 1; break;
      case 9: slot = 2; weight = 1; break;
      default: ASSERT_UNREACHABLE; slot = 0; weight = 0; break;
    }
    int channels = (slot == 0) ? mi.trunkNumChannels
                 : (slot == 1) ? mi.midNumChannels
                 :               mi.maxConvChannels3x3;
    const mx::array& inp = (slot == 0) ? inTrunk
                         : (slot == 1) ? inMid
                         :               inMax;
    double ms = timeOneInputTransform(cfg, inp, channels, useFP16);
    totalMs += ms * weight;
    totalWeight += weight;
  }
  return totalMs / totalWeight;
}

// Score one output-untransform candidate. Same rotation/warmup structure.
static double scoreOutputUntransform(const MLXWinograd::OutputUntransform& cfg,
                                     int N, int H, int W,
                                     const MLXWinogradTuner::ModelInfoForTuning& mi,
                                     bool useFP16) {
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  mx::array mTrunk = makeRandomMatmulOut(Ntiles, mi.trunkNumChannels,   0xD4D4D4D4u, useFP16);
  mx::array mMid   = makeRandomMatmulOut(Ntiles, mi.midNumChannels,     0xE5E5E5E5u, useFP16);
  mx::array mMax   = makeRandomMatmulOut(Ntiles, mi.maxConvChannels3x3, 0xF6F6F6F6u, useFP16);
  mx::eval(mTrunk); mx::eval(mMid); mx::eval(mMax);

  const int reps = 20;
  double totalMs = 0.0;
  double totalWeight = 0.0;
  for(int i = 0; i < reps; i++) {
    int slot;
    double weight;
    switch(i % 10) {
      case 0: slot = 0; weight = 0; break;
      case 1: slot = 0; weight = 1; break;
      case 2: slot = 1; weight = 1; break;
      case 3: slot = 2; weight = 1; break;
      case 4: slot = 0; weight = 1; break;
      case 5: slot = 1; weight = 1; break;
      case 6: slot = 2; weight = 1; break;
      case 7: slot = 0; weight = 1; break;
      case 8: slot = 1; weight = 1; break;
      case 9: slot = 2; weight = 1; break;
      default: ASSERT_UNREACHABLE; slot = 0; weight = 0; break;
    }
    int outC = (slot == 0) ? mi.trunkNumChannels
             : (slot == 1) ? mi.midNumChannels
             :               mi.maxConvChannels3x3;
    const mx::array& mIn = (slot == 0) ? mTrunk
                         : (slot == 1) ? mMid
                         :               mMax;
    double ms = timeOneOutputUntransform(cfg, mIn, N, H, W, outC, useFP16);
    totalMs += ms * weight;
    totalWeight += weight;
  }
  return totalMs / totalWeight;
}

} // namespace

namespace {

static const std::vector<int>& inputTg0Values(bool full) {
  static const std::vector<int> v = {1,2,4,8,16,24,32,48,64,96,128,160,192,256,384,512,1024};
  (void)full;
  return v;
}
static const std::vector<int>& inputTg1Values(bool full) {
  static const std::vector<int> vFull    = {1,2,4,5,8,10,16,20,25,32,40,50,64,100,128};
  static const std::vector<int> vNonFull = {1,2,4,8,10,16,25,32,50,100};
  return full ? vFull : vNonFull;
}
static const std::vector<int>& outputTg0Values(bool full) {
  // Mirror input set — treat tg0 symmetrically.
  static const std::vector<int> v = {1,2,4,8,16,24,32,48,64,96,128,160,192,256,384,512,1024};
  (void)full;
  return v;
}
static const std::vector<int>& outputTg1Values(bool full) {
  // SP3 non-full inconsistency (skipped 8) is fixed here.
  static const std::vector<int> vFull    = {1,2,4,5,8,10,16,20,25,32,40,50,64,100,128};
  static const std::vector<int> vNonFull = {1,2,4,8,10,16,25,32,50,100};
  return full ? vFull : vNonFull;
}

// New axes from SP4. After SP5: wptValues() is used by both stages;
// vwValues() is input-only (output kernel is VW=1 monomorphic).
static const std::vector<int>& wptValues() {
  static const std::vector<int> v = {1, 2, 4, 8};
  return v;
}
static const std::vector<int>& vwValues() {
  static const std::vector<int> v = {1, 2, 4};
  return v;
}

// Returns true iff (tg0, tg1, wpt, vw, gridOrder) is structurally valid
// AND vw divides the fast-axis dim of the current stage shape.
static bool isInputCandidateValid(int tg0, int tg1, int wpt, int vw,
                                  MLXWinograd::GridOrder go,
                                  int C, int /*Ntiles*/) {
  if(tg0 <= 0 || tg1 <= 0 || wpt <= 0 || vw <= 0) return false;
  if(tg0 * tg1 > 1024) return false;
  if(go == MLXWinograd::GridOrder::Cfast) {
    if(vw > 1 && (C % vw) != 0) return false;
  } else {
    // Tfast: vw must be 1 (kernel static_assert enforces this).
    if(vw != 1) return false;
  }
  return true;
}
// SP5 Task 3: output kernel is VW=1 monomorphic — no vw parameter, no
// vw-divisibility check on outC.
// SP5 Task 4: output kernel is Cfast monomorphic — no gridOrder parameter.
static bool isOutputCandidateValid(int tg0, int tg1, int wpt,
                                   int /*outC*/, int /*Ntiles*/) {
  if(tg0 <= 0 || tg1 <= 0 || wpt <= 0) return false;
  if(tg0 * tg1 > 1024) return false;
  return true;
}

static std::vector<MLXWinograd::InputTransform>
buildInputCandidates(bool full, int C, int Ntiles, MLXWinograd::GridOrder go) {
  std::vector<MLXWinograd::InputTransform> out;
  for(int tg0 : inputTg0Values(full))
  for(int tg1 : inputTg1Values(full))
  for(int wpt : wptValues())
  for(int vw  : vwValues()) {
    if(!isInputCandidateValid(tg0, tg1, wpt, vw, go, C, Ntiles)) continue;
    out.push_back({tg0, tg1, wpt, vw, go});
  }
  return out;
}
static std::vector<MLXWinograd::OutputUntransform>
buildOutputCandidates(bool full, int outC, int Ntiles) {
  std::vector<MLXWinograd::OutputUntransform> out;
  for(int tg0 : outputTg0Values(full))
  for(int tg1 : outputTg1Values(full))
  for(int wpt : wptValues()) {
    if(!isOutputCandidateValid(tg0, tg1, wpt, outC, Ntiles)) continue;
    out.push_back({tg0, tg1, wpt});
  }
  return out;
}

// Flat sweep over (tg0, tg1, wpt, vw, gridOrder) for the input transform.
// Replaces SP4's Joint-A/B/refine cascade. Returns the best (lowest-time)
// candidate that passes isInputCandidateValid; nullopt if no candidate is
// valid (defensive -- should not happen for a real model).
static std::optional<MLXWinograd::InputTransform>
flatSweepInput(int N, int H, int W,
               const MLXWinogradTuner::ModelInfoForTuning& mi,
               bool useFP16, bool full, Logger* logger) {
  using GO = MLXWinograd::GridOrder;
  const int C  = mi.maxConvChannels3x3;
  const int tilesY = (H + 1) / 2;
  const int tilesX = (W + 1) / 2;
  const int Ntiles = N * tilesY * tilesX;

  std::optional<MLXWinograd::InputTransform> best;
  double bestTime = std::numeric_limits<double>::infinity();
  int considered = 0;

  // SP5 Task 4: the output gridOrder check in isValid() is gone (output kernel
  // is Cfast-monomorphic), so the input gridOrder axis can again be searched
  // over both Cfast and Tfast. SP5 Task 6: the global gridOrder field is also
  // gone — input gridOrder stands alone, no cross-stage consistency to enforce.
  for(GO go : {GO::Cfast, GO::Tfast}) {
    auto cands = MLXWinogradTuner::buildInputCandidatesForTesting(full, C, Ntiles, go);
    for(const auto& cand : cands) {
      considered++;
      double t = scoreInputTransform(cand, N, H, W, mi, useFP16);
      if(t < bestTime) { bestTime = t; best = cand; }
    }
  }
  if(logger) {
    logger->write("MLX tuner flatSweepInput: considered=" + std::to_string(considered)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " vw="  + std::to_string(best->vw)
                       + " gridOrder=" + std::to_string((int)best->gridOrder)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none"));
  }
  return best;
}

// Flat sweep over (tg0, tg1, wpt) for the output untransform. Output VW
// and gridOrder are not searched: the kernel is monomorphic on VW=1 (SP5
// Task 3) and Cfast (SP5 Task 4).
static std::optional<MLXWinograd::OutputUntransform>
flatSweepOutput(int N, int H, int W,
                const MLXWinogradTuner::ModelInfoForTuning& mi,
                bool useFP16, bool full, Logger* logger) {
  const int outC = mi.midNumChannels;  // output untransform reads from matmul output
  const int Ntiles = N * ((H + 1) / 2) * ((W + 1) / 2);

  std::optional<MLXWinograd::OutputUntransform> best;
  double bestTime = std::numeric_limits<double>::infinity();
  int considered = 0;

  // Output kernel is VW=1 monomorphic (SP5 Task 3) and Cfast monomorphic
  // (SP5 Task 4), so neither VW nor gridOrder is searched here.
  auto cands = MLXWinogradTuner::buildOutputCandidatesForTesting(full, outC, Ntiles);
  for(auto cand : cands) {
    considered++;
    double t = scoreOutputUntransform(cand, N, H, W, mi, useFP16);
    if(t < bestTime) { bestTime = t; best = cand; }
  }
  if(logger) {
    logger->write("MLX tuner flatSweepOutput: considered=" + std::to_string(considered)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none"));
  }
  return best;
}

} // namespace

MLXWinogradTuneParams MLXWinogradTuner::loadOrAutoTune(
    string tunerFile,
    const string& homeDataDirOverride,
    const string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,
    bool reTune,
    bool useFP16,
    const MLXWinogradTuneParams* /*seedOverride*/) {
  if(tunerFile.empty()) {
    string dir = defaultDirectory(true, homeDataDirOverride);
    tunerFile = dir + "/" + defaultFileName(gpuName, nnXLen, nnYLen,
                                            modelInfo.trunkNumChannels,
                                            modelInfo.modelVersion, useFP16);
  }

  // Cache load path: if the file exists, validates, and reTune is false, use it.
  if(!reTune && !tunerFile.empty() && FileUtils::exists(tunerFile)) {
    try {
      MLXWinogradTuneParams loaded = MLXWinogradTuneParams::load(tunerFile);
      if(loaded.isValid()) {
        if(logger)
          logger->write("Loaded MLX Winograd tuning parameters from " + tunerFile);
        return loaded;
      }
      if(logger)
        logger->write("MLX Winograd cache " + tunerFile + " failed isValid(); re-tuning");
    } catch(const IOError& e) {
      if(logger)
        logger->write(std::string("MLX Winograd cache load failed: ") + e.what() + "; re-tuning");
    }
  }

  // Flat per-stage sweep.
  auto t0 = std::chrono::steady_clock::now();
  auto bestIn  = flatSweepInput (batchSize, nnYLen, nnXLen, modelInfo, useFP16, full, logger);
  auto bestOut = flatSweepOutput(batchSize, nnYLen, nnXLen, modelInfo, useFP16, full, logger);
  auto t1 = std::chrono::steady_clock::now();
  double tuneMs = std::chrono::duration<double, std::milli>(t1 - t0).count();
  if(logger)
    logger->write("MLX tuner flat sweep complete in " + Global::strprintf("%.0f", tuneMs) + " ms");

  if(!bestIn || !bestOut)
    throw StringError("MLXWinogradTuner: flat sweep returned no valid candidate");

  MLXWinogradTuneParams result;
  result.inputTransform    = *bestIn;
  result.outputUntransform = *bestOut;
  // SP5 Task 6: global gridOrder is deleted; input gridOrder stands alone.

  if(!result.isValid())
    throw StringError("MLXWinogradTuner: flat sweep result failed isValid()");

  if(!tunerFile.empty()) {
    MLXWinogradTuneParams::save(tunerFile, result);
    if(logger)
      logger->write("Saved MLX Winograd tuning parameters to " + tunerFile);
  }
  return result;
}

std::vector<MLXWinograd::InputTransform>
MLXWinogradTuner::buildInputCandidatesForTesting(bool full, int C, int Ntiles, MLXWinograd::GridOrder go) {
  return buildInputCandidates(full, C, Ntiles, go);
}
std::vector<MLXWinograd::OutputUntransform>
MLXWinogradTuner::buildOutputCandidatesForTesting(bool full, int outC, int Ntiles) {
  return buildOutputCandidates(full, outC, Ntiles);
}

double MLXWinogradTuner::scoreInputTransformForTesting(
    const MLXWinograd::InputTransform& cfg,
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    bool useFP16) {
  return scoreInputTransform(cfg, N, H, W, mi, useFP16);
}

double MLXWinogradTuner::scoreOutputUntransformForTesting(
    const MLXWinograd::OutputUntransform& cfg,
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    bool useFP16) {
  return scoreOutputUntransform(cfg, N, H, W, mi, useFP16);
}

void runMLXWinotunerTests() {
  cout << "Running MLX Winograd tuner tests" << endl;

  // ---- v3 round-trip: tg0/tg1/wpt/vw/gridOrder (input), tg0/tg1/wpt (output) ----
  {
    // SP5 Task 8 — v3 roundtrip: write -> load -> compare all 8 fields. Two
    // cases for input gridOrder: Cfast and Tfast. (Tfast forces vw=1 per
    // isValid invariant.)
    using namespace MLXWinograd;
    for(auto inGo : {GridOrder::Cfast, GridOrder::Tfast}) {
      MLXWinogradTuneParams p;
      p.inputTransform.tg0 = 32;
      p.inputTransform.tg1 = 1;
      p.inputTransform.wpt = 2;
      p.inputTransform.vw  = (inGo == GridOrder::Cfast) ? 2 : 1;
      p.inputTransform.gridOrder = inGo;
      p.outputUntransform.tg0 = 32;
      p.outputUntransform.tg1 = 8;
      p.outputUntransform.wpt = 1;
      testAssert(p.isValid());

      std::string tmpFile = "/tmp/sp5_v3_roundtrip_" + std::to_string((int)inGo) + ".txt";
      MLXWinogradTuneParams::save(tmpFile, p);
      MLXWinogradTuneParams q = MLXWinogradTuneParams::load(tmpFile);
      testAssert(q.inputTransform.tg0 == p.inputTransform.tg0);
      testAssert(q.inputTransform.tg1 == p.inputTransform.tg1);
      testAssert(q.inputTransform.wpt == p.inputTransform.wpt);
      testAssert(q.inputTransform.vw  == p.inputTransform.vw);
      testAssert(q.inputTransform.gridOrder == p.inputTransform.gridOrder);
      testAssert(q.outputUntransform.tg0 == p.outputUntransform.tg0);
      testAssert(q.outputUntransform.tg1 == p.outputUntransform.tg1);
      testAssert(q.outputUntransform.wpt == p.outputUntransform.wpt);
      testAssert(q.isValid());
      std::remove(tmpFile.c_str());
    }
    cout << "  v3 roundtrip (Cfast + Tfast) OK" << endl;
  }

  // SP3 Task 4: dtype-aware cache filenames must coexist in the same directory
  // without collision. Verify defaultFileName gains a _fp16/_fp32 suffix.
  {
    std::string nameF32 = MLXWinogradTuner::defaultFileName(
      "AppleSilicon", 19, 19, 384, 13, /*useFP16=*/false);
    std::string nameF16 = MLXWinogradTuner::defaultFileName(
      "AppleSilicon", 19, 19, 384, 13, /*useFP16=*/true);
    testAssert(nameF32 != nameF16);
    testAssert(nameF32.find("_fp32") != std::string::npos);
    testAssert(nameF16.find("_fp16") != std::string::npos);
    testAssert(nameF32.size() >= 4 && nameF32.substr(nameF32.size()-4) == ".txt");
    testAssert(nameF16.size() >= 4 && nameF16.substr(nameF16.size()-4) == ".txt");
    cout << "  defaultFileName dtype suffix OK: "
         << nameF32 << " vs " << nameF16 << endl;
  }

  // ---- Corrupt-version rejection ----
  {
    std::string tmp = "/tmp/katago_mlx_winotuner_badversion.txt";
    {
      std::ofstream f(tmp);
      f << "VERSION=999\n#inputTransform\ntg0=32 tg1=1\n#outputUntransform\ntg0=32 tg1=1\n";
    }
    bool threw = false;
    try { (void)MLXWinogradTuneParams::load(tmp); }
    catch(const IOError&) { threw = true; }
    testAssert(threw);
  }

  // ---- v3 isValid invariants ----
  {
    // SP5 Task 8 — v3 isValid invariants.
    using namespace MLXWinograd;
    auto basePass = [&]() {
      MLXWinogradTuneParams p;
      p.inputTransform = {32, 1, 1, 2, GridOrder::Cfast};
      p.outputUntransform = {32, 2, 1};
      return p;
    };

    // Baseline passes.
    testAssert(basePass().isValid());

    // tg0 <= 0 fails.
    { auto p = basePass(); p.inputTransform.tg0 = 0;  testAssert(!p.isValid()); }
    { auto p = basePass(); p.outputUntransform.tg0 = -1; testAssert(!p.isValid()); }

    // tg0 * tg1 > 1024 fails.
    { auto p = basePass(); p.inputTransform.tg0 = 64; p.inputTransform.tg1 = 32;
      testAssert(!p.isValid()); }

    // wpt < 1 fails.
    { auto p = basePass(); p.inputTransform.wpt = 0;  testAssert(!p.isValid()); }
    { auto p = basePass(); p.outputUntransform.wpt = 0; testAssert(!p.isValid()); }

    // vw < 1 fails on input.
    { auto p = basePass(); p.inputTransform.vw = 0;   testAssert(!p.isValid()); }

    // Tfast on input forces vw=1.
    { auto p = basePass();
      p.inputTransform.gridOrder = GridOrder::Tfast;
      p.inputTransform.vw = 2;
      testAssert(!p.isValid()); }
    { auto p = basePass();
      p.inputTransform.gridOrder = GridOrder::Tfast;
      p.inputTransform.vw = 1;
      testAssert(p.isValid()); }

    cout << "  v3 isValid invariants OK" << endl;
  }

  // SP4 Task 7: candidate enumeration expanded with validity filtering.
  {
    using namespace MLXWinograd;
    // Cfast, C=64 (divisible by all vw): full Cartesian product over all axes
    // minus tg0*tg1>1024.
    auto cands = MLXWinogradTuner::buildInputCandidatesForTesting(
        /*full*/true, /*C*/64, /*Ntiles*/200, GridOrder::Cfast);

    // Sanity: returns hundreds of valid configs.
    testAssert(cands.size() > 100);
    testAssert(cands.size() < 5000);   // bounded by validity filter

    // All candidates satisfy tg0*tg1 <= 1024.
    for(const auto& c : cands)
      testAssert(c.tg0 * c.tg1 <= 1024);

    // C=66 with vw>1: should filter out vw=2 (66%2=0 — VW=2 allowed)
    // and vw=4 (66%4=2 != 0 — VW=4 should NOT appear in candidates).
    auto cands_C66 = MLXWinogradTuner::buildInputCandidatesForTesting(
        true, /*C*/66, /*Ntiles*/200, GridOrder::Cfast);
    for(const auto& c : cands_C66) {
      if(c.vw == 4)
        testAssert(false);  // vw=4 candidate should have been filtered out for C=66
    }

    // Tfast: vw must be 1 (kernel static_assert). All Tfast candidates have vw=1.
    auto cands_Tfast = MLXWinogradTuner::buildInputCandidatesForTesting(
        true, 64, 200, GridOrder::Tfast);
    for(const auto& c : cands_Tfast) {
      testAssert(c.vw == 1);
      testAssert(c.gridOrder == GridOrder::Tfast);
    }

    // Output side: same shape of assertions. (SP5 Task 4: gridOrder param
    // dropped from buildOutputCandidatesForTesting — output is Cfast-only.)
    auto out_cands = MLXWinogradTuner::buildOutputCandidatesForTesting(
        true, /*outC*/64, /*Ntiles*/200);
    testAssert(out_cands.size() > 100);
    for(const auto& c : out_cands)
      testAssert(c.tg0 * c.tg1 <= 1024);

    std::cout << "  MLX Winograd Task 7 candidate enumeration validity passed ("
              << cands.size() << " input / " << out_cands.size() << " output candidates C=64)"
              << std::endl;
  }

  // ---- Measurement primitives return finite positive times ----
  // We can't call the static helpers from the test, so we use the public
  // surface that will be wired in Task 4: loadOrAutoTune with reTune=true
  // would run the search; for Task-3 scope we just verify the public
  // schema struct works with valid configs. The measurement primitive itself
  // is exercised by the search-works test added in Task 4.

  {
    // SP5 Task 10 — Gated flat-sweep convergence test.
    // Runs the production flat sweep on a small synthetic problem and asserts
    // that the winner is isValid and that its timing is no worse than the
    // SP1 baked default (tg0=32, tg1=1, wpt=1, vw=1, Cfast).
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.midNumChannels      = 64;
      mi.maxConvChannels3x3  = 64;
      mi.modelVersion        = 11;

      // loadOrAutoTune rewrites an empty tunerFile to a default cache path,
      // so use an explicit temp path and remove it after to avoid touching
      // the user's cache directory.
      std::string tmpTunerFile = "/tmp/sp5_task10_sweep_cache.txt";
      std::remove(tmpTunerFile.c_str());

      MLXWinogradTuneParams tuned = MLXWinogradTuner::loadOrAutoTune(
          /*tunerFile=*/tmpTunerFile,
          /*homeDataDirOverride=*/"",
          /*gpuName=*/"AppleSilicon",
          /*nnXLen=*/19, /*nnYLen=*/19, /*batchSize=*/1,
          mi,
          /*logger=*/nullptr,
          /*full=*/false,
          /*reTune=*/true,
          /*useFP16=*/true);
      testAssert(tuned.isValid());

      // Score the baked default and the tuned winner via scoreInputTransform.
      // tuned.time <= baked.time (within noise).
      MLXWinograd::InputTransform baked{};
      baked.tg0 = 32; baked.tg1 = 1; baked.wpt = 1; baked.vw = 1;
      baked.gridOrder = MLXWinograd::GridOrder::Cfast;
      auto bestOf5 = [&](const MLXWinograd::InputTransform& cfg) -> double {
        double best = std::numeric_limits<double>::infinity();
        for(int rep = 0; rep < 5; rep++) {
          double t = MLXWinogradTuner::scoreInputTransformForTesting(
              cfg, 1, 19, 19, mi, true);
          if(t < best) best = t;
        }
        return best;
      };
      double bakedMs = bestOf5(baked);
      double tunedMs = bestOf5(tuned.inputTransform);
      // Allow 10% noise budget.
      testAssert(tunedMs <= bakedMs * 1.10);
      std::cout << "  SP5 flat-sweep convergence (gated) OK"
                << " bakedMs=" << bakedMs
                << " tunedMs=" << tunedMs << std::endl;

      std::remove(tmpTunerFile.c_str());
    }
  }

  cout << "MLX Winograd tuner tests passed" << endl;
}

#endif // USE_MLX_BACKEND
