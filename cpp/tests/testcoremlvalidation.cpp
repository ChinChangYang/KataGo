/*
 * testcoremlvalidation.cpp
 *
 * Standalone test program for cross-validating KataGo Eigen backend output
 * against Core ML converted models.
 *
 * Usage:
 *   ./testcoremlvalidation <model.bin.gz> <input.json>
 *
 * Input JSON format:
 *   {
 *     "spatial_input": [[[...]]], // [C, H, W] in NCHW format
 *     "global_input": [...],      // [G]
 *     "input_mask": [[...]]       // [H, W]
 *   }
 *
 * Output JSON format (to stdout):
 *   {
 *     "policy": [[[...]]],        // [policy_channels, H, W]
 *     "pass_policy": [...],       // [policy_channels]
 *     "value": [...],             // [3]
 *     "ownership": [[...]],       // [H, W]
 *     "score_value": [...]        // [6]
 *   }
 */

#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <cmath>
#include <cassert>

#include "../core/global.h"
#include "../core/config_parser.h"
#include "../core/fileutils.h"
#include "../core/mainargs.h"
#include "../neuralnet/nninterface.h"
#include "../neuralnet/nninputs.h"
#include "../neuralnet/nneval.h"
#include "../external/nlohmann_json/json.hpp"

using namespace std;
using json = nlohmann::json;

// Constants
static const int BOARD_SIZE = 19;

// Convert NCHW to NHWC format (for Eigen backend)
static vector<float> nchwToNhwc(const vector<float>& nchw, int c, int h, int w) {
  vector<float> nhwc(nchw.size());
  for(int ci = 0; ci < c; ci++) {
    for(int hi = 0; hi < h; hi++) {
      for(int wi = 0; wi < w; wi++) {
        int nchw_idx = ci * h * w + hi * w + wi;
        int nhwc_idx = hi * w * c + wi * c + ci;
        nhwc[nhwc_idx] = nchw[nchw_idx];
      }
    }
  }
  return nhwc;
}

// Convert NHWC to NCHW format (for output)
static vector<float> nhwcToNchw(const vector<float>& nhwc, int c, int h, int w) {
  vector<float> nchw(nhwc.size());
  for(int ci = 0; ci < c; ci++) {
    for(int hi = 0; hi < h; hi++) {
      for(int wi = 0; wi < w; wi++) {
        int nchw_idx = ci * h * w + hi * w + wi;
        int nhwc_idx = hi * w * c + wi * c + ci;
        nchw[nchw_idx] = nhwc[nhwc_idx];
      }
    }
  }
  return nchw;
}

// Parse spatial input from JSON (NCHW format)
static vector<float> parseSpatialInput(const json& j, int& numChannels) {
  if(!j.is_array()) {
    throw runtime_error("spatial_input must be an array");
  }

  numChannels = j.size();
  int h = BOARD_SIZE;
  int w = BOARD_SIZE;

  vector<float> spatial(numChannels * h * w);

  for(int c = 0; c < numChannels; c++) {
    if(!j[c].is_array() || j[c].size() != (size_t)h) {
      throw runtime_error("spatial_input channel must be HxW array");
    }
    for(int hi = 0; hi < h; hi++) {
      if(!j[c][hi].is_array() || j[c][hi].size() != (size_t)w) {
        throw runtime_error("spatial_input row must have W elements");
      }
      for(int wi = 0; wi < w; wi++) {
        spatial[c * h * w + hi * w + wi] = j[c][hi][wi].get<float>();
      }
    }
  }

  return spatial;
}

// Parse global input from JSON
static vector<float> parseGlobalInput(const json& j, int& numChannels) {
  if(!j.is_array()) {
    throw runtime_error("global_input must be an array");
  }

  numChannels = j.size();
  vector<float> global(numChannels);

  for(int i = 0; i < numChannels; i++) {
    global[i] = j[i].get<float>();
  }

  return global;
}

