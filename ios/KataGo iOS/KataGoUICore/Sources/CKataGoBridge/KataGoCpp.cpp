//
//  KataGoCpp.cpp
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

#include "KataGoCpp.hpp"

#include <chrono>
#include <fstream>
#include <mutex>
#include <sstream>

#include <zlib.h>

// Resolved via the `cpp/` header search path injected in Package.swift
// (cxxSettings -I). Was a `../../../cpp/main.h` relative include when these
// sources lived in the KataGoInterface framework target.
#include "main.h"
#include "core/global.h"
#include "neuralnet/modelversion.h"

using namespace std;

// Thread-safe stream buffer
class ThreadSafeStreamBuf : public std::streambuf {
    std::string buffer;
    std::mutex m;
    std::condition_variable cv;
    std::atomic<bool> done {false};

public:
    int overflow(int c) override {
        std::lock_guard<std::mutex> lock(m);
        buffer += static_cast<char>(c);
        if (c == '\n') {
            cv.notify_all();
        }
        return c;
    }

    int underflow() override {
        std::unique_lock<std::mutex> lock(m);
        cv.wait(lock, [&]{ return !buffer.empty() || done; });
        if (buffer.empty()) {
            return std::char_traits<char>::eof();
        }
        return buffer.front();
    }

    int uflow() override {
        std::unique_lock<std::mutex> lock(m);
        cv.wait(lock, [&]{ return !buffer.empty() || done; });
        if (buffer.empty()) {
            return std::char_traits<char>::eof();
        }
        int c = buffer.front();
        buffer.erase(buffer.begin());
        return c;
    }

    void setDone() {
        done = true;
        cv.notify_all();
    }

    // Read one '\n'-terminated line, waiting at most `timeoutSeconds` for one to
    // arrive. Returns false — leaving any partial text buffered for the next
    // call — when the deadline passes with no complete line available.
    //
    // uflow()/underflow() above wait on `cv` with NO deadline, and setDone() is
    // never called on the in-process bridge (it never reaches EOF), so a caller
    // blocked in getline() when the engine goes silent stays blocked forever.
    // That is fine for the app, which drives a live engine from a dedicated
    // read loop, but fatal in an app extension: one wedged read leaves the
    // Safari panel permanently mid-request with no way to recover. Callers that
    // must honor their own deadline read through here instead.
    //
    // Reads the buffer directly rather than through the istream. Safe because
    // this streambuf never calls setg(), so there is no get area to keep in
    // sync: uflow() consumes exactly the characters getline() asks for and
    // never reads ahead, so it can strand nothing here for this reader to lose,
    // and vice versa. Both take the same mutex.
    //
    // The app DOES use both, in different phases: the engine handshake reads
    // through here (so it can give up on an engine that never answers instead
    // of parking a reader on the process-global buffer, where it would eat the
    // next engine's `version` reply), and the steady-state message loop reads
    // through getline(). They never run at the same time — the handshake is the
    // sole reader by construction, and every host parks its read loop across a
    // relaunch.
    bool readLine(std::string& out, double timeoutSeconds) {
        std::unique_lock<std::mutex> lock(m);
        const auto deadline = std::chrono::steady_clock::now()
            + std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double>(timeoutSeconds));
        cv.wait_until(lock, deadline, [&]{
            return done || buffer.find('\n') != std::string::npos;
        });
        const auto newline = buffer.find('\n');
        if (newline == std::string::npos) {
            return false;
        }
        out.assign(buffer, 0, newline);
        buffer.erase(0, newline + 1);
        return true;
    }

    // Drop any buffered, not-yet-read bytes. Used to discard stale output left
    // in this process-global buffer by a prior engine run before a fresh
    // handshake. `done` is intentionally NOT reset: setDone() is never called on
    // the in-process bridge (it never reaches EOF), so it stays false here.
    void clear() {
        std::lock_guard<std::mutex> lock(m);
        buffer.clear();
    }
};

// Thread-safe stream buffer from KataGo
ThreadSafeStreamBuf tsbFromKataGo;

// Input stream from KataGo
istream inFromKataGo(&tsbFromKataGo);

// Thread-safe stream buffer to KataGo
ThreadSafeStreamBuf tsbToKataGo;

// Output stream to KataGo
ostream outToKataGo(&tsbToKataGo);

// ---- Fatal-error channel ---------------------------------------------------
//
// Written by KataGoRunGtp's catch, drained by KataGoTakeLastFatalError. A plain
// mutex-guarded string rather than the message stream: the engine's output
// buffer is drained by a read loop that has already stopped by the time a
// launch fails, so anything written there would be lost.

namespace {

std::mutex fatalErrorMutex;
std::string lastFatalError;

void setLastFatalError(const std::string& message) {
    std::lock_guard<std::mutex> lock(fatalErrorMutex);
    lastFatalError = message;
}

}  // namespace

string KataGoTakeLastFatalError() {
    std::lock_guard<std::mutex> lock(fatalErrorMutex);
    string out = lastFatalError;
    lastFatalError.clear();
    return out;
}

// ---- Model-file validation -------------------------------------------------

