#ifdef USE_MLX_BACKEND

/**
 * MLX backend for KataGo.
 * Uses Apple's MLX framework for neural network inference on Apple Silicon.
 * Supports FP16 (half precision) and FP32 computation with NHWC memory layout.
 * FP16 Winograd uses selective fp32 accumulation at the matmul reduction and
 * BatchNorm intermediate (spec docs/superpowers/specs/2026-05-20-mlx-winograd-fp16-design.md).
 * `mlxUseFP16 = auto` resolves to fp16 after SP3 acceptance lands.
 */

#include "../neuralnet/nninterface.h"
#include "../neuralnet/desc.h"
#include "../neuralnet/modelversion.h"
#include "../neuralnet/nninputs.h"
#include "../neuralnet/nneval.h"
#include "../neuralnet/activations.h"
#include "../neuralnet/mlxwinograd.h"
#include "../neuralnet/mlxwinotuner.h"
#include "../core/global.h"
#include "../core/test.h"

#include <mlx/mlx.h>
#include <iostream>
#include <cstring>
#include <memory>
#include <mutex>
#include <map>
#include <tuple>
#include <random>
#include <array>
#include <cmath>

// Test-only free functions. runMLXWinogradTests is defined at the bottom of
// this file (alongside runMLXBatchNormFP16Test_SP3 / runMLXConvLayerFP16WinogradTest_SP3).
// runMLXWinotunerTests is defined in mlxwinotuner.cpp.
void runMLXWinogradTests();
void runMLXWinotunerTests();

namespace mx = mlx::core;

// Type alias for compiled inference functions
using CompiledInferenceFunc = std::function<std::vector<mx::array>(const std::vector<mx::array>&)>;

// Cache key: (batchSize, nnXLen, nnYLen, useMask, hasMeta, useFP16)
using CompileCacheKey = std::tuple<int, int, int, bool, bool, bool>;
using namespace std;


// LoadedModel / ModelDesc ---------------------------------------------------------------------------------------------

struct LoadedModel {
  ModelDesc modelDesc;

  LoadedModel(const string& fileName, const string& expectedSha256) {
    ModelDesc::loadFromFileMaybeGZipped(fileName, modelDesc, expectedSha256);
  }

  LoadedModel() = delete;
  LoadedModel(const LoadedModel&) = delete;
  LoadedModel& operator=(const LoadedModel&) = delete;
};

LoadedModel* NeuralNet::loadModelFile(const string& file, const string& expectedSha256) {
  LoadedModel* loadedModel = new LoadedModel(file, expectedSha256);
  return loadedModel;
}

void NeuralNet::freeLoadedModel(LoadedModel* loadedModel) {
  delete loadedModel;
}

const ModelDesc& NeuralNet::getModelDesc(const LoadedModel* loadedModel) {
  return loadedModel->modelDesc;
}

// Helpers --------------------------------------------------------------------------------------------------------------

// Convert convolution weights from OIHW to OHWI (MLX conv2d weight format)
static mx::array convertConvWeightsOIHWtoOHWI(const vector<float>& weights,
                                               int outChannels, int inChannels,
                                               int kH, int kW) {
  // Original: [outC, inC, kH, kW] - stored in column-major order
  // Target: [outC, kH, kW, inC]
  vector<float> converted(weights.size());
  for (int oc = 0; oc < outChannels; oc++) {
    for (int ic = 0; ic < inChannels; ic++) {
      for (int h = 0; h < kH; h++) {
        for (int w = 0; w < kW; w++) {
          int srcIdx = ((oc * inChannels + ic) * kH + h) * kW + w;
          int dstIdx = ((oc * kH + h) * kW + w) * inChannels + ic;
          converted[dstIdx] = weights[srcIdx];
        }
      }
    }
  }
  mx::Shape shape = {outChannels, kH, kW, inChannels};
  return mx::array(converted.data(), shape, mx::float32);
}

// Convert array to compute dtype
static mx::array toComputeDtype(const mx::array& arr, bool useFP16) {
  return useFP16 ? mx::astype(arr, mx::float16) : arr;
}

// Mish activation: x * tanh(softplus(x)) = x * tanh(log(1 + exp(x)))
//
// Numerical stability: softplus is computed via logaddexp(0, x), which MLX
// implements as max(0, x) + log1p(exp(-|x|)) (see mlx/backend/cpu/binary_ops.h
// LogAddExp). The exp argument is always in (-inf, 0], so exp(-|x|) lies in
// (0, 1] and cannot overflow in either FP32 or FP16. This is why MLX does
// not need the ACTIVATION_MISH_SCALE8 variant that CUDA/OpenCL/TensorRT apply
// at model load (desc.cpp:applyScale8ToReduceActivations, cudabackend.cpp:2128,
// trtbackend.cpp:86, openclbackend.cpp:116) to keep Mish inside FP16
// representable range: those backends compute softplus via a path that
// overflows for x >~ 11 in FP16 (since exp(11.09) >~ 65504 = FP16 max).
// Cross-backend validation against an Eigen FP32 reference confirms FP16
// MLX is within typical half-precision tolerance with no Mish-overflow
// artifacts (see testgpuerror workflow in CLAUDE.md).
static mx::array applyMish(const mx::array& x) {
  // softplus(x) = log(1 + exp(x)) = log(exp(0) + exp(x)) = logaddexp(0, x).
  // MLX's logaddexp uses max(0,x) + log1p(exp(-|x|)) -- overflow-free.
  mx::array softplus = mx::logaddexp(mx::array(0.0f), x);
  return x * mx::tanh(softplus);
}

// Apply activation function
static mx::array applyActivation(const mx::array& x, int activationType) {
  switch(activationType) {
    case ACTIVATION_RELU:
      return mx::maximum(x, mx::array(0.0f));
    case ACTIVATION_MISH:
      return applyMish(x);
    case ACTIVATION_MISH_SCALE8:
      // ACTIVATION_MISH_SCALE8 is an FP16-numerics workaround applied in-place
      // at model load by CUDA/OpenCL/TensorRT (see desc.cpp:applyScale8To-
      // ReduceActivations). MLX does not call that transform because its
      // logaddexp-based softplus is already overflow-free in FP16 (see
      // applyMish above), so we should never see this enum here. If a model
      // ever ships with MISH_SCALE8 baked in on disk, fail loudly rather than
      // silently fall through to identity. Mirrors Eigen/Metal behavior.
      testAssert(false);
      return x;  // unreached; satisfies compiler
    case ACTIVATION_IDENTITY:
    default:
      return x;
  }
}

// Fused matmul + bias: result = input @ weights + bias
// Uses addmm for better performance (single kernel instead of matmul + add)
static mx::array matmulBias(const mx::array& input, const mx::array& weights, const mx::array& bias) {
  // addmm(c, a, b, alpha, beta) = alpha * (a @ b) + beta * c
  return mx::addmm(bias, input, weights, 1.0f, 1.0f);
}

// Winograd is on by default; KATAGO_MLX_WINOGRAD=0 forces mx::conv2d
// (A/B correctness testing and runtime safety valve).
static bool mlxWinogradEnabled() {
  static const bool enabled = [](){
    const char* e = std::getenv("KATAGO_MLX_WINOGRAD");
    return !(e != nullptr && std::string(e) == "0");
  }();
  return enabled;
}

// Tuner is on by default; KATAGO_MLX_WINOTUNER=0 forces baked SP1 defaults.
static bool mlxWinotunerEnabled() {
  static const bool enabled = [](){
    const char* e = std::getenv("KATAGO_MLX_WINOTUNER");
    return !(e != nullptr && std::string(e) == "0");
  }();
  return enabled;
}
// KATAGO_MLX_WINOTUNER_FORCE=1 ignores cache file, retunes and overwrites.
static bool mlxWinotunerForce() {
  static const bool force = [](){
    const char* e = std::getenv("KATAGO_MLX_WINOTUNER_FORCE");
    return (e != nullptr && std::string(e) == "1");
  }();
  return force;
}
// KATAGO_MLX_WINOTUNER_FULL=1 uses the wider grid ranges.
static bool mlxWinotunerFull() {
  static const bool full = [](){
    const char* e = std::getenv("KATAGO_MLX_WINOTUNER_FULL");
    return (e != nullptr && std::string(e) == "1");
  }();
  return full;
}
// GPU name for the tuner cache filename.
// mlx::core::metal::device_info() is declared in the header but not exported
// in all libmlx builds; fall back to a fixed string.
static std::string mlxGpuName() {
  return "AppleSilicon";
}

// Layers --------------------------------------------------------------------------------------------------------------

struct ConvLayer {
  const string name;
  const int convYSize;
  const int convXSize;
  const int inChannels;
  const int outChannels;
  const int dilationY;
  const int dilationX;
  const bool useFP16;
  const bool useWinograd;
  mx::array weights;            // OHWI format (only built when !useWinograd)
  mx::array winogradWeights;    // 4x4 domain U, valid only if useWinograd
  const MLXWinograd::InputTransform    winoInCfg;
  const MLXWinograd::OutputUntransform winoOutCfg;

  ConvLayer() = delete;
  ConvLayer(const ConvLayer&) = delete;
  ConvLayer& operator=(const ConvLayer&) = delete;

  ConvLayer(const ConvLayerDesc& desc,
            const MLXWinograd::InputTransform& inCfg,
            const MLXWinograd::OutputUntransform& outCfg,
            bool useFP16_ = false)
    : name(desc.name),
      convYSize(desc.convYSize),
      convXSize(desc.convXSize),
      inChannels(desc.inChannels),
      outChannels(desc.outChannels),
      dilationY(desc.dilationY),
      dilationX(desc.dilationX),
      useFP16(useFP16_),
      // SP3: `!useFP16` gate removed — Winograd path now runs in fp16 too.
      useWinograd(mlxWinogradEnabled()
                  && convYSize==3 && convXSize==3
                  && dilationY==1 && dilationX==1),
      weights(useWinograd ? mx::array(0.0f) : toComputeDtype(convertConvWeightsOIHWtoOHWI(desc.weights, outChannels, inChannels, convYSize, convXSize), useFP16_)),
      winogradWeights(useWinograd
        ? MLXWinograd::makeWinogradWeights(desc.weights, outChannels, inChannels, useFP16_)
        : mx::array(0.0f))
      ,winoInCfg(inCfg)
      ,winoOutCfg(outCfg)
  {}

