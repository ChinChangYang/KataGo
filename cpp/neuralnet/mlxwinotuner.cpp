#ifdef USE_MLX_BACKEND

#include "../neuralnet/mlxwinotuner.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <limits>
#include <sstream>
#include <map>
#include <string>
#include <vector>

#include "../core/fileutils.h"
#include "../core/global.h"
#include "../core/logger.h"
#include "../core/makedir.h"
#include "../dataio/homedata.h"

#include "mlx/mlx.h"
#include "mlx/fast.h"
#include <chrono>
#include <random>

using namespace std;

static const int MLX_WINO_TUNER_VERSION = 2;
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
  if(inputTransform.vw  < 1 || outputUntransform.vw  < 1) return false;
  // Stage-shared invariant: both stages' gridOrder must match the global.
  if(inputTransform.gridOrder    != gridOrder) return false;
  if(outputUntransform.gridOrder != gridOrder) return false;
  // SP4: Tfast (GRID_ORDER=1) requires VW=1 in the kernels. Reject any
  // candidate that violates this — surfaces the constraint earlier than
  // the Metal JIT static_assert.
  if(gridOrder == MLXWinograd::GridOrder::Tfast) {
    if(inputTransform.vw  != 1) return false;
    if(outputUntransform.vw != 1) return false;
  }
  return true;
}

void MLXWinogradTuneParams::save(const string& filename, const MLXWinogradTuneParams& params) {
  ofstream out;
  FileUtils::open(out, filename);
  out << MLX_WINO_TUNEPARAMS_VERSION_LINE << "\n";
  out << "#global\n";
  out << "gridOrder=" << (int)params.gridOrder
      << " matmulOrient=" << (int)params.matmulOrient << "\n";
  out << "#inputTransform\n";
  out << "tg0=" << params.inputTransform.tg0
      << " tg1=" << params.inputTransform.tg1
      << " wpt=" << params.inputTransform.wpt
      << " vw="  << params.inputTransform.vw
      << " gridOrder=" << (int)params.inputTransform.gridOrder << "\n";
  out << "#outputUntransform\n";
  out << "tg0=" << params.outputUntransform.tg0
      << " tg1=" << params.outputUntransform.tg1
      << " wpt=" << params.outputUntransform.wpt
      << " vw="  << params.outputUntransform.vw
      << " gridOrder=" << (int)params.outputUntransform.gridOrder << "\n";
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
  if(lines.size() != 4)
    throw IOError("MLXWinogradTuneParams::load: expected 4 non-comment lines in " + filename);

  MLXWinogradTuneParams params;
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[1]);
    params.gridOrder    = (MLXWinograd::GridOrder)requireKey(kvs, "gridOrder", filename);
    params.matmulOrient = (MLXWinograd::MatmulOrient)requireKey(kvs, "matmulOrient", filename);
  }
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[2]);
    params.inputTransform.tg0 = requireKey(kvs, "tg0", filename);
    params.inputTransform.tg1 = requireKey(kvs, "tg1", filename);
    params.inputTransform.wpt = requireKey(kvs, "wpt", filename);
    params.inputTransform.vw  = requireKey(kvs, "vw",  filename);
    params.inputTransform.gridOrder = (MLXWinograd::GridOrder)requireKey(kvs, "gridOrder", filename);
  }
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[3]);
    params.outputUntransform.tg0 = requireKey(kvs, "tg0", filename);
    params.outputUntransform.tg1 = requireKey(kvs, "tg1", filename);
    params.outputUntransform.wpt = requireKey(kvs, "wpt", filename);
    params.outputUntransform.vw  = requireKey(kvs, "vw",  filename);
    params.outputUntransform.gridOrder = (MLXWinograd::GridOrder)requireKey(kvs, "gridOrder", filename);
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

// MLXWinogradTuner::loadOrAutoTune is defined in Task 4 once the search loop exists.

namespace mx = mlx::core;

