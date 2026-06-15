//
//  KataGoCpp.cpp
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

#include "KataGoCpp.hpp"

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
                  int mlxDeviceToUse,
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
    subArgs.push_back(string("-override-config mlxDeviceToUseThread0=") + to_string(mlxDeviceToUse));
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

void KataGoSendCommand(string command) {
    // Write GTP commands to the outToKataGo
    outToKataGo << command << endl;
}

void KataGoSendMessage(string message) {
    cout << message;
}