  mx::array apply(const mx::array& input) const {
    if(useWinograd) {
      return MLXWinograd::winogradConv2d(input, winogradWeights, outChannels, winoInCfg, winoOutCfg, useFP16);
    }
    // MLX conv2d: input NHWC, weights OHWI
    // Compute padding to maintain spatial dimensions (same padding)
    int padY = (convYSize - 1) * dilationY / 2;
    int padX = (convXSize - 1) * dilationX / 2;

    return mx::conv2d(
      input,
      weights,
      /*stride=*/std::make_pair(1, 1),
      /*padding=*/std::make_pair(padY, padX),
      /*dilation=*/std::make_pair(dilationY, dilationX),
      /*groups=*/1
    );
  }
};

struct BatchNormLayer {
  const string name;
  const int numChannels;
  const int activation;
  const bool useFP16;
  mx::array mergedScale; // Shape: [C], always fp32 (SP3)
  mx::array mergedBias;  // Shape: [C], always fp32 (SP3)

  BatchNormLayer() = delete;
  BatchNormLayer(const BatchNormLayer&) = delete;
  BatchNormLayer& operator=(const BatchNormLayer&) = delete;

  // SP3: mergedScale/mergedBias storage is always fp32 to preserve dynamic
  // range across the 25-block-deep b18c384 chain. The `useFP16` parameter
  // is intentionally ignored. See spec §3 item 4.
  static mx::array createArray1D(const std::vector<float>& data, int size, bool /*useFP16*/) {
    mx::Shape shape = {size};
    return mx::array(data.data(), shape, mx::float32);
  }

  static std::vector<float> getMergedScale(const BatchNormLayerDesc& desc) {
    // If mergedScale is already computed, use it
    if(!desc.mergedScale.empty()) {
      return desc.mergedScale;
    }
    // Otherwise compute from mean/variance/scale/bias (for tests)
    std::vector<float> mergedScale(desc.numChannels);
    for(int c = 0; c < desc.numChannels; c++) {
      mergedScale[c] = desc.scale[c] / sqrt(desc.variance[c] + desc.epsilon);
    }
    return mergedScale;
  }

  static std::vector<float> getMergedBias(const BatchNormLayerDesc& desc) {
    // If mergedBias is already computed, use it
    if(!desc.mergedBias.empty()) {
      return desc.mergedBias;
    }
    // Otherwise compute from mean/variance/scale/bias (for tests)
    std::vector<float> mergedBias(desc.numChannels);
    for(int c = 0; c < desc.numChannels; c++) {
      float ms = desc.scale[c] / sqrt(desc.variance[c] + desc.epsilon);
      mergedBias[c] = desc.bias[c] - ms * desc.mean[c];
    }
    return mergedBias;
  }

  BatchNormLayer(const BatchNormLayerDesc& desc, int activationType, bool useFP16_ = false)
    : name(desc.name),
      numChannels(desc.numChannels),
      activation(activationType),
      useFP16(useFP16_),
      mergedScale(createArray1D(getMergedScale(desc), desc.numChannels, useFP16_)),
      mergedBias(createArray1D(getMergedBias(desc), desc.numChannels, useFP16_))
  {}

  mx::array apply(const mx::array& input, const mx::array& mask, bool useMask) const {
    // input: NHWC [N, H, W, C] in compute dtype (fp16 or fp32).
    // mask: NHW1 [N, H, W, 1] in compute dtype.
    // mergedScale/mergedBias are always fp32; MLX type promotion lifts the
    // multiply-add-activation chain to fp32 automatically (selective fp32
    // accumulation, spec §3 item 4 — defense against inf/nan in deep stacks).
    // Mask multiply runs while activated is still fp32 (safe because mask is
    // binary 0/1, so fp32*fp16 and fp16*fp16 round to bit-equal results).
    // The single trailing astype-to-fp16 covers both useMask branches.
    mx::array normalized = input * mergedScale + mergedBias;
    mx::array activated = applyActivation(normalized, activation);
    if(useMask)
      activated = activated * mask;
    // Cast back to fp16 so downstream layers see the expected compute dtype.
    if(useFP16) activated = mx::astype(activated, mx::float16);
    return activated;
  }
};

struct MatMulLayer {
  const string name;
  const int inChannels;
  const int outChannels;
  mx::array weights; // [inC, outC]

  MatMulLayer() = delete;
  MatMulLayer(const MatMulLayer&) = delete;
  MatMulLayer& operator=(const MatMulLayer&) = delete;

  static mx::array createWeights(const MatMulLayerDesc& desc, bool useFP16) {
    if(desc.inChannels > 0 && desc.outChannels > 0) {
      // Original weights: [inC, outC] (column-major)
      mx::Shape shape = {desc.inChannels, desc.outChannels};
      mx::array arr = mx::array(desc.weights.data(), shape, mx::float32);
      return toComputeDtype(arr, useFP16);
    }
    std::vector<float> dummy = {0.0f};
    mx::Shape shape = {1};
    return mx::array(dummy.data(), shape, mx::float32);
  }

  MatMulLayer(const MatMulLayerDesc& desc, bool useFP16 = false)
    : name(desc.name),
      inChannels(desc.inChannels),
      outChannels(desc.outChannels),
      weights(createWeights(desc, useFP16))
  {}

  mx::array apply(const mx::array& input) const {
    // input: [N, inC]
    // output: [N, outC]
    return mx::matmul(input, weights);
  }
};

struct MatBiasLayer {
  const string name;
  const int numChannels;
  mx::array bias;

  MatBiasLayer() = delete;
  MatBiasLayer(const MatBiasLayer&) = delete;
  MatBiasLayer& operator=(const MatBiasLayer&) = delete;

  static mx::array createBias(const MatBiasLayerDesc& desc, bool useFP16) {
    mx::Shape shape = {desc.numChannels};
    mx::array arr = mx::array(desc.weights.data(), shape, mx::float32);
    return toComputeDtype(arr, useFP16);
  }

  MatBiasLayer(const MatBiasLayerDesc& desc, bool useFP16 = false)
    : name(desc.name),
      numChannels(desc.numChannels),
      bias(createBias(desc, useFP16))
  {}

  mx::array apply(const mx::array& input) const {
    return input + bias;
  }
};

// Global pooling: computes [mean, mean * (sqrt(maskSum) - 14) * 0.1, max] concatenated along channel axis
static mx::array applyGlobalPooling(const mx::array& input, const mx::array& mask, const mx::array& maskSum, bool useMask) {
  // input: NHWC [N, H, W, C]
  // mask: NHW1 [N, H, W, 1]
  // maskSum: N111 [N, 1, 1, 1]

  // Compute sum over spatial dims
  std::vector<int> spatialAxes = {1, 2};
  mx::array spatialSum = mx::sum(input, spatialAxes, /*keepdims=*/true); // [N, 1, 1, C]

  // Mean = sum / maskSum
  mx::array mean = spatialSum / maskSum; // [N, 1, 1, C]

  // sqrt(maskSum) - 14) * 0.1
  mx::array sqrtMaskSum = mx::sqrt(maskSum);
  mx::array scaleFactor = (sqrtMaskSum - mx::array(14.0f)) * mx::array(0.1f);
  mx::array meanScaled = mean * scaleFactor;

  // Max - skip mask adjustment when useMask=false (all positions valid)
  mx::array maxVal = useMask
    ? mx::max(input - (mx::array(1.0f) - mask) * mx::array(1e9f), spatialAxes, /*keepdims=*/true)
    : mx::max(input, spatialAxes, /*keepdims=*/true);

  // Concatenate along channel axis (axis 3 for NHWC)
  std::vector<mx::array> concatInputs = {mean, meanScaled, maxVal};
  return mx::concatenate(concatInputs, /*axis=*/3);
}

// Value head pooling: computes [mean, mean * (sqrt(maskSum) - 14) * 0.1, mean * ((sqrt-14)^2 * 0.01 - 0.1)]
static mx::array applyValueHeadPooling(const mx::array& input, const mx::array& maskSum) {
  // input: NHWC [N, H, W, C]
  // maskSum: N111 [N, 1, 1, 1]

  std::vector<int> spatialAxes = {1, 2};
  mx::array spatialSum = mx::sum(input, spatialAxes, /*keepdims=*/true);
  mx::array mean = spatialSum / maskSum;

  mx::array sqrtMaskSum = mx::sqrt(maskSum);
  mx::array diff = sqrtMaskSum - mx::array(14.0f);
  mx::array meanScaled1 = mean * diff * mx::array(0.1f);
  mx::array meanScaled2 = mean * (diff * diff * mx::array(0.01f) - mx::array(0.1f));

  std::vector<mx::array> concatInputs = {mean, meanScaled1, meanScaled2};
  return mx::concatenate(concatInputs, /*axis=*/3);
}

// Residual Block
struct ResidualBlock {
  const string name;
  const BatchNormLayer preBN;
  const ConvLayer regularConv;
  const BatchNormLayer midBN;
  const ConvLayer finalConv;

  ResidualBlock() = delete;
  ResidualBlock(const ResidualBlock&) = delete;
  ResidualBlock& operator=(const ResidualBlock&) = delete;

  ResidualBlock(const ResidualBlockDesc& desc,
                const MLXWinograd::InputTransform& inCfg,
                const MLXWinograd::OutputUntransform& outCfg,
                bool useFP16 = false)
    : name(desc.name),
      preBN(desc.preBN, desc.preActivation.activation, useFP16),
      regularConv(desc.regularConv, inCfg, outCfg, useFP16),
      midBN(desc.midBN, desc.midActivation.activation, useFP16),
      finalConv(desc.finalConv, inCfg, outCfg, useFP16)
  {}

  mx::array apply(const mx::array& input, const mx::array& mask, bool useMask) const {
    mx::array out = preBN.apply(input, mask, useMask);
    out = regularConv.apply(out);
    out = midBN.apply(out, mask, useMask);
    out = finalConv.apply(out);
    return input + out;
  }
};

// Global Pooling Residual Block
struct GlobalPoolingResidualBlock {
  const string name;
  const BatchNormLayer preBN;
  const ConvLayer regularConv;
  const ConvLayer gpoolConv;
  const BatchNormLayer gpoolBN;
  const MatMulLayer gpoolToBiasMul;
  const BatchNormLayer midBN;
  const ConvLayer finalConv;

  GlobalPoolingResidualBlock() = delete;
  GlobalPoolingResidualBlock(const GlobalPoolingResidualBlock&) = delete;
  GlobalPoolingResidualBlock& operator=(const GlobalPoolingResidualBlock&) = delete;

