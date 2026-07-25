//
//  KataGoCpp.cpp
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

#include "KataGoCpp.hpp"

#include <chrono>

// Resolved via the `cpp/` header search path injected in Package.swift
// (cxxSettings -I). Was a `../../../cpp/main.h` relative include when these
// sources lived in the KataGoInterface framework target.
#include "main.h"

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
    // sync — uflow() is the only other reader, and no caller mixes the two.
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
    MainCmds::gtp(subArgs);
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
