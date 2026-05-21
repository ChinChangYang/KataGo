#ifdef USE_MLX_BACKEND

#include "../neuralnet/mlxwinotuner.h"
#include "../neuralnet/desc.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <deque>
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
#include <regex>

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
  // Tfast (GRID_ORDER=1) requires VW=1 in the kernels. Reject any input
  // candidate that violates this — surfaces the constraint earlier than
  // the Metal JIT static_assert. (Output VW is gone; global gridOrder
  // is gone; input gridOrder stands alone.)
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
// Input kernel always writes Std layout (matmulOrient axis is gone).
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

  // Output shape: [16, Ntiles, C] (Std only).
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
// m is always Std-layout ([16, Ntiles, outC]).
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
  // unique entry per (dtype, wpt) combination. (Output kernel is VW=1
  // monomorphic, Cfast monomorphic, and Std-only.)
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

// Forward decl: planShapeRotation is defined further down in this anonymous
// namespace alongside its policy constants, but the scoring functions above
// reference it. Pure function; safe to forward-declare.
static std::vector<MLXWinogradTuner::ShapePlan>
planShapeRotation(const std::vector<std::pair<int,int>>& histogram);

// Score one input-transform candidate. Adaptive rotation over the model's
// actual 3x3 conv input-channel distribution: planShapeRotation produces a
// list of (channels, measureReps, weight) entries; per shape we time
// `measureReps + 1` reps (1 warmup discarded for the dominant only) and
// take the median, weighted into the final score by `weight`.
static double scoreInputTransform(const MLXWinograd::InputTransform& cfg,
                                  int N, int H, int W,
                                  const MLXWinogradTuner::ModelInfoForTuning& mi,
                                  bool useFP16) {
  auto plan = planShapeRotation(mi.conv3x3InputHistogram);
  assert(!plan.empty());

  // Pre-build one random input array per planned shape. Warmup is one extra
  // measurement on the dominant (plan[0]) that is discarded.
  std::vector<mx::array> inputs;
  inputs.reserve(plan.size());
  uint32_t seed = 0xA1A1A1A1u;
  for(const auto& sp : plan) {
    inputs.push_back(makeRandomInput(N, H, W, sp.channels, seed, useFP16));
    mx::eval(inputs.back());
    seed = seed * 1664525u + 1013904223u;  // distinct seed per shape
  }

  // Warmup: 1 rep on dominant, discarded.
  (void)timeOneInputTransform(cfg, inputs[0], plan[0].channels, useFP16);

  double score = 0.0;
  for(size_t i = 0; i < plan.size(); i++) {
    std::vector<double> samples;
    samples.reserve(plan[i].measureReps);
    for(int r = 0; r < plan[i].measureReps; r++) {
      double ms = timeOneInputTransform(cfg, inputs[i], plan[i].channels, useFP16);
      samples.push_back(ms);
    }
    // Median (upper of two middles for even sizes; identical to nth_element
    // at index size/2). Spec §Score formula.
    std::nth_element(samples.begin(),
                     samples.begin() + samples.size() / 2,
                     samples.end());
    double median = samples[samples.size() / 2];
    if(!std::isfinite(median)) median = 0.0;  // defensive — never emit nan
    score += plan[i].weight * median;
  }
  return score;
}

// Score one output-untransform candidate. Symmetric to scoreInputTransform:
// adaptive rotation over the model's 3x3 conv output-channel distribution.
static double scoreOutputUntransform(const MLXWinograd::OutputUntransform& cfg,
                                     int N, int H, int W,
                                     const MLXWinogradTuner::ModelInfoForTuning& mi,
                                     bool useFP16) {
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  auto plan = planShapeRotation(mi.conv3x3OutputHistogram);
  assert(!plan.empty());

  std::vector<mx::array> matmulOuts;
  matmulOuts.reserve(plan.size());
  uint32_t seed = 0xD4D4D4D4u;
  for(const auto& sp : plan) {
    matmulOuts.push_back(makeRandomMatmulOut(Ntiles, sp.channels, seed, useFP16));
    mx::eval(matmulOuts.back());
    seed = seed * 1664525u + 1013904223u;
  }

  // Warmup: 1 rep on dominant, discarded.
  (void)timeOneOutputUntransform(cfg, matmulOuts[0], N, H, W,
                                 plan[0].channels, useFP16);

  double score = 0.0;
  for(size_t i = 0; i < plan.size(); i++) {
    std::vector<double> samples;
    samples.reserve(plan[i].measureReps);
    for(int r = 0; r < plan[i].measureReps; r++) {
      double ms = timeOneOutputUntransform(cfg, matmulOuts[i], N, H, W,
                                           plan[i].channels, useFP16);
      samples.push_back(ms);
    }
    std::nth_element(samples.begin(),
                     samples.begin() + samples.size() / 2,
                     samples.end());
    double median = samples[samples.size() / 2];
    if(!std::isfinite(median)) median = 0.0;
    score += plan[i].weight * median;
  }
  return score;
}

// Selection-and-allocation policy for the work-weighted shape rotation.
// Pure function. Inputs: list of (channels, occurrence_count) pairs from the
// model's 3x3 conv distribution. Output: vector<ShapePlan> sorted desc by
// weight, with Σ measureReps == 19 and Σ weight ≈ 1.0.
//
// Spec §Selection Rule constants:
static constexpr int    kTotalReps         = 20;
static constexpr int    kWarmupReps        = 1;
static constexpr int    kMeasureReps       = kTotalReps - kWarmupReps;  // 19
static constexpr size_t kMaxShapes         = 3;
static constexpr double kWorkFractionFloor = 0.03;
static constexpr int    kRepFloor          = 3;

