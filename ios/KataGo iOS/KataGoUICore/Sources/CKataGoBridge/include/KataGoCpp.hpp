//
//  KataGoCpp.hpp
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

#ifndef KataGoCpp_hpp
#define KataGoCpp_hpp

#include <string>

using namespace std;

void KataGoRunGtp(string modelPath,
                  string humanModelPath,
                  string configPath,
                  const int* mlxDeviceToUse,
                  int numDevices,
                  int numSearchThreads,
                  int nnMaxBatchSize,
                  int maxBoardSizeForNNBuffer,
                  bool requireExactNNLen,
                  string homeDataDir,
                  bool tunerFull,
                  bool reTune);

/// The message from the last engine launch that ended in an uncaught C++
/// exception, or "" if the last launch exited cleanly. Reading it CLEARS it, so
/// one failure is reported once.
///
/// KataGoRunGtp used to let such an exception unwind past the Swift `Thread`
/// closure and terminate the process: `NNEvaluator`'s constructor throws
/// `StringError` for an unloadable model file (nneval.cpp deliberately carries
/// no try/catch — "we're in big trouble if this raises an exception"), and
/// main.cpp's catch-all is `#if defined(OS_IS_WINDOWS)`. Now the exception is
/// caught at the seam and parked here for the launch site to surface.
string KataGoTakeLastFatalError();

/// Cheap pre-flight check that `path` looks like a KataGo network the engine
/// can load. Returns "" when it does, otherwise a user-facing reason.
///
/// Reads only the DECOMPRESSED HEAD of the file — the model header is
/// whitespace-delimited text in both .bin.gz and .txt.gz, ahead of any binary
/// weight block — so validating an 800 MB network costs a couple of hundred
/// kilobytes of I/O rather than decompressing it whole. Applies the same rules
/// as `ModelDesc`'s constructor, including the version bounds, read from
/// `NNModelVersion` so they cannot drift from the engine.
///
/// This catches the "you picked a JPEG" / "this net needs a newer KataGo"
/// class at import time. It is NOT exhaustive: truncated weights or non-finite
/// parameters only surface at load, which is what KataGoTakeLastFatalError is
/// for.
string KataGoValidateModelFile(string path);

string KataGoGetMessageLine();
string KataGoGetMessageLineTimed(double timeoutSeconds);
void KataGoSendCommand(string command);
void KataGoSendMessage(string message);
void KataGoClearMessages();

#endif /* KataGoCpp_hpp */
