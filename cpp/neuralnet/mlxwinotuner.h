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

  // tg0 * tg1 <= 1024, all positive, input gridOrder must match the global
  // (output kernel is Cfast-monomorphic after SP5 Task 4).
  // vw must divide the fast-axis dim of the current model —
  // that check happens at candidate-enumeration time, not here.
  bool isValid() const;

  // VERSION=2 plain-text persistence. Format:
  //   VERSION=2
  //   #global
  //   gridOrder=<0|1>
  //   #inputTransform
  //   tg0=<int> tg1=<int> wpt=<int> vw=<int> gridOrder=<0|1>
  //   #outputUntransform
  //   tg0=<int> tg1=<int> wpt=<int>
  // (SP5 Tasks 3-5 done: output vw, gridOrder, and matmulOrient dropped;
  //  v3 schema bump pending in Task 7.)
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
  // seedOverride: reserved for API stability; currently ignored by the flat
  // sweep. Production callers pass nullptr.
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
  buildOutputCandidatesForTesting(bool full, int outC, int Ntiles);

  // Test-only — exposes the per-stage scoring primitives so tests can compare
  // configs apples-to-apples without depending on the full tuner measurement path.
  double scoreInputTransformForTesting(const MLXWinograd::InputTransform& cfg,
                                       int N, int H, int W,
                                       const ModelInfoForTuning& mi,
                                       bool useFP16);
  double scoreOutputUntransformForTesting(const MLXWinograd::OutputUntransform& cfg,
                                          int N, int H, int W,
                                          const ModelInfoForTuning& mi,
                                          bool useFP16);
}

#endif // USE_MLX_BACKEND
#endif // NEURALNET_MLXWINOTUNER_H_