static std::vector<MLXWinogradTuner::ShapePlan>
planShapeRotation(const std::vector<std::pair<int,int>>& histogram) {
  // Spec §Degenerate Cases: empty histogram is a model-corruption signal we
  // surface, not silently mask.
  assert(!histogram.empty());

  // Step 1: compute work = count * channels; sort desc by work; take top-K.
  struct Entry { int channels; long long work; };
  std::vector<Entry> entries;
  entries.reserve(histogram.size());
  for(const auto& [c, n] : histogram) {
    if(c <= 0 || n <= 0) continue;
    entries.push_back({c, static_cast<long long>(c) * static_cast<long long>(n)});
  }
  assert(!entries.empty());

  std::sort(entries.begin(), entries.end(),
            [](const Entry& a, const Entry& b) {
              if(a.work != b.work) return a.work > b.work;
              return a.channels > b.channels;  // tie-break: larger C first
            });
  if(entries.size() > kMaxShapes)
    entries.resize(kMaxShapes);

  // Step 2: threshold against post-top-K total work; recompute total.
  long long totalWork = 0;
  for(const auto& e : entries) totalWork += e.work;
  assert(totalWork > 0);
  entries.erase(
      std::remove_if(entries.begin(), entries.end(),
          [totalWork](const Entry& e) {
            return static_cast<double>(e.work) / static_cast<double>(totalWork)
                   < kWorkFractionFloor;
          }),
      entries.end());
  // Dominant survives (it's the largest; if its share < 3% then total<dominant/0.03
  // which is impossible). So entries is non-empty.
  assert(!entries.empty());

  totalWork = 0;
  for(const auto& e : entries) totalWork += e.work;

  // Step 3: normalize weights.
  std::vector<MLXWinogradTuner::ShapePlan> plan;
  plan.reserve(entries.size());
  for(const auto& e : entries) {
    MLXWinogradTuner::ShapePlan sp;
    sp.channels = e.channels;
    sp.weight = static_cast<double>(e.work) / static_cast<double>(totalWork);
    sp.measureReps = 0;  // assigned below
    plan.push_back(sp);
  }

  // Step 4: allocate kMeasureReps with floor.
  if(plan.size() == 1) {
    plan[0].measureReps = kMeasureReps;
    return plan;
  }

  // Tentative round-to-nearest allocation.
  for(auto& sp : plan) {
    sp.measureReps = static_cast<int>(std::lround(sp.weight * kMeasureReps));
  }

  // Floor-bump: any minor shape below kRepFloor gets bumped, deficit out of dominant.
  for(size_t i = 1; i < plan.size(); i++) {
    if(plan[i].measureReps < kRepFloor) {
      int deficit = kRepFloor - plan[i].measureReps;
      plan[i].measureReps += deficit;
      plan[0].measureReps -= deficit;
    }
  }

  // Rounding repair: dominant absorbs +/-1 so Σ == kMeasureReps.
  int sum = 0;
  for(const auto& sp : plan) sum += sp.measureReps;
  plan[0].measureReps += (kMeasureReps - sum);

  // Final invariants. The dominant-underflow assert here will fire only for
  // numShapes > 6 (3*kRepFloor + 1 > kMeasureReps), which is unreachable
  // given kMaxShapes = 3.
  assert(plan[0].measureReps >= kRepFloor);
#ifndef NDEBUG
  int finalSum = 0;
  for(const auto& sp : plan) finalSum += sp.measureReps;
  assert(finalSum == kMeasureReps);
#endif

  return plan;
}

// Per-shape median timing for diagnostic logging. Same rotation/plan as the
// scoring functions; reports one (channels, median_ms) entry per planned
// shape instead of a single weighted score. Used by the flat-sweep log's
// "shape_ms=" field and the gated per-shape consistency test.

static std::vector<std::pair<int,double>>
scoreInputTransformPerShape(const MLXWinograd::InputTransform& cfg,
                            int N, int H, int W,
                            const MLXWinogradTuner::ModelInfoForTuning& mi,
                            bool useFP16) {
  auto plan = planShapeRotation(mi.conv3x3InputHistogram);
  assert(!plan.empty());

  std::vector<mx::array> inputs;
  inputs.reserve(plan.size());
  uint32_t seed = 0xA1A1A1A1u;
  for(const auto& sp : plan) {
    inputs.push_back(makeRandomInput(N, H, W, sp.channels, seed, useFP16));
    mx::eval(inputs.back());
    seed = seed * 1664525u + 1013904223u;
  }

  // Warmup: 1 rep on dominant, discarded.
  (void)timeOneInputTransform(cfg, inputs[0], plan[0].channels, useFP16);

  std::vector<std::pair<int,double>> out;
  out.reserve(plan.size());
  for(size_t i = 0; i < plan.size(); i++) {
    std::vector<double> samples;
    samples.reserve(plan[i].measureReps);
    for(int r = 0; r < plan[i].measureReps; r++) {
      samples.push_back(
          timeOneInputTransform(cfg, inputs[i], plan[i].channels, useFP16));
    }
    std::nth_element(samples.begin(),
                     samples.begin() + samples.size() / 2,
                     samples.end());
    double median = samples[samples.size() / 2];
    if(!std::isfinite(median)) median = 0.0;
    out.emplace_back(plan[i].channels, median);
  }
  return out;
}

static std::vector<std::pair<int,double>>
scoreOutputUntransformPerShape(const MLXWinograd::OutputUntransform& cfg,
                               int N, int H, int W,
                               const MLXWinogradTuner::ModelInfoForTuning& mi,
                               bool useFP16) {
  int Ntiles = N * ((H + 1) / 2) * ((W + 1) / 2);

  auto plan = planShapeRotation(mi.conv3x3OutputHistogram);
  assert(!plan.empty());

  std::vector<mx::array> matmulOuts;
  matmulOuts.reserve(plan.size());
  uint32_t seed = 0xD4D4D4D4u;
  for(const auto& sp : plan) {
    matmulOuts.push_back(makeRandomMatmulOut(Ntiles, sp.channels, seed, useFP16));
    mx::eval(matmulOuts.back());
    seed = seed * 1664525u + 1013904223u;
  }

  // Warmup: 1 rep on dominant, discarded.
  (void)timeOneOutputUntransform(cfg, matmulOuts[0], N, H, W,
                                 plan[0].channels, useFP16);

  std::vector<std::pair<int,double>> out;
  out.reserve(plan.size());
  for(size_t i = 0; i < plan.size(); i++) {
    std::vector<double> samples;
    samples.reserve(plan[i].measureReps);
    for(int r = 0; r < plan[i].measureReps; r++) {
      samples.push_back(
          timeOneOutputUntransform(cfg, matmulOuts[i], N, H, W,
                                   plan[i].channels, useFP16));
    }
    std::nth_element(samples.begin(),
                     samples.begin() + samples.size() / 2,
                     samples.end());
    double median = samples[samples.size() / 2];
    if(!std::isfinite(median)) median = 0.0;
    out.emplace_back(plan[i].channels, median);
  }
  return out;
}

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
  // Symmetric with full set (the 8 entry is preserved in non-full).
  static const std::vector<int> vFull    = {1,2,4,5,8,10,16,20,25,32,40,50,64,100,128};
  static const std::vector<int> vNonFull = {1,2,4,8,10,16,25,32,50,100};
  return full ? vFull : vNonFull;
}

