//
//  KataGoCpp.cpp
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

#include "KataGoCpp.hpp"

#include "../../../cpp/main.h"
#include "../../../cpp/neuralnet/coremlbackend.h"

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
                  string coremlModelPath,
                  string humanCoremlModelPath,
                  string configPath,
                  int coremlDeviceToUse,
                  int gtpForceNNSize,
                  int numSearchThreads,
                  int nnMaxBatchSize) {
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
    subArgs.push_back(string("-coreml-model"));
    subArgs.push_back(coremlModelPath);
    subArgs.push_back(string("-human-coreml-model"));
    subArgs.push_back(humanCoremlModelPath);
    subArgs.push_back(string("-config"));
    subArgs.push_back(configPath);
    subArgs.push_back(string("-override-config coremlDeviceToUse=") + to_string(coremlDeviceToUse));

    if (gtpForceNNSize > 0) {
        subArgs.push_back(string("-override-config gtpForceNNSize=") + to_string(gtpForceNNSize));
    }

    subArgs.push_back(string("-override-config numSearchThreads=") + to_string(numSearchThreads));
    subArgs.push_back(string("-override-config nnMaxBatchSize=") + to_string(nnMaxBatchSize));
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
