#ifdef USE_MLX_BACKEND

#include "../neuralnet/mlxwinotuner.h"

#include <fstream>
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

static const int MLX_WINO_TUNER_VERSION = 1;
static const char* MLX_WINO_TUNEPARAMS_VERSION_LINE = "VERSION=1";

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
  return true;
}

void MLXWinogradTuneParams::save(const string& filename, const MLXWinogradTuneParams& params) {
  ofstream out;
  FileUtils::open(out, filename);
  out << MLX_WINO_TUNEPARAMS_VERSION_LINE << "\n";
  out << "#inputTransform" << "\n";
  out << "tg0=" << params.inputTransform.tg0
      << " tg1=" << params.inputTransform.tg1 << "\n";
  out << "#outputUntransform" << "\n";
  out << "tg0=" << params.outputUntransform.tg0
      << " tg1=" << params.outputUntransform.tg1 << "\n";
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
                  + string(MLX_WINO_TUNEPARAMS_VERSION_LINE) + " in " + filename);
  if(lines.size() != 3)
    throw IOError("MLXWinogradTuneParams::load: expected 3 non-comment lines in " + filename);

  MLXWinogradTuneParams params;
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[1]);
    params.inputTransform.tg0 = requireKey(kvs, "tg0", filename);
    params.inputTransform.tg1 = requireKey(kvs, "tg1", filename);
  }
  {
    map<string,int> kvs = parseKeyValueLine(filename, lines[2]);
    params.outputUntransform.tg0 = requireKey(kvs, "tg0", filename);
    params.outputUntransform.tg1 = requireKey(kvs, "tg1", filename);
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
                                         int trunkNumChannels, int modelVersion) {
  string clean;
  for(char c : gpuName) {
    if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
      clean += c;
  }
  return Global::strprintf("tunemlxwino%d_gpu%s_x%d_y%d_c%d_mv%d.txt",
                           MLX_WINO_TUNER_VERSION, clean.c_str(),
                           nnXLen, nnYLen, trunkNumChannels, modelVersion);
}

// MLXWinogradTuner::loadOrAutoTune is defined in Task 4 once the search loop exists.

namespace mx = mlx::core;

