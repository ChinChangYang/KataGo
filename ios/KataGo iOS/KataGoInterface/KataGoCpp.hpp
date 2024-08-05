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

void KataGoRunGtp(string modelPath, string humanModelPath, string configPath);
string KataGoGetMessageLine();
void KataGoSendCommand(string command);

#endif /* KataGoCpp_hpp */