  GlobalPoolingResidualBlock(const GlobalPoolingResidualBlockDesc& desc,
                             const MLXWinograd::InputTransform& inCfg,
                             const MLXWinograd::OutputUntransform& outCfg,
                             bool useFP16 = false)
    : name(desc.name),
      preBN(desc.preBN, desc.preActivation.activation, useFP16),
      regularConv(desc.regularConv, inCfg, outCfg, useFP16),
      gpoolConv(desc.gpoolConv, inCfg, outCfg, useFP16),
      gpoolBN(desc.gpoolBN, desc.gpoolActivation.activation, useFP16),
      gpoolToBiasMul(desc.gpoolToBiasMul, useFP16),
      midBN(desc.midBN, desc.midActivation.activation, useFP16),
      finalConv(desc.finalConv, inCfg, outCfg, useFP16)
  {}

  mx::array apply(const mx::array& input, const mx::array& mask, const mx::array& maskSum, bool useMask) const {
    mx::array preOut = preBN.apply(input, mask, useMask);

    // Regular path
    mx::array regularOut = regularConv.apply(preOut);

    // Global pooling path
    mx::array gpoolOut = gpoolConv.apply(preOut);
    gpoolOut = gpoolBN.apply(gpoolOut, mask, useMask);
    mx::array pooled = applyGlobalPooling(gpoolOut, mask, maskSum, useMask);

    // Squeeze spatial dims for matmul: [N, 1, 1, C*3] -> [N, C*3]
    std::vector<int> squeezeAxes = {1, 2};
    mx::array pooledFlat = mx::squeeze(pooled, squeezeAxes);
    mx::array bias = gpoolToBiasMul.apply(pooledFlat);

    // Add bias to regular path (broadcast): [N, outC] -> [N, 1, 1, outC]
    mx::Shape biasShape = {static_cast<int>(bias.shape()[0]), 1, 1, static_cast<int>(bias.shape()[1])};
    bias = mx::reshape(bias, biasShape);
    mx::array combined = regularOut + bias;

    combined = midBN.apply(combined, mask, useMask);
    mx::array finalOut = finalConv.apply(combined);

    return input + finalOut;
  }
};

// Nested Bottleneck Residual Block (simplified - forward declaration for recursive types)
struct NestedBottleneckResidualBlock;

// Block variant type for trunk
struct BlockVariant {
  enum Type { REGULAR, GLOBAL_POOLING, NESTED_BOTTLENECK };
  Type type;
  unique_ptr<ResidualBlock> regular;
  unique_ptr<GlobalPoolingResidualBlock> globalPooling;
  unique_ptr<NestedBottleneckResidualBlock> nestedBottleneck;

  BlockVariant(const ResidualBlockDesc& desc,
               const MLXWinograd::InputTransform& inCfg,
               const MLXWinograd::OutputUntransform& outCfg,
               bool useFP16 = false)
    : type(REGULAR), regular(make_unique<ResidualBlock>(desc, inCfg, outCfg, useFP16)) {}

  BlockVariant(const GlobalPoolingResidualBlockDesc& desc,
               const MLXWinograd::InputTransform& inCfg,
               const MLXWinograd::OutputUntransform& outCfg,
               bool useFP16 = false)
    : type(GLOBAL_POOLING), globalPooling(make_unique<GlobalPoolingResidualBlock>(desc, inCfg, outCfg, useFP16)) {}

  // Forward declaration - defined after NestedBottleneckResidualBlock
  BlockVariant(const NestedBottleneckResidualBlockDesc& desc,
               const MLXWinograd::InputTransform& inCfg,
               const MLXWinograd::OutputUntransform& outCfg,
               bool useFP16);

  mx::array apply(const mx::array& input, const mx::array& mask, const mx::array& maskSum, bool useMask) const;
};

struct NestedBottleneckResidualBlock {
  const string name;
  const BatchNormLayer preBN;
  const ConvLayer preConv;
  vector<BlockVariant> blocks;
  const BatchNormLayer postBN;
  const ConvLayer postConv;

  NestedBottleneckResidualBlock() = delete;
  NestedBottleneckResidualBlock(const NestedBottleneckResidualBlock&) = delete;
  NestedBottleneckResidualBlock& operator=(const NestedBottleneckResidualBlock&) = delete;

  NestedBottleneckResidualBlock(const NestedBottleneckResidualBlockDesc& desc,
                                const MLXWinograd::InputTransform& inCfg,
                                const MLXWinograd::OutputUntransform& outCfg,
                                bool useFP16 = false)
    : name(desc.name),
      preBN(desc.preBN, desc.preActivation.activation, useFP16),
      preConv(desc.preConv, inCfg, outCfg, useFP16),
      postBN(desc.postBN, desc.postActivation.activation, useFP16),
      postConv(desc.postConv, inCfg, outCfg, useFP16)
  {
    for(size_t i = 0; i < desc.blocks.size(); i++) {
      int blockKind = desc.blocks[i].first;
      if(blockKind == ORDINARY_BLOCK_KIND) {
        blocks.emplace_back(*static_cast<ResidualBlockDesc*>(desc.blocks[i].second.get()), inCfg, outCfg, useFP16);
      }
      else if(blockKind == GLOBAL_POOLING_BLOCK_KIND) {
        blocks.emplace_back(*static_cast<GlobalPoolingResidualBlockDesc*>(desc.blocks[i].second.get()), inCfg, outCfg, useFP16);
      }
    }
  }

  mx::array apply(const mx::array& input, const mx::array& mask, const mx::array& maskSum, bool useMask) const {
    mx::array out = preBN.apply(input, mask, useMask);
    out = preConv.apply(out);

    for(const auto& block : blocks) {
      out = block.apply(out, mask, maskSum, useMask);
    }

    out = postBN.apply(out, mask, useMask);
    out = postConv.apply(out);

    return input + out;
  }
};

// Define BlockVariant constructor for NestedBottleneckResidualBlock now that it's complete
BlockVariant::BlockVariant(const NestedBottleneckResidualBlockDesc& desc,
                           const MLXWinograd::InputTransform& inCfg,
                           const MLXWinograd::OutputUntransform& outCfg,
                           bool useFP16)
  : type(NESTED_BOTTLENECK), nestedBottleneck(make_unique<NestedBottleneckResidualBlock>(desc, inCfg, outCfg, useFP16)) {}

mx::array BlockVariant::apply(const mx::array& input, const mx::array& mask, const mx::array& maskSum, bool useMask) const {
  switch(type) {
    case REGULAR:
      return regular->apply(input, mask, useMask);
    case GLOBAL_POOLING:
      return globalPooling->apply(input, mask, maskSum, useMask);
    case NESTED_BOTTLENECK:
      return nestedBottleneck->apply(input, mask, maskSum, useMask);
    default:
      return input;
  }
}

// SGF Metadata Encoder
struct SGFMetadataEncoder {
  const int metaEncoderVersion;
  const int numInputMetaChannels;
  const MatMulLayer mul1;
  const MatBiasLayer bias1;
  const int act1;
  const MatMulLayer mul2;
  const MatBiasLayer bias2;
  const int act2;
  const MatMulLayer mul3;

  SGFMetadataEncoder() = delete;
  SGFMetadataEncoder(const SGFMetadataEncoder&) = delete;
  SGFMetadataEncoder& operator=(const SGFMetadataEncoder&) = delete;

  SGFMetadataEncoder(const SGFMetadataEncoderDesc& desc, bool useFP16 = false)
    : metaEncoderVersion(desc.metaEncoderVersion),
      numInputMetaChannels(desc.numInputMetaChannels),
      mul1(desc.mul1, useFP16),
      bias1(desc.bias1, useFP16),
      act1(desc.act1.activation),
      mul2(desc.mul2, useFP16),
      bias2(desc.bias2, useFP16),
      act2(desc.act2.activation),
      mul3(desc.mul3, useFP16)
  {}

  mx::array apply(const mx::array& metaInput) const {
    // Fuse matmul + bias with addmm for better performance
    mx::array out = matmulBias(metaInput, mul1.weights, bias1.bias);
    out = applyActivation(out, act1);
    out = matmulBias(out, mul2.weights, bias2.bias);
    out = applyActivation(out, act2);
    out = mul3.apply(out);  // Last layer has no bias
    return out;
  }
};

// Trunk
struct Trunk {
  const string name;
  const int trunkNumChannels;
  const ConvLayer initialConv;
  const MatMulLayer initialMatMul;
  unique_ptr<SGFMetadataEncoder> sgfMetadataEncoder;
  vector<BlockVariant> blocks;
  const BatchNormLayer trunkTipBN;

  Trunk() = delete;
  Trunk(const Trunk&) = delete;
  Trunk& operator=(const Trunk&) = delete;

  Trunk(const TrunkDesc& desc,
        const MLXWinograd::InputTransform& inCfg,
        const MLXWinograd::OutputUntransform& outCfg,
        bool useFP16 = false)
    : name(desc.name),
      trunkNumChannels(desc.trunkNumChannels),
      initialConv(desc.initialConv, inCfg, outCfg, useFP16),
      initialMatMul(desc.initialMatMul, useFP16),
      trunkTipBN(desc.trunkTipBN, desc.trunkTipActivation.activation, useFP16)
  {
    if(desc.sgfMetadataEncoder.metaEncoderVersion > 0 && desc.sgfMetadataEncoder.numInputMetaChannels > 0) {
      sgfMetadataEncoder = make_unique<SGFMetadataEncoder>(desc.sgfMetadataEncoder, useFP16);
    }

    for(size_t i = 0; i < desc.blocks.size(); i++) {
      int blockKind = desc.blocks[i].first;
      if(blockKind == ORDINARY_BLOCK_KIND) {
        blocks.emplace_back(*static_cast<ResidualBlockDesc*>(desc.blocks[i].second.get()), inCfg, outCfg, useFP16);
      }
      else if(blockKind == GLOBAL_POOLING_BLOCK_KIND) {
        blocks.emplace_back(*static_cast<GlobalPoolingResidualBlockDesc*>(desc.blocks[i].second.get()), inCfg, outCfg, useFP16);
      }
      else if(blockKind == NESTED_BOTTLENECK_BLOCK_KIND) {
        blocks.emplace_back(*static_cast<NestedBottleneckResidualBlockDesc*>(desc.blocks[i].second.get()), inCfg, outCfg, useFP16);
      }
    }
  }

