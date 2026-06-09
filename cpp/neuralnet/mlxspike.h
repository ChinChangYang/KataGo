#ifndef NEURALNET_MLXSPIKE_H_
#define NEURALNET_MLXSPIKE_H_

// Throwaway Phase-0 spike: returns 5.0 if MLX's C++ API compiles, links, and
// evaluates (JIT Metal kernel) inside the katago framework. Remove with the
// spike branch.
extern "C" double mlxSpikeSelfTest();

#endif  // NEURALNET_MLXSPIKE_H_