namespace {

// One stage-1 (input transform) timed run on a synthetic [N,H,W,C] tensor.
// Mirrors the inner-loop shape of winogradConv2d's stage 1, but issues only
// the input-transform kernel so we can score it in isolation. Returns wall ms.
static double timeOneInputTransform(const MLXWinograd::InputTransform& cfg,
                                    const mx::array& input, int channels,
                                    bool useFP16) {
  int N = input.shape(0);
  int H = input.shape(1);
  int W = input.shape(2);
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  const mx::Dtype dtype = useFP16 ? mx::float16 : mx::float32;
  const char* kernelName = useFP16 ? "wino_input_transform_f16_tune"
                                   : "wino_input_transform_f32_tune";

  auto fn = mx::fast::metal_kernel(
      kernelName,
      /*input_names=*/{"inp"},
      /*output_names=*/{"outp"},
      /*source=*/MLXWinograd::kWinoInputSource);

  // Untimed warmup: ensures pipeline-state + lazy-graph caches are hot for THIS
  // (cfg.tg0, cfg.tg1) before the timed eval. Defensive against any per-call
  // JIT or runtime overhead.
  {
    auto warmOuts = fn(
        /*inputs=*/{input},
        /*output_shapes=*/{ mx::Shape{16, Ntiles, channels} },
        /*output_dtypes=*/{ dtype },
        /*grid=*/std::make_tuple(channels, Ntiles, 1),
        /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
        /*template_args=*/{ {"T", dtype} },
        /*init_value=*/std::nullopt,
        /*verbose=*/false,
        /*stream=*/mx::StreamOrDevice{});
    mx::eval(warmOuts[0]);
  }

  // Timed pass — build fresh lazy node and eval it.
  auto outs = fn(
      /*inputs=*/{input},
      /*output_shapes=*/{ mx::Shape{16, Ntiles, channels} },
      /*output_dtypes=*/{ dtype },
      /*grid=*/std::make_tuple(channels, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/{ {"T", dtype} },
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});
  auto t0 = std::chrono::steady_clock::now();
  mx::eval(outs[0]);
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// Same shape for output untransform: synthetic [16, Ntiles, outC] -> [N,H,W,outC].
static double timeOneOutputUntransform(const MLXWinograd::OutputUntransform& cfg,
                                       const mx::array& m, int N, int H, int W, int outC,
                                       bool useFP16) {
  int nhwc_arr[4] = {N, H, W, outC};
  mx::array nhwcArr(nhwc_arr, {4}, mx::int32);

  const mx::Dtype dtype = useFP16 ? mx::float16 : mx::float32;
  const char* kernelName = useFP16 ? "wino_output_untransform_f16_tune"
                                   : "wino_output_untransform_f32_tune";

  auto fn = mx::fast::metal_kernel(
      kernelName,
      /*input_names=*/{"m", "nhwc"},
      /*output_names=*/{"outp"},
      /*source=*/MLXWinograd::kWinoOutputSource);

  // Untimed warmup: ensures pipeline-state + lazy-graph caches are hot for THIS
  // (cfg.tg0, cfg.tg1) before the timed eval. Defensive against any per-call
  // JIT or runtime overhead.
  {
    auto warmOuts = fn(
        /*inputs=*/{m, nhwcArr},
        /*output_shapes=*/{ mx::Shape{N, H, W, outC} },
        /*output_dtypes=*/{ dtype },
        /*grid=*/std::make_tuple(outC, m.shape(1), 1),
        /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
        /*template_args=*/{ {"T", dtype} },
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
      /*grid=*/std::make_tuple(outC, m.shape(1), 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/{ {"T", dtype} },
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

struct InputCandidate  { MLXWinograd::InputTransform   cfg; double scoreMs; };
struct OutputCandidate { MLXWinograd::OutputUntransform cfg; double scoreMs; };

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

// New axes from SP4.
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
static bool isOutputCandidateValid(int tg0, int tg1, int wpt, int vw,
                                   MLXWinograd::GridOrder go,
                                   int outC, int /*Ntiles*/) {
  if(tg0 <= 0 || tg1 <= 0 || wpt <= 0 || vw <= 0) return false;
  if(tg0 * tg1 > 1024) return false;
  if(go == MLXWinograd::GridOrder::Cfast) {
    if(vw > 1 && (outC % vw) != 0) return false;
  } else {
    if(vw != 1) return false;
  }
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
buildOutputCandidates(bool full, int outC, int Ntiles, MLXWinograd::GridOrder go) {
  std::vector<MLXWinograd::OutputUntransform> out;
  for(int tg0 : outputTg0Values(full))
  for(int tg1 : outputTg1Values(full))
  for(int wpt : wptValues())
  for(int vw  : vwValues()) {
    if(!isOutputCandidateValid(tg0, tg1, wpt, vw, go, outC, Ntiles)) continue;
    out.push_back({tg0, tg1, wpt, vw, go});
  }
  return out;
}

template <typename T>
static void shuffleVec(std::vector<T>& v, uint32_t seed) {
  std::mt19937 rng(seed);
  std::shuffle(v.begin(), v.end(), rng);
}

struct WptVwScore {
  int wpt;
  int vw;
  double scoreMs;
};

// SP4 Joint Pass A: when top-3 (wpt, vw) configs cluster within this
// relative tolerance of the best, collapse to top-1 to save Joint B
// retiming effort. 2% empirically distinguishes "tied" from "real lead".
static constexpr double kJointPassACollapseThreshold = 0.02;

// Common Joint-Pass-A driver: sweeps (wpt, vw), scores each via the
// provided lambda (which is responsible for validity filtering and
// per-candidate exception handling and logging), then picks top-3 and
// optionally collapses to top-1 if scores cluster within
// kJointPassACollapseThreshold.
//
// The lambda receives (wpt, vw) and returns scoreMs (+infinity on error
// or invalid candidate). The lambda is also expected to write to the
// logger if non-null.
//
// If top3.size() < 3 (rare — fewer valid candidates than 3), the collapse
// check still applies pairwise — top3.back() is the worst of however-many
// remain. Degenerate all-failed sweeps (all infinities) are not collapsed
// because best > 0 && isfinite(best) is false.
template <typename ScoreFn>
static std::vector<WptVwScore>
jointPassA_collect(ScoreFn scoreFn, const char* stageName, Logger* logger) {
  std::vector<WptVwScore> scored;
  for(int wpt : wptValues())
  for(int vw  : vwValues()) {
    double ms = scoreFn(wpt, vw);  // returns +infinity if invalid or failed
    scored.push_back({wpt, vw, ms});
  }
  std::sort(scored.begin(), scored.end(),
            [](const WptVwScore& a, const WptVwScore& b){ return a.scoreMs < b.scoreMs; });
  std::vector<WptVwScore> top3;
  for(size_t i = 0; i < scored.size() && top3.size() < 3; i++)
    top3.push_back(scored[i]);
  // Collapse to top-1 when the spread among top-3 is below threshold.
  // Guarded: only collapse when best is finite and positive (degenerate
  // all-failed sweeps keep size-3 of infinities so the caller can detect).
  if(top3.size() > 1) {
    double best = top3[0].scoreMs;
    if(best > 0 && std::isfinite(best) &&
       (top3.back().scoreMs - best) / best < kJointPassACollapseThreshold) {
      top3.resize(1);
      if(logger) logger->write(Global::strprintf(
        "  jointA %s top-3 within %.0f%% — collapsing to top-1",
        stageName, kJointPassACollapseThreshold * 100.0));
    }
  }
  return top3;
}

// Joint pass A: at SP3-default (tg0=32, tg1=1), sweep all valid (wpt, vw)
// pairs for the input transform under the given gridOrder. Returns top-3
// by score ascending. If top-3 cluster within kJointPassACollapseThreshold
// of best, collapses to top-1.
static std::vector<WptVwScore>
jointPassA_Input(int N, int H, int W,
                 const MLXWinogradTuner::ModelInfoForTuning& mi,
                 MLXWinograd::GridOrder go,
                 bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  auto scoreFn = [&](int wpt, int vw) -> double {
    if(!isInputCandidateValid(/*tg0*/32, /*tg1*/1, wpt, vw, go,
                              mi.trunkNumChannels, Ntiles))
      return std::numeric_limits<double>::infinity();
    MLXWinograd::InputTransform cfg = {32, 1, wpt, vw, go};
    double ms;
    try {
      ms = scoreInputTransform(cfg, N, H, W, mi, useFP16);
    } catch(const std::exception& e) {
      if(logger) logger->write(Global::strprintf(
        "  jointA inp wpt=%d vw=%d FAILED: %s", wpt, vw, e.what()));
      return std::numeric_limits<double>::infinity();
    }
    if(logger) logger->write(Global::strprintf(
      "  jointA inp wpt=%d vw=%d  meanMs=%.4f", wpt, vw, ms));
    return ms;
  };
  return jointPassA_collect(scoreFn, "inp", logger);
}

// Same shape for output untransform.
static std::vector<WptVwScore>
jointPassA_Output(int N, int H, int W,
                  const MLXWinogradTuner::ModelInfoForTuning& mi,
                  MLXWinograd::GridOrder go,
                  bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  auto scoreFn = [&](int wpt, int vw) -> double {
    if(!isOutputCandidateValid(/*tg0*/32, /*tg1*/1, wpt, vw, go,
                               mi.trunkNumChannels, Ntiles))
      return std::numeric_limits<double>::infinity();
    MLXWinograd::OutputUntransform cfg = {32, 1, wpt, vw, go};
    double ms;
    try {
      ms = scoreOutputUntransform(cfg, N, H, W, mi, useFP16);
    } catch(const std::exception& e) {
      if(logger) logger->write(Global::strprintf(
        "  jointA out wpt=%d vw=%d FAILED: %s", wpt, vw, e.what()));
      return std::numeric_limits<double>::infinity();
    }
    if(logger) logger->write(Global::strprintf(
      "  jointA out wpt=%d vw=%d  meanMs=%.4f", wpt, vw, ms));
    return ms;
  };
  return jointPassA_collect(scoreFn, "out", logger);
}

// Common Joint-Pass-B driver: for each top-(wpt, vw) from pass A, sweeps
// all valid candidates of type CandT (built by `buildCands`), scores each
// via `scoreFn`, shuffles per-(wpt,vw) group for noise-resistance, and
// returns the globally-best candidate. Per-candidate dispatch errors are
// caught and the candidate is silently skipped (not assigned +infinity —
// i.e. no entry influences `bestMs`).
//
// `buildCands` signature: (int wpt, int vw) -> std::vector<CandT>
//   Returns all valid (tg0, tg1, wpt, vw, go) combos under the given (wpt, vw).
// `scoreFn` signature:    (const CandT&)    -> double
//   Returns wall-clock ms. May throw on dispatch error.
// `defaultCand` is returned when nothing succeeds.
template <typename CandT, typename BuildFn, typename ScoreFn>
static CandT
jointPassB_collect(const std::vector<WptVwScore>& topWptVw,
                   BuildFn buildCands,
                   ScoreFn scoreFn,
                   const CandT& defaultCand,
                   const char* stageName,
                   Logger* logger) {
  CandT best = defaultCand;
  double bestMs = std::numeric_limits<double>::infinity();

  for(const auto& wv : topWptVw) {
    std::vector<CandT> cands = buildCands(wv.wpt, wv.vw);
    // Shuffle for noise-resistance: different runs hit candidates in
    // different order, reducing clock-warmup bias.
    shuffleVec(cands, 0xDEADBEEFu ^ (uint32_t)(wv.wpt * 31 + wv.vw));

    for(const auto& c : cands) {
      double ms;
      try {
        ms = scoreFn(c);
      } catch(const std::exception& e) {
        if(logger) logger->write(Global::strprintf(
          "  jointB %s tg0=%d tg1=%d wpt=%d vw=%d FAILED: %s",
          stageName, c.tg0, c.tg1, c.wpt, c.vw, e.what()));
        continue;
      }
      if(logger) logger->write(Global::strprintf(
        "  jointB %s tg0=%d tg1=%d wpt=%d vw=%d  meanMs=%.4f",
        stageName, c.tg0, c.tg1, c.wpt, c.vw, ms));
      if(ms < bestMs) { bestMs = ms; best = c; }
    }
  }
  return best;
}

// Joint pass B: for each top-(wpt, vw) from pass A, sweep (tg0, tg1) and
// retime each. Returns the best (tg0, tg1, wpt, vw) overall for this stage.
// Per-candidate dispatch errors are caught and the candidate is silently
// skipped, so the search continues across e.g. M1-variant threadgroup-mem
// limits without aborting.
static MLXWinograd::InputTransform
jointPassB_Input(const std::vector<WptVwScore>& topWptVw,
                 int N, int H, int W,
                 const MLXWinogradTuner::ModelInfoForTuning& mi,
                 MLXWinograd::GridOrder go,
                 bool full, bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  MLXWinograd::InputTransform defaultCand = {32, 1, 1, 1, go};

  auto buildCands = [&](int wpt, int vw) {
    std::vector<MLXWinograd::InputTransform> cands;
    for(int tg0 : inputTg0Values(full))
    for(int tg1 : inputTg1Values(full)) {
      if(!isInputCandidateValid(tg0, tg1, wpt, vw, go, mi.trunkNumChannels, Ntiles))
        continue;
      cands.push_back({tg0, tg1, wpt, vw, go});
    }
    return cands;
  };
  auto scoreFn = [&](const MLXWinograd::InputTransform& c) {
    return scoreInputTransform(c, N, H, W, mi, useFP16);
  };
  return jointPassB_collect(topWptVw, buildCands, scoreFn, defaultCand, "inp", logger);
}

// Same shape for output untransform.
static MLXWinograd::OutputUntransform
jointPassB_Output(const std::vector<WptVwScore>& topWptVw,
                  int N, int H, int W,
                  const MLXWinogradTuner::ModelInfoForTuning& mi,
                  MLXWinograd::GridOrder go,
                  bool full, bool useFP16, Logger* logger) {
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  MLXWinograd::OutputUntransform defaultCand = {32, 1, 1, 1, go};

  auto buildCands = [&](int wpt, int vw) {
    std::vector<MLXWinograd::OutputUntransform> cands;
    for(int tg0 : outputTg0Values(full))
    for(int tg1 : outputTg1Values(full)) {
      if(!isOutputCandidateValid(tg0, tg1, wpt, vw, go, mi.trunkNumChannels, Ntiles))
        continue;
      cands.push_back({tg0, tg1, wpt, vw, go});
    }
    return cands;
  };
  auto scoreFn = [&](const MLXWinograd::OutputUntransform& c) {
    return scoreOutputUntransform(c, N, H, W, mi, useFP16);
  };
  return jointPassB_collect(topWptVw, buildCands, scoreFn, defaultCand, "out", logger);
}

} // namespace

static MLXWinograd::InputTransform searchInputTransform(
    const MLXWinograd::InputTransform& seedCfg,
    int N, int H, int W,
    const MLXWinogradTuner::ModelInfoForTuning& mi,
    bool full, bool useFP16, Logger* logger) {
  // TODO(Task 11): the hierarchical driver runs separate enumeration per
  // (matmulOrient, gridOrder) outer combo. For now we filter vw candidates
  // using trunkNumChannels only — conservative since all current models have
  // trunkNumChannels divisible by max VW (4).
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  auto candidates = buildInputCandidates(full, mi.trunkNumChannels, Ntiles, seedCfg.gridOrder);
  shuffleVec(candidates, 0xDEADBEEFu);
  candidates.insert(candidates.begin(), seedCfg);  // anchor: ensure seed is timed first as the reference baseline

  MLXWinograd::InputTransform best = seedCfg;
  double bestMs = std::numeric_limits<double>::infinity();
  for(const auto& c : candidates) {
    double ms = scoreInputTransform(c, N, H, W, mi, useFP16);
    if(logger != nullptr) {
      logger->write(Global::strprintf(
          "  inputTransform tg0=%d tg1=%d wpt=%d vw=%d go=%d  meanMs=%.4f",
          c.tg0, c.tg1, c.wpt, c.vw, (int)c.gridOrder, ms));
    }
    if(ms < bestMs) { bestMs = ms; best = c; }
  }
  return best;
}

static MLXWinograd::OutputUntransform searchOutputUntransform(
    const MLXWinograd::OutputUntransform& seedCfg,
    int N, int H, int W,
    const MLXWinogradTuner::ModelInfoForTuning& mi,
    bool full, bool useFP16, Logger* logger) {
  // TODO(Task 11): the hierarchical driver runs separate enumeration per
  // (matmulOrient, gridOrder) outer combo. For now we filter vw candidates
  // using trunkNumChannels only — conservative since all current models have
  // trunkNumChannels divisible by max VW (4).
  int Ntiles = N * ((H+1)/2) * ((W+1)/2);
  auto candidates = buildOutputCandidates(full, mi.trunkNumChannels, Ntiles, seedCfg.gridOrder);
  shuffleVec(candidates, 0xCAFEBABEu);
  candidates.insert(candidates.begin(), seedCfg);  // anchor: ensure seed is timed first as the reference baseline

  MLXWinograd::OutputUntransform best = seedCfg;
  double bestMs = std::numeric_limits<double>::infinity();
  for(const auto& c : candidates) {
    double ms = scoreOutputUntransform(c, N, H, W, mi, useFP16);
    if(logger != nullptr) {
      logger->write(Global::strprintf(
          "  outputUntransform tg0=%d tg1=%d wpt=%d vw=%d go=%d  meanMs=%.4f",
          c.tg0, c.tg1, c.wpt, c.vw, (int)c.gridOrder, ms));
    }
    if(ms < bestMs) { bestMs = ms; best = c; }
  }
  return best;
}

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
    const MLXWinogradTuneParams* seedOverride) {
  if(tunerFile.empty()) {
    string dir = defaultDirectory(true, homeDataDirOverride);
    tunerFile = dir + "/" + defaultFileName(gpuName, nnXLen, nnYLen,
                                            modelInfo.trunkNumChannels,
                                            modelInfo.modelVersion,
                                            useFP16);
  }

  if(!reTune && FileUtils::exists(tunerFile)) {
    try {
      MLXWinogradTuneParams loaded = MLXWinogradTuneParams::load(tunerFile);
      if(loaded.isValid()) {
        if(logger != nullptr)
          logger->write("Loaded MLX Winograd tuning parameters from " + tunerFile);
        return loaded;
      }
    } catch(const IOError& e) {
      if(logger != nullptr)
        logger->write(std::string("MLX Winograd tune file unusable, retuning: ") + e.what());
    }
  }

  if(logger != nullptr) {
    logger->write("Performing autotuning for MLX Winograd transforms");
    logger->write("Tuning input transform (this may take ~30 seconds)...");
  }

  MLXWinograd::InputTransform    inSeed;    // default {tg0=32, tg1=1}
  MLXWinograd::OutputUntransform outSeed;   // default {tg0=32, tg1=1}
  if(seedOverride != nullptr) {
    inSeed  = seedOverride->inputTransform;
    outSeed = seedOverride->outputUntransform;
  }
  MLXWinograd::InputTransform   inBest =
      searchInputTransform(inSeed, batchSize, nnYLen, nnXLen, modelInfo, full, useFP16, logger);
  if(logger != nullptr) logger->write("Tuning output untransform...");
  MLXWinograd::OutputUntransform outBest =
      searchOutputUntransform(outSeed, batchSize, nnYLen, nnXLen, modelInfo, full, useFP16, logger);

  MLXWinogradTuneParams result;
  result.inputTransform    = inBest;
  result.outputUntransform = outBest;

  MLXWinogradTuneParams::save(tunerFile, result);
  if(logger != nullptr) {
    logger->write(Global::strprintf(
        "MLX Winograd tuning done: inputTransform=(%d,%d) outputUntransform=(%d,%d), saved to %s",
        inBest.tg0, inBest.tg1, outBest.tg0, outBest.tg1, tunerFile.c_str()));
  }
  return result;
}

std::vector<MLXWinograd::InputTransform>
MLXWinogradTuner::buildInputCandidatesForTesting(bool full, int C, int Ntiles, MLXWinograd::GridOrder go) {
  return buildInputCandidates(full, C, Ntiles, go);
}
std::vector<MLXWinograd::OutputUntransform>
MLXWinogradTuner::buildOutputCandidatesForTesting(bool full, int outC, int Ntiles, MLXWinograd::GridOrder go) {
  return buildOutputCandidates(full, outC, Ntiles, go);
}

std::vector<MLXWinogradTuner::WptVwScoreForTesting>
MLXWinogradTuner::jointPassA_InputForTesting(
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    MLXWinograd::GridOrder go,
    bool useFP16) {
  auto top = jointPassA_Input(N, H, W, mi, go, useFP16, nullptr);
  std::vector<WptVwScoreForTesting> out;
  for(auto& s : top) out.push_back({s.wpt, s.vw, s.scoreMs});
  return out;
}

std::vector<MLXWinogradTuner::WptVwScoreForTesting>
MLXWinogradTuner::jointPassA_OutputForTesting(
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    MLXWinograd::GridOrder go,
    bool useFP16) {
  auto top = jointPassA_Output(N, H, W, mi, go, useFP16, nullptr);
  std::vector<WptVwScoreForTesting> out;
  for(auto& s : top) out.push_back({s.wpt, s.vw, s.scoreMs});
  return out;
}

#endif // USE_MLX_BACKEND