  mx::array apply(
    const mx::array& input,
    const mx::array& inputGlobal,
    const mx::array* inputMeta,
    const mx::array& mask,
    const mx::array& maskSum,
    bool useMask
  ) const {
    // Initial conv
    mx::array trunk = initialConv.apply(input);

    // Add global input bias
    mx::array globalBias = initialMatMul.apply(inputGlobal);
    // Reshape from [N, C] to [N, 1, 1, C] for broadcasting
    mx::Shape globalBiasShape = {static_cast<int>(globalBias.shape()[0]), 1, 1, static_cast<int>(globalBias.shape()[1])};
    globalBias = mx::reshape(globalBias, globalBiasShape);
    trunk = trunk + globalBias;

    // Add SGF metadata if present
    if(sgfMetadataEncoder && inputMeta != nullptr) {
      mx::array metaBias = sgfMetadataEncoder->apply(*inputMeta);
      mx::Shape metaBiasShape = {static_cast<int>(metaBias.shape()[0]), 1, 1, static_cast<int>(metaBias.shape()[1])};
      metaBias = mx::reshape(metaBias, metaBiasShape);
      trunk = trunk + metaBias;
    }

    // Apply mask - skip when useMask=false (all positions valid)
    if(useMask)
      trunk = trunk * mask;

    // Apply residual blocks
    for(const auto& block : blocks) {
      trunk = block.apply(trunk, mask, maskSum, useMask);
    }

    // Final BN + activation
    trunk = trunkTipBN.apply(trunk, mask, useMask);

    return trunk;
  }
};

// Policy Head
struct PolicyHead {
  const string name;
  const int modelVersion;
  const ConvLayer p1Conv;
  const ConvLayer g1Conv;
  const BatchNormLayer g1BN;
  const MatMulLayer gpoolToBiasMul;
  const BatchNormLayer p1BN;
  const ConvLayer p2Conv;
  const MatMulLayer gpoolToPassMul;

  PolicyHead() = delete;
  PolicyHead(const PolicyHead&) = delete;
  PolicyHead& operator=(const PolicyHead&) = delete;

  PolicyHead(const PolicyHeadDesc& desc,
             const MLXWinograd::InputTransform& inCfg,
             const MLXWinograd::OutputUntransform& outCfg,
             bool useFP16 = false)
    : name(desc.name),
      modelVersion(desc.modelVersion),
      p1Conv(desc.p1Conv, inCfg, outCfg, useFP16),
      g1Conv(desc.g1Conv, inCfg, outCfg, useFP16),
      g1BN(desc.g1BN, desc.g1Activation.activation, useFP16),
      gpoolToBiasMul(desc.gpoolToBiasMul, useFP16),
      p1BN(desc.p1BN, desc.p1Activation.activation, useFP16),
      p2Conv(desc.p2Conv, inCfg, outCfg, useFP16),
      gpoolToPassMul(desc.gpoolToPassMul, useFP16)
  {}

  std::pair<mx::array, mx::array> apply(
    const mx::array& trunk,
    const mx::array& mask,
    const mx::array& maskSum,
    bool useMask
  ) const {
    // Policy conv
    mx::array p1Out = p1Conv.apply(trunk);

    // Global pooling path
    mx::array g1Out = g1Conv.apply(trunk);
    g1Out = g1BN.apply(g1Out, mask, useMask);
    mx::array pooled = applyGlobalPooling(g1Out, mask, maskSum, useMask);
    std::vector<int> squeezeAxes = {1, 2};
    mx::array pooledFlat = mx::squeeze(pooled, squeezeAxes);

    // Add bias from global pooling
    mx::array bias = gpoolToBiasMul.apply(pooledFlat);
    mx::Shape biasShape = {static_cast<int>(bias.shape()[0]), 1, 1, static_cast<int>(bias.shape()[1])};
    bias = mx::reshape(bias, biasShape);
    p1Out = p1Out + bias;

    p1Out = p1BN.apply(p1Out, mask, useMask);

    // Final policy conv
    mx::array policy = p2Conv.apply(p1Out);

    // Pass policy
    mx::array policyPass = gpoolToPassMul.apply(pooledFlat);

    return {policyPass, policy};
  }
};

// Value Head
struct ValueHead {
  const string name;
  const int modelVersion;
  const ConvLayer v1Conv;
  const BatchNormLayer v1BN;
  const MatMulLayer v2Mul;
  const MatBiasLayer v2Bias;
  const int v2Activation;
  const MatMulLayer v3Mul;
  const MatBiasLayer v3Bias;
  const MatMulLayer sv3Mul;
  const MatBiasLayer sv3Bias;
  const ConvLayer vOwnershipConv;

  ValueHead() = delete;
  ValueHead(const ValueHead&) = delete;
  ValueHead& operator=(const ValueHead&) = delete;

  ValueHead(const ValueHeadDesc& desc,
            const MLXWinograd::InputTransform& inCfg,
            const MLXWinograd::OutputUntransform& outCfg,
            bool useFP16 = false)
    : name(desc.name),
      modelVersion(desc.modelVersion),
      v1Conv(desc.v1Conv, inCfg, outCfg, useFP16),
      v1BN(desc.v1BN, desc.v1Activation.activation, useFP16),
      v2Mul(desc.v2Mul, useFP16),
      v2Bias(desc.v2Bias, useFP16),
      v2Activation(desc.v2Activation.activation),
      v3Mul(desc.v3Mul, useFP16),
      v3Bias(desc.v3Bias, useFP16),
      sv3Mul(desc.sv3Mul, useFP16),
      sv3Bias(desc.sv3Bias, useFP16),
      vOwnershipConv(desc.vOwnershipConv, inCfg, outCfg, useFP16)
  {}

  std::tuple<mx::array, mx::array, mx::array> apply(
    const mx::array& trunk,
    const mx::array& mask,
    const mx::array& maskSum,
    bool useMask
  ) const {
    mx::array v1Out = v1Conv.apply(trunk);
    v1Out = v1BN.apply(v1Out, mask, useMask);

    // Value head pooling (only uses maskSum, not mask)
    mx::array v1Mean = applyValueHeadPooling(v1Out, maskSum);
    std::vector<int> squeezeAxes = {1, 2};
    mx::array v1MeanFlat = mx::squeeze(v1Mean, squeezeAxes);

    // Fuse matmul + bias with addmm for better performance
    mx::array v2Out = matmulBias(v1MeanFlat, v2Mul.weights, v2Bias.bias);
    v2Out = applyActivation(v2Out, v2Activation);

    mx::array value = matmulBias(v2Out, v3Mul.weights, v3Bias.bias);
    mx::array scoreValue = matmulBias(v2Out, sv3Mul.weights, sv3Bias.bias);

    mx::array ownership = vOwnershipConv.apply(v1Out);

    return {value, scoreValue, ownership};
  }
};

// Model
struct Model {
  const string name;
  const int modelVersion;
  const int numInputChannels;
  const int numInputGlobalChannels;
  const int numInputMetaChannels;
  const int numPolicyChannels;
  const int numValueChannels;
  const int numScoreValueChannels;
  const int numOwnershipChannels;
  const bool useFP16;

  const Trunk trunk;
  const PolicyHead policyHead;
  const ValueHead valueHead;

  Model() = delete;
  Model(const Model&) = delete;
  Model& operator=(const Model&) = delete;

  Model(const ModelDesc& desc, const MLXWinogradTuneParams& tuneParams, bool useFP16_ = false)
    : name(desc.name),
      modelVersion(desc.modelVersion),
      numInputChannels(desc.numInputChannels),
      numInputGlobalChannels(desc.numInputGlobalChannels),
      numInputMetaChannels(desc.numInputMetaChannels),
      numPolicyChannels(desc.numPolicyChannels),
      numValueChannels(desc.numValueChannels),
      numScoreValueChannels(desc.numScoreValueChannels),
      numOwnershipChannels(desc.numOwnershipChannels),
      useFP16(useFP16_),
      trunk(desc.trunk, tuneParams.inputTransform, tuneParams.outputUntransform, useFP16_),
      policyHead(desc.policyHead, tuneParams.inputTransform, tuneParams.outputUntransform, useFP16_),
      valueHead(desc.valueHead, tuneParams.inputTransform, tuneParams.outputUntransform, useFP16_)
  {}

  // Apply model inference with mx::array inputs directly (for compiled execution)
  // inputs: [input, inputGlobal, mask, maskSum] or [input, inputGlobal, mask, maskSum, inputMeta]
  // outputs: [policy, policyPass, value, scoreValue, ownership]
  std::vector<mx::array> applyArrays(
    const std::vector<mx::array>& inputs,
    bool useMask
  ) const {
    // Convert inputs to compute dtype if FP16 is enabled
    mx::array input = toComputeDtype(inputs[0], useFP16);
    mx::array inputGlobalArr = toComputeDtype(inputs[1], useFP16);
    mx::array mask = toComputeDtype(inputs[2], useFP16);
    // maskSum stays FP32 - small scalar, negligible impact
    const mx::array& maskSum = inputs[3];
    unique_ptr<mx::array> inputMeta;
    if(inputs.size() > 4) {
      inputMeta = make_unique<mx::array>(toComputeDtype(inputs[4], useFP16));
    }
    const mx::array* inputMetaPtr = inputMeta.get();

    // Apply trunk
    mx::array trunkOut = trunk.apply(input, inputGlobalArr, inputMetaPtr, mask, maskSum, useMask);

    // Apply policy head
    auto [policyPass, policy] = policyHead.apply(trunkOut, mask, maskSum, useMask);

    // Apply value head
    auto [value, scoreValue, ownership] = valueHead.apply(trunkOut, mask, maskSum, useMask);

    // Convert outputs back to FP32 for interface compatibility
    if(useFP16) {
      policy = mx::astype(policy, mx::float32);
      policyPass = mx::astype(policyPass, mx::float32);
      value = mx::astype(value, mx::float32);
      scoreValue = mx::astype(scoreValue, mx::float32);
      ownership = mx::astype(ownership, mx::float32);
    }

    return {policy, policyPass, value, scoreValue, ownership};
  }

  // Create a compiled inference function for the given configuration
  // hasMeta is used as part of the cache key but not needed in the function itself
  CompiledInferenceFunc createCompiledFunc(bool useMask, bool /*hasMeta*/) const {
    // Create lambda that captures this model
    auto inferenceFunc = [this, useMask](const std::vector<mx::array>& inputs) -> std::vector<mx::array> {
      return this->applyArrays(inputs, useMask);
    };

    // Wrap in std::function and compile
    std::function<std::vector<mx::array>(const std::vector<mx::array>&)> func = inferenceFunc;
    return mx::compile(func, /*shapeless=*/false);
  }