// One stage-1 (input transform) timed run on a synthetic [N,H,W,C] tensor.
// Mirrors the inner-loop shape of winogradConv2d's stage 1, but issues only
// the input-transform kernel so we can score it in isolation. Returns wall ms.
[[maybe_unused]]
static double timeOneInputTransform(const MLXWinograd::InputTransform& cfg,
                                    const mx::array& input, int channels) {
  int N = input.shape(0);
  int H = input.shape(1);
  int W = input.shape(2);
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  auto fn = mx::fast::metal_kernel(
      "wino_input_transform_f32_tune",
      /*input_names=*/{"inp"},
      /*output_names=*/{"outp"},
      /*source=*/MLXWinograd::kWinoInputSource);
  auto outs = fn(
      /*inputs=*/{input},
      /*output_shapes=*/{ mx::Shape{16, Ntiles, channels} },
      /*output_dtypes=*/{ mx::float32 },
      /*grid=*/std::make_tuple(channels, Ntiles, 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/{},
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});

  auto t0 = std::chrono::steady_clock::now();
  mx::eval(outs[0]);
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// Same shape for output untransform: synthetic [16, Ntiles, outC] -> [N,H,W,outC].
[[maybe_unused]]
static double timeOneOutputUntransform(const MLXWinograd::OutputUntransform& cfg,
                                       const mx::array& m, int N, int H, int W, int outC) {
  int nhwc_arr[4] = {N, H, W, outC};
  mx::array nhwcArr(nhwc_arr, {4}, mx::int32);

  auto fn = mx::fast::metal_kernel(
      "wino_output_untransform_f32_tune",
      /*input_names=*/{"m", "nhwc"},
      /*output_names=*/{"outp"},
      /*source=*/MLXWinograd::kWinoOutputSource);
  auto outs = fn(
      /*inputs=*/{m, nhwcArr},
      /*output_shapes=*/{ mx::Shape{N, H, W, outC} },
      /*output_dtypes=*/{ mx::float32 },
      /*grid=*/std::make_tuple(outC, m.shape(1), 1),
      /*threadgroup=*/std::make_tuple(cfg.tg0, cfg.tg1, 1),
      /*template_args=*/{},
      /*init_value=*/std::nullopt,
      /*verbose=*/false,
      /*stream=*/mx::StreamOrDevice{});

  auto t0 = std::chrono::steady_clock::now();
  mx::eval(outs[0]);
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// Random NHWC fp32 input tensor for the input-transform timing harness.
[[maybe_unused]]
static mx::array makeRandomInput(int N, int H, int W, int C, uint32_t seed) {
  std::vector<float> v((size_t)N * H * W * C);
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  for(auto& x : v) x = dist(rng);
  return mx::array(v.data(), {N, H, W, C}, mx::float32);
}

// Random [16, Ntiles, outC] fp32 tensor for the output-untransform timing harness.
[[maybe_unused]]
static mx::array makeRandomMatmulOut(int Ntiles, int outC, uint32_t seed) {
  std::vector<float> v((size_t)16 * Ntiles * outC);
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> dist(-1.0f, 1.0f);
  for(auto& x : v) x = dist(rng);
  return mx::array(v.data(), {16, Ntiles, outC}, mx::float32);
}

// Score one input-transform candidate. Mirrors OpenCL line 2172-2206:
// 20 reps rotating across {trunk, mid, max} channel counts; rep 0 is warmup
// with weight 0; remaining 19 reps weighted into a mean wall-clock time.
[[maybe_unused]]
static double scoreInputTransform(const MLXWinograd::InputTransform& cfg,
                                  int N, int H, int W,
                                  const MLXWinogradTuner::ModelInfoForTuning& mi) {
  mx::array inTrunk = makeRandomInput(N, H, W, mi.trunkNumChannels, 0xA1A1A1A1u);
  mx::array inMid   = makeRandomInput(N, H, W, mi.midNumChannels,   0xB2B2B2B2u);
  mx::array inMax   = makeRandomInput(N, H, W, mi.maxConvChannels3x3, 0xC3C3C3C3u);
  mx::eval(inTrunk); mx::eval(inMid); mx::eval(inMax);

  const int reps = 20;
  double totalMs = 0.0;
  double totalWeight = 0.0;
  for(int i = 0; i < reps; i++) {
    int channels;
    double weight;
    switch(i % 10) {
      case 0: channels = mi.trunkNumChannels;     weight = 0; break; // warmup
      case 1: channels = mi.trunkNumChannels;     weight = 1; break;
      case 2: channels = mi.midNumChannels;       weight = 1; break;
      case 3: channels = mi.maxConvChannels3x3;   weight = 1; break;
      case 4: channels = mi.trunkNumChannels;     weight = 1; break;
      case 5: channels = mi.midNumChannels;       weight = 1; break;
      case 6: channels = mi.maxConvChannels3x3;   weight = 1; break;
      case 7: channels = mi.trunkNumChannels;     weight = 1; break;
      case 8: channels = mi.midNumChannels;       weight = 1; break;
      case 9: channels = mi.maxConvChannels3x3;   weight = 1; break;
      default: channels = mi.trunkNumChannels;    weight = 1; break;
    }
    const mx::array& inp =
      (channels == mi.trunkNumChannels) ? inTrunk :
      (channels == mi.midNumChannels)   ? inMid   : inMax;
    double ms = timeOneInputTransform(cfg, inp, channels);
    totalMs += ms * weight;
    totalWeight += weight;
  }
  return totalMs / totalWeight;
}

// Score one output-untransform candidate. Same rotation/warmup structure.
[[maybe_unused]]
static double scoreOutputUntransform(const MLXWinograd::OutputUntransform& cfg,
                                     int N, int H, int W,
                                     const MLXWinogradTuner::ModelInfoForTuning& mi) {
  int tilesY = (H + 1) / 2;
  int tilesX = (W + 1) / 2;
  int Ntiles = N * tilesY * tilesX;

  mx::array mTrunk = makeRandomMatmulOut(Ntiles, mi.trunkNumChannels,   0xD4D4D4D4u);
  mx::array mMid   = makeRandomMatmulOut(Ntiles, mi.midNumChannels,     0xE5E5E5E5u);
  mx::array mMax   = makeRandomMatmulOut(Ntiles, mi.maxConvChannels3x3, 0xF6F6F6F6u);
  mx::eval(mTrunk); mx::eval(mMid); mx::eval(mMax);

  const int reps = 20;
  double totalMs = 0.0;
  double totalWeight = 0.0;
  for(int i = 0; i < reps; i++) {
    int outC;
    double weight;
    switch(i % 10) {
      case 0: outC = mi.trunkNumChannels;     weight = 0; break;
      case 1: outC = mi.trunkNumChannels;     weight = 1; break;
      case 2: outC = mi.midNumChannels;       weight = 1; break;
      case 3: outC = mi.maxConvChannels3x3;   weight = 1; break;
      case 4: outC = mi.trunkNumChannels;     weight = 1; break;
      case 5: outC = mi.midNumChannels;       weight = 1; break;
      case 6: outC = mi.maxConvChannels3x3;   weight = 1; break;
      case 7: outC = mi.trunkNumChannels;     weight = 1; break;
      case 8: outC = mi.midNumChannels;       weight = 1; break;
      case 9: outC = mi.maxConvChannels3x3;   weight = 1; break;
      default: outC = mi.trunkNumChannels;    weight = 1; break;
    }
    const mx::array& mIn =
      (outC == mi.trunkNumChannels) ? mTrunk :
      (outC == mi.midNumChannels)   ? mMid   : mMax;
    double ms = timeOneOutputUntransform(cfg, mIn, N, H, W, outC);
    totalMs += ms * weight;
    totalWeight += weight;
  }
  return totalMs / totalWeight;
}

#endif // USE_MLX_BACKEND
