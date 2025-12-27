/*
 * validation.cpp
 *
 * Command for cross-validating neural network outputs against Core ML.
 * Reads inputs from JSON file and outputs raw neural network values as JSON.
 *
 * Usage:
 *   katago validation -model <model.bin.gz> -input <input.json>
 *
 * This command is designed for testing and validation purposes only.
 */

#include "../main.h"
#include "../command/commandline.h"
#include "../core/global.h"
#include "../core/fileutils.h"
#include "../game/board.h"
#include "../neuralnet/nninterface.h"
#include "../neuralnet/nneval.h"
#include "../neuralnet/nninputs.h"
#include "../external/nlohmann_json/json.hpp"

#include <fstream>
#include <iostream>

using namespace std;
using json = nlohmann::json;

// Parse spatial input from JSON (NCHW format) and convert to NHWC
static void parseSpatialInput(
  const json& j,
  int numExpectedChannels,
  int boardYSize,
  int boardXSize,
  vector<float>& spatialNhwc
) {
  if(!j.is_array()) {
    throw StringError("spatial_input must be an array");
  }

  int numChannels = (int)j.size();
  if(numChannels != numExpectedChannels) {
    throw StringError("spatial_input has " + to_string(numChannels) +
                      " channels but model expects " + to_string(numExpectedChannels));
  }

  int h = boardYSize;
  int w = boardXSize;
  spatialNhwc.resize(h * w * numChannels);

  // Read NCHW and convert to NHWC
  for(int c = 0; c < numChannels; c++) {
    if(!j[c].is_array() || (int)j[c].size() != h) {
      throw StringError("spatial_input channel must be HxW array");
    }
    for(int hi = 0; hi < h; hi++) {
      if(!j[c][hi].is_array() || (int)j[c][hi].size() != w) {
        throw StringError("spatial_input row must have W elements");
      }
      for(int wi = 0; wi < w; wi++) {
        // NHWC indexing: [hi * w * c + wi * c + ci]
        spatialNhwc[hi * w * numChannels + wi * numChannels + c] = j[c][hi][wi].get<float>();
      }
    }
  }
}