// Parse mask from JSON
static vector<float> parseMask(const json& j) {
  if(!j.is_array() || j.size() != BOARD_SIZE) {
    throw runtime_error("input_mask must be 19x19 array");
  }

  vector<float> mask(BOARD_SIZE * BOARD_SIZE);

  for(int hi = 0; hi < BOARD_SIZE; hi++) {
    if(!j[hi].is_array() || j[hi].size() != BOARD_SIZE) {
      throw runtime_error("input_mask row must have 19 elements");
    }
    for(int wi = 0; wi < BOARD_SIZE; wi++) {
      mask[hi * BOARD_SIZE + wi] = j[hi][wi].get<float>();
    }
  }

  return mask;
}

// Convert 3D array to JSON (NCHW format)
static json arrayToJson3D(const float* data, int c, int h, int w) {
  json result = json::array();
  for(int ci = 0; ci < c; ci++) {
    json channel = json::array();
    for(int hi = 0; hi < h; hi++) {
      json row = json::array();
      for(int wi = 0; wi < w; wi++) {
        row.push_back(data[ci * h * w + hi * w + wi]);
      }
      channel.push_back(row);
    }
    result.push_back(channel);
  }
  return result;
}

// Convert 2D array to JSON
static json arrayToJson2D(const float* data, int h, int w) {
  json result = json::array();
  for(int hi = 0; hi < h; hi++) {
    json row = json::array();
    for(int wi = 0; wi < w; wi++) {
      row.push_back(data[hi * w + wi]);
    }
    result.push_back(row);
  }
  return result;
}

// Convert 1D array to JSON
static json arrayToJson1D(const float* data, int n) {
  json result = json::array();
  for(int i = 0; i < n; i++) {
    result.push_back(data[i]);
  }
  return result;
}

