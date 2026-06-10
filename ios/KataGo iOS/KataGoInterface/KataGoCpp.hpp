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
                  int metalDeviceToUse,
                  int numSearchThreads,
                  int nnMaxBatchSize,
                  int maxBoardSizeForNNBuffer,
                  bool requireExactNNLen,
                  string homeDataDir,
                  bool tunerFull,
                  bool reTune);

string KataGoGetMessageLine();
void KataGoSendCommand(string command);
void KataGoSendMessage(string message);

#endif /* KataGoCpp_hpp */
