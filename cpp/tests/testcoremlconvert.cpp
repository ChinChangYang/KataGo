#include "../tests/tests.h"

#ifdef USE_METAL_BACKEND

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include <sys/resource.h>
#include <zlib.h>

#include "../core/sha2.h"
#include "katagocoreml/KataGoConverter.hpp"

using namespace std;

namespace {

// (staged for runCoremlConvertPeakMemoryTest)
static size_t peakRssBytes() {
  struct rusage usage;
  if(getrusage(RUSAGE_SELF, &usage) != 0)
    return 0;
  return (size_t)usage.ru_maxrss;
}

static string sha256OfFile(const string& path) {
  ifstream in(path, ios::binary);
  if(!in)
    throw runtime_error("sha256OfFile: cannot open " + path);
  vector<uint8_t> bytes((istreambuf_iterator<char>(in)), istreambuf_iterator<char>());
  char hash[65];
  SHA2::get256(bytes.data(), bytes.size(), hash);
  return string(hash);
}

// (staged for runCoremlConvertPeakMemoryTest)
static size_t gzDecompressedSize(const string& path) {
  gzFile gz = gzopen(path.c_str(), "rb");
  if(!gz)
    throw runtime_error("gzDecompressedSize: cannot open " + path);
  vector<uint8_t> chunk(1024 * 1024);
  size_t total = 0;
  int n;
  while((n = gzread(gz, chunk.data(), (unsigned)chunk.size())) > 0)
    total += (size_t)n;
  if(n < 0) {
    int errnum;
    const char* msg = gzerror(gz, &errnum);
    gzclose(gz);
    throw runtime_error("gzDecompressedSize: read error on " + path + ": " + string(msg));
  }
  gzclose(gz);
  return total;
}

static string convertToTemp(
  const string& modelPath, const string& tag, int boardX, int boardY,
  bool fp16, bool optimizeMask, string& outPackageDir
) {
  outPackageDir = "/tmp/katago_convtest_" + tag + ".mlpackage";
  katagocoreml::ConversionOptions opts;
  opts.board_x_size = boardX;
  opts.board_y_size = boardY;
  opts.compute_precision = fp16 ? "FLOAT16" : "FLOAT32";
  opts.optimize_identity_mask = optimizeMask;
  opts.min_batch_size = 1;
  opts.max_batch_size = 8;
  std::error_code ec;
  std::filesystem::remove_all(outPackageDir, ec);
  katagocoreml::KataGoConverter::convert(modelPath, outPackageDir, opts);
  return outPackageDir + "/Data/com.apple.CoreML/weights/weight.bin";
}

} // namespace

void Tests::runCoremlConvertSmokeTest() {
  cout << "Running runCoremlConvertSmokeTest" << endl;
  const string model = "tests/models/g170-b6c96-s175395328-d26788732.bin.gz";
  string pkg;
  string weightBin = convertToTemp(model, "smoke", 19, 19, true, false, pkg);
  ifstream check(weightBin, ios::binary);
  testAssert(check.good());
  cout << "  weight.bin sha256 = " << sha256OfFile(weightBin) << endl;
  cout << "runCoremlConvertSmokeTest passed" << endl;
}

void Tests::runCoremlConvertCrossFormatTest() {
  cout << "Running runCoremlConvertCrossFormatTest" << endl;
  const string binModel = "tests/models/g170-b6c96-s175395328-d26788732.bin.gz";
  const string txtModel = "tests/models/g170-b6c96-s175395328-d26788732.txt.gz";
  // Full matrix: precision x board size x optimize_identity_mask. For identical
  // options, the binary-stream parser and the text parser must agree exactly.
  for(bool fp16 : {true, false}) {
    for(auto bs : { std::pair<int,int>{19, 19}, std::pair<int,int>{9, 9} }) {
      for(bool mask : {false, true}) {
        string tag = string(fp16 ? "fp16" : "fp32") + "_" + to_string(bs.first)
                   + "_" + (mask ? "mask" : "nomask");
        string binPkg, txtPkg;
        string binWeights = convertToTemp(binModel, "xfmt_bin_" + tag, bs.first, bs.second, fp16, mask, binPkg);
        string txtWeights = convertToTemp(txtModel, "xfmt_txt_" + tag, bs.first, bs.second, fp16, mask, txtPkg);
        string binHash = sha256OfFile(binWeights);
        string txtHash = sha256OfFile(txtWeights);
        cout << "  " << tag << ": bin=" << binHash << " txt=" << txtHash << endl;
        testAssert(binHash == txtHash);
      }
    }
  }
  cout << "runCoremlConvertCrossFormatTest passed" << endl;
}

void Tests::runCoremlConvertDeterminismTest() {
  cout << "Running runCoremlConvertDeterminismTest" << endl;
  const string model = "tests/models/g170e-b10c128-s1141046784-d204142634.bin.gz";
  string pkgA, pkgB;
  string a = convertToTemp(model, "det_a", 19, 19, true, false, pkgA);
  string b = convertToTemp(model, "det_b", 19, 19, true, false, pkgB);
  testAssert(sha256OfFile(a) == sha256OfFile(b));
  cout << "runCoremlConvertDeterminismTest passed" << endl;
}

void Tests::runCoremlConvertGoldenTest() {
  cout << "Running runCoremlConvertGoldenTest" << endl;
  // Golden hashes from the converter for g170-b6c96, FP16, 19x19,
  // optimize_identity_mask=false. model.mlmodel is byte-stable thanks to
  // deterministic protobuf serialization. DO NOT bump katagocoreml VERSION.
  const string GOLDEN_WEIGHT_SHA = "4dd744f0907d37bf45287ebf765a124c472f61116dc753bdc48fb6ab3a5599d9";
  const string GOLDEN_MODEL_SHA  = "923f7ed7b2eba03eaca58068f3a90195444278e956a4f5f361df6dd75ba23316";

  const string model = "tests/models/g170-b6c96-s175395328-d26788732.bin.gz";
  string pkg;
  string weightBin = convertToTemp(model, "golden", 19, 19, true, false, pkg);
  string modelSpec = pkg + "/Data/com.apple.CoreML/model.mlmodel";

  string weightSha = sha256OfFile(weightBin);
  string modelSha = sha256OfFile(modelSpec);
  cout << "  weight.bin sha256 = " << weightSha << endl;
  cout << "  model.mlmodel sha256 = " << modelSha << endl;

  testAssert(weightSha == GOLDEN_WEIGHT_SHA);
  testAssert(modelSha == GOLDEN_MODEL_SHA);
  cout << "runCoremlConvertGoldenTest passed" << endl;
}

#endif // USE_METAL_BACKEND
