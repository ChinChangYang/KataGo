//
//  main.cpp
//  KataGo Engine Helper (katago-engine)
//
//  Headless KataGo engine spawned as a SUBPROCESS by the macOS app (one per
//  window). It runs the stock upstream GTP loop (`MainCmds::gtp`) on the
//  process's REAL stdin/stdout — no `cin`/`cout` rdbuf redirection like the
//  in-process `KataGoCpp.cpp` bridge does, because each child owns its own
//  standard streams. That is exactly what frees the app's own stdio and lets
//  many engines run concurrently (the basis for multi-window).
//
//  All engine arguments (model/human-model/config paths + `-override-config`
//  device/threads/batch/homeDataDir/tuner flags) are supplied by the parent on
//  argv, mirroring the proven in-process invocation built in `KataGoCpp.cpp`.
//  argv[0] is the executable path; argv[1..] is the GTP sub-command vector
//  (argv[1] == "gtp"), passed straight through to `MainCmds::gtp`.
//
//  `MainCmds::gtp` is provided by the linked `katago.framework` (it exports the
//  symbol). We forward-declare it here so the helper needs no engine headers;
//  the engine's own #ifndef OS_IS_IOS-guarded main() stays compiled out.

#include <string>
#include <vector>

namespace MainCmds {
int gtp(const std::vector<std::string>& args);
}

// Installs the persistent Core ML cache bridge (EngineCoreMLBridge.swift) so the
// MLX backend's ANE path reuses the on-disk cache instead of recompiling Core ML
// to /tmp on every launch. Must run before MainCmds::gtp creates any compute
// handle. The in-process katago_coreml_bridge seam the app installs does NOT
// cross the process boundary, so the subprocess installs its own here.
extern "C" void katago_register_coreml_bridge(void);

int main(int argc, const char* const* argv) {
  katago_register_coreml_bridge();
  std::vector<std::string> args;
  args.reserve(argc > 1 ? static_cast<size_t>(argc - 1) : 0);
  for (int i = 1; i < argc; ++i) {
    args.emplace_back(argv[i]);
  }
  return MainCmds::gtp(args);
}