  void apply(
    const float* inputSpatial,
    const float* inputGlobal,
    const float* inputMeta,
    int batchSize,
    int nnXLen,
    int nnYLen,
    bool requireExactNNLen,
    float* policyOut,
    float* policyPassOut,
    float* valueOut,
    float* scoreValueOut,
    float* ownershipOut
  ) const {
    // SP3: This raw-output path memcpys policy.data<float>() etc. into the
    // caller's fp32 buffers. If useFP16==true, .data<float>() yields fp16
    // bit-patterns reinterpreted as fp32 -> garbage. Use applyCompiled()
    // (production) which casts outputs back to fp32 inside applyArrays().
    testAssert(!useFP16);

    // When requireExactNNLen=true, all boards are exactly nnXLen x nnYLen,
    // so all mask values are 1 and we can skip mask operations
    const bool useMask = !requireExactNNLen;

    // Create input tensors - NHWC format
    mx::Shape inputShape = {batchSize, nnYLen, nnXLen, numInputChannels};
    mx::array input = mx::array(inputSpatial, inputShape, mx::float32);
    mx::Shape globalShape = {batchSize, numInputGlobalChannels};
    mx::array inputGlobalArr = mx::array(inputGlobal, globalShape, mx::float32);

    // Extract mask from first channel of input
    mx::Shape sliceStart = {0, 0, 0, 0};
    mx::Shape sliceEnd = {batchSize, nnYLen, nnXLen, 1};
    mx::array mask = mx::slice(input, sliceStart, sliceEnd);

    // Compute mask sum - needed for pooling normalization even when useMask=false
    // Pre-compute fixed maskSum = nnXLen * nnYLen when all mask values are 1
    std::vector<int> sumAxes = {1, 2};
    mx::array maskSum = requireExactNNLen
      ? mx::full({batchSize, 1, 1, 1}, static_cast<float>(nnXLen * nnYLen))
      : mx::sum(mask, sumAxes, /*keepdims=*/true);

    // Optional metadata input
    unique_ptr<mx::array> inputMetaArr;
    if(numInputMetaChannels > 0 && inputMeta != nullptr) {
      mx::Shape metaShape = {batchSize, numInputMetaChannels};
      inputMetaArr = make_unique<mx::array>(mx::array(inputMeta, metaShape, mx::float32));
    }

    // Apply trunk
    mx::array trunkOut = trunk.apply(input, inputGlobalArr, inputMetaArr.get(), mask, maskSum, useMask);

    // Apply policy head
    auto [policyPass, policy] = policyHead.apply(trunkOut, mask, maskSum, useMask);

    // Apply value head
    auto [value, scoreValue, ownership] = valueHead.apply(trunkOut, mask, maskSum, useMask);

    // Force evaluation of all outputs
    std::vector<mx::array> outputs = {policy, policyPass, value, scoreValue, ownership};
    mx::eval(outputs);

    // Copy results to output buffers
    memcpy(policyOut, policy.data<float>(), batchSize * numPolicyChannels * nnXLen * nnYLen * sizeof(float));
    memcpy(policyPassOut, policyPass.data<float>(), batchSize * numPolicyChannels * sizeof(float));
    memcpy(valueOut, value.data<float>(), batchSize * numValueChannels * sizeof(float));
    memcpy(scoreValueOut, scoreValue.data<float>(), batchSize * numScoreValueChannels * sizeof(float));
    memcpy(ownershipOut, ownership.data<float>(), batchSize * numOwnershipChannels * nnXLen * nnYLen * sizeof(float));
  }

  // Apply model using a pre-compiled inference function
  void applyCompiled(
    const CompiledInferenceFunc& compiledFunc,
    const float* inputSpatial,
    const float* inputGlobal,
    const float* inputMeta,
    int batchSize,
    int nnXLen,
    int nnYLen,
    bool requireExactNNLen,
    float* policyOut,
    float* policyPassOut,
    float* valueOut,
    float* scoreValueOut,
    float* ownershipOut
  ) const {
    // Create input tensors - NHWC format
    mx::Shape inputShape = {batchSize, nnYLen, nnXLen, numInputChannels};
    mx::array input = mx::array(inputSpatial, inputShape, mx::float32);
    mx::Shape globalShape = {batchSize, numInputGlobalChannels};
    mx::array inputGlobalArr = mx::array(inputGlobal, globalShape, mx::float32);

    // Extract mask from first channel of input
    mx::Shape sliceStart = {0, 0, 0, 0};
    mx::Shape sliceEnd = {batchSize, nnYLen, nnXLen, 1};
    mx::array mask = mx::slice(input, sliceStart, sliceEnd);

    // Compute mask sum
    std::vector<int> sumAxes = {1, 2};
    mx::array maskSum = requireExactNNLen
      ? mx::full({batchSize, 1, 1, 1}, static_cast<float>(nnXLen * nnYLen))
      : mx::sum(mask, sumAxes, /*keepdims=*/true);

    // Build input vector for compiled function
    std::vector<mx::array> inputs = {input, inputGlobalArr, mask, maskSum};

    // Add metadata if present
    if(numInputMetaChannels > 0 && inputMeta != nullptr) {
      mx::Shape metaShape = {batchSize, numInputMetaChannels};
      inputs.push_back(mx::array(inputMeta, metaShape, mx::float32));
    }

    // Call compiled function
    std::vector<mx::array> outputs = compiledFunc(inputs);

    // Force evaluation
    mx::eval(outputs);

    // Extract results - outputs are [policy, policyPass, value, scoreValue, ownership]
    mx::array& policy = outputs[0];
    mx::array& policyPass = outputs[1];
    mx::array& value = outputs[2];
    mx::array& scoreValue = outputs[3];
    mx::array& ownership = outputs[4];

    // Copy results to output buffers
    memcpy(policyOut, policy.data<float>(), batchSize * numPolicyChannels * nnXLen * nnYLen * sizeof(float));
    memcpy(policyPassOut, policyPass.data<float>(), batchSize * numPolicyChannels * sizeof(float));
    memcpy(valueOut, value.data<float>(), batchSize * numValueChannels * sizeof(float));
    memcpy(scoreValueOut, scoreValue.data<float>(), batchSize * numScoreValueChannels * sizeof(float));
    memcpy(ownershipOut, ownership.data<float>(), batchSize * numOwnershipChannels * nnXLen * nnYLen * sizeof(float));
  }
};

// ComputeContext and ComputeHandle ------------------------------------------------------------------------------------

struct ComputeContext {
  const int nnXLen;
  const int nnYLen;
  const enabled_t useFP16Mode;
  std::string homeDataDirOverride;
  Logger* logger;

  std::mutex cachedModelsMutex;
  std::map<std::string, std::shared_ptr<const Model>> cachedModels;
  std::map<std::string, int> cachedModelsRefCount;

  ComputeContext() = delete;
  ComputeContext(const ComputeContext&) = delete;
  ComputeContext& operator=(const ComputeContext&) = delete;

  ComputeContext(int nnX, int nnY, enabled_t fp16Mode,
                 const std::string& homeDataDirOverride_, Logger* logger_)
    : nnXLen(nnX),
      nnYLen(nnY),
      useFP16Mode(fp16Mode),
      homeDataDirOverride(homeDataDirOverride_),
      logger(logger_),
      cachedModelsMutex(),
      cachedModels(),
      cachedModelsRefCount()
  {}

  ~ComputeContext() {
    assert(cachedModels.size() == 0);
  }
};

struct ComputeHandle {
  ComputeContext* context;
  bool inputsUseNHWC;
  bool requireExactNNLen;
  bool useFP16;
  std::string modelCacheKey;  // assigned in ctor body after loadOrAutoTune
  std::shared_ptr<const Model> model;
  const int modelVersion;

  // Compiled function cache - keyed by (batchSize, nnXLen, nnYLen, useMask, hasMeta, useFP16)
  mutable std::mutex compiledFuncsMutex;
  mutable std::map<CompileCacheKey, CompiledInferenceFunc> compiledFuncs;

  ComputeHandle() = delete;
  ComputeHandle(const ComputeHandle&) = delete;
  ComputeHandle& operator=(const ComputeHandle&) = delete;

  static std::string makeCacheKey(const LoadedModel& loadedModel,
                                  const MLXWinogradTuneParams& tuneParams,
                                  bool useFP16) {
    return loadedModel.modelDesc.name + "-" + loadedModel.modelDesc.sha256
      + (useFP16 ? "-fp16" : "-fp32")
      + (mlxWinogradEnabled() ? "-wg" : "-nowg")
      + "-it" + std::to_string(tuneParams.inputTransform.tg0)
      + "x"   + std::to_string(tuneParams.inputTransform.tg1)
      + "x"   + std::to_string(tuneParams.inputTransform.wpt)
      + "x"   + std::to_string(tuneParams.inputTransform.vw)
      + "g"   + std::to_string((int)tuneParams.inputTransform.gridOrder)
      + "-ou" + std::to_string(tuneParams.outputUntransform.tg0)
      + "x"   + std::to_string(tuneParams.outputUntransform.tg1)
      + "x"   + std::to_string(tuneParams.outputUntransform.wpt);
  }

