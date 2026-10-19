// PROTOTYPE (wayfinder #36), throwaway.
// usage: mlpackage_cli <model.bin.gz> <out.mlpackage> <boardLen> <FLOAT16|FLOAT32> <maxBatch> [optimizeMask=0]
#include "katagocoreml/KataGoConverter.hpp"
#include <cstdlib>
#include <iostream>

int main(int argc, char** argv) {
  if(argc < 6) {
    std::cerr << "usage: mlpackage_cli <model.bin.gz> <out.mlpackage> <boardLen> <FLOAT16|FLOAT32> <maxBatch> [optimizeMask]\n";
    return 2;
  }
  katagocoreml::ConversionOptions opts;
  opts.board_x_size = opts.board_y_size = std::atoi(argv[3]);
  opts.compute_precision = argv[4];
  opts.min_batch_size = 1;
  opts.max_batch_size = std::atoi(argv[5]);
  opts.optimize_identity_mask = argc > 6 && std::atoi(argv[6]) != 0;
  opts.author = "KataGo";
  opts.license = "See original model file for license terms";
  katagocoreml::KataGoConverter::convert(argv[1], argv[2], opts);
  std::cout << "wrote " << argv[2] << "\n";
  return 0;
}