namespace {

// Fills `out` with up to `maxOut` bytes of the model file's DECOMPRESSED head,
// inflating gzip input with zlib's gzip-aware window (15 + 32 — the same one
// FileUtils uses). Deliberately feeds inflate a truncated slice of the archive
// and stops as soon as the head is full: the caller only needs the leading
// header tokens, and reading an 800 MB network whole to check its version would
// defeat the point.
bool readModelHead(const string& path, bool gzipped, size_t maxOut, string& out) {
    std::ifstream in(path, std::ios::binary);
    if(!in)
        return false;

    if(!gzipped) {
        out.resize(maxOut);
        in.read(&out[0], (std::streamsize)maxOut);
        out.resize((size_t)in.gcount());
        return !out.empty();
    }

    // 256 KB of compressed input inflates to far more than `maxOut` for this
    // data (the head is text, and the weight block that follows it is dense).
    string compressed;
    compressed.resize(1 << 18);
    in.read(&compressed[0], (std::streamsize)compressed.size());
    compressed.resize((size_t)in.gcount());
    if(compressed.empty())
        return false;

    z_stream zs;
    zs.zalloc = Z_NULL;
    zs.zfree = Z_NULL;
    zs.opaque = Z_NULL;
    zs.avail_in = 0;
    zs.next_in = Z_NULL;
    if(inflateInit2(&zs, 15 + 32) != Z_OK) {
        (void)inflateEnd(&zs);
        return false;
    }

    out.resize(maxOut);
    zs.next_in = (Bytef*)compressed.data();
    zs.avail_in = (uInt)compressed.size();
    zs.next_out = (Bytef*)&out[0];
    zs.avail_out = (uInt)maxOut;
    const int zret = inflate(&zs, Z_NO_FLUSH);
    const size_t produced = maxOut - zs.avail_out;
    (void)inflateEnd(&zs);

    // Z_OK (output filled), Z_BUF_ERROR (input ran out) and Z_STREAM_END (a
    // small file that fit entirely) are all expected here — only a genuine
    // format error that produced nothing means "this is not a gzip archive".
    if(produced == 0 || zret == Z_DATA_ERROR || zret == Z_MEM_ERROR || zret == Z_NEED_DICT)
        return false;
    out.resize(produced);
    return true;
}

}  // namespace