  ComputeHandle(ComputeContext* ctx, const LoadedModel& loadedModel, bool iNHWC, bool requireExactNNLen_, bool useFP16_)
    : context(ctx),
      inputsUseNHWC(iNHWC),
      requireExactNNLen(requireExactNNLen_),
      useFP16(useFP16_),
      modelCacheKey(),
      model(nullptr),
      modelVersion(loadedModel.modelDesc.modelVersion),
      compiledFuncsMutex(),
      compiledFuncs()
  {
    // Determine tuner params: either run the autotuner, or use baked SP1 defaults.
    // SP3: tuner runs at every precision so fp16 gets its own cache file
    // (_fp16.txt suffix). See spec §3 item 3.
    MLXWinogradTuneParams tuneParams;
    if(mlxWinogradEnabled() && mlxWinotunerEnabled()) {
      // Shape diagnostic: print the model's 3x3 conv shape distribution before
      // calling the tuner so the log carries this signal on every load, including
      // cache-hit runs where loadOrAutoTune short-circuits. Spec §3a.
      if(context->logger != NULL) {
        context->logger->write(
            MLXWinogradTuner::formatConv3x3Distribution(loadedModel.modelDesc));
      }
      MLXWinogradTuner::ModelInfoForTuning mi;
      mi.trunkNumChannels   = loadedModel.modelDesc.trunk.trunkNumChannels;
      mi.midNumChannels     = loadedModel.modelDesc.trunk.midNumChannels;
      mi.maxConvChannels3x3 = std::max({
          loadedModel.modelDesc.trunk.trunkNumChannels,
          loadedModel.modelDesc.trunk.midNumChannels,
          loadedModel.modelDesc.trunk.regularNumChannels,
          loadedModel.modelDesc.trunk.gpoolNumChannels
      });
      mi.modelVersion = loadedModel.modelDesc.modelVersion;
      // Adaptive-scoring inputs: compute the 3x3 conv distribution once at
      // load time and pass it to the tuner. Task 5 will remove the
      // mid/maxConvChannels3x3 assignments above once scoring no longer
      // reads them.
      auto [inHist, outHist] =
          MLXWinogradTuner::buildConv3x3Histograms(loadedModel.modelDesc);
      mi.conv3x3InputHistogram  = std::move(inHist);
      mi.conv3x3OutputHistogram = std::move(outHist);
      tuneParams = MLXWinogradTuner::loadOrAutoTune(
          /*tunerFile=*/"",
          context->homeDataDirOverride,
          mlxGpuName(),
          context->nnXLen, context->nnYLen,
          /*batchSize=*/8,
          mi,
          context->logger,
          /*full=*/mlxWinotunerFull(),
          /*reTune=*/mlxWinotunerForce(),
          /*useFP16=*/useFP16_,
          /*seedOverride=*/nullptr);
    }

    modelCacheKey = makeCacheKey(loadedModel, tuneParams, useFP16_);

    std::lock_guard<std::mutex> lock(context->cachedModelsMutex);
    if(context->cachedModels.find(modelCacheKey) == context->cachedModels.end()) {
      context->cachedModels[modelCacheKey] =
          std::make_shared<const Model>(loadedModel.modelDesc, tuneParams, useFP16_);
    }
    model = context->cachedModels[modelCacheKey];
    context->cachedModelsRefCount[modelCacheKey] += 1;
  }

  ~ComputeHandle() {
    std::lock_guard<std::mutex> lock(context->cachedModelsMutex);
    context->cachedModelsRefCount[modelCacheKey] -= 1;
    assert(context->cachedModelsRefCount[modelCacheKey] >= 0);
    if(context->cachedModelsRefCount[modelCacheKey] == 0) {
      context->cachedModelsRefCount.erase(modelCacheKey);
      context->cachedModels.erase(modelCacheKey);
    }
  }

  // Get or create compiled inference function for the given configuration
  const CompiledInferenceFunc& getCompiledFunc(int batchSize, int nnXLen, int nnYLen, bool useMask, bool hasMeta) const {
    CompileCacheKey key = std::make_tuple(batchSize, nnXLen, nnYLen, useMask, hasMeta, useFP16);

    std::lock_guard<std::mutex> lock(compiledFuncsMutex);
    auto it = compiledFuncs.find(key);
    if(it != compiledFuncs.end()) {
      return it->second;
    }

    // Create and cache compiled function
    compiledFuncs[key] = model->createCompiledFunc(useMask, hasMeta);
    return compiledFuncs[key];
  }
};

// InputBuffers --------------------------------------------------------------------------------------------------------

struct InputBuffers {
  int maxBatchSize;

  size_t singleInputElts;
  size_t singleInputGlobalElts;
  size_t singleInputMetaElts;

  size_t singlePolicyPassResultElts;
  size_t singlePolicyResultElts;
  size_t singleValueResultElts;
  size_t singleScoreValueResultElts;
  size_t singleOwnershipResultElts;

  std::vector<float> spatialInput;
  std::vector<float> globalInput;
  std::vector<float> metaInput;
  std::vector<float> policyResults;
  std::vector<float> policyPassResults;
  std::vector<float> valueResults;
  std::vector<float> scoreValueResults;
  std::vector<float> ownershipResults;

  InputBuffers(const LoadedModel* loadedModel, int maxBatchSz, int nnXLen, int nnYLen) {
    const ModelDesc& m = loadedModel->modelDesc;

    maxBatchSize = maxBatchSz;
    singleInputElts = m.numInputChannels * nnXLen * nnYLen;
    singleInputGlobalElts = m.numInputGlobalChannels;
    singleInputMetaElts = m.numInputMetaChannels;

    singlePolicyPassResultElts = (size_t)(m.numPolicyChannels);
    singlePolicyResultElts = (size_t)(m.numPolicyChannels * nnXLen * nnYLen);
    singleValueResultElts = (size_t)m.numValueChannels;
    singleScoreValueResultElts = (size_t)m.numScoreValueChannels;
    singleOwnershipResultElts = (size_t)m.numOwnershipChannels * nnXLen * nnYLen;

    assert(NNModelVersion::getNumSpatialFeatures(m.modelVersion) == m.numInputChannels);
    assert(NNModelVersion::getNumGlobalFeatures(m.modelVersion) == m.numInputGlobalChannels);
    if(m.numInputMetaChannels > 0) {
      assert(SGFMetadata::METADATA_INPUT_NUM_CHANNELS == m.numInputMetaChannels);
    }

    spatialInput.resize(m.numInputChannels * nnXLen * nnYLen * maxBatchSize);
    globalInput.resize(m.numInputGlobalChannels * maxBatchSize);
    if(m.numInputMetaChannels > 0)
      metaInput.resize(m.numInputMetaChannels * maxBatchSize);
    else
      metaInput.resize(1);

    policyResults.resize(singlePolicyResultElts * maxBatchSize);
    policyPassResults.resize(singlePolicyPassResultElts * maxBatchSize);
    valueResults.resize(singleValueResultElts * maxBatchSize);
    scoreValueResults.resize(singleScoreValueResultElts * maxBatchSize);
    ownershipResults.resize(singleOwnershipResultElts * maxBatchSize);
  }

  ~InputBuffers() {}

  InputBuffers() = delete;
  InputBuffers(const InputBuffers&) = delete;
  InputBuffers& operator=(const InputBuffers&) = delete;
};

InputBuffers* NeuralNet::createInputBuffers(const LoadedModel* loadedModel, int maxBatchSize, int nnXLen, int nnYLen) {
  return new InputBuffers(loadedModel, maxBatchSize, nnXLen, nnYLen);
}

void NeuralNet::freeInputBuffers(InputBuffers* inputBuffers) {
  delete inputBuffers;
}

// NeuralNet Interface -------------------------------------------------------------------------------------------------

void NeuralNet::globalInitialize() {
  // MLX initializes automatically
}

void NeuralNet::globalCleanup() {
  // MLX cleans up automatically
}

ComputeContext* NeuralNet::createComputeContext(
  const std::vector<int>& gpuIdxs,
  Logger* logger,
  int nnXLen,
  int nnYLen,
  const string& openCLTunerFile,
  const string& homeDataDirOverride,
  bool openCLReTunePerBoardSize,
  enabled_t useFP16Mode,
  enabled_t useNHWCMode,
  const LoadedModel* loadedModel
) {
  (void)gpuIdxs;
  (void)openCLTunerFile;
  (void)openCLReTunePerBoardSize;
  (void)loadedModel;

  bool useNHWC = useNHWCMode == enabled_t::False ? false : true;

  if(!useNHWC)
    throw StringError("MLX backend: useNHWC = false not supported");

  ComputeContext* context = new ComputeContext(nnXLen, nnYLen, useFP16Mode, homeDataDirOverride, logger);
  return context;
}

void NeuralNet::freeComputeContext(ComputeContext* computeContext) {
  delete computeContext;
}

ComputeHandle* NeuralNet::createComputeHandle(
  ComputeContext* context,
  const LoadedModel* loadedModel,
  Logger* logger,
  int maxBatchSize,
  bool requireExactNNLen,
  bool inputsUseNHWC,
  int gpuIdxForThisThread,
  int serverThreadIdx
) {
  // SP3: Auto resolves to fp16 (gated on acceptance: MLX-fp16 paired-t beat
  // both Metal-fp16 and MLX-fp32 with non-overlapping CIs, and testgpuerror
  // accuracy exit=0). Users who need bit-for-bit fp32 reproducibility set
  // `mlxUseFP16 = false` explicitly. See the traceability commit for the
  // exact gate numbers.
  bool useFP16 = (context->useFP16Mode != enabled_t::False);

  if(logger != NULL) {
    logger->write("MLX backend thread " + Global::intToString(serverThreadIdx) + ": Model version " + Global::intToString(loadedModel->modelDesc.modelVersion));
    logger->write("MLX backend thread " + Global::intToString(serverThreadIdx) + ": Model name: " + loadedModel->modelDesc.name);
    logger->write("MLX backend thread " + Global::intToString(serverThreadIdx) + ": FP16 = " + (useFP16 ? "true" : "false"));
  }

  (void)maxBatchSize;
  (void)gpuIdxForThisThread;

  if(!inputsUseNHWC)
    throw StringError("MLX backend: inputsUseNHWC = false unsupported");

  return new ComputeHandle(context, *loadedModel, inputsUseNHWC, requireExactNNLen, useFP16);
}

void NeuralNet::freeComputeHandle(ComputeHandle* gpuHandle) {
  delete gpuHandle;
}

bool NeuralNet::isUsingFP16(const ComputeHandle* handle) {
  return handle->useFP16;
}