// Parse global input from JSON
static void parseGlobalInput(
  const json& j,
  int numExpectedChannels,
  vector<float>& globalInput
) {
  if(!j.is_array()) {
    throw StringError("global_input must be an array");
  }

  int numChannels = (int)j.size();
  if(numChannels != numExpectedChannels) {
    throw StringError("global_input has " + to_string(numChannels) +
                      " channels but model expects " + to_string(numExpectedChannels));
  }

  globalInput.resize(numChannels);
  for(int i = 0; i < numChannels; i++) {
    globalInput[i] = j[i].get<float>();
  }
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

int MainCmds::validation(const vector<string>& args) {
  Board::initHash();
  ScoreValue::initTables();

  string modelFile;
  string inputFile;

  try {
    KataGoCommandLine cmd("Run neural network validation for Core ML comparison.");
    cmd.addModelFileArg();

    TCLAP::ValueArg<string> inputArg(
      "i", "input", "Path to JSON input file", true, "", "FILE"
    );
    cmd.add(inputArg);

    cmd.setShortUsageArgLimit();
    cmd.parseArgs(args);

    modelFile = cmd.getModelFile();
    inputFile = inputArg.getValue();

  } catch(TCLAP::ArgException& e) {
    cerr << "Error: " << e.error() << " for argument " << e.argId() << endl;
    return 1;
  }

  // Load input JSON
  json inputJson;
  try {
    ifstream inFile(inputFile);
    if(!inFile.is_open()) {
      throw StringError("Could not open input file: " + inputFile);
    }
    inFile >> inputJson;
    inFile.close();
  } catch(const json::exception& e) {
    cerr << "JSON parse error: " << e.what() << endl;
    return 1;
  }

  // Parse board dimensions from JSON
  int boardXSize;
  int boardYSize;

  try {
    if(!inputJson.contains("boardXSize") || !inputJson.contains("boardYSize")) {
      throw StringError("Input JSON must contain 'boardXSize' and 'boardYSize' fields");
    }

    boardXSize = inputJson["boardXSize"].get<int>();
    boardYSize = inputJson["boardYSize"].get<int>();

    // Validate board size range
    if(boardXSize < 2 || boardXSize > Board::MAX_LEN ||
       boardYSize < 2 || boardYSize > Board::MAX_LEN) {
      throw StringError("Board size must be between 2 and " + to_string(Board::MAX_LEN) +
                       ", got " + to_string(boardXSize) + "x" + to_string(boardYSize));
    }

    // For now, require square boards (KataGo models are trained on square boards)
    if(boardXSize != boardYSize) {
      throw StringError("Board must be square, got " + to_string(boardXSize) +
                       "x" + to_string(boardYSize));
    }
  } catch(const json::exception& e) {
    cerr << "Board size parse error: " << e.what() << endl;
    return 1;
  } catch(const StringError& e) {
    cerr << "Board size validation error: " << e.what() << endl;
    return 1;
  }

  // Initialize neural net backend
  NeuralNet::globalInitialize();

  // Load model
  LoadedModel* loadedModel = nullptr;
  try {
    loadedModel = NeuralNet::loadModelFile(modelFile, "");
  } catch(const StringError& e) {
    cerr << "Error loading model: " << e.what() << endl;
    NeuralNet::globalCleanup();
    return 1;
  }

  const ModelDesc& modelDesc = NeuralNet::getModelDesc(loadedModel);

  // Get model parameters
  int numSpatialFeatures = modelDesc.numInputChannels;
  int numGlobalFeatures = modelDesc.numInputGlobalChannels;
  int numPolicyChannels = modelDesc.numPolicyChannels;
  int modelVersion = modelDesc.modelVersion;

  // Parse inputs
  vector<float> spatialNhwc;
  vector<float> globalInput;

  try {
    parseSpatialInput(inputJson["spatial_input"], numSpatialFeatures, boardYSize, boardXSize, spatialNhwc);
    parseGlobalInput(inputJson["global_input"], numGlobalFeatures, globalInput);
  } catch(const StringError& e) {
    cerr << "Input parse error: " << e.what() << endl;
    NeuralNet::freeLoadedModel(loadedModel);
    NeuralNet::globalCleanup();
    return 1;
  }

  // Create compute context
  Logger logger(nullptr, false);
  vector<int> gpuIdxs = {-1};  // Use default

  ComputeContext* context = NeuralNet::createComputeContext(
    gpuIdxs,
    &logger,
    boardXSize,
    boardYSize,
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
  InputBuffers* inputBuffers = NeuralNet::createInputBuffers(loadedModel, maxBatchSize, boardXSize, boardYSize);

  // Create NNResultBuf and fill with our custom inputs
  NNResultBuf resultBuf;
  resultBuf.rowSpatialBuf = spatialNhwc;
  resultBuf.rowGlobalBuf = globalInput;
  resultBuf.hasRowMeta = false;
  resultBuf.symmetry = 0;  // No symmetry transformation
  resultBuf.policyOptimism = 0.0;
  resultBuf.includeOwnerMap = true;
  resultBuf.boardXSizeForServer = boardXSize;
  resultBuf.boardYSizeForServer = boardYSize;

  // Create NNOutput to receive results
  NNOutput output;
  output.nnXLen = boardXSize;
  output.nnYLen = boardYSize;
  output.whiteOwnerMap = new float[boardXSize * boardYSize];

  // Set up pointers for batch processing
  NNResultBuf* inputBufs[1] = {&resultBuf};
  vector<NNOutput*> outputs = {&output};

  // Run inference
  NeuralNet::getOutput(handle, inputBuffers, 1, inputBufs, outputs);

  // Build output JSON with raw values
  json outputJson;

  // Policy output (board positions)
  // The policyProbs array contains log-probabilities (logits)
  // We output them in 2D format [H, W]
  int policySize = boardXSize * boardYSize;
  vector<float> policyBoard(policySize);
  for(int i = 0; i < policySize; i++) {
    policyBoard[i] = output.policyProbs[i];
  }
  outputJson["policy"] = arrayToJson2D(policyBoard.data(), boardYSize, boardXSize);

  // Pass policy (single value)
  float passPolicy = output.policyProbs[policySize];
  outputJson["pass_policy"] = json::array({passPolicy});

  // Value output (3 elements: win, loss, no result)
  // Note: These are raw logits from the perspective of the player to move
  float valueOutput[3] = {
    output.whiteWinProb,
    output.whiteLossProb,
    output.whiteNoResultProb
  };
  outputJson["value"] = arrayToJson1D(valueOutput, 3);

  // Ownership output [H, W]
  if(output.whiteOwnerMap != nullptr) {
    outputJson["ownership"] = arrayToJson2D(output.whiteOwnerMap, boardYSize, boardXSize);
  } else {
    outputJson["ownership"] = json::array();
  }

  // Score value output (6 elements)
  float scoreValueOutput[6] = {
    output.whiteScoreMean,
    output.whiteScoreMeanSq,
    output.whiteLead,
    output.varTimeLeft,
    output.shorttermWinlossError,
    output.shorttermScoreError
  };
  outputJson["score_value"] = arrayToJson1D(scoreValueOutput, 6);

  // Add metadata
  outputJson["model_version"] = modelVersion;
  outputJson["num_spatial_features"] = numSpatialFeatures;
  outputJson["num_global_features"] = numGlobalFeatures;
  outputJson["num_policy_channels"] = numPolicyChannels;

  // Output JSON to stdout
  cout << outputJson.dump(2) << endl;

  // Cleanup
  delete[] output.whiteOwnerMap;
  NeuralNet::freeInputBuffers(inputBuffers);
  NeuralNet::freeComputeHandle(handle);
  NeuralNet::freeComputeContext(context);
  NeuralNet::freeLoadedModel(loadedModel);
  NeuralNet::globalCleanup();

  return 0;
}