string KataGoValidateModelFile(string path) {
    const string lower = Global::toLower(path);
    const bool isGz = Global::isSuffix(lower, ".gz");
    const bool isPlain = Global::isSuffix(lower, ".txt") || Global::isSuffix(lower, ".bin");
    if(!isGz && !isPlain)
        return "A network file must end with .bin.gz, .txt.gz, .bin or .txt. "
               "This does not look like a KataGo network.";

    string head;
    if(!readModelHead(path, isGz, 1 << 13, head))
        return isGz ? "This file could not be read as a gzip archive. "
                      "It is probably not a KataGo network."
                    : "This file could not be read.";

    // The header is whitespace-delimited text in every model format, ahead of
    // any binary weight block, so an istringstream over the head reads it the
    // same way ModelDesc's constructor does.
    std::istringstream in(head);
    string name;
    int modelVersion = -1;
    in >> name;
    in >> modelVersion;
    if(in.fail())
        return "No network name and version could be read from this file. "
               "It is probably not a KataGo network.";

    // ModelDesc's own name rules — the name is embedded in cache filenames.
    if(name.size() > 96)
        return "This file's network name is too long to be a KataGo network.";
    for(char c : name) {
        const bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                        (c >= '0' && c <= '9') || c == '_' || c == '-';
        if(!ok)
            return "This file does not start with a valid KataGo network name.";
    }

    // Version bounds read from NNModelVersion so they track the engine.
    if(modelVersion < 0)
        return "This file reports an invalid network version. "
               "It is probably not a KataGo network.";
    if(modelVersion < NNModelVersion::oldestModelVersionImplemented)
        return "This network is from an extremely old version of KataGo and is "
               "no longer supported (version " + Global::intToString(modelVersion) + ").";
    if(modelVersion > NNModelVersion::latestModelVersionImplemented)
        return "This network needs a newer version of KataGo than this app "
               "includes (version " + Global::intToString(modelVersion) + ").";

    // Two more header fields, purely as corroboration that we really are inside
    // a model header rather than a text file that happens to start plausibly.
    int numInputChannels = 0;
    int numInputGlobalChannels = 0;
    in >> numInputChannels;
    in >> numInputGlobalChannels;
    if(in.fail() || numInputChannels <= 0 || numInputGlobalChannels <= 0)
        return "This file's network header is incomplete or malformed.";

    return "";
}

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
                  bool reTune) {
    // Replace the global cout object with the custom one
    cout.rdbuf(&tsbFromKataGo);

    // Replace the global cin object with the custom one
    cin.rdbuf(&tsbToKataGo);

    vector<string> subArgs;

    // Call the main command gtp
    subArgs.push_back(string("gtp"));
    subArgs.push_back(string("-model"));
    subArgs.push_back(modelPath);
    subArgs.push_back(string("-human-model"));
    subArgs.push_back(humanModelPath);
    subArgs.push_back(string("-config"));
    subArgs.push_back(configPath);
    // Fixed GPU+ANE inference mux: one device code per NN server thread
    // (0 = MLX/GPU, 100 = CoreML/ANE). setup.cpp reads numNNServerThreadsPerModel
    // then mlxDeviceToUseThread<i> per thread. This MUST match the override order
    // KataGoEngineArguments.gtp builds (the macOS IPC contract test is the
    // executable spec): numNNServerThreadsPerModel, then per-thread devices, then
    // mlxUseFP16. The pointer is consumed synchronously here, before MainCmds::gtp.
    subArgs.push_back(string("-override-config numNNServerThreadsPerModel=") + to_string(numDevices));
    for (int i = 0; i < numDevices; i++) {
        subArgs.push_back(string("-override-config mlxDeviceToUseThread") + to_string(i) +
                          "=" + to_string(mlxDeviceToUse[i]));
    }
    subArgs.push_back(string("-override-config mlxUseFP16=true"));
    subArgs.push_back(string("-override-config numSearchThreads=") + to_string(numSearchThreads));
    subArgs.push_back(string("-override-config nnMaxBatchSize=") + to_string(nnMaxBatchSize));
    subArgs.push_back(string("-override-config maxBoardSizeForNNBuffer=") + to_string(maxBoardSizeForNNBuffer));
    subArgs.push_back(string("-override-config requireMaxBoardSize=") + (requireExactNNLen ? "true" : "false"));
    // iOS/visionOS: the app's sandbox container root is not writable, so the
    // default ~/.katago home-data dir cannot be created and the MLX/GPU
    // Winograd autotuner aborts (HomeData::getHomeDataDir -> MakeDir::make
    // throws on an uncaught NN-server thread). Point homeDataDir at a writable,
    // app-created location instead. Empty on macOS, whose sandbox container
    // root is writable, so the default ~/.katago path already works there.
    if(!homeDataDir.empty())
        subArgs.push_back(string("-override-config homeDataDir=") + homeDataDir);
    // MLX/GPU Winograd autotuner controls from the app's tuning UI. mlxbackend's
    // createComputeContext reads these; the MLX/GPU ComputeHandle ctor passes
    // them to loadOrAutoTune. tunerFull=true -> wide grid (slow, distinct cache
    // file); reTune=true -> force a fresh tune that overwrites the cache. Always
    // pushed so the keys are present (and marked used) regardless of value; the
    // ANE/CoreML path ignores them.
    subArgs.push_back(string("-override-config mlxTunerFull=") + (tunerFull ? "true" : "false"));
    subArgs.push_back(string("-override-config mlxReTune=") + (reTune ? "true" : "false"));

    // Every throwing path out of the engine ends here. The model file is read
    // by NNEvaluator's CONSTRUCTOR (nneval.cpp: `loadedModel =
    // NeuralNet::loadModelFile(...)`), which runs on THIS thread via
    // Setup::initializeNNEvaluator — so a malformed, truncated or
    // wrong-version network throws right here rather than on an NN server
    // thread, and this catch genuinely sees it. Without it the exception
    // unwinds into the Swift `Thread` closure that called us and reaches
    // std::terminate: nneval.cpp carries no try/catch by design, and main.cpp's
    // catch-all is `#if defined(OS_IS_WINDOWS)`.
    //
    // Returning normally instead lets the Swift launch seam unwind its state
    // and fall back to the model picker, with KataGoTakeLastFatalError
    // supplying the reason. Jetsam/OOM is NOT an exception and is unaffected —
    // the crash sentinel still owns that case.
    try {
        MainCmds::gtp(subArgs);
    }
    catch(const std::exception& e) {
        setLastFatalError(e.what());
    }
    catch(...) {
        setLastFatalError("The engine stopped with an unknown error.");
    }
}

string KataGoGetMessageLine() {
    // Get a line from the input stream from KataGo
    string cppLine;
    getline(inFromKataGo, cppLine);

    return cppLine;
}

string KataGoGetMessageLineTimed(double timeoutSeconds) {
    // Bounded counterpart to KataGoGetMessageLine, for callers that must stay
    // responsive when the engine produces nothing (see readLine).
    //
    // A timeout yields "" — deliberately indistinguishable from a genuine blank
    // line, because every caller treats both the same way: keep reading until
    // your OWN deadline. GTP emits a blank line after each response, so blank
    // lines are ordinary traffic, not a signal.
    string cppLine;
    if (!tsbFromKataGo.readLine(cppLine, timeoutSeconds)) {
        return string();
    }

    return cppLine;
}

void KataGoSendCommand(string command) {
    // Write GTP commands to the outToKataGo
    outToKataGo << command << endl;
}

void KataGoSendMessage(string message) {
    cout << message;
}

void KataGoClearMessages() {
    // Drop stale, not-yet-read output (the read side that KataGoGetMessageLine
    // drains) left over from a prior engine run. Only the read-side buffer is
    // cleared; the write side (tsbToKataGo) is drained by the engine itself.
    tsbFromKataGo.clear();
}