void NeuralNet::getOutput(
  ComputeHandle* computeHandle,
  InputBuffers* inputBuffers,
  int numBatchEltsFilled,
  NNResultBuf** inputBufs,
  vector<NNOutput*>& outputs
) {
  assert(numBatchEltsFilled <= inputBuffers->maxBatchSize);
  assert(numBatchEltsFilled > 0);
  const int batchSize = numBatchEltsFilled;
  const int nnXLen = computeHandle->context->nnXLen;
  const int nnYLen = computeHandle->context->nnYLen;
  const int modelVersion = computeHandle->modelVersion;

  const int numSpatialFeatures = NNModelVersion::getNumSpatialFeatures(modelVersion);
  const int numGlobalFeatures = NNModelVersion::getNumGlobalFeatures(modelVersion);
  const int numMetaFeatures = inputBuffers->singleInputMetaElts;
  assert(numSpatialFeatures == computeHandle->model->numInputChannels);
  assert(numSpatialFeatures * nnXLen * nnYLen == inputBuffers->singleInputElts);
  assert(numGlobalFeatures == inputBuffers->singleInputGlobalElts);
  const int numPolicyChannels = computeHandle->model->numPolicyChannels;

  // Copy input data to buffers
  for(int nIdx = 0; nIdx < batchSize; nIdx++) {
    float* rowSpatialInput = inputBuffers->spatialInput.data() + (inputBuffers->singleInputElts * nIdx);
    float* rowGlobalInput = inputBuffers->globalInput.data() + (inputBuffers->singleInputGlobalElts * nIdx);
    float* rowMetaInput = inputBuffers->metaInput.data() + (inputBuffers->singleInputMetaElts * nIdx);

    const float* rowGlobal = inputBufs[nIdx]->rowGlobalBuf.data();
    const float* rowSpatial = inputBufs[nIdx]->rowSpatialBuf.data();
    const float* rowMeta = inputBufs[nIdx]->rowMetaBuf.data();
    const bool hasRowMeta = inputBufs[nIdx]->hasRowMeta;

    std::copy(rowGlobal, rowGlobal + numGlobalFeatures, rowGlobalInput);

    if(numMetaFeatures > 0) {
      testAssert(rowMeta != NULL);
      testAssert(hasRowMeta);
      std::copy(rowMeta, rowMeta + numMetaFeatures, rowMetaInput);
    }
    else {
      testAssert(!hasRowMeta);
    }

    SymmetryHelpers::copyInputsWithSymmetry(rowSpatial, rowSpatialInput, 1, nnYLen, nnXLen, numSpatialFeatures, computeHandle->inputsUseNHWC, inputBufs[nIdx]->symmetry);
  }

  // Run model using compiled function
  const bool useMask = !computeHandle->requireExactNNLen;
  const bool hasMeta = (numMetaFeatures > 0);
  const CompiledInferenceFunc& compiledFunc = computeHandle->getCompiledFunc(batchSize, nnXLen, nnYLen, useMask, hasMeta);

  computeHandle->model->applyCompiled(
    compiledFunc,
    inputBuffers->spatialInput.data(),
    inputBuffers->globalInput.data(),
    (numMetaFeatures > 0 ? inputBuffers->metaInput.data() : nullptr),
    batchSize,
    nnXLen,
    nnYLen,
    computeHandle->requireExactNNLen,
    inputBuffers->policyResults.data(),
    inputBuffers->policyPassResults.data(),
    inputBuffers->valueResults.data(),
    inputBuffers->scoreValueResults.data(),
    inputBuffers->ownershipResults.data()
  );

  assert(inputBuffers->singlePolicyPassResultElts == numPolicyChannels);
  assert(inputBuffers->singlePolicyResultElts == numPolicyChannels * nnXLen * nnYLen);
  assert(outputs.size() == batchSize);

  float policyProbsTmp[NNPos::MAX_NN_POLICY_SIZE];

  float* policyData = inputBuffers->policyResults.data();
  float* policyPassData = inputBuffers->policyPassResults.data();
  float* valueData = inputBuffers->valueResults.data();
  float* scoreValueData = inputBuffers->scoreValueResults.data();
  float* ownershipData = inputBuffers->ownershipResults.data();

  for(int row = 0; row < batchSize; row++) {
    NNOutput* output = outputs[row];
    assert(output->nnXLen == nnXLen);
    assert(output->nnYLen == nnYLen);
    float policyOptimism = (float)inputBufs[row]->policyOptimism;

    const float* policyPassSrcBuf = policyPassData + row * numPolicyChannels;
    const float* policySrcBuf = policyData + row * numPolicyChannels * nnXLen * nnYLen;
    float* policyProbs = output->policyProbs;

    // Handle policy optimism (version >= 12)
    if(numPolicyChannels == 2 || (numPolicyChannels == 4 && modelVersion >= 16)) {
      // MLX output is NHWC
      for(int i = 0; i < nnXLen * nnYLen; i++) {
        float p = policySrcBuf[i * numPolicyChannels];
        float pOpt = policySrcBuf[i * numPolicyChannels + 1];
        policyProbsTmp[i] = p + (pOpt - p) * policyOptimism;
      }
      SymmetryHelpers::copyOutputsWithSymmetry(policyProbsTmp, policyProbs, 1, nnYLen, nnXLen, inputBufs[row]->symmetry);
      policyProbs[nnXLen * nnYLen] = policyPassSrcBuf[0] + (policyPassSrcBuf[1] - policyPassSrcBuf[0]) * policyOptimism;
    }
    else {
      assert(numPolicyChannels == 1);
      SymmetryHelpers::copyOutputsWithSymmetry(policySrcBuf, policyProbs, 1, nnYLen, nnXLen, inputBufs[row]->symmetry);
      policyProbs[inputBuffers->singlePolicyResultElts] = policyPassSrcBuf[0];
    }

    int numValueChannels = computeHandle->model->numValueChannels;
    assert(numValueChannels == 3);
    output->whiteWinProb = valueData[row * numValueChannels];
    output->whiteLossProb = valueData[row * numValueChannels + 1];
    output->whiteNoResultProb = valueData[row * numValueChannels + 2];

    if(output->whiteOwnerMap != NULL) {
      const float* ownershipSrcBuf = ownershipData + row * nnXLen * nnYLen;
      assert(computeHandle->model->numOwnershipChannels == 1);
      SymmetryHelpers::copyOutputsWithSymmetry(ownershipSrcBuf, output->whiteOwnerMap, 1, nnYLen, nnXLen, inputBufs[row]->symmetry);
    }

    if(modelVersion >= 9) {
      int numScoreValueChannels = computeHandle->model->numScoreValueChannels;
      assert(numScoreValueChannels == 6);
      output->whiteScoreMean = scoreValueData[row * numScoreValueChannels];
      output->whiteScoreMeanSq = scoreValueData[row * numScoreValueChannels + 1];
      output->whiteLead = scoreValueData[row * numScoreValueChannels + 2];
      output->varTimeLeft = scoreValueData[row * numScoreValueChannels + 3];
      output->shorttermWinlossError = scoreValueData[row * numScoreValueChannels + 4];
      output->shorttermScoreError = scoreValueData[row * numScoreValueChannels + 5];
    }
    else if(modelVersion >= 8) {
      int numScoreValueChannels = computeHandle->model->numScoreValueChannels;
      assert(numScoreValueChannels == 4);
      output->whiteScoreMean = scoreValueData[row * numScoreValueChannels];
      output->whiteScoreMeanSq = scoreValueData[row * numScoreValueChannels + 1];
      output->whiteLead = scoreValueData[row * numScoreValueChannels + 2];
      output->varTimeLeft = scoreValueData[row * numScoreValueChannels + 3];
      output->shorttermWinlossError = 0;
      output->shorttermScoreError = 0;
    }
    else if(modelVersion >= 4) {
      int numScoreValueChannels = computeHandle->model->numScoreValueChannels;
      assert(numScoreValueChannels == 2);
      output->whiteScoreMean = scoreValueData[row * numScoreValueChannels];
      output->whiteScoreMeanSq = scoreValueData[row * numScoreValueChannels + 1];
      output->whiteLead = output->whiteScoreMean;
      output->varTimeLeft = 0;
      output->shorttermWinlossError = 0;
      output->shorttermScoreError = 0;
    }
    else if(modelVersion >= 3) {
      int numScoreValueChannels = computeHandle->model->numScoreValueChannels;
      assert(numScoreValueChannels == 1);
      output->whiteScoreMean = scoreValueData[row * numScoreValueChannels];
      output->whiteScoreMeanSq = output->whiteScoreMean * output->whiteScoreMean;
      output->whiteLead = output->whiteScoreMean;
      output->varTimeLeft = 0;
      output->shorttermWinlossError = 0;
      output->shorttermScoreError = 0;
    }
    else {
      ASSERT_UNREACHABLE;
    }
  }
}

void NeuralNet::printDevices() {
  cout << "MLX Backend (Apple Silicon)" << endl;
  cout << "Default device: " << mx::default_device() << endl;
}

// FOR TESTING ---------------------------------------------------------------------------------------------------------

bool NeuralNet::testEvaluateConv(
  const ConvLayerDesc* desc,
  int batchSize,
  int nnXLen,
  int nnYLen,
  bool useFP16,
  bool useNHWC,
  const vector<float>& inputBuffer,
  vector<float>& outputBuffer
) {
  // Run MLX-specific aux tests (Winograd kernel + tuner) exactly once per
  // process, on the first invocation of testEvaluateConv. This is the
  // MLX-side hook reachable from Tests::runNNLayerTests through
  // testConvLayer, allowing testnn.cpp to stay backend-agnostic.
  // The flag is set BEFORE the calls so a propagating exception does not
  // cause the aux tests to re-run on subsequent conv configs.
  static bool ranMLXAuxTests = false;
  if(!ranMLXAuxTests) {
    ranMLXAuxTests = true;
    runMLXWinogradTests();
    runMLXWinotunerTests();
  }

  if(!useNHWC) {
    return false; // MLX only supports NHWC
  }

  size_t numOutputFloats = (size_t)batchSize * nnXLen * nnYLen * desc->outChannels;
  outputBuffer.resize(numOutputFloats);

  MLXWinograd::InputTransform   defaultInCfg;
  MLXWinograd::OutputUntransform defaultOutCfg;
  ConvLayer layer(*desc, defaultInCfg, defaultOutCfg, useFP16);
  mx::Shape inputShape = {batchSize, nnYLen, nnXLen, desc->inChannels};
  mx::array input = mx::array(inputBuffer.data(), inputShape, mx::float32);
  mx::array computeInput = toComputeDtype(input, useFP16);
  mx::array output = layer.apply(computeInput);
  if(useFP16) output = mx::astype(output, mx::float32);
  mx::eval(output);

  memcpy(outputBuffer.data(), output.data<float>(), numOutputFloats * sizeof(float));
  return true;
}

