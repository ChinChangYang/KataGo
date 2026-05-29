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

#endif // USE_METAL_BACKEND
