#ifndef NEURALNET_MLXWINOTUNER_H_
#define NEURALNET_MLXWINOTUNER_H_

#ifdef USE_MLX_BACKEND

#include <string>
#include "../neuralnet/mlxwinograd.h"

class Logger;

struct MLXWinogradTuneParams {
  MLXWinograd::InputTransform    inputTransform;
  MLXWinograd::OutputUntransform outputUntransform;
  MLXWinograd::GridOrder         gridOrder    = MLXWinograd::GridOrder::Cfast;
  MLXWinograd::MatmulOrient      matmulOrient = MLXWinograd::MatmulOrient::Std;

  // tg0 * tg1 <= 1024, all positive, gridOrder of both stages must match
  // the global. vw must divide the fast-axis dim of the current model —
  // that check happens at candidate-enumeration time, not here.
  bool isValid() const;

  // VERSION=2 plain-text persistence. Format:
  //   VERSION=2
  //   #global
  //   gridOrder=<0|1> matmulOrient=<0|1>
  //   #inputTransform
  //   tg0=<int> tg1=<int> wpt=<int> vw=<int> gridOrder=<0|1>
  //   #outputUntransform
  //   tg0=<int> tg1=<int> wpt=<int> vw=<int> gridOrder=<0|1>
  static void save(const std::string& filename, const MLXWinogradTuneParams& params);
  static MLXWinogradTuneParams load(const std::string& filename);
};

namespace MLXWinogradTuner {
  struct ModelInfoForTuning {
    int trunkNumChannels;
    int midNumChannels;
    int maxConvChannels3x3;
    int modelVersion;
  };

  std::string defaultDirectory(bool makeDir, const std::string& homeDataDirOverride);
  std::string defaultFileName(const std::string& gpuName,
                              int nnXLen, int nnYLen,
                              int trunkNumChannels, int modelVersion,
                              bool useFP16);

  // Loads existing tune file if present and valid; otherwise runs the two
  // grid searches, saves the result, and returns it.
  // useFP16: passed to defaultFileName for cache-file naming AND to the
  // search-timing kernels so geometry is measured at the active precision.
  // seedOverride: when non-null, the search uses these configs as the initial
  // baseline instead of the SP1 baked defaults {tg0=32, tg1=1}. Used by tests
  // to verify that the search converges from a bad seed; production callers
  // pass nullptr.
  MLXWinogradTuneParams loadOrAutoTune(
    std::string tunerFile,
    const std::string& homeDataDirOverride,
    const std::string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,
    bool reTune,
    bool useFP16,
    const MLXWinogradTuneParams* seedOverride = nullptr
  );

  // Test-only — exposes the per-model candidate enumeration. Not part of the
  // stable API; production callers should use loadOrAutoTune.
  std::vector<MLXWinograd::InputTransform>
  buildInputCandidatesForTesting(bool full, int C, int Ntiles, MLXWinograd::GridOrder go);
  std::vector<MLXWinograd::OutputUntransform>
  buildOutputCandidatesForTesting(bool full, int outC, int Ntiles, MLXWinograd::GridOrder go);
}

#endif // USE_MLX_BACKEND
#endif // NEURALNET_MLXWINOTUNER_H_