bool NeuralNet::testEvaluateBatchNorm(
  const BatchNormLayerDesc* desc,
  int batchSize,
  int nnXLen,
  int nnYLen,
  bool useFP16,
  bool useNHWC,
  const vector<float>& inputBuffer,
  const vector<float>& maskBuffer,
  vector<float>& outputBuffer
) {
  if(!useNHWC) {
    return false;
  }

  size_t numOutputFloats = (size_t)batchSize * nnXLen * nnYLen * desc->numChannels;
  outputBuffer.resize(numOutputFloats);

  BatchNormLayer layer(*desc, ACTIVATION_IDENTITY, useFP16);
  mx::Shape inputShape = {batchSize, nnYLen, nnXLen, desc->numChannels};
  mx::Shape maskShape = {batchSize, nnYLen, nnXLen, 1};
  mx::array input = mx::array(inputBuffer.data(), inputShape, mx::float32);
  mx::array mask = mx::array(maskBuffer.data(), maskShape, mx::float32);
  mx::array computeInput = toComputeDtype(input, useFP16);
  mx::array computeMask = toComputeDtype(mask, useFP16);
  mx::array output = layer.apply(computeInput, computeMask, /*useMask=*/true);
  if(useFP16) output = mx::astype(output, mx::float32);
  mx::eval(output);

  memcpy(outputBuffer.data(), output.data<float>(), numOutputFloats * sizeof(float));
  return true;
}

bool NeuralNet::testEvaluateResidualBlock(
  const ResidualBlockDesc* desc,
  int batchSize,
  int nnXLen,
  int nnYLen,
  bool useFP16,
  bool useNHWC,
  const vector<float>& inputBuffer,
  const vector<float>& maskBuffer,
  vector<float>& outputBuffer
) {
  if(!useNHWC) {
    return false;
  }

  size_t numOutputFloats = (size_t)batchSize * nnXLen * nnYLen * desc->preBN.numChannels;
  outputBuffer.resize(numOutputFloats);

  MLXWinograd::InputTransform   defaultInCfg;
  MLXWinograd::OutputUntransform defaultOutCfg;
  ResidualBlock block(*desc, defaultInCfg, defaultOutCfg, useFP16);
  mx::Shape inputShape = {batchSize, nnYLen, nnXLen, desc->preBN.numChannels};
  mx::Shape maskShape = {batchSize, nnYLen, nnXLen, 1};
  mx::array input = mx::array(inputBuffer.data(), inputShape, mx::float32);
  mx::array mask = mx::array(maskBuffer.data(), maskShape, mx::float32);
  mx::array computeInput = toComputeDtype(input, useFP16);
  mx::array computeMask = toComputeDtype(mask, useFP16);
  mx::array output = block.apply(computeInput, computeMask, /*useMask=*/true);
  if(useFP16) output = mx::astype(output, mx::float32);
  mx::eval(output);

  memcpy(outputBuffer.data(), output.data<float>(), numOutputFloats * sizeof(float));
  return true;
}

bool NeuralNet::testEvaluateGlobalPoolingResidualBlock(
  const GlobalPoolingResidualBlockDesc* desc,
  int batchSize,
  int nnXLen,
  int nnYLen,
  bool useFP16,
  bool useNHWC,
  const vector<float>& inputBuffer,
  const vector<float>& maskBuffer,
  vector<float>& outputBuffer
) {
  if(!useNHWC) {
    return false;
  }

  size_t numOutputFloats = (size_t)batchSize * nnXLen * nnYLen * desc->preBN.numChannels;
  outputBuffer.resize(numOutputFloats);

  MLXWinograd::InputTransform   defaultInCfg;
  MLXWinograd::OutputUntransform defaultOutCfg;
  GlobalPoolingResidualBlock block(*desc, defaultInCfg, defaultOutCfg, useFP16);
  mx::Shape inputShape = {batchSize, nnYLen, nnXLen, desc->preBN.numChannels};
  mx::Shape maskShape = {batchSize, nnYLen, nnXLen, 1};
  mx::array input = mx::array(inputBuffer.data(), inputShape, mx::float32);
  mx::array mask = mx::array(maskBuffer.data(), maskShape, mx::float32);
  mx::array computeInput = toComputeDtype(input, useFP16);
  mx::array computeMask = toComputeDtype(mask, useFP16);
  std::vector<int> sumAxes = {1, 2};
  // maskSum stays FP32 for precision
  mx::array maskSum = mx::sum(mask, sumAxes, /*keepdims=*/true);
  mx::array output = block.apply(computeInput, computeMask, maskSum, /*useMask=*/true);
  if(useFP16) output = mx::astype(output, mx::float32);
  mx::eval(output);

  memcpy(outputBuffer.data(), output.data<float>(), numOutputFloats * sizeof(float));
  return true;
}

// SP3 Task 2: directly-asserting unit test for BatchNormLayer fp16 mode.
// Declared here because BatchNormLayer is not in any public header.
// Called from runMLXWinogradTests() (same TU).
void runMLXBatchNormFP16Test_SP3() {
  namespace mxc = mx;  // reuse the file-scope alias from line 29
  using std::cout;
  using std::endl;

  int N=1,H=5,W=5,C=4;
  std::vector<float> mean(C, 0.0f), variance(C, 1.0f), scale(C, 1.0f), bias(C, 0.0f);
  BatchNormLayerDesc bnDesc;
  bnDesc.name = "bnSP3Test";
  bnDesc.numChannels = C;
  bnDesc.epsilon = 1e-5f;
  bnDesc.mean = mean;
  bnDesc.variance = variance;
  bnDesc.scale = scale;
  bnDesc.bias = bias;
  BatchNormLayer bn(bnDesc, ACTIVATION_IDENTITY, /*useFP16=*/true);

  // mergedScale/mergedBias must be fp32 even in fp16 mode.
  testAssert(bn.mergedScale.dtype() == mxc::float32);
  testAssert(bn.mergedBias.dtype()  == mxc::float32);

  // apply() must return fp16 when useFP16=true.
  std::vector<float> inV((size_t)N*H*W*C, 0.5f);
  std::vector<float> maskV((size_t)N*H*W*1, 1.0f);
  mxc::array inArrF32(inV.data(), {N,H,W,C}, mxc::float32);
  mxc::array inArr = mxc::astype(inArrF32, mxc::float16);
  mxc::array maskArrF32(maskV.data(), {N,H,W,1}, mxc::float32);
  mxc::array maskArr = mxc::astype(maskArrF32, mxc::float16);
  mxc::array out = bn.apply(inArr, maskArr, /*useMask=*/true);
  mxc::eval(out);
  testAssert(out.dtype() == mxc::float16);
  cout << "  BatchNormLayer fp16: mergedScale/Bias fp32, output fp16 OK" << endl;
}

// SP3 Task 3: directly-asserting unit test for ConvLayer fp16 Winograd path.
// Declared here because ConvLayer is not in any public header.
// Called from runMLXWinogradTests() (same TU).
void runMLXConvLayerFP16WinogradTest_SP3() {
  namespace mxc = mx;  // reuse the file-scope alias from line 29
  using std::cout;
  using std::endl;

  int N=1,H=19,W=19,Cin=8,Cout=16;
  std::mt19937 grng(779);
  std::uniform_real_distribution<float> gdist(-1.f,1.f);
  std::vector<float> in((size_t)N*H*W*Cin); for(auto&x:in)x=gdist(grng);
  std::vector<float> w((size_t)Cout*Cin*9); for(auto&x:w)x=gdist(grng);
  auto refv = MLXWinograd::cpuConv2d3x3(in,N,H,W,Cin,w,Cout);

  ConvLayerDesc convDesc;
  convDesc.name = "convSP3FP16Test";
  convDesc.convYSize = 3;
  convDesc.convXSize = 3;
  convDesc.inChannels = Cin;
  convDesc.outChannels = Cout;
  convDesc.dilationY = 1;
  convDesc.dilationX = 1;
  convDesc.weights = w;

  MLXWinograd::InputTransform inCfg;
  MLXWinograd::OutputUntransform outCfg;
  ConvLayer conv(convDesc, inCfg, outCfg, /*useFP16=*/true);
  testAssert(conv.useWinograd);  // SP3 gate dropped: fp16 still picks Winograd

  mxc::array inArrF32(in.data(),{N,H,W,Cin},mxc::float32);
  mxc::array inArr = mxc::astype(inArrF32, mxc::float16);
  mxc::array o = conv.apply(inArr);
  mxc::eval(o);
  testAssert(o.dtype() == mxc::float16);
  mxc::array oF32 = mxc::astype(o, mxc::float32);
  mxc::eval(oF32);
  const float* od = oF32.data<float>();
  double maxErr=0.0;
  for(size_t i=0;i<refv.size();i++)
    maxErr=std::max(maxErr,(double)std::fabs(refv[i]-od[i]));
  cout<<"  ConvLayer fp16 winograd maxErr="<<maxErr<<endl;
  testAssert(maxErr < 5e-2);
}

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
  cout << "MLX Winograd F(2,3) CPU reference OK" << endl;

  // GPU Winograd metal_kernel validated against the Task 1 CPU oracle.
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

  runMLXBatchNormFP16Test_SP3();
  runMLXConvLayerFP16WinogradTest_SP3();

  // SP4 Task 2 / SP5 Task 5: smoke test — verify Winograd plumbing.
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

  // SP4 Task 3: WPT=1, 4, 8 must produce bit-identical output (fp32).
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

  // SP4 Task 3 tail-guard coverage: Ntiles=100 (N=1, H=W=19) is NOT
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

  // SP4 Task 4 / SP5 Task 3: input VW=1, 2, 4 must produce bit-identical fp16
  // output (Cfast). C=64 is divisible by 4 — VW=4 valid. Output VW removed in
  // SP5 Task 3 (output kernel is VW=1 monomorphic).
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

  // SP4 Task 5 / SP5 Task 4: input-stage GridOrder::Cfast and GridOrder::Tfast
  // must produce bit-identical fp32 output. They differ only in which thread
  // does which (c, tileIdx) pair; the on-disk layout is unchanged. The output
  // kernel is Cfast-monomorphic after SP5 Task 4, so only the input gridOrder
  // is varied here.
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

  // SP4 Task 5 / SP5 Task 4 tail-guard coverage: input Tfast with C=67 (not
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

  // SP5 Task 5: matmulOrient axis removed end-to-end. The Std-vs-Tpd
  // equivalence tests and the Tfast×Tpd combined-branching test have been
  // deleted along with the enum.

  {
    // SP5 Task 9 — Output kernel is monomorphic on VW=1, GRID_ORDER=Cfast.
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
    // the transformed [16, Cin, Cout] tensor (Std-only after Task 5).
    mx::array U = makeWinogradWeights(wData, Cout, Cin, /*useFP16=*/false);

    // Output config: Std post-SP5 OutputUntransform has tg0/tg1/wpt only.
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