// wptValues() is used by both stages; vwValues() is input-only
// (output kernel is VW=1 monomorphic).
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
// Output kernel is VW=1 monomorphic — no vw parameter, no
// vw-divisibility check on outC. Output kernel is also Cfast monomorphic
// — no gridOrder parameter.
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
// Returns the best (lowest-time)
// candidate that passes isInputCandidateValid; nullopt if no candidate is
// valid (defensive -- should not happen for a real model).
static std::optional<MLXWinograd::InputTransform>
flatSweepInput(int N, int H, int W,
               const MLXWinogradTuner::ModelInfoForTuning& mi,
               bool useFP16, bool full, Logger* logger) {
  using GO = MLXWinograd::GridOrder;
  // Candidate enumeration's vw-divisibility filter uses C as the most
  // restrictive channel count the kernel will encounter. Use the max of the
  // model's actual 3x3 input channel distribution.
  int C = 0;
  for(const auto& p : mi.conv3x3InputHistogram) C = std::max(C, p.first);
  assert(C > 0);
  const int tilesY = (H + 1) / 2;
  const int tilesX = (W + 1) / 2;
  const int Ntiles = N * tilesY * tilesX;

  // Score the baked default (default-constructed = {tg0=32, tg1=1, wpt=1,
  // vw=1, gridOrder=Cfast}) so the sweep log carries a baseline the operator
  // can compare the winner against. Always adopted-winner; no fallback.
  // The defaults satisfy isInputCandidateValid for any (C, Ntiles) because
  // vw=1 divides every channel count; see mlxwinograd.h for the struct defaults.
  const double baselineMs =
      scoreInputTransform(MLXWinograd::InputTransform{}, N, H, W, mi, useFP16);

  std::optional<MLXWinograd::InputTransform> best;
  double bestTime = std::numeric_limits<double>::infinity();
  int considered = 0;

  // The output gridOrder check in isValid() is gone (output kernel is
  // Cfast-monomorphic), so the input gridOrder axis can be searched over
  // both Cfast and Tfast. The global gridOrder field is also gone —
  // input gridOrder stands alone, no cross-stage consistency to enforce.
  for(GO go : {GO::Cfast, GO::Tfast}) {
    auto cands = MLXWinogradTuner::buildInputCandidatesForTesting(full, C, Ntiles, go);
    for(const auto& cand : cands) {
      considered++;
      double t = scoreInputTransform(cand, N, H, W, mi, useFP16);
      if(t < bestTime) { bestTime = t; best = cand; }
    }
  }
  if(logger) {
    std::string deltaStr;
    std::string perShapeStr;
    if(best && baselineMs >= 1e-9) {
      double deltaPct = (bestTime - baselineMs) / baselineMs * 100.0;
      // %+.1f always emits a sign; the gated log-format test regex relies on
      // this (matches [-+], not [-+]?). Don't drop the + flag.
      deltaStr = Global::strprintf("%+.1f", deltaPct);

      // Per-shape median timing on the winner — diagnostic only; winner
      // selection above used the weighted score from scoreInputTransform.
      auto perShape = scoreInputTransformPerShape(*best, N, H, W, mi, useFP16);
      perShapeStr = " shape_ms=";
      for(size_t i = 0; i < perShape.size(); i++) {
        if(i > 0) perShapeStr += ",";
        perShapeStr += "c" + std::to_string(perShape[i].first)
                    + ":" + Global::strprintf("%.3f", perShape[i].second);
      }
    } else {
      deltaStr = "nan";
      // best=none branch: omit per-shape fields (matches existing degenerate
      // log shape; spec §4 / §Error handling).
      perShapeStr = "";
    }
    logger->write("MLX tuner flatSweepInput: considered=" + std::to_string(considered)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " vw="  + std::to_string(best->vw)
                       + " gridOrder=" + std::to_string((int)best->gridOrder)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none")
                  + " baseline_ms=" + Global::strprintf("%.3f", baselineMs)
                  + " delta_pct=" + deltaStr
                  + perShapeStr);
  }
  return best;
}

