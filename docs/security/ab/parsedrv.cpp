// A/B driver for the CoreML converter parser (cpp/external/katagocoreml): parse one model, report the outcome.
#include "parser/KataGoParser.hpp"
#include <cstdio>
#include <exception>
int main(int argc, char** argv) {
  try { katagocoreml::KataGoParser(argv[1]).parse(); std::puts("PARSED-OK"); }
  catch(const std::exception& e) { std::printf("REJECTED: %s\n", e.what()); }
  return 0;
}