int main(int argc, char** argv) {
  if(argc != 3) {
    cerr << "Usage: " << argv[0] << " <model.bin.gz> <input.json>" << endl;
    return 1;
  }

  string modelPath = argv[1];
  string inputPath = argv[2];

  try {
    // Initialize neural net backend
    NeuralNet::globalInitialize();

    // Load input JSON
    ifstream inputFile(inputPath);
    if(!inputFile.is_open()) {
      throw runtime_error("Could not open input file: " + inputPath);
    }
    json inputJson;
    inputFile >> inputJson;
    inputFile.close();

    // Parse inputs
    int numSpatialChannels = 0;
    int numGlobalChannels = 0;
    vector<float> spatialNchw = parseSpatialInput(inputJson["spatial_input"], numSpatialChannels);
    vector<float> globalInput = parseGlobalInput(inputJson["global_input"], numGlobalChannels);
    vector<float> maskInput = parseMask(inputJson["input_mask"]);

    // Convert spatial to NHWC for Eigen backend
    vector<float> spatialNhwc = nchwToNhwc(spatialNchw, numSpatialChannels, BOARD_SIZE, BOARD_SIZE);

    // Load model
    LoadedModel* loadedModel = NeuralNet::loadModelFile(modelPath, "");
    const ModelDesc& modelDesc = NeuralNet::getModelDesc(loadedModel);

    // Verify input dimensions
    if(modelDesc.numInputChannels != numSpatialChannels) {
      cerr << "Warning: Model expects " << modelDesc.numInputChannels
           << " spatial channels but input has " << numSpatialChannels << endl;
    }
    if(modelDesc.numInputGlobalChannels != numGlobalChannels) {
      cerr << "Warning: Model expects " << modelDesc.numInputGlobalChannels
           << " global channels but input has " << numGlobalChannels << endl;
    }

    // Create compute context
    vector<int> gpuIdxs = {-1};  // Use default
    Logger logger(nullptr, false);
    ComputeContext* context = NeuralNet::createComputeContext(
      gpuIdxs,
      &logger,
      BOARD_SIZE,
      BOARD_SIZE,
      "",  // openCLTunerFile
      "",  // homeDataDirOverride
      false,  // openCLReTunePerBoardSize
      enabled_t::Auto,  // useFP16Mode
      enabled_t::Auto,  // useNHWCMode
      loadedModel
    );

    // Create compute handle
    const int maxBatchSize = 1;
    const bool requireExactNNLen = true;
    const bool inputsUseNHWC = true;  // Eigen backend uses NHWC
    ComputeHandle* handle = NeuralNet::createComputeHandle(
      context,
      loadedModel,
      &logger,
      maxBatchSize,
      requireExactNNLen,
      inputsUseNHWC,
      -1,  // gpuIdxForThisThread
      0    // serverThreadIdx
    );

    // Create input/output buffers
    InputBuffers* inputBuffers = NeuralNet::createInputBuffers(loadedModel, maxBatchSize, BOARD_SIZE, BOARD_SIZE);

    // Fill input buffers
    // Note: This is a simplified approach - real input filling uses NNInputs::fillRowV*
    // For validation purposes, we directly inject the input values

    // Get buffer pointers
    float* spatialBuf = inputBuffers->spatialInput.data();
    float* globalBuf = inputBuffers->globalInput.data();

    // Copy spatial input (already in NHWC format)
    memcpy(spatialBuf, spatialNhwc.data(), spatialNhwc.size() * sizeof(float));

    // Copy global input
    memcpy(globalBuf, globalInput.data(), globalInput.size() * sizeof(float));

    // Create NNOutput to receive results
    NNOutput output;
    output.nnXLen = BOARD_SIZE;
    output.nnYLen = BOARD_SIZE;
    output.whiteOwnerMap = new float[BOARD_SIZE * BOARD_SIZE];

    // Create result buffer
    NNResultBuf resultBuf;
    resultBuf.result = make_shared<NNOutput>(output);
    resultBuf.hasResult = false;
    resultBuf.includeOwnership = true;

    // Set up input buffer reference
    NNResultBuf* inputBufs[1] = {&resultBuf};
    vector<NNOutput*> outputs = {resultBuf.result.get()};

    // Run inference
    NeuralNet::getOutput(handle, inputBuffers, 1, inputBufs, outputs);

    // Extract raw outputs and format as JSON
    NNOutput* out = outputs[0];

    json outputJson;

    // Policy output - reshape from flat to [numPolicyChannels, H, W]
    int numPolicyChannels = modelDesc.numPolicyChannels;
    int policySize = BOARD_SIZE * BOARD_SIZE;
    vector<float> policyNchw(numPolicyChannels * policySize);

    // The policy output in KataGo is in pos format (flat), we need to reshape
    // For simplicity, treat as single channel board positions
    for(int i = 0; i < policySize; i++) {
      policyNchw[i] = out->policyProbs[i];
    }
    // Fill remaining channels with zeros if multi-channel
    for(int i = policySize; i < numPolicyChannels * policySize; i++) {
      policyNchw[i] = 0.0f;
    }

    outputJson["policy"] = arrayToJson3D(policyNchw.data(), numPolicyChannels, BOARD_SIZE, BOARD_SIZE);

    // Pass policy (last element of policyProbs)
    float passPolicy = out->policyProbs[policySize];  // Position after board
    outputJson["pass_policy"] = json::array({passPolicy});

    // Value output (3 elements: win, loss, no result)
    float valueOutput[3] = {
      out->whiteWinProb,
      out->whiteLossProb,
      out->whiteNoResultProb
    };
    outputJson["value"] = arrayToJson1D(valueOutput, 3);

    // Ownership output [H, W]
    outputJson["ownership"] = arrayToJson2D(out->whiteOwnerMap, BOARD_SIZE, BOARD_SIZE);

    // Score value output (6 elements)
    float scoreValueOutput[6] = {
      out->whiteScoreMean,
      out->whiteScoreMeanSq,
      out->whiteLead,
      out->varTimeLeft,
      out->shorttermWinlossError,
      out->shorttermScoreError
    };
    outputJson["score_value"] = arrayToJson1D(scoreValueOutput, 6);

    // Output JSON to stdout
    cout << outputJson.dump(2) << endl;

    // Cleanup
    delete[] out->whiteOwnerMap;
    NeuralNet::freeInputBuffers(inputBuffers);
    NeuralNet::freeComputeHandle(handle);
    NeuralNet::freeComputeContext(context);
    NeuralNet::freeLoadedModel(loadedModel);
    NeuralNet::globalCleanup();

    return 0;

  } catch(const exception& e) {
    cerr << "Error: " << e.what() << endl;
    NeuralNet::globalCleanup();
    return 1;
  }
}