// Flat sweep over (tg0, tg1, wpt) for the output untransform. Output VW
// and gridOrder are not searched: the kernel is monomorphic on VW=1 and
// Cfast.
static std::optional<MLXWinograd::OutputUntransform>
flatSweepOutput(int N, int H, int W,
                const MLXWinogradTuner::ModelInfoForTuning& mi,
                bool useFP16, bool full, Logger* logger) {
  // Output-untransform candidate enumeration doesn't filter on outC
  // (isOutputCandidateValid ignores it — VW=1 monomorphic), but we still
  // pass a representative value. Use the max of the model's actual 3x3
  // output distribution.
  int outC = 0;
  for(const auto& p : mi.conv3x3OutputHistogram) outC = std::max(outC, p.first);
  assert(outC > 0);
  const int Ntiles = N * ((H + 1) / 2) * ((W + 1) / 2);

  // Score the baked default (default-constructed = {tg0=32, tg1=1, wpt=1})
  // so the sweep log carries a baseline the operator can compare the winner
  // against. Symmetric to flatSweepInput.
  const double baselineMs =
      scoreOutputUntransform(MLXWinograd::OutputUntransform{}, N, H, W, mi, useFP16);

  std::optional<MLXWinograd::OutputUntransform> best;
  double bestTime = std::numeric_limits<double>::infinity();
  int considered = 0;

  // Output kernel is VW=1 monomorphic and Cfast monomorphic, so neither
  // VW nor gridOrder is searched here.
  auto cands = MLXWinogradTuner::buildOutputCandidatesForTesting(full, outC, Ntiles);
  for(auto cand : cands) {
    considered++;
    double t = scoreOutputUntransform(cand, N, H, W, mi, useFP16);
    if(t < bestTime) { bestTime = t; best = cand; }
  }
  if(logger) {
    std::string deltaStr;
    std::string perShapeStr;
    if(best && baselineMs >= 1e-9) {
      double deltaPct = (bestTime - baselineMs) / baselineMs * 100.0;
      // %+.1f always emits a sign; the gated log-format test regex relies on
      // this (matches [-+], not [-+]?). Don't drop the + flag.
      deltaStr = Global::strprintf("%+.1f", deltaPct);

      auto perShape = scoreOutputUntransformPerShape(*best, N, H, W, mi, useFP16);
      perShapeStr = " shape_ms=";
      for(size_t i = 0; i < perShape.size(); i++) {
        if(i > 0) perShapeStr += ",";
        perShapeStr += "c" + std::to_string(perShape[i].first)
                    + ":" + Global::strprintf("%.3f", perShape[i].second);
      }
    } else {
      deltaStr = "nan";
      perShapeStr = "";
    }
    logger->write("MLX tuner flatSweepOutput: considered=" + std::to_string(considered)
                  + (best
                     ? " best=tg0=" + std::to_string(best->tg0)
                       + " tg1=" + std::to_string(best->tg1)
                       + " wpt=" + std::to_string(best->wpt)
                       + " time_ms=" + Global::strprintf("%.3f", bestTime)
                     : " best=none")
                  + " baseline_ms=" + Global::strprintf("%.3f", baselineMs)
                  + " delta_pct=" + deltaStr
                  + perShapeStr);
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
  // Global gridOrder is deleted; input gridOrder stands alone.

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

std::vector<MLXWinogradTuner::ShapePlan>
MLXWinogradTuner::planShapeRotationForTesting(
    const std::vector<std::pair<int,int>>& histogram) {
  return planShapeRotation(histogram);
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

std::vector<std::pair<int,double>>
MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
    const MLXWinograd::InputTransform& cfg,
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    bool useFP16) {
  return scoreInputTransformPerShape(cfg, N, H, W, mi, useFP16);
}

std::vector<std::pair<int,double>>
MLXWinogradTuner::scoreOutputUntransformPerShapeForTesting(
    const MLXWinograd::OutputUntransform& cfg,
    int N, int H, int W,
    const ModelInfoForTuning& mi,
    bool useFP16) {
  return scoreOutputUntransformPerShape(cfg, N, H, W, mi, useFP16);
}

std::string MLXWinogradTuner::formatConv3x3DistributionLine(
    int total,
    const std::map<int,int>& inputChannelCounts,
    const std::map<int,int>& outputChannelCounts) {
  // Build a deterministic ordering: pairs sorted descending by invocation
  // count, ties broken by channel count descending. Truncate each histogram
  // to top-10 with a trailing ",..." guard for pathological models.
  auto serialize = [](const std::map<int,int>& counts) -> std::string {
    if(counts.empty()) return "{}";
    std::vector<std::pair<int,int>> pairs(counts.begin(), counts.end());
    std::sort(pairs.begin(), pairs.end(),
              [](const std::pair<int,int>& a, const std::pair<int,int>& b) {
                if(a.second != b.second) return a.second > b.second;
                return a.first > b.first;
              });
    constexpr size_t kMax = 10;
    bool truncated = pairs.size() > kMax;
    if(truncated) pairs.resize(kMax);

    std::string s;
    for(size_t i = 0; i < pairs.size(); i++) {
      if(i > 0) s += ",";
      s += std::to_string(pairs[i].first) + ":" + std::to_string(pairs[i].second);
    }
    if(truncated) s += ",...";
    return s;
  };

  return "MLX tuner conv3x3 distribution: total=" + std::to_string(total)
       + " input_c="  + serialize(inputChannelCounts)
       + " output_c=" + serialize(outputChannelCounts);
}

// Pure core: filter to 3x3 convs and emit (channels, count) histograms.
// Decoupled from ModelDesc so it's testable without synthesizing the
// copy-deleted ModelDesc hierarchy. Takes pointers because ConvLayerDesc
// has a deleted copy ctor; pointers must be non-null and outlive the call.
static std::pair<std::vector<std::pair<int,int>>,
                 std::vector<std::pair<int,int>>>
buildConv3x3HistogramsFromConvs(const std::vector<const ConvLayerDesc*>& convs) {
  std::map<int,int> inputC, outputC;
  for(const ConvLayerDesc* c : convs) {
    if(c->convXSize == 3 && c->convYSize == 3) {
      inputC[c->inChannels]++;
      outputC[c->outChannels]++;
    }
  }
  std::vector<std::pair<int,int>> inVec(inputC.begin(), inputC.end());
  std::vector<std::pair<int,int>> outVec(outputC.begin(), outputC.end());
  return {std::move(inVec), std::move(outVec)};
}

std::pair<std::vector<std::pair<int,int>>,
          std::vector<std::pair<int,int>>>
MLXWinogradTuner::buildConv3x3HistogramsFromConvsForTesting(
    const std::vector<const ConvLayerDesc*>& convs) {
  return buildConv3x3HistogramsFromConvs(convs);
}

// ModelDesc shim. Walks iterConvLayers, collects pointers to the
// descriptors owned by modelDesc, and delegates to the pure core. Used
// by mlxbackend.cpp at model load. The returned histograms reference no
// memory from modelDesc — only ints — so the descriptor lifetime
// requirement is local to this call.
std::pair<std::vector<std::pair<int,int>>,
          std::vector<std::pair<int,int>>>
MLXWinogradTuner::buildConv3x3Histograms(const ModelDesc& modelDesc) {
  std::vector<const ConvLayerDesc*> convs;
  modelDesc.iterConvLayers([&](const ConvLayerDesc& c) { convs.push_back(&c); });
  return buildConv3x3HistogramsFromConvs(convs);
}

std::string MLXWinogradTuner::formatConv3x3Distribution(const ModelDesc& modelDesc) {
  // Convenience wrapper for callers that want the formatted line directly
  // from a ModelDesc. The histogram is built here and (separately) again by
  // mlxbackend.cpp for the tuner's ModelInfoForTuning — two walks per model
  // load. This is acceptable because model load happens once per process;
  // a single-walk refactor would tangle the mlxbackend call site without
  // measurable savings.
  auto [inVec, outVec] = MLXWinogradTuner::buildConv3x3Histograms(modelDesc);
  std::map<int,int> inMap(inVec.begin(), inVec.end());
  std::map<int,int> outMap(outVec.begin(), outVec.end());
  int total = 0;
  for(const auto& kv : outVec) total += kv.second;  // total = #3x3 convs
  return formatConv3x3DistributionLine(total, inMap, outMap);
}

void runMLXWinotunerTests() {
  cout << "Running MLX Winograd tuner tests" << endl;

  {
    // Conv-3x3 distribution formatter — pure-function test. Verifies the
    // log-line format directly without any descriptor walk or GPU work.
    // Order convention (spec §3a): pairs sorted descending by invocation
    // count, ties broken by channel count descending.

    // Case A: two distinct shapes, each appearing once. Tie on count, so
    // tie-break by channel count descending: 64 before 32.
    {
      std::map<int,int> inputC  = {{32, 1}, {64, 1}};
      std::map<int,int> outputC = {{32, 1}, {64, 1}};
      std::string line = MLXWinogradTuner::formatConv3x3DistributionLine(2, inputC, outputC);
      testAssert(line.find("MLX tuner conv3x3 distribution:") != std::string::npos);
      testAssert(line.find("total=2") != std::string::npos);
      testAssert(line.find("input_c=64:1,32:1") != std::string::npos);
      testAssert(line.find("output_c=64:1,32:1") != std::string::npos);
    }

    // Case B: asymmetric counts. 384 appears 36 times, 192 once. Sort by
    // count descending, so 384 first regardless of channel-count order.
    {
      std::map<int,int> inputC  = {{384, 36}, {192, 1}};
      std::map<int,int> outputC = {{384, 37}};
      std::string line = MLXWinogradTuner::formatConv3x3DistributionLine(37, inputC, outputC);
      testAssert(line.find("total=37") != std::string::npos);
      testAssert(line.find("input_c=384:36,192:1") != std::string::npos);
      testAssert(line.find("output_c=384:37") != std::string::npos);
    }

    // Case C: empty model — no 3x3 convs. Spec §Error handling: print the
    // line with explicit "{}" markers; don't suppress.
    {
      std::map<int,int> empty;
      std::string line = MLXWinogradTuner::formatConv3x3DistributionLine(0, empty, empty);
      testAssert(line.find("total=0") != std::string::npos);
      testAssert(line.find("input_c={}") != std::string::npos);
      testAssert(line.find("output_c={}") != std::string::npos);
    }
    std::cout << "  conv3x3 distribution formatter OK" << std::endl;
  }

  {
    // planShapeRotation — pure-function tests. Verifies the selection rule
    // (top-3, 3% threshold, 3-rep floor, proportional remainder) directly
    // without any GPU work. Spec §Selection Rule.

    // Case A: single shape — entire budget on that shape, weight = 1.0.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting({{192, 72}});
      testAssert(plan.size() == 1);
      testAssert(plan[0].channels == 192);
      testAssert(plan[0].measureReps == 19);
      testAssert(std::abs(plan[0].weight - 1.0) < 1e-9);
    }

    // Case B: two shapes both above threshold (b18c384nbt-like, after the
    // 22:1 entry has already been dropped by threshold). Expected:
    // work = 192*72, 128*5 = 13824, 640; weights 0.956, 0.044;
    // round(0.956*19)=18, round(0.044*19)=1; floor bumps 1->3; dominant 18-2=16.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting({{192, 72}, {128, 5}});
      testAssert(plan.size() == 2);
      testAssert(plan[0].channels == 192);
      testAssert(plan[1].channels == 128);
      testAssert(plan[0].measureReps == 16);
      testAssert(plan[1].measureReps == 3);
      testAssert(plan[0].measureReps + plan[1].measureReps == 19);
      testAssert(std::abs(plan[0].weight + plan[1].weight - 1.0) < 1e-9);
      testAssert(plan[0].weight > plan[1].weight);
    }

    // Case C: minor shape below 3% threshold — dropped entirely, dominant
    // absorbs all 19 reps. Histogram: 192:72 (work 13824, 95.5%), 22:1 (work 22, 0.15%).
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting({{192, 72}, {22, 1}});
      testAssert(plan.size() == 1);
      testAssert(plan[0].channels == 192);
      testAssert(plan[0].measureReps == 19);
      testAssert(std::abs(plan[0].weight - 1.0) < 1e-9);
    }

    // Case D: four shapes — top-3 cut drops the 4th, then threshold drops
    // one more. Input: 384:60, 192:8, 128:5, 64:5. After top-3: drop 64:5.
    // work remaining = 23040, 1536, 640; total 25216; 128's share = 2.54% < 3%
    // -> drop 128. Final: 384 (93.75%) + 192 (6.25%). reps: round(0.9375*19)=18,
    // round(0.0625*19)=1; floor bumps 1->3; dominant 18-2=16.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting(
          {{384, 60}, {192, 8}, {128, 5}, {64, 5}});
      testAssert(plan.size() == 2);
      testAssert(plan[0].channels == 384);
      testAssert(plan[1].channels == 192);
      testAssert(plan[0].measureReps == 16);
      testAssert(plan[1].measureReps == 3);
    }

    // Case E: three shapes all above threshold. Input: 200:10, 100:10, 50:10.
    // work = 2000, 1000, 500; total 3500; shares 57.1%, 28.6%, 14.3% (all >3%).
    // reps: round(0.571*19)=11, round(0.286*19)=5, round(0.143*19)=3.
    // Sum = 19 exactly (no rounding repair needed). All >= floor of 3.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting(
          {{200, 10}, {100, 10}, {50, 10}});
      testAssert(plan.size() == 3);
      testAssert(plan[0].channels == 200);
      testAssert(plan[1].channels == 100);
      testAssert(plan[2].channels == 50);
      int total = plan[0].measureReps + plan[1].measureReps + plan[2].measureReps;
      testAssert(total == 19);
      testAssert(plan[2].measureReps >= 3);
      testAssert(plan[0].measureReps >= plan[1].measureReps);
      testAssert(plan[1].measureReps >= plan[2].measureReps);
    }

    // Case F: 2 shapes with equal work and complementary 0.5 shares —
    // exercises the rounding-repair branch. Input: 200:1, 100:2 (work
    // 200, 200; tied; tie-break by larger C → plan[0]=C=200). Each
    // share is 0.5; lround(0.5*19) = lround(9.5) = 10 each (lround
    // rounds halves away from zero); pre-repair sum = 20; repair:
    // dominant absorbs delta = 19 - 20 = -1; final (9, 10). Both
    // measureReps stay ≥ kRepFloor=3 so floor-bump is a no-op.
    {
      auto plan = MLXWinogradTuner::planShapeRotationForTesting(
          {{200, 1}, {100, 2}});
      testAssert(plan.size() == 2);
      testAssert(plan[0].channels == 200);
      testAssert(plan[1].channels == 100);
      testAssert(plan[0].measureReps + plan[1].measureReps == 19);
      testAssert(plan[0].measureReps == 9);
      testAssert(plan[1].measureReps == 10);
      testAssert(plan[0].measureReps >= 3);
      testAssert(plan[1].measureReps >= 3);
    }

    std::cout << "  planShapeRotation OK" << std::endl;
  }

  {
    // buildConv3x3HistogramsFromConvs — pure-function test on the conv
    // filter+histogram. Constructs ConvLayerDesc instances directly
    // (default-constructible per desc.h:25). ConvLayerDesc has a deleted
    // copy ctor (desc.h:29), so we build the descriptors in a deque
    // (stable addresses, no copies on growth) and pass pointers to the
    // helper. Does not touch ModelDesc.

    auto initConv = [](ConvLayerDesc& c, int kY, int kX, int inC, int outC) {
      c.convYSize  = kY;
      c.convXSize  = kX;
      c.inChannels = inC;
      c.outChannels = outC;
    };

    // Four layers: only the two 3x3 layers should contribute.
    std::deque<ConvLayerDesc> storage;
    std::vector<const ConvLayerDesc*> convs;
    storage.emplace_back(); initConv(storage.back(), 1, 1, 10, 10); convs.push_back(&storage.back());  // 1x1 — filtered
    storage.emplace_back(); initConv(storage.back(), 3, 3, 20, 30); convs.push_back(&storage.back());  // input_c[20]++, output_c[30]++
    storage.emplace_back(); initConv(storage.back(), 3, 3, 30, 30); convs.push_back(&storage.back());  // input_c[30]++, output_c[30]++
    storage.emplace_back(); initConv(storage.back(), 5, 5, 40, 40); convs.push_back(&storage.back());  // 5x5 — filtered

    auto [inHist, outHist] =
        MLXWinogradTuner::buildConv3x3HistogramsFromConvsForTesting(convs);

    // Convert to maps for order-independent comparison.
    std::map<int,int> inMap(inHist.begin(), inHist.end());
    std::map<int,int> outMap(outHist.begin(), outHist.end());

    testAssert(inMap.size() == 2);
    testAssert(inMap[20] == 1);
    testAssert(inMap[30] == 1);
    testAssert(inMap.count(10) == 0);  // 1x1 didn't leak through
    testAssert(inMap.count(40) == 0);  // 5x5 didn't leak through

    testAssert(outMap.size() == 1);
    testAssert(outMap[30] == 2);
    testAssert(outMap.count(10) == 0);
    testAssert(outMap.count(40) == 0);

    // Asymmetric 3x3 (e.g. 3x1) must also be filtered — the kernel is
    // strictly square-3.
    std::deque<ConvLayerDesc> asymStorage;
    std::vector<const ConvLayerDesc*> asym;
    asymStorage.emplace_back(); initConv(asymStorage.back(), 3, 1, 16, 16); asym.push_back(&asymStorage.back());
    asymStorage.emplace_back(); initConv(asymStorage.back(), 1, 3, 16, 16); asym.push_back(&asymStorage.back());
    asymStorage.emplace_back(); initConv(asymStorage.back(), 3, 3, 16, 16); asym.push_back(&asymStorage.back());
    auto [inA, outA] =
        MLXWinogradTuner::buildConv3x3HistogramsFromConvsForTesting(asym);
    testAssert(inA.size() == 1 && inA[0].first == 16 && inA[0].second == 1);
    testAssert(outA.size() == 1 && outA[0].first == 16 && outA[0].second == 1);

    // Empty input → empty histograms (no assert; this is just the pure
    // core. The mlxbackend.cpp call site asserts non-empty after a real
    // model walk; mlxbackend.cpp pre-computes the histogram at model
    // load and stores it on ModelInfoForTuning so the tuner does not
    // re-walk the descriptor).
    std::vector<const ConvLayerDesc*> empty;
    auto [inE, outE] =
        MLXWinogradTuner::buildConv3x3HistogramsFromConvsForTesting(empty);
    testAssert(inE.empty());
    testAssert(outE.empty());

    std::cout << "  buildConv3x3HistogramsFromConvs OK" << std::endl;
  }

  // ---- v3 round-trip: tg0/tg1/wpt/vw/gridOrder (input), tg0/tg1/wpt (output) ----
  {
    // v3 roundtrip: write -> load -> compare all 8 fields. Two
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

  // dtype-aware cache filenames must coexist in the same directory
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
    // v3 isValid invariants.
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

  // Candidate enumeration with validity filtering.
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

    // Output side: same shape of assertions. (gridOrder is not a parameter
    // of buildOutputCandidatesForTesting — output is Cfast-only.)
    auto out_cands = MLXWinogradTuner::buildOutputCandidatesForTesting(
        true, /*outC*/64, /*Ntiles*/200);
    testAssert(out_cands.size() > 100);
    for(const auto& c : out_cands)
      testAssert(c.tg0 * c.tg1 <= 1024);

    std::cout << "  MLX Winograd candidate enumeration validity passed ("
              << cands.size() << " input / " << out_cands.size() << " output candidates C=64)"
              << std::endl;
  }

  // ---- Measurement primitives return finite positive times ----
  // We can't call the static helpers from the test, so we use the public
  // surface: loadOrAutoTune with reTune=true runs the search and we verify
  // that the public schema struct works with valid configs. The measurement
  // primitive itself is exercised by the search-works test below.

  {
    // Gated flat-sweep convergence test.
    // Runs the production flat sweep on a small synthetic problem and asserts
    // that the winner is isValid and that its timing is no worse than the
    // baked default (tg0=32, tg1=1, wpt=1, vw=1, Cfast).
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.modelVersion        = 11;
      // Synthetic single-shape histogram for the toy C=64 test model.
      mi.conv3x3InputHistogram  = {{64, 1}};
      mi.conv3x3OutputHistogram = {{64, 1}};

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
      std::cout << "  flat-sweep convergence (gated) OK"
                << " bakedMs=" << bakedMs
                << " tunedMs=" << tunedMs << std::endl;

      std::remove(tmpTunerFile.c_str());
    }
  }

  {
    // Baseline anchor — Test 1: log-format gated check (input stage).
    // Asserts that flatSweepInput's log line carries the new baseline_ms and
    // delta_pct fields with the documented format. Gated because the synthetic
    // sweep takes a few seconds; opt in with the env var below.
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.modelVersion        = 11;
      // Synthetic single-shape histogram for the toy C=64 test model.
      mi.conv3x3InputHistogram  = {{64, 1}};
      mi.conv3x3OutputHistogram = {{64, 1}};

      std::string tmpTunerFile = "/tmp/baseline_anchor_log_format.txt";
      std::remove(tmpTunerFile.c_str());

      std::ostringstream captured;
      Logger logger(nullptr, /*logToStdoutDefault=*/false,
                    /*logToStderrDefault=*/false, /*logTimeDefault=*/false,
                    /*logConfigContents=*/false);
      logger.addOStream(captured);

      (void)MLXWinogradTuner::loadOrAutoTune(
          /*tunerFile=*/tmpTunerFile,
          /*homeDataDirOverride=*/"",
          /*gpuName=*/"AppleSilicon",
          /*nnXLen=*/19, /*nnYLen=*/19, /*batchSize=*/1,
          mi,
          /*logger=*/&logger,
          /*full=*/false,
          /*reTune=*/true,
          /*useFP16=*/true);

      const std::string log = captured.str();
      // Logger::writeLocked prefixes each line with ": " when logTime=false, so
      // `log` reads ": MLX tuner ...". std::regex_search is anchor-free so the
      // ": " prefix is transparent; only the substring match matters here.
      // The regex matches the non-degenerate path only (best != nullopt). The
      // best=none / delta_pct=nan branch is unreachable for the synthetic 19x19
      // C=64 problem this test runs against (hundreds of valid candidates).
      // Updated for shape diagnostic: regex now requires the per-shape
      // median fields appended by flatSweepInput.
      std::regex inputRe(
          R"(MLX tuner flatSweepInput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ vw=[0-9]+ gridOrder=[01] time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+][0-9]+\.[0-9]+ shape_ms=c[0-9]+:[0-9]+\.[0-9]+(?:,c[0-9]+:[0-9]+\.[0-9]+)*)");
      testAssert(std::regex_search(log, inputRe));
      std::cout << "  flatSweepInput log-format (gated) OK" << std::endl;

      std::regex outputRe(
          R"(MLX tuner flatSweepOutput: considered=[0-9]+ best=tg0=[0-9]+ tg1=[0-9]+ wpt=[0-9]+ time_ms=[0-9]+\.[0-9]+ baseline_ms=[0-9]+\.[0-9]+ delta_pct=[-+][0-9]+\.[0-9]+ shape_ms=c[0-9]+:[0-9]+\.[0-9]+(?:,c[0-9]+:[0-9]+\.[0-9]+)*)");
      testAssert(std::regex_search(log, outputRe));
      std::cout << "  flatSweepOutput log-format (gated) OK" << std::endl;

      std::remove(tmpTunerFile.c_str());
    }
  }

  {
    // Baseline anchor — Test 2: baseline-consistency gated check.
    // Asserts that the baseline_ms value printed by flatSweepInput
    // matches an independent re-score of the default-constructed
    // InputTransform within a 25% relative-error budget.
    //
    // parsedBaseline is a single 20-rep weighted mean (one call into
    // scoreInputTransform). minOf3 is the min of three such weighted
    // means — systematically biased slightly low relative to a single
    // mean due to selection bias (~5-10% on this hardware), on top of
    // the ~10% per-sample noise floor. The 25% budget covers both.
    //
    // Reuses the KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST gate so users who
    // opt into the sweep-convergence cost also get this check. Note
    // this runs an INDEPENDENT loadOrAutoTune sweep — total cost when
    // the gate is set is roughly 2x the pre-Task-3 cost.
    //
    // Coverage scope: input stage only. flatSweepOutput's baseline_ms
    // is format-checked by Test 1 but not consistency-checked here.
    // The output kernel uses a different scoring function and default
    // struct (OutputUntransform{}); a symmetric check is deferred.
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.modelVersion        = 11;
      // Synthetic single-shape histogram for the toy C=64 test model.
      mi.conv3x3InputHistogram  = {{64, 1}};
      mi.conv3x3OutputHistogram = {{64, 1}};

      std::string tmpTunerFile = "/tmp/baseline_anchor_consistency.txt";
      std::remove(tmpTunerFile.c_str());

      std::ostringstream captured;
      Logger logger(nullptr, /*logToStdoutDefault=*/false,
                    /*logToStderrDefault=*/false, /*logTimeDefault=*/false,
                    /*logConfigContents=*/false);
      logger.addOStream(captured);

      (void)MLXWinogradTuner::loadOrAutoTune(
          /*tunerFile=*/tmpTunerFile,
          /*homeDataDirOverride=*/"",
          /*gpuName=*/"AppleSilicon",
          /*nnXLen=*/19, /*nnYLen=*/19, /*batchSize=*/1,
          mi,
          /*logger=*/&logger,
          /*full=*/false,
          /*reTune=*/true,
          /*useFP16=*/true);

      const std::string log = captured.str();
      std::smatch m;
      std::regex baselineRe(R"(flatSweepInput:[^\n]*baseline_ms=([0-9]+\.[0-9]+))");
      testAssert(std::regex_search(log, m, baselineRe));
      const double parsedBaseline = std::stod(m[1].str());

      double minOf3 = std::numeric_limits<double>::infinity();
      for(int rep = 0; rep < 3; rep++) {
        double t = MLXWinogradTuner::scoreInputTransformForTesting(
            MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
        if(t < minOf3) minOf3 = t;
      }

      const double relErr = std::abs(parsedBaseline - minOf3) / minOf3;
      testAssert(relErr < 0.25);
      std::cout << "  baseline-consistency (gated) OK"
                << " parsed=" << parsedBaseline
                << " minOf3=" << minOf3
                << " relErr=" << relErr << std::endl;

      std::remove(tmpTunerFile.c_str());
    }
  }

  {
    // Per-shape numeric consistency — Test 2 from the shape-diagnostic spec.
    // Asserts the dominant-shape median printed by flatSweepInput
    // (shape_ms=c<C>:<ms>) is in the same ballpark as an independent
    // reference measurement of the default InputTransform{} on that shape.
    //
    // IMPORTANT — cross-config comparison: parsedDominantMs is measured by
    // flatSweepInput on the WINNER configuration (whatever the sweep
    // selected). minOf3 is computed on the DEFAULT InputTransform{} via
    // three independent scoreInputTransformPerShapeForTesting calls. These
    // are not the same config, so the relative-error budget is necessarily
    // loose. The budget covers:
    //   - winner-vs-default speed gap (sweep can find configs 10-40%
    //     faster than default on some shapes/hardware)
    //   - selection bias on the min-of-3 reference (~5-10% low vs single)
    //   - per-call noise floor (~10%)
    // The 50% budget is intentionally conservative; this is a sanity-check
    // that measurement is roughly working, not a tight precision check.
    // Tighter precision checks belong in same-config stability tests.
    //
    // Coverage scope: input stage only. flatSweepOutput's per-shape fields
    // are format-checked by the log-format test (gate
    // KATAGO_MLX_WINOTUNER_RUN_LOG_FORMAT_TEST) but not consistency-
    // checked here — symmetric output check is deferred.
    //
    // Gate is new (KATAGO_MLX_WINOTUNER_RUN_PER_SHAPE_TEST) and separate
    // from the baseline-anchor gate above; this test runs an additional
    // tuner sweep.
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_PER_SHAPE_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.modelVersion        = 11;
      // Synthetic single-shape histogram for the toy C=64 test model.
      mi.conv3x3InputHistogram  = {{64, 1}};
      mi.conv3x3OutputHistogram = {{64, 1}};

      std::string tmpTunerFile = "/tmp/per_shape_consistency.txt";
      std::remove(tmpTunerFile.c_str());

      std::ostringstream captured;
      Logger logger(nullptr, /*logToStdoutDefault=*/false,
                    /*logToStderrDefault=*/false, /*logTimeDefault=*/false,
                    /*logConfigContents=*/false);
      logger.addOStream(captured);

      (void)MLXWinogradTuner::loadOrAutoTune(
          /*tunerFile=*/tmpTunerFile,
          /*homeDataDirOverride=*/"",
          /*gpuName=*/"AppleSilicon",
          /*nnXLen=*/19, /*nnYLen=*/19, /*batchSize=*/1,
          mi,
          /*logger=*/&logger,
          /*full=*/false,
          /*reTune=*/true,
          /*useFP16=*/true);

      const std::string log = captured.str();
      std::smatch m;
      std::regex trunkRe(R"(flatSweepInput:[^\n]*shape_ms=c[0-9]+:([0-9]+\.[0-9]+))");
      testAssert(std::regex_search(log, m, trunkRe));
      const double parsedDominantMs = std::stod(m[1].str());

      // Per-shape consistency: parse the dominant shape's median from
      // the flatSweepInput log line (which used scoreInputTransformPerShape
      // on the winner) and compare against scoreInputTransformPerShapeForTesting
      // on the default InputTransform. Cross-config (winner vs default)
      // so a wide relErr bound (<0.50) is appropriate; see spec §Testing.
      std::vector<std::pair<int,double>> r1 =
          MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
              MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
      std::vector<std::pair<int,double>> r2 =
          MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
              MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
      std::vector<std::pair<int,double>> r3 =
          MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
              MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
      testAssert(!r1.empty() && !r2.empty() && !r3.empty());
      // Each result has the same shapes in the same order; take the
      // dominant (index 0) per-shape median across the 3 runs.
      double minOf3 = std::min({r1[0].second, r2[0].second, r3[0].second});

      const double relErr = std::abs(parsedDominantMs - minOf3) / minOf3;
      // 50% budget — see comment block above for rationale on the loose
      // bound (cross-config comparison + selection bias + noise).
      testAssert(relErr < 0.50);
      std::cout << "  per-shape dominant consistency (gated) OK"
                << " parsed=" << parsedDominantMs
                << " minOf3=" << minOf3
                << " relErr=" << relErr << std::endl;

      std::remove(tmpTunerFile.c_str());
    }
  }

  {
    // Per-shape scoring smoke test: verify that scoreInputTransformPerShape
    // and scoreOutputUntransformPerShape return finite positive values for
    // each planned shape with a default-constructed
    // InputTransform/OutputUntransform on a tiny shape. Gated under the same
    // env var as the other GPU-touching tests; ungated CI shouldn't pay for
    // GPU work.
    const char* gate = std::getenv("KATAGO_MLX_WINOTUNER_RUN_SWEEP_TEST");
    if(gate != nullptr && std::string(gate) == "1") {
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels    = 64;
      mi.modelVersion        = 11;
      // Synthetic single-shape histogram for the toy C=64 test model.
      mi.conv3x3InputHistogram  = {{64, 1}};
      mi.conv3x3OutputHistogram = {{64, 1}};

      std::vector<std::pair<int,double>> in =
          MLXWinogradTuner::scoreInputTransformPerShapeForTesting(
              MLXWinograd::InputTransform{}, 1, 19, 19, mi, true);
      testAssert(!in.empty());
      for(const auto& [c, v] : in) {
        testAssert(c > 0);
        testAssert(std::isfinite(v));
        testAssert(v > 0.0);
        testAssert(v < 1000.0);  // sanity: <1s per call on Apple Silicon
      }

      std::vector<std::pair<int,double>> out =
          MLXWinogradTuner::scoreOutputUntransformPerShapeForTesting(
              MLXWinograd::OutputUntransform{}, 1, 19, 19, mi, true);
      testAssert(!out.empty());
      for(const auto& [c, v] : out) {
        testAssert(c > 0);
        testAssert(std::isfinite(v));
        testAssert(v > 0.0);
        testAssert(v < 1000.0);
      }
      std::cout << "  per-shape scoring smoke (gated) OK"
                << " in[0]=c" << in[0].first << ":" << in[0].second
                << " out[0]=c" << out[0].first << ":" << out[0].second
                << std::endl;
    }
  }

  cout << "MLX Winograd tuner tests passed" << endl;
}

#endif // USE_MLX_BACKEND
