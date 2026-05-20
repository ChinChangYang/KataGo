#ifndef NEURALNET_MLXWINOTUNER_H_
#define NEURALNET_MLXWINOTUNER_H_

#ifdef USE_MLX_BACKEND

#include <string>
#include "../neuralnet/mlxwinograd.h"

class Logger;

struct MLXWinogradTuneParams {
  MLXWinograd::InputTransform    inputTransform;
  MLXWinograd::OutputUntransform outputUntransform;

  // tg0 * tg1 <= 1024 (Metal threadgroup-thread cap) for both stages,
  // and all values strictly positive.
  bool isValid() const;

  // Plain-text persistence mirroring OpenCLTuneParams::save/load:
  // VERSION line at top, '#section' comments, 'KEY=VALUE KEY=VALUE' lines.
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
                              int trunkNumChannels, int modelVersion);

  // Loads existing tune file if present and valid; otherwise runs the two
  // grid searches, saves the result, and returns it. Defined in Task 4.
  MLXWinogradTuneParams loadOrAutoTune(
    std::string tunerFile,
    const std::string& homeDataDirOverride,
    const std::string& gpuName,
    int nnXLen, int nnYLen, int batchSize,
    ModelInfoForTuning modelInfo,
    Logger* logger,
    bool full,
    bool reTune
  );
}

#endif // USE_MLX_BACKEND
#endif // NEURALNET_MLXWINOTUNER_H_